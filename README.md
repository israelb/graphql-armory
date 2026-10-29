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

> **Status: early development (0.1, unreleased).** Pundit only; CanCanCan comes next. Not published yet.

## Install

```ruby
gem "graphql-armory"
gem "pundit"
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

## Telemetry

Pass `sinks: [->(signal, data) {}]`. Signals are `:allowed`, `:denied`, `:bypassed`; data holds only `type`, `action` and `reason`, never record attributes.

## Guarantees and limits

Covered by the black-box suite in `spec/security`, on both engines: user A cannot read user B's objects by root field, nested association or `loads:`; lists never contain foreign objects; uncovered types fail closed and show in the audit; a field hidden with `visible?` is absent from introspection and error suggestions (that is graphql-ruby's behaviour, pinned by a test).

Not covered yet: arguments, mutations, interfaces and unions, visibility driven by policies, CanCanCan, decoding global IDs in `loads:`. Policies must return `true`/`false`/`nil`; anything else raises `AdapterError`. Do not use `dataloader.request` inside policies; use `dataloader.with(...).load`.

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
| 1 | Authorization (Pundit, CanCanCan) | 🚧 | Pundit done. CanCanCan pending. Not covered yet: arguments, mutations, interfaces and unions, visibility driven by policies, decoding global IDs in `loads:`. `Execution::Next` needs graphql >= 2.6.2. Unreleased. |
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
