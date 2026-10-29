<p align="center">
  <img src="assets/logo.jpeg" alt="graphql-armory" width="560">
</p>

# graphql-armory

Open-source extensions for [graphql-ruby](https://github.com/rmosolgo/graphql-ruby), built on its public extension points: no fork, no monkey patching.

The first module is **authorization**. It plugs [Pundit](https://github.com/varvet/pundit) policies into graphql-ruby so that:

- **Nothing is open by default.** A type or field no rule covers answers `null` (or an error), never data.
- **Lists only contain what the user may see**, including connections: the scope runs before pagination and counting.
- **Lookups by ID cannot leak** (IDOR). A record you may not read and a record that does not exist look identical.
- **An audit tells you what you forgot**, from a rake task or an RSpec matcher, so CI fails instead of production leaking.

> **Status: early development (0.1, unreleased).** Pundit and CanCanCan adapters. Not published yet.

## Install

```ruby
gem "graphql-armory", "~> 0.1.0.pre"   # a prerelease: `gem install graphql-armory --pre`
gem "pundit"      # or "cancancan", whichever you use
```

Requires Ruby >= 3.1 and graphql >= 2.4. `GraphQL::Execution::Next` is supported from graphql 2.6.2 (see [Engines](#engines)).

## Quick start

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

The actor is `context[:current_user]`. A complete, tested version lives in [`examples/invoices.rb`](examples/invoices.rb).

### Rules

| Declaration | Meaning |
|---|---|
| `default_action :read` | Default rule for every type below this base class. |
| `authorize :manage` | This type is checked with `manage?` instead. |
| `authorize :read, model: Invoice` | The model when it is not named like the type. |
| `field ..., authorize: :manage` | The field asks another question of the same policy. |
| `authorize :none, reason: "..."` | Explicit bypass. A reason is required and appears in the audit. |

A bypass does not propagate: a field of a bypassed type still needs its own rule, or it is denied.

### What happens on denial

```ruby
use GraphQL::Armory::Authorization, adapter: :pundit, on_unauthorized: :null # default
```

| Mode | Client sees | Use |
|---|---|---|
| `:null` | `null`, no error | Default. Reveals nothing. |
| `:error` | `"Not found"`, code `NOT_FOUND`, identical on every path | When clients need to tell. |
| `:raise` | `NotAuthorizedError` naming only the type | When your app rescues it. |

Denied non-null fields raise the generic "Not found" error, because GraphQL cannot return `null` there (on Execution::Next a denied object in a non-null position answers graphql-ruby's own "Cannot return null for non-nullable field", and `:raise` messages are prefixed with the field path). `find_by:` lookups always answer `null` in every mode: a missing ID cannot raise, and a foreign ID must look the same.

### Lists, connections and lookups

Lists of a type are narrowed through `InvoicePolicy::Scope` (relations) or by calling the policy per item (arrays). Return a relation when you can: SQL filters before Ruby sees anything.

```ruby
field :invoice, InvoiceType, authorize: :none, reason: "looked up through the scope", find_by: :id do
  argument :id, ID
end

field :invoice_via_ref, InvoiceType, authorize: :none, reason: "loaded through the scope" do
  argument :invoice_id, ID, loads: InvoiceType
end
```

`find_by:` and `loads:` look the record up **inside the user's scope**, so another tenant's ID answers exactly like a missing one. Opt out of the scope for a `loads:` only on purpose, with `load_through_scope: false`; the audit lists it.

**Global IDs.** When your schema defines `object_from_id` (Relay global IDs), `loads:` decodes the id with it, refuses a record of another model, and looks the record up again inside the scope (one extra query per load). Without `object_from_id`, the id is the primary key. `object_from_id` must return the record itself, not a lazy value: a lazy value is denied. A decoder that raises `ActiveRecord::RecordNotFound` (like `GlobalID.find`) or `ArgumentError` (a malformed id) is answered like a missing record; other errors propagate. `loads:` of an interface or union (for example `Types::Node`) raises `ConfigurationError`: load a concrete type. Composite primary keys are not supported.

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

It reports types nobody protects (a base class that never included `Base`), types and fields with no rule, policies missing the method or `Scope`, `loads:` that skip the scope, and lists every declared bypass with its reason.

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
- **`loads:` works on top-level arguments only.** Inside an input object it is not scoped, and the engines disagree (the interpreter raises, `Execution::Next` yields nil).
- **Do not put `authorize:` on a mutation field or on payload fields**; the mutation's own rule is the one that counts. A subclass that redeclares `authorize :none` is open to everyone, on purpose.

## Interfaces and unions

They are never authorized themselves: graphql-ruby only runs `authorized?` on the concrete type, and every path ends there (root field, association, each list item, `loads:`, union and interface resolution). A foreign object in a list of a union or an interface comes back `null`, like in any other list. So `include Base` in an interface or a union is refused with a message pointing to the possible types; declare the rule on each concrete type.

What an interface adds is its fields, declared once and resolved on many types:

- A field with no rule is **covered** by the rule of the Base types that implement the interface (a plain implementer runs no check at all), unless one of them is a bypass (`authorize :none`). Then the field is **denied for every implementer**, because it cannot tell which type it runs on, and the audit reports it (`:field_without_rule`, for example `Document.number`). Declare it (`authorize: :none, reason:` or an action) to fix it.
- `visible_when:` is not supported on an interface field; put it on the concrete types' fields.
- `authorize: true` is not valid on an interface field: it is always denied, and the audit reports it. Use an action or `:none`.
- An interface whose field class does not include `Base`, such as graphql-ruby's built-in Relay `Node`, runs no field check, so its `id` stays readable on a bypassed implementer. The audit reports it (`:unprotected`, `Node.id`); give your own `Node` interface a Base field class if that matters.
- The audit reports an interface field once, on the interface that declares it, not again on each implementer.

## Telemetry

Pass `sinks: [->(signal, data) {}]`. Signals are `:allowed`, `:denied`, `:bypassed`; data holds only `type`, `action` and `reason`, never record attributes.

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

Coming from hand-written `authorized?` and `scope_items`? See [MIGRATING.md](MIGRATING.md).

## Development

Ruby is not required on the host:

```
docker compose run --rm test                                    # full suite, interpreter
GRAPHQL_ARMORY_ENGINE=next docker compose run --rm test         # full suite, Execution::Next
GRAPHQL_VERSION="~> 2.4.0" docker compose run --rm test         # another graphql version
```

## Roadmap

Status: ✅ done, 🚧 in progress, ⬜ not started. Update this table in the same PR that changes a module.

| Order | Module | Status | Current limits |
|---|---|---|---|
| 1 | Authorization (Pundit, CanCanCan) | 🚧 | Pundit and CanCanCan done (the audit checks less with CanCanCan). Global IDs in `loads:` decoded through `object_from_id`. `Execution::Next` needs graphql >= 2.6.2. Published as 0.1.0.pre (prerelease). |
| 2 | Encrypted, versioned IDs and cursors | ⬜ | Research not started. |
| 3 | Persisted queries / operation whitelisting | ⬜ | Research not started. |
| 4 | Rate limiting | ⬜ | Research not started. |
| 5 | Stable (keyset) connections | ⬜ | Research not started. |
| 6 | Subscriptions over Pusher / Ably | ⬜ | Research not started. |
| 7 | Response caching | ⬜ | Research not started. |
| 8 | API versioning (changesets) | ⬜ | Research not started. |
| 9 | `@defer` / `@stream` | ⬜ | Research not started. |
| 10 | Dashboard | ⬜ | Research not started. |

Each module starts with its own research before design. A module is ✅ only when it is released and its limits are documented here.

## Related gems

- [graphql-armory-rust_parser](https://github.com/israelb/graphql-armory-rust_parser): a GraphQL parser written in Rust, installable as graphql-ruby's default parser.

## Clean-room policy

This project is written independently. It uses only graphql-ruby's open-source code, its public guides, and the public documentation of Pundit and CanCanCan. It does not use, copy or derive from GraphQL-Pro or GraphQL-Enterprise code.

## License

MIT. See [LICENSE](LICENSE).
