# API versioning

Each client gets the schema it was built against, and fields can arrive and leave without breaking older clients.

> **In progress.** This first part versions **fields** (`added:`, `removed:`) and decides each request's version. Arguments, enum values, input fields, types, the per-version audit, the diff and the `deprecated:` keyword come in the next parts, and are not available yet.

## The problem

A public GraphQL API has clients you do not control: mobile builds that stay in the stores for months, partners who integrated once. graphql-ruby gives you one tool for change, `deprecation_reason:`, and it only labels a field:

- **Nothing tells a client which schema it is talking to.** A field you remove disappears for everyone at once, including the app build from last spring.
- **So nothing is ever removed.** The schema grows forever, or a client breaks.
- **Hand-written `visible?` methods** reading ad-hoc context flags can hide fields per client, but there is no list of what exists in which version, and every team writes its own.

## The solution

You declare an ordered list of versions once, and each field says when it arrived and when it left. Each request names the version its client was built against, and the plugin applies it:

- **One version per query, everywhere.** The query sees that version's schema in validation, execution on both engines, introspection, "Did you mean" suggestions and `to_definition`. A field outside the version does not exist for that client.
- **Older clients keep their schema** until you retire their version.
- **Refused, never re-routed.** A retired version, an unknown or future label, an empty String or anything that is not a String is refused before anything runs, with a stable code. The plugin never serves a different version than the one asked for.
- **Built on graphql-ruby's own `visible?`.** It hooks `Schema.query_class`, to decide the version once per query, and `visible?` on the field classes you give it.

Versioning is **not authorization**. Any client may ask for any served version, so a field that exists in a served older version is public to anyone who asks for that version. What a user may read is [Authorization](authorization.md)'s job.

## How to use it

Declare the versions on the schema, oldest first, and include `Base` in your base field class:

```ruby
class AppSchema < GraphQL::Schema
  query Types::Query
  use GraphQL::Schema::Visibility                      # or GraphQL::Schema::Warden to stay on the legacy path
  use GraphQL::Armory::Versioning,
    versions: %w[2024-01-15 2024-06-01 2025-01-01],   # oldest first: the order is the order
    retired:  %w[2024-01-15],                         # no longer served
    default:  :latest                                 # what a request with no version gets
end

class Types::BaseField < GraphQL::Schema::Field
  include GraphQL::Armory::Versioning::Base
end

class Types::BaseObject < GraphQL::Schema::Object
  field_class Types::BaseField
end
```

Then give fields a lifecycle:

```ruby
class Types::Invoice < Types::BaseObject
  field :number, String, null: false                                    # every version
  field :total, Integer, null: false, added: "2024-06-01"               # from 2024-06-01 on
  field :amount, Integer, null: false, removed: "2025-01-01",           # up to 2024-06-01
                 deprecation_reason: "Use `total`"
  field :tags, [String], null: false, added: "2025-01-01" do
    argument :first, Integer, required: false
  end
end
```

A field lives from `added:` (the first version when absent) up to, not including, `removed:` (still here when absent). A field with neither lives in every version. Every field of a class that includes `Base` still reads the query's version when graphql-ruby asks whether it is visible. `deprecation_reason:` is graphql-ruby's own and works as always: the field is deprecated in every version it exists in. Deprecating it only from a given version comes in a later part.

Use `GraphQL::Schema::Visibility` (or `GraphQL::Schema::Warden`): without either, graphql-ruby prints a deprecation warning the first time a query hides something.

### Labels

Labels are opaque Strings, ordered by their position in `versions:`. Calendar dates (`YYYY-MM-DD`) are the recommended convention, as public APIs such as Stripe's and GitHub's use, and when every label looks like a date the list must be ascending. Any other labels work too (`%w[1 2 3]`): their order is the order you wrote.

A version stays in `versions:` while any field names it. Retiring a version moves it to `retired:`, which must be the oldest versions and must leave at least one served.

### Selecting a version

Your app puts the version in the context, from wherever your protocol carries it. One line in the controller, from a header:

```ruby
AppSchema.execute(params[:query], variables: variables, context: {
  current_user: current_user,
  armory_version: request.headers["X-API-Version"],   # nil is fine: default: applies
})
```

It could as well come from the URL or from a version pinned on the client's account. What the plugin does with it:

| `context[:armory_version]` | Result | `extensions.code` |
|---|---|---|
| A served version's label | That version | — |
| `nil`, or no key (the key is the Symbol `:armory_version`: a String key `"armory_version"` counts as no key) | The `default:` policy | `MISSING_API_VERSION` under `default: :refuse` |
| A retired version's label | Refused, nothing runs | `RETIRED_API_VERSION` |
| Anything else: an unknown or future label, `""`, a label with extra spaces, a Symbol, a number | Refused, nothing runs | `UNKNOWN_API_VERSION` |

`default:` is required, because the plugin must not guess:

- `:latest` for a new API: clients that send nothing follow the schema forward.
- A label (`"2024-06-01"`) for an API that already has clients in production: they keep the schema they see today.
- `:refuse` once every client sends a version (watch `:version_defaulted` reach zero first).

A version set by a custom `context_class` counts too: the plugin decides after the query and its context are built.

### Telling a refusal apart

A refusal is the request's only error, with a stable code in `extensions.code`: `UNKNOWN_API_VERSION`, `RETIRED_API_VERSION` or `MISSING_API_VERSION`. Match on the code. Messages are fixed ("Unknown API version", "This API version is retired", "Send an API version"): they never repeat what the client sent and never list your versions. If you want clients to discover the served versions, add a root field of your own that lists them.

### Reading the version in your code

`GraphQL::Armory::Versioning.version(context)` answers the query's `Version`: its `label`, its `index`, and comparisons with another version or a label.

```ruby
def notes
  version = GraphQL::Armory::Versioning.version(context)
  version < "2025-01-01" ? object.legacy_notes : object.notes
end
```

The plugin decides the schema, never the data: when the data a client gets must differ per version, your resolvers decide it from this. Comparing with a label your list does not hold raises `UnknownVersionError`, so a typo fails loudly. It raises `ConfigurationError` for anything that is not a query's context.

### Dumping a version's schema

```ruby
AppSchema.to_definition(context: { armory_version: "2024-06-01" })
```

Without `armory_version:`, the `default:` policy applies: `:latest` dumps the latest version, and `:refuse` makes `to_definition` raise `MissingVersionError`, telling you the context to pass. `context: { armory_full_schema: true }` (Authorization's switch for a full dump) does not widen a version: there is no schema that holds every version at once. `Schema.validate(query, context: { armory_version: ... })` validates against that version the same way.

### Watching the rollout

Pass `sinks:` to see what the plugin decided, one signal per query:

| Signal | Data | When |
|---|---|---|
| `:version_served` | `version` | The request named a served version |
| `:version_defaulted` | `version` | The request named none, and `default:` picked one |
| `:version_refused` | `reason`: `:unknown`, `:retired` or `:missing` | The request was refused |

`version` is the schema's own label, never the client's value. `:version_defaulted` counts the clients that do not send a version yet; `:version_refused` with `:retired` counts the clients still on a version you retired. See [Telemetry](telemetry.md).

### Testing with versioning

`Versioning::Controls` holds a small schema to test against: `Controls::Versions.example` (`2024-01-15` retired, `2024-06-01` and `2025-01-01` served), `Controls::Schema.example(visibility: :visibility | :warden, default:, base:, sinks:)` with a field of each lifecycle, `Controls::Root.example(resolved)` that records what resolved, and `Controls::Context.example(version:)`. The decision itself is `Versioning::Gate`: `Gate.build(versions:, default:, retired:)` takes `use`'s settings, `gate.(context)` answers a `Decision` and records its signal, and `gate.resolve(label)` answers it recording nothing. `Gate.new`, with nothing wired, refuses every request. `Gate::Substitute` answers the decision you tell it (`answer(decision)`) and records the contexts and labels it was asked about.

## Reference

`use GraphQL::Armory::Versioning, versions:, default:, retired: [], sinks: [], on_sink_error: nil`

- `versions:` an Array of non-empty String labels, oldest first, with no duplicate; ascending when every label is a date (`YYYY-MM-DD`).
- `retired:` an Array: the oldest labels of `versions:`, leaving at least one served.
- `default:` `:latest`, a served label, or `:refuse`. Required.
- `sinks:` an Array of callables taking `(signal, data)` or `(signal, data, context)`; `on_sink_error:` a callable `(error, signal)`. See [Telemetry](telemetry.md).
- Anything else raises `Versioning::ConfigurationError` when the schema loads.
- Works with your own `query_class`, set before `use`, after it, or in a child schema: the plugin subclasses it. `use` it once per schema hierarchy: a second `use`, on the same schema or a child, raises.

`include GraphQL::Armory::Versioning::Base` goes in a field class (a `GraphQL::Schema::Field` subclass); anywhere else it raises `ArgumentError` in this part. It adds `added:` and `removed:` to `field`, each a non-empty String: anything else, or the same label for both, raises `ConfigurationError` when the field is defined. A label `versions:` does not hold, or a `removed:` before its `added:`, raises `ConfigurationError`, naming the field, every time a query asks about that field: types load before `use`, so it cannot be checked earlier. `field.armory_lifecycle.to_h` answers `{ added:, removed: }`.

Context key: `armory_version` (a String naming a served version).

Errors: `Versioning::ConfigurationError` (a server-side setup mistake), `UnknownVersionError` (a label the list does not hold, a `ConfigurationError`), `RefusedVersionError` with `code`, and `MissingVersionError` (one of those, for a missing version).

## Guarantees and limits

**What is guaranteed.** A client that names version V gets V's schema on every path that reads the query's schema: selection and aliases, fragments, validation and its suggestions, introspection (`__schema`, `__type`, `fields`), `to_definition` and `Schema.validate` with V in the context, on the interpreter and on `Execution::Next`, and each query of a multiplex sees its own version. A refused version runs nothing, even with `validate: false`, and even when the query brings its own `static_validator:` (the plugin replaces it; a [persisted queries](persisted-queries.md) refusal is kept, since it runs nothing either). The version lives in the query's context: one query's version cannot reach another's. What this part covers is fields; nothing else carries a lifecycle yet.

**Limits.**

- **Lookups with no context see every field.** `Types::Invoice.get_field("amount")`, `Types::Invoice.fields` and other lookups without a query answer the field whatever its lifecycle: graphql-ruby answers them without asking `visible?`. Read a version's schema through `to_definition(context: { armory_version: ... })`. A tooling entry point for this comes in a later part.
- **Subscription triggers** build their query with `context: {}` unless you pass one, so the `default:` policy applies to them: under `default: :refuse` a trigger that reaches a versioned field raises `MissingVersionError`, and under `:latest` it cannot name a field removed in the latest version. Pass `context: { armory_version: ... }` to every `trigger`. Subscriptions are not tested with versioning yet.
- **Queries built outside `query_class`.** A `Query::Partial` (`run_partials`) sees its parent's version, because it reads its parent's schema, and so does the second context `Schema::Visibility`'s `migration_errors: true` builds for a query; neither records a signal. A `GraphQL::Query` your code builds itself skips `query_class`: it is decided from its own `armory_version` the first time a versioned field is asked about, and records no signal. A refused version raises `RefusedVersionError` there instead of answering a validation error, and such a query that touches no field of a class that includes `Base` runs.
- **`validate: false` with a field outside the version** raises graphql-ruby's own error ("No field definition found", or a `NoMethodError` on graphql 2.4) quoting the client's selection; nothing resolves.
- **The legacy `Schema::Warden` falls back.** When a type's own definition of a field is hidden in V, the Warden serves a parent class's or an interface's definition of the same name instead. `Schema::Visibility` never does: use it.
- **Named `Schema::Visibility` profiles** (`profiles:`) are not supported yet: any field of a class that includes `Base` asked under one raises `ConfigurationError`. Dynamic profiles (`dynamic: true`, or no profiles) work.
- **`Schema::AlwaysVisible`** never asks `visible?`, so nothing would be versioned: the first query raises `ConfigurationError` instead, even when it was added after `use`.
- **Your own `visible?`** on a base field class must call `super`, or the plugin is skipped for those fields.
- **Two refusing plugins.** With persisted queries, a request both refuse gets the persisted query's code. Either way nothing runs.
- **Signals.** `to_definition`, `Schema.validate` and subscription triggers go through `query_class` too, so each records one signal.
- **Cost.** A field without a lifecycle costs nothing. A versioned field costs a few Hash lookups each time graphql-ruby asks `visible?` (once per field per query). Not measured yet.
