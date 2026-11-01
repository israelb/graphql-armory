# Authorization

Pundit or CanCanCan policies for graphql-ruby, declared once on your types and enforced on every path.

## The problem

graphql-ruby leaves authorization to you. Each type needs an `authorized?` method, each list a `scope_items`, each `loads:` its own check, and nothing tells you which ones you forgot. One forgotten type is enough for user A to read user B's invoice by its ID (an IDOR), through a root field, a nested association, a list, or an argument that loads a record. And an error that says "not allowed" instead of "not found" tells an attacker the record exists.

## The solution

graphql-armory plugs your existing policies into graphql-ruby's public hooks:

- **Nothing is open by default.** A type or field no rule covers answers `null` (or an error), never data.
- **Lists only contain what the user may see**, including connections: the scope runs before pagination and counting.
- **Lookups by ID cannot leak** (IDOR). A record you may not read and a record that does not exist look identical.
- **An audit tells you what you forgot**, from a rake task or an RSpec matcher, so CI fails instead of production leaking.

## How to use it

Your policies stay plain Pundit. The only new thing is where the rules are declared:

```ruby
class BaseField < GraphQL::Schema::Field
  include GraphQL::Armory::Authorization::Base
end

class BaseObject < GraphQL::Schema::Object
  include GraphQL::Armory::Authorization::Base
  field_class BaseField
  default_action :read          # every type is checked with InvoicePolicy#read?, AccountPolicy#read?...
end

class InvoiceType < BaseObject
  field :number, String, null: false
  field :internal_notes, String, authorize: :manage   # this field asks InvoicePolicy#manage?
end

class QueryType < BaseObject
  authorize :none, reason: "root type; each field declares its own rule"
  field :invoices, [InvoiceType], null: false, authorize: :none, reason: "narrowed by InvoicePolicy::Scope"
end

class AppSchema < GraphQL::Schema
  query QueryType
  use GraphQL::Armory::Authorization, adapter: :pundit
end
```

The actor is `context[:current_user]`; for another key, pass `adapter: GraphQL::Armory::Authorization::Adapters::Pundit.new(user_key: :viewer)`. A complete, tested version lives in [`examples/invoices.rb`](../examples/invoices.rb).

## Rules

| Declaration | Meaning |
|---|---|
| `default_action :read` | Default rule for every type below this base class. |
| `authorize :manage` | This type is checked with `manage?` instead. |
| `authorize :read, model: Invoice` | The model when it is not named like the type. |
| `authorize :read, policy: InvoicePolicy` | Names the policy, instead of finding it from the record. |
| `field ..., authorize: :manage` | The field asks another question of the same policy: the one the class that defines the field names, or else the one found from the record. |
| `authorize :none, reason: "..."` | Explicit bypass. A reason is required and appears in the audit. |

A bypass does not propagate: a field of a bypassed type still needs its own rule, or it is denied. One exception, which the audit names: a field runs under the rule of the class that defines it, so a field a bypassed subclass inherits from a parent with a rule, or from a parent that does not include `Base`, is **served with no check**, because the parent's type check never ran on that record. Give the parent's field its own `authorize:`, or remove it. Redeclaring it on the subclass with `authorize:` protects that field too, but the audit still reports the parent's definition, because a hidden child falls back to it. The same goes for a field whose field class does not include `Base`: graphql-ruby's own `authorized?` answers true, so on a bypassed type it is served.

## What happens on denial

```ruby
use GraphQL::Armory::Authorization, adapter: :pundit, on_unauthorized: :null # default
```

| Mode | Client sees | Use |
|---|---|---|
| `:null` | `null`, no error | Default. Reveals nothing. |
| `:error` | `"Not found"`, code `NOT_FOUND`, identical on every path | When clients need to tell. |
| `:raise` | `NotAuthorizedError` naming only the type | When your app rescues it. |

Denied non-null fields raise the generic "Not found" error, because GraphQL cannot return `null` there (on Execution::Next a denied object in a non-null position answers graphql-ruby's own "Cannot return null for non-nullable field", and `:raise` messages are prefixed with the field path). `find_by:` lookups always answer `null` in every mode: a missing ID cannot raise, and a foreign ID must look the same.

### If your schema defines its own denial hooks

The modes above run in the plugin's `unauthorized_field` and `unauthorized_object`. A method your schema class defines on itself wins over the plugin's, wherever `use` is in the class, so that denial answers whatever your method answers and `on_unauthorized:` does not apply to it. If your method names the field or the type it refused, it confirms to the client that they exist.

The audit reports each one as a `:hook` problem. Remove the method, or call `super` from it and declare it, with your reason:

```ruby
use GraphQL::Armory::Authorization, adapter: :pundit,
  own_denial_hooks: { unauthorized_field: "logs the denial, then calls super" }
```

A declared hook is listed in the audit as a bypass with that reason. The audit cannot read what your method does: the declaration is your word that it reveals nothing. Naming a hook that does not win over the plugin's is also a `:hook` problem. Your own `resolve_type` is not reported: an app with interfaces or unions must define it, and it decides types, not what a denial looks like.

A declared hook that returns `nil` for a non-null field behaves differently per engine: the interpreter answers "Cannot return null", and `Execution::Next` leaves the null with no error. Call `super`, or raise.

**Your own checks on base classes.** The same applies one level down: `Base` is included in your base classes, so a method you define there wins over the plugin's. The audit reports each as an `:own_check` problem, once, where it is defined:

- `authorized?` on a base field, a base argument, a resolver or a mutation, and `self.authorized?` on a type, a base object or an input object. If it does not call `super`, **it skips the rule**: a `BaseMutation#authorized?` that answers `true` runs a mutation the policy refuses.
- `unauthorized_object` on a resolver, a mutation (with or without `Base`), a base field, or `self.unauthorized_object` on an input object. graphql-ruby calls it on whatever loads a record, before the schema's hook. If it returns the object, the code **runs on the record the policy refused**. If it raises, the client sees your message. A foreign id outside the scope never reaches it.
- `authorizes?` on a base field, a resolver, a type or a base object (`self.authorizes?`). On `Execution::Next`, answering `false` means `authorized?` does not run, so the rule is skipped.
- `self.authorized_new` or `self.wrap` on a type. Each decides whether `authorized?` runs, so on the interpreter it can skip the rule.
- `self.scope_items` on a type, a connection, an interface or a union. It replaces the user's scope: a list can hold records the policy's scope excludes, and a connection counts them. Unless reauthorization is off, each record still goes through the rule.
- `reauthorize_scoped_objects(false)`, as a call or as your own method, wherever it is off on an object, interface or union in the schema, reported once on the class that sets it. Your own method is reported whatever it answers, at each level of a chain, because the audit does not run it. It is reported even where it skips nothing today, such as on a type with `authorize :none`, because a declaration costs one line and a wrong guess serves refused records. The interpreter asks the field's return type and `Execution::Next` the resolved object, so check both engines before you declare it: on `Execution::Next` a list of an interface or union applies no scope at all and still skips the rule. graphql-ruby then skips `authorized?` for records that came through the scope, so **a user the rule refuses gets them**, and with your own `scope_items` that includes another account's records. Keep it only when the scope is exactly as strict as the rule, and declare it: `own_checks: { Types::Invoice => { reauthorize_scoped_objects: "the scope is as strict as :read" } }`.
- `visible?` on a type, a field or an argument whose `visible_when:` depends on it. If it does not call `super`, `visible_when:` hides nothing. Elsewhere your own `visible?` is not reported.

Each level of a chain is reported: a method that calls `super` does not hide one below it that answers true, so declare every level you keep.

Methods that come from graphql-ruby or from this gem, in their files and on classes they name, are not reported, so the connection and edge classes of graphql-ruby's install template stay clean.

Remove the method, or make it call `super` and declare it, by the class that defines it and with your reason:

```ruby
use GraphQL::Armory::Authorization, adapter: :pundit,
  own_checks: { Types::BaseMutation => { authorized?: "adds the OTP check, then calls super" } }
```

A declared check is listed as a bypass. Each method is declared on its own, and naming one the schema does not use is an `:own_check` problem. The audit cannot read what your method does: the declaration is your word.

**What the audit does not see.**

- It looks at the classes when it runs, so a method defined later is seen by the next audit.
- A type no definition leads to. The audit follows the schema's roots, `orphan_types` and what each definition references (fields, arguments, interfaces, union members, a connection's node), not filtering by `visible?`, so types hidden with no request and every definition of a duplicated name are audited. A type that only your own `resolve_type` returns, listed nowhere, is not seen.
- A missing action on an argument of an input object, when a plain field takes that input object. It raises at runtime instead of serving.
- A Base resolver on a field class with no `Base`, under a type with a rule: its rule's actions and its arguments are not read. It raises at runtime instead of serving.
- A missing policy action on a field of a bypassed type. The audit does not ask the policy there, so a misspelled action passes it and raises at runtime instead of serving.
- A shadowed definition whose argument names a type that cannot load makes the audit raise `ArgumentError`. A late-bound type that never resolves is skipped instead, with no problem reported.
- `authorize: true` on a field a bypassed type inherits is reported as denied, while the rule of the class that defines it does run: a user it allows gets the data, a user it refuses does not. Trust the rule, not that message.
- Code written to get past it. The audit reads the classes, it does not run your methods: a declared alias of a library method, a class of yours named under `GraphQL::`, or a forged `__FILE__` are not caught. The audit protects against mistakes, not against the app's own code.
- `rescue_from(NotAuthorizedError)`: with `on_unauthorized: :raise`, rescuing is what you are meant to do, so keep that handler's message generic. The interpreter catches field denials there and not object denials, which then raise out of the query; `Execution::Next` catches both.

## Lists, connections and lookups

Lists of a type are narrowed through `InvoicePolicy::Scope` (relations) or by calling the policy per item (arrays). Return a relation when you can: SQL filters before Ruby sees anything.

```ruby
field :invoice, InvoiceType, authorize: :none, reason: "looked up through the scope", find_by: :id do
  argument :id, ID
end

field :invoice_via_ref, InvoiceType, authorize: :none, reason: "loaded through the scope" do
  argument :invoice_id, ID, loads: InvoiceType
end
```

**A rule on a connection or edge class does not run.** graphql-ruby's install template includes `ConnectionBehaviors` and `EdgeBehaviors` in a class that already has `Base`, and they bring an `authorized?` that always answers true. A rule there, declared or inherited, is ignored: a refused user still gets `pageInfo` and any field of the connection itself, while `nodes` stay narrowed. `visible_when:` there is ignored the same way. A direct `Relay::BaseEdge` subclass does run its rule, but only where an edge is built, and the `nodes` field never builds one. The audit reports all of these as `:ignored_rule`.

Put the rule where something answers for it, and declare `authorize :none, reason: "...", covers_fields: true` on the class. A field rule asks the policy of the parent object, so it works on a connection nested under a record. On a root field there is no parent to ask (Pundit raises, CanCanCan refuses everyone), so use a resolver with `authorize :manage, model: Invoice`.

`find_by:` and `loads:` (also inside input objects whose base class includes `Base`) look the record up **inside the user's scope**, so another tenant's ID answers exactly like a missing one. Opt out of the scope for a field's `loads:` only on purpose, with `load_through_scope: false`; the audit lists it. Whoever owns an argument loads it: a field class or a resolver with no `Base` never loads through the scope, whatever the other one includes, and the audit lists its `loads:` too. On `Execution::Next` the opt-out also reaches `loads:` nested in that field's input objects (the interpreter keeps those scoped), and the audit lists them too (`Query.field(filter.invoice_id)`). An input object that overrides `object_from_id` or defines `load_<argument>` itself is honoured on the interpreter and not seen by the audit.

**Global IDs.** When your schema defines `object_from_id` (Relay global IDs), `loads:` decodes the id with it, refuses a record of another model, and looks the record up again inside the scope (one extra query per load). Without `object_from_id`, the id is the primary key. `object_from_id` must return the record itself, not a lazy value: a lazy value is denied. A decoder that raises `ActiveRecord::RecordNotFound` (like `GlobalID.find`), `ArgumentError` (a malformed id) or `GraphQL::Armory::Encoder::InvalidError` (see [encrypted IDs](encrypted-ids.md)) is answered like a missing record; other errors propagate. `loads:` of an interface or union (for example `Types::Node`) raises `ConfigurationError`: load a concrete type. Composite primary keys are not supported.

## The audit

```ruby
GraphQL::Armory::Authorization::Audit.(AppSchema)   # => report with problems
```

```ruby
# spec/schema_spec.rb
require "graphql/armory/authorization/rspec"
expect(AppSchema).to be_fully_authorized
```

```ruby
# Exits 1 when anything is uncovered. In Rails the task loads by itself when the gem is required after Rails, as Bundler does.
# Elsewhere, in the Rakefile:
load "tasks/graphql_armory.rake"
# bundle exec rake "graphql_armory:audit[AppSchema]"
```

**When it runs.** Only when you call it, through one of the three forms above. It never runs when the schema loads or during a request, and it sends nothing to your API's users. Your rules are what protect each request, and they run with or without the audit. The audit is a static check for the team that owns the schema: it reads the classes and tells you where a rule will not run. Put the spec or the rake task in CI, so a change that opens a hole fails the build. Nothing enforces this for you: an app that never runs the audit gets no warning.

**What a pass means.** `report.ok?` means it found none of the problems below, not that every rule is correct: it checks that a rule exists and runs, not that your policy decides well. It also has limits, listed in [What the audit does not see](#if-your-schema-defines-its-own-denial-hooks).

**What it reports.** Each problem has a `kind`, a `path` and a `message`. Every declared bypass is listed apart, with its reason.

| Kind | What it means | What to do |
|---|---|---|
| `:plugin` | The schema never installed the plugin. | Add `use GraphQL::Armory::Authorization, adapter: ...`. |
| `:unprotected` | A base class, or the field class of an interface's field on a bypassed implementer, does not include `Base`, so nothing checks it. | Include `Base`. |
| `:no_rule` | A type, mutation or resolver has no rule, so it is denied to everyone. | Add `authorize` or `default_action`. |
| `:field_without_rule` | A field of a bypassed type has no rule. The message says what really happens: denied, or served with no check (see [Rules](#rules)). | Give the field `authorize:` where it is defined (on the parent, if inherited), or remove it. A field class without `Base` needs one that includes it. |
| `:adapter` | The policy a rule needs does not exist, or lacks the method or the `Scope`. | Add what is missing. |
| `:model` | The model a rule needs cannot be worked out. | Pass `model:`. |
| `:unscoped_load` | A `loads:` goes through `object_from_id` instead of the user's scope. | Let the load use the scope. |
| `:unscoped_list` | A list or connection of records skips the user's scope, with `scope: false`, `connection: false` on a connection type, or a list type graphql-ruby does not detect such as `X.to_list_type`. A rule on each record hides its fields, not how many there are. | Remove the option, or write the type as `[Type]`. |
| `:hook` | The schema's own `unauthorized_field` or `unauthorized_object` wins over the plugin's. | Remove it, or declare it in `own_denial_hooks:`. |
| `:own_check` | Your own method can skip the rule: `authorized?`, `wrap`, `visible?` and others, or `reauthorize_scoped_objects` turned off. | Remove it, or declare it in `own_checks:`. |
| `:ignored_rule` | A rule that does not run, or a field or argument defined more than once. | See [Redefined fields and arguments](#redefined-fields-and-arguments) and [Lists, connections and lookups](#lists-connections-and-lookups). |
| `:foreign_model` | A field rule is defined on an interface or a parent whose model is not this type's, so the policy of this type's model is never asked for that field. A record of another class or a laxer subclass gets past it. Redefine the field on this type with its `authorize:` and an `override_reason:`, or name the same model on the parent. |
| `:foreign_policy` | A type or a Base resolver names a `policy:`, but a rule it uses is defined on an interface, a parent, an input object or a resolver, so that rule asks another policy. A user this type's policy refuses can get the data. A field never sees its resolved type, so this cannot be fixed at runtime. | Move the rule to the class that names the policy and remove the original, or name the `policy:` on the class that defines the rule, if it can hold one: an interface or an input object cannot. There is no declaration for it. |

A declaration (`own_checks:`, `own_denial_hooks:`, `override_reason:`, `authorize :none, reason:`) is your word: the audit stops reporting that problem and lists the reason, so a reviewer can read it. It does not read what your code does. A declaration that names nothing in use is itself a problem.

Upgrading can make an audit that used to pass fail, because the audit reports more: read each new problem instead of declaring it to get the build green.

### Adopting it on a schema with many problems

A first audit of an existing schema can report hundreds of problems. A baseline records them so the build fails only on new ones, while the team works through the list:

```sh
bundle exec rake "graphql_armory:audit_baseline[AppSchema,config/graphql_armory_baseline.json]"   # once; commit the file
bundle exec rake "graphql_armory:audit[AppSchema,config/graphql_armory_baseline.json]"            # in CI
```

```ruby
expect(AppSchema).to be_fully_authorized(baseline: "config/graphql_armory_baseline.json")
```

**A baseline does not protect anything.** The accepted problems are still open, and a refused user may still get that data. `report.ok?` stays false and the output lists every accepted problem under "still open".

| What happens | Result |
|---|---|
| A problem not in the file | Fails, named under "new" |
| An accepted problem whose message changed, for example after an upgrade | Fails as new: read it, then edit the file |
| An accepted problem that grew: a field or a `loads:` added to that type, or a type added under that base class or interface | Fails as new, naming what it now reaches |
| An accepted problem that now appears more times | The extra ones fail as new |
| An accepted problem that is gone | Fails until it leaves the file, so it cannot come back unseen |
| A file that is missing or invalid | Fails: it never runs as if there were no baseline |
| A schema without the plugin | Cannot be accepted: install the plugin first |
| An `:own_check` or a `:hook` problem | Cannot be accepted: whatever uses that method later would pass unseen. Remove it, or declare it in `own_checks:` or `own_denial_hooks:` with a reason, which the audit lists |

Run `audit_baseline` again after fixing problems: on a file that exists it only removes what is gone, and it never adds. To accept a new problem, edit the file by hand, so it shows in the pull request: add its kind, path and message as the output prints them; `count` and `covers` may be left out, and then the entry accepts one problem that reaches nothing, so run `audit_baseline` afterwards to fill them in. The file holds each problem's kind, path, message and count, and the names it reaches (`covers`), and no data of the app. Removing what a problem reaches is fine: running `audit_baseline` narrows the entry.

### Redefined fields and arguments

When a field is hidden from a user, by `visible?` or anything else, and the request carries no visibility profile, graphql-ruby does not answer "no such field": it looks for another definition of that name and serves it. So this rule does not run for a user the child's field is hidden from:

```ruby
class Types::Base < Types::BaseObject
  field :notes, String
end

class Types::Doc < Types::Base
  field :notes, String, authorize: :manage   # hidden: the parent's field answers instead
end
```

A fallback also loses the field's arguments, return type and extensions. Arguments fall back the same way: one redefined on an input object's subclass, on a resolver's subclass, or twice on one owner.

The audit reports every redefinition of a field or argument, over an ancestor, over an interface or on the same owner (`:ignored_rule`), `global_id_field :id` over `Node`'s id included, even with the same rule, because only a request knows whether it gets hidden and what that loses. You have three ways out:

- Remove one of the definitions.
- Use `Schema::Visibility, dynamic: true`, with no `profiles:`. graphql-ruby skips the fallback to an ancestor only for a request that carries a visibility profile; a static profile runs with a plain Hash and still falls back, and the audit knows the difference. Two definitions on one owner fall back to each other under any profile, so they are always reported.
- Declare it, with `override_reason:`. It is listed as a bypass, and one with nothing to declare is a problem. A declared override still falls back, so the definition it shadows is audited like any other.

```ruby
field :notes, String, authorize: :manage, override_reason: "the parent's field is as strict"
argument :internal, Boolean, required: false, authorize: :manage, override_reason: "the parent's argument is as strict"
global_id_field :id, override_reason: "Node's id answers the same"   # on a type that implements Node, once per type, on a field class that includes Base
```

## CanCanCan

Same schema, different adapter. Your types and fields do not change:

```ruby
use GraphQL::Armory::Authorization, adapter: :cancan
```

The actor is `context[:current_ability]` (it wins over `current_user`), or `Ability.new(context[:current_user])` (`user_key:` names another key; pass `Adapters::CanCan.new(ability_class: MyAbility)` for another class). It is built once per query.

| Question | CanCanCan call |
|---|---|
| Can this object be seen? | `ability.can?(:read, object)` |
| Can this field be seen? | `ability.can?(:manage, object, :internal_notes)` for a field that declares `authorize: :manage`: the attribute is passed, because `can :read, User, [:username]` makes `can?(:read, user)` true for the whole object |
| Which items of a list? | `Model.accessible_by(ability, :read)`, still a paginable relation; Arrays are filtered with `can?` |

**Block-only rules.** `can(:read, Invoice) { |i| ... }` cannot be turned into SQL, so `accessible_by` fails. The adapter raises `MissingScopeError` instead of guessing. To accept the cost, declare it on the type: `authorize :read, scope: :in_memory`. Lists are then filtered with `can?` one by one and efficient pagination is lost; `find_by:` and `loads:` find the record and then ask `can?`. Fields covered by the type's rule are not asked about their attribute: give the ones an attribute rule must hide their own `authorize: :action`. Options the adapter does not understand (`policy:`, another `scope:`) raise `ConfigurationError`.

**The audit covers less.** It still reports missing rules, bypasses and unscoped `loads:`, but not whether the `Ability` grants the action: abilities depend on the user.

**Guests.** `Ability.new(nil)` is your ability class's decision. Make it deny everything if there is no user.

## Visibility

Hide a type or a field from users who may not use it, in introspection and in "did you mean" suggestions:

```ruby
class InvoiceExportType < BaseObject
  authorize :read, model: Invoice, visible_when: :export     # InvoicePolicy#export? / can?(:export, Invoice)
end

field :internal_notes, String, authorize: :manage, visible_when: :export
```

`visible_when:` is an action like any other, but it is asked **of the model's class, with no record**: `InvoicePolicy.new(user, Invoice).export?` with Pundit, `can?(:export, Invoice)` with CanCanCan. Write a method that decides from the user (`user.admin?`), not from the record. Nothing is hidden unless you declare it, and the audit reports a `visible_when:` action the policy does not define.

A hidden member also hides what leads only to it: a root field that returns a hidden type disappears with it.

**Schema dumps.** graphql 2.6 builds an ordinary context for `to_definition`, which cannot be told apart from an anonymous request, and an anonymous request must never see hidden members. Ask for the full schema explicitly:

```ruby
AppSchema.to_definition(context: { armory_full_schema: true })
```

Things to know:

- **Hiding is not authorization.** A hidden field is absent from the schema, so a query for it fails like a field that never existed. What the user may *read* is still decided by `authorize`.
- **The policy receives the class.** A policy that reads the record (`record.account_id`) raises `NoMethodError` for a `visible_when:` action; write that action from the user. The error propagates out of `execute`, so make sure your error handler does not echo it.
- **CanCanCan conditions are not applied to a class.** `can :export, Invoice, account_id: 1` makes the member visible to anyone who holds the rule. For a field, the attribute is passed: `can?(:export, Invoice, :internal_notes)`.
- **A subclass that redeclares `authorize` replaces the rule**, `visible_when:` included: repeat it.
- **`visible_when:` on a field needs a type that includes `Base`** (not an interface or a plain type); otherwise it raises `ConfigurationError` when a query selects it.
- **Static `Schema::Visibility` profiles are not supported**: `visible_when:` raises `ConfigurationError` under one, and a profile-only schema makes the audit's `possible_types` lookups raise `ArgumentError`. Plain `use Schema::Visibility`, `dynamic: true` and the default warden work.

Visibility is computed per query (and memoized inside it). Role-based profile caching across requests is graphql-ruby's `Schema::Visibility` feature and is not wrapped here.

## Arguments

An argument with no rule is **covered by its field**: the field already decides whether the user may call it. Declare a rule on the arguments that must be stricter, and they are checked when the client sends them:

```ruby
class BaseArgument < GraphQL::Schema::Argument
  include GraphQL::Armory::Authorization::Base
end
# in your base field: argument_class BaseArgument

field :invoices, [InvoiceType], authorize: :none, reason: "narrowed by the scope" do
  argument :include_internal, Boolean, required: false, authorize: :manage, model: Invoice
  argument :tag, String, required: false, visible_when: :export, model: Invoice
  argument :status, String, required: false, authorize: :none, reason: "public filter"
end
```

- **`authorize: :manage`** asks the policy about the parent object when it is an instance of the model, otherwise about the model's class (a root field has no record, so write the action from the user). The model is the one the field's type wraps, or `model:` when it wraps none, as on a root field. A denial denies the whole field, with the usual null or error.
- **Defaults.** graphql-ruby does not check an argument the client left at its default, and the two engines disagree about it (the interpreter skips the check, `Execution::Next` applies the default), so a restricted argument with a `default_value:` is refused with an `ArgumentError`. Sending `false` explicitly counts as using the argument.
- **Every argument class needs `Base`.** `argument_class` is not inherited: set it on your base field, and also on resolvers, input objects (for restricted arguments nested in a filter) and directives that need it.
- **`visible_when:`** hides the argument like it hides a field: it is absent from introspection and from suggestions, and a query that uses it fails like an argument that never existed.
- **`authorize: :none, reason:`** only declares and documents: the audit lists it with its reason.
- `authorize: true` is refused on an argument, and an argument with no model to ask about raises `ConfigurationError`.

## Mutations and resolvers

Include `Base` in your base mutation (or resolver) and declare what each one needs. A mutation is an action, not a read, so `default_action` does not apply and **a mutation with no `authorize` is denied**.

```ruby
class Mutations::BaseMutation < GraphQL::Schema::RelayClassicMutation
  include GraphQL::Armory::Authorization::Base
  argument_class Types::BaseArgument
  field_class Types::BaseField
  object_class Types::BaseObject
end

class Mutations::ApproveInvoice < Mutations::BaseMutation
  authorize :approve, model: Invoice            # InvoicePolicy#approve?(invoice) / can?(:approve, invoice)
  argument :invoice_id, ID, loads: Types::Invoice
  field :invoice, Types::Invoice, null: true
end
```

- **The record is the loaded one.** The rule runs after `loads:`, once per loaded record of the model (with none loaded, the model's class is asked). `loads:` goes through the user's scope, so a foreign id answers like a missing one.
- **Denial** follows the schema's `on_unauthorized` mode, like a field (`null`, `"Not found"`, or raise). With `on_denied: :errors` the mutation does not run and answers `{ errors: [{ message: "Not allowed", code: "FORBIDDEN" }] }` as data, so the payload needs an `errors` field.
- **Payload types** are ordinary objects: declare `authorize :none, reason: "...", covers_fields: true` so their fields are covered by the mutation instead of denied.
- **`authorize :none, reason:`** documents a mutation anyone may call; the audit lists it with its reason. A mutation with no rule appears as `:no_rule` (for example `Mutation.forgotten`), and a rule the policy does not define as `:adapter`.
- An unknown `on_denied:` raises `ArgumentError`; a mutation with a rule but no model raises `ConfigurationError`.
- **Class-level answers are weak.** With no loaded record of the model (no `loads:`, an empty `loads: [ID]`, or a `loads:` of another type) the rule is asked about the model's class: CanCan answers true for anyone holding the right, and a Pundit policy that reads `record` attributes raises. Load the record you are authorizing.
- **`ready?` runs before authorization** (and, on the interpreter, before a failing `loads:`). Keep it free of side effects.
- **`loads:` inside an input object** goes through the scope only when your base input object includes `Base` (`class Types::BaseInputObject < GraphQL::Schema::InputObject; include GraphQL::Armory::Authorization::Base; end`); otherwise the audit reports it as `:unscoped_load`.
- **Do not put `authorize:` on a mutation field or on payload fields**; the mutation's own rule is the one that counts. A subclass that redeclares `authorize :none` is open to everyone, on purpose.

## Interfaces and unions

They are never authorized themselves: graphql-ruby only runs `authorized?` on the concrete type, and every path ends there (root field, association, each list item, `loads:`, union and interface resolution). A foreign object in a list of a union or an interface comes back `null`, like in any other list. So `include Base` in an interface or a union is refused with a message pointing to the possible types; declare the rule on each concrete type.

What an interface adds is its fields, declared once and resolved on many types:

- A field with no rule is **covered** by the rule of the Base types that implement the interface (a plain implementer runs no check at all), unless one of them is a bypass (`authorize :none`). Then the field is **denied for every implementer**, because it cannot tell which type it runs on, and the audit reports it (`:field_without_rule`, for example `Document.number`). Declare it (`authorize: :none, reason:` or an action) to fix it.
- `visible_when:` is not supported on an interface field; put it on the concrete types' fields, and use `Schema::Visibility`. Without it, a hidden field falls back to the interface's, so a user it hides this from gets that one and the concrete field's rule does not run. The same goes for a parent class's field, and for anything that hides the field: its resolver, its return type, the schema's `visible?`. See [Redefined fields and arguments](#redefined-fields-and-arguments).
- `authorize: true` is not valid on an interface field: it is always denied, and the audit reports it. Use an action or `:none`.
- An interface whose field class does not include `Base`, such as graphql-ruby's built-in Relay `Node`, runs no field check, so its `id` stays readable on a bypassed implementer. The audit reports it (`:unprotected`, `Node.id`); give your own `Node` interface a Base field class if that matters.
- The audit reports an interface field once, on the interface that declares it, not again on each implementer.

## Telemetry

**When something raises during an object's check.** If a policy raises and a `rescue_from` handles the error, the handler runs and the object is denied, whatever the handler answers. Without a handler the error reaches the request. This includes a `GraphQL::ExecutionError`: when a `rescue_from` catches it, its message does not reach the client, who gets the ordinary denial.

The decisions are visible to you and not to the client. Pass `sinks:` to hear each one:

```ruby
use GraphQL::Armory::Authorization, adapter: :pundit,
  sinks: [->(signal, data) { Rails.logger.info("armory #{signal} #{data}") }]
# armory denied {:type=>"Invoice", :action=>:read}
```

Signals are `:allowed`, `:denied`, `:bypassed` (an `authorize :none` rule ran) and `:scoped` (a list went through the user's scope). Data holds only `type`, `action` and `reason`, never record attributes. `GraphQL::Armory::Telemetry::Notifications` reports them to `ActiveSupport::Notifications`. Every signal, what to watch for and how to test it: [Telemetry](telemetry.md). A `sinks:` that is not an Array of callables raises `Telemetry::ConfigurationError` at boot.

## Guarantees and limits

Covered by the black-box suite in `spec/security`, on both engines: user A cannot read user B's objects by root field, nested association or `loads:`; lists never contain foreign objects; uncovered types fail closed and show in the audit; a field hidden with `visible?` is absent from introspection and error suggestions (that is graphql-ruby's behaviour, pinned by a test).

With Pundit, a record's policy comes from its class, never from the record: `self.policy_class` and `self.model_name` work, the same methods on an instance are not asked, and an object built from client input cannot name a policy. A decorator asks the decorator's class, so give it its own policy or name one with `policy:`. An ActiveRecord relation asks its model; an Array is checked item by item; any other list asks its own class, so give it `model:` on the rule.

`use_visibility_profile: false` on one query (`multiplex_next` on `Execution::Next`) brings back graphql-ruby's fallback to a hidden field's other definitions, and the audit reads only the schema: it cannot see that option in your code. Do not combine it with a field redefined under `Schema::Visibility`.

`reauthorize_scoped_objects(false)` skips the rule, which is why the audit reports it. On connections nested inside connections the engines differ: the interpreter skips it and `Execution::Next` may still refuse, so never rely on either.

A parent with `model: "Note"` and a child with `model: Note` keep the parent's spelling on the parent's field rules: a subclass with no policy of its own raises `Pundit::NotDefinedError` there, even for an allowed user. Name the model the same way on both.

A direct subclass of `BaseConnection` or `BaseEdge` that adds a field, itself, from a parent or from an interface, is audited like any other type, so with no `Base` it is reported as `:unprotected`. A `total_count` is the usual case: include `Base` and declare `authorize :none, reason: "...", covers_fields: true` on the class. That reason covers every field the class has now or gets later, and the report names only the class. To check a field, add `policy:` to the same declaration and give the field `authorize:`: without `policy:` the rule is asked about graphql-ruby's pagination object, which has no policy, so it raises `Pundit::NotDefinedError` for every user, and the audit does not say so. A field redefined under a name graphql-ruby generates there (`edges`, `nodes`, `page_info`, `node`, `cursor`) is not seen by this check: do not put data in one. A generated field renamed through `field_options` is reported as an added field, unless the class declares `covers_fields`, which covers it.

Do not put `scope: false` on a `nodes` or `edges` you write yourself on a connection. The audit reports one that reads another method, a resolver, another element type or another key, but not one with `resolve_static:`, `resolve_each:`, `resolve_batch:`, `resolve_legacy_instance_method:` or `dataload:`: on `Execution::Next` those run instead of the generated method, so a refused user sees how many records it holds while the audit says ok. `hash_key: :nodes` is not reported on the field either. A generated `edges` with `edge_type(edge, node_type: other)` or renamed through `field_options` gets a false `:unscoped_list`.

A field added to or redefined on a custom `EntryPoints` or `DynamicFields` is reported as `:unprotected`, whatever it declares: no type's rule runs on it, so move it to a type with a rule.

The audit exempts only types flagged `introspection` whose name starts with `__`, the prefix the GraphQL spec reserves. A subclass of a built-in such as `GraphQL::Introspection::TypeType` keeps that name, so a data field added to one, or to a `__Helper`, is not audited: do not put data there.

A Symbol names a policy only as the `model:` the schema author wrote: a Symbol a type wraps is a record, like a String, and has no policy of its own unless a `SymbolPolicy` exists. A client sending the model's own name reaches that policy with the Symbol as its record, so a headless policy must not read a record's fields. A Module as a subject still names its class's policy, so never turn client text into a constant with `Object.const_get`. An app's own `visible?` raising `ConfigurationError` while the audit lists the schema is reported on the first run only, because graphql-ruby does not list the schema twice.

The model a rule declares, or the constant named like the type, is the one the audit reads, so its policy answers too: with Pundit, both that policy and the policy of the record's class must allow it. A record of another class, or a subclass with a laxer policy, cannot get past the declared one, and a subclass keeps its own stricter policy. A subclass with no policy runs under the declared one; anything else with no policy of its own raises `Pundit::NotDefinedError`. A rule's `policy:` answers alone. A field never sees its resolved type, so a rule defined on an interface or a parent asks that owner's model, or only the record's class when the owner has none: the audit reports it as `:foreign_model`, and naming a subclass as `model:` on a child type does not change it. The name of a model is inferred from the last segment of the type's name, so `Types::Billing::Shared` reads a top-level `Shared` and its policy too: declare `model:` when that is not the record. Lists go through the scope of the declared model, or the record's when none is declared. CanCanCan's `can?` reads the record itself, so the declared model does not answer there; a Symbol record is refused unless it is the `model:` written on the rule.

Policies must return `true`/`false`/`nil`; anything else raises `AdapterError`. Do not use `dataloader.request` inside policies; use `dataloader.with(...).load`.

## Engines

Both execution engines are tested: the default interpreter and `Execution::Next`. In graphql 2.5.26 to 2.6.1, Next crashes on denied fields, so the gem refuses to run on Next there (`ConfigurationError`). Everything else works from graphql 2.4.

## Performance

`benchmark/authorization.rb`, 1000 invoices, graphql 2.6.2, Ruby 3.2, Docker on Windows:

| Engine | Query | plain | armory (array) | armory (relation) |
|---|---|---|---|---|
| interpreter | `number` | 117.6 i/s | 45.9 i/s | 44.2 i/s |
| interpreter | 3 fields | 58.8 i/s | 21.6 i/s | 21.0 i/s |
| next | `number` | 654.2 i/s | 71.8 i/s | 70.8 i/s |
| next | 3 fields | 417.5 i/s | 42.1 i/s | 39.5 i/s |

The absolute cost is about 13 to 15 ms per 1000 items on both engines; most of it is probably Pundit's policy lookup, which is not cached so code reloading cannot serve stale classes. Run it yourself: `docker compose run --rm test bundle exec ruby benchmark/authorization.rb` (add `GRAPHQL_ARMORY_ENGINE=next` for Next).

## Migrating

Coming from hand-written `authorized?` and `scope_items`? See [MIGRATING.md](../MIGRATING.md).
