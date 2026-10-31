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

The actor is `context[:current_user]`. A complete, tested version lives in [`examples/invoices.rb`](../examples/invoices.rb).

## Rules

| Declaration | Meaning |
|---|---|
| `default_action :read` | Default rule for every type below this base class. |
| `authorize :manage` | This type is checked with `manage?` instead. |
| `authorize :read, model: Invoice` | The model when it is not named like the type. |
| `field ..., authorize: :manage` | The field asks another question of the same policy. |
| `authorize :none, reason: "..."` | Explicit bypass. A reason is required and appears in the audit. |

A bypass does not propagate: a field of a bypassed type still needs its own rule, or it is denied.

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
- A type no definition leads to. The audit follows the schema's roots, `orphan_types` and what each definition references (fields, arguments, interfaces, union members, a connection's node), not filtering by `visible?`, so types hidden with no request and every definition of a duplicated name are audited. A type that only your own `resolve_type` returns, listed nowhere, is not seen. Also not seen: the fields of a type that subclasses `Relay::BaseConnection` or `Relay::BaseEdge` directly.
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

`find_by:` and `loads:` (also inside input objects whose base class includes `Base`) look the record up **inside the user's scope**, so another tenant's ID answers exactly like a missing one. Opt out of the scope for a field's `loads:` only on purpose, with `load_through_scope: false`; the audit lists it. On `Execution::Next` the opt-out also reaches `loads:` nested in that field's input objects (the interpreter keeps those scoped), and the audit lists them too (`Query.field(filter.invoice_id)`). An input object that overrides `object_from_id` or defines `load_<argument>` itself is honoured on the interpreter and not seen by the audit.

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
# Rakefile (or a Rails task file): exits 1 when anything is uncovered
load "tasks/graphql_armory.rake"
# bundle exec rake "graphql_armory:audit[AppSchema]"
```

It reports types nobody protects (a base class that never included `Base`), types and fields with no rule, policies missing the method or `Scope`, `loads:` that skip the scope, your own denial hooks and checks on base classes, and lists every declared bypass with its reason.

## CanCanCan

Same schema, different adapter. Your types and fields do not change:

```ruby
use GraphQL::Armory::Authorization, adapter: :cancan
```

The actor is `context[:current_ability]` (it wins over `current_user`), or `Ability.new(context[:current_user])` (pass `Adapters::CanCan.new(ability_class: MyAbility)` for another class). It is built once per query.

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
- **Static `Schema::Visibility` profiles are not supported** and raise `ConfigurationError`; plain `use Schema::Visibility`, `dynamic: true` and the default warden work.

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
- `visible_when:` is not supported on an interface field; put it on the concrete types' fields, and use `Schema::Visibility`. Without it, a hidden field falls back to the interface's, so a user it hides this from gets that one and the concrete field's rule does not run. The same goes for a parent class's field, and for anything that hides the field: its resolver, its return type, the schema's `visible?`. Without `Schema::Visibility` the audit reports every override whose rule differs from an ancestor's (`:ignored_rule`), because only a request knows whether it gets hidden. Give both the same rule, remove the ancestor's, use `Schema::Visibility`, or declare it: `field :notes, String, authorize: :manage, override_reason: "the parent's field is as strict"`. A declared override is listed as a bypass, and an `override_reason:` with nothing to declare is a problem.
- `authorize: true` is not valid on an interface field: it is always denied, and the audit reports it. Use an action or `:none`.
- An interface whose field class does not include `Base`, such as graphql-ruby's built-in Relay `Node`, runs no field check, so its `id` stays readable on a bypassed implementer. The audit reports it (`:unprotected`, `Node.id`); give your own `Node` interface a Base field class if that matters.
- The audit reports an interface field once, on the interface that declares it, not again on each implementer.

## Telemetry

The decisions are visible to you and not to the client. Pass `sinks:` to hear each one:

```ruby
use GraphQL::Armory::Authorization, adapter: :pundit,
  sinks: [->(signal, data) { Rails.logger.info("armory #{signal} #{data}") }]
# armory denied {:type=>"Invoice", :action=>:read}
```

Signals are `:allowed`, `:denied`, `:bypassed` (an `authorize :none` rule ran) and `:scoped` (a list went through the user's scope). Data holds only `type`, `action` and `reason`, never record attributes. `GraphQL::Armory::Telemetry::Notifications` reports them to `ActiveSupport::Notifications`. Every signal, what to watch for and how to test it: [Telemetry](telemetry.md). A `sinks:` that is not an Array of callables raises `Telemetry::ConfigurationError` at boot.

## Guarantees and limits

Covered by the black-box suite in `spec/security`, on both engines: user A cannot read user B's objects by root field, nested association or `loads:`; lists never contain foreign objects; uncovered types fail closed and show in the audit; a field hidden with `visible?` is absent from introspection and error suggestions (that is graphql-ruby's behaviour, pinned by a test).

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
