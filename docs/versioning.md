# API versioning

Each client gets the schema it was built against, and fields can arrive and leave without breaking older clients.

> **In progress.** This first part versions **fields** (`added:`, `removed:`) and decides each request's version. Arguments, enum values, input fields, types, the per-version audit, the diff and the `deprecated:` keyword come in the next parts, and are not available yet.

## The problem

A public GraphQL API has clients you do not control: mobile builds that stay in the stores for months, partners who integrated once. graphql-ruby gives you one tool for change, `deprecation_reason:`, and it only labels a field:

- **Nothing tells a client which schema it is talking to.** A field you remove disappears for everyone at once, including the app build from last spring.
- **So nothing is ever removed.** The schema grows forever, or a client breaks.
- **Hand-written `visible?` methods** reading ad-hoc context flags can hide fields per client, but there is no list of what exists in which version, and every team writes its own.

## The solution

You declare an ordered list of versions once, and each type, field, argument, input field and enum value says when it arrived and when it left. Each request names the version its client was built against, and the plugin applies it:

- **One version per query, everywhere.** The query sees that version's schema in validation, execution on both engines, introspection, "Did you mean" suggestions and `to_definition`. A type, field, argument, input field or enum value outside the version does not exist for that client, as a literal, a fragment or through a variable.
- **Older clients keep their schema** until you retire their version.
- **Refused, never re-routed.** A retired version, an unknown or future label, an empty String or anything that is not a String is refused before anything runs, with a stable code. The plugin never serves a different version than the one asked for.
- **Built on graphql-ruby's own `visible?`.** It hooks `Schema.query_class`, to decide the version once per query, and `visible?` on the base classes you give it.

Versioning is **not authorization**. Any client may ask for any served version, so a field that exists in a served older version is public to anyone who asks for that version. What a user may read is [Authorization](authorization.md)'s job.

## How to use it

Declare the versions on the schema, oldest first, and include `Base` in your base classes:

```ruby
class AppSchema < GraphQL::Schema
  query Types::Query
  use GraphQL::Schema::Visibility                      # or GraphQL::Schema::Warden to stay on the legacy path
  use GraphQL::Armory::Versioning,
    versions: %w[2024-01-15 2024-06-01 2025-01-01],   # oldest first: the order is the order
    retired:  %w[2024-01-15],                         # no longer served
    default:  :latest                                 # what a request with no version gets
end

class Types::BaseArgument < GraphQL::Schema::Argument
  include GraphQL::Armory::Versioning::Base
end

class Types::BaseField < GraphQL::Schema::Field
  include GraphQL::Armory::Versioning::Base
  argument_class Types::BaseArgument
end

class Types::BaseEnumValue < GraphQL::Schema::EnumValue
  include GraphQL::Armory::Versioning::Base
end

class Types::BaseObject < GraphQL::Schema::Object
  include GraphQL::Armory::Versioning::Base
  field_class Types::BaseField
end

class Types::BaseTypeMembership < GraphQL::Schema::TypeMembership
  include GraphQL::Armory::Versioning::Base           # for implements X, added: and possible_types Y, added:
end

module Types::BaseInterface
  include GraphQL::Schema::Interface                  # first, then Base
  include GraphQL::Armory::Versioning::Base
  field_class Types::BaseField
  type_membership_class Types::BaseTypeMembership
end

class Types::BaseInputObject < GraphQL::Schema::InputObject
  include GraphQL::Armory::Versioning::Base
  argument_class Types::BaseArgument                  # input fields are arguments
end

class Types::BaseEnum < GraphQL::Schema::Enum
  include GraphQL::Armory::Versioning::Base
  enum_value_class Types::BaseEnumValue
end

class Types::BaseUnion < GraphQL::Schema::Union
  include GraphQL::Armory::Versioning::Base
  type_membership_class Types::BaseTypeMembership
end

class Types::BaseScalar < GraphQL::Schema::Scalar; include GraphQL::Armory::Versioning::Base; end
class Types::BaseMutation < GraphQL::Schema::RelayClassicMutation
  include GraphQL::Armory::Versioning::Base
  argument_class Types::BaseArgument
  field_class Types::BaseField
  object_class Types::BaseObject
  input_object_class Types::BaseInputObject
end
```

Set `argument_class Types::BaseArgument` wherever arguments are declared: base fields, input objects, resolvers, mutations and your own directives.

Then give members a lifecycle:

```ruby
class Types::Invoice < Types::BaseObject
  field :number, String, null: false                                    # every version
  field :total, Integer, null: false, added: "2024-06-01"               # from 2024-06-01 on
  field :amount, Integer, null: false, removed: "2025-01-01",           # up to 2024-06-01
                 deprecation_reason: "Use `total`"
  field :tags, [String], null: false, added: "2025-01-01" do
    argument :first, Integer, required: false
    argument :page, Integer, required: false, removed: "2025-01-01"     # an argument, up to 2024-06-01
  end
end

class Types::Status < Types::BaseEnum
  value "PAID"
  value "VOID", added: "2024-06-01"                                     # an enum value, from 2024-06-01 on
end

class Types::InvoiceFilter < Types::BaseInputObject
  argument :status, Types::Status, required: false
  argument :since, String, required: false, added: "2025-01-01"         # an input field, from 2025-01-01 on
end
```

A member lives from `added:` (the first version when absent) up to, not including, `removed:` (still here when absent). A member with neither lives in every version. Every field and enum value of a class that includes `Base` still reads the query's version when graphql-ruby asks whether it is visible; an argument reads it only when it, its default value or the type it `loads:` is versioned. `deprecation_reason:` is graphql-ruby's own and works as always: the member is deprecated in every version it exists in. Deprecating it only from a given version comes in a later part.

A versioned argument is the client's to omit in the versions it does not live in, so give its resolver keyword a Ruby default (`def tags(first: 10)`): graphql-ruby never applies the `default_value:` of an argument hidden in the query's version, and calls the resolver without it.

Types take `lifecycle` in their class body:

```ruby
class Types::Contract < Types::BaseObject
  lifecycle added: "2025-01-01"                       # the type, and every field and argument that uses it
  field :party, String, null: false
end

class Types::CreateContract < Types::BaseMutation
  lifecycle added: "2025-01-01"                       # the mutation, its field, its input and payload types
end
```

A type outside the version is gone with everything that uses it: graphql-ruby hides each field that returns it and each argument that takes it, and the plugin also hides an argument that `loads:` it. An argument that `loads:` an interface or union still lives, but an object of a member type outside the version is not authorized there: graphql-ruby's unauthorized path runs (`unauthorized_object`), never the resolver. A field leaves with the type that declared it, so an interface that includes a versioned interface loses that interface's fields where it does not live. A subclass keeps its parent's lifecycle unless it declares its own, which must fit inside every versioned ancestor's; a mutation's generated input and payload types take the mutation's; an object never takes its interfaces', and an interface never takes the interfaces it includes. `lifecycle` needs `added:`, `removed:` or both.

A membership takes the same keywords when an existing type joins an interface or a union:

```ruby
class Types::Invoice < Types::BaseObject
  implements Types::Archivable, added: "2025-01-01"   # an Archivable, with its fields, from 2025-01-01
end

class Types::Document < Types::BaseUnion
  possible_types Types::Invoice
  possible_types Types::Contract, added: "2025-01-01"
end
```

Outside the membership, the object is not a member: the interface's fields are gone from it (a field the object declares itself stays), `interfaces` and `possibleTypes` omit it, a fragment on the abstract type does not apply to it, and a `resolve_type` answering it raises `GraphQL::UnresolvedTypeError` (see "Data outside the version"). The membership only hides the relationship: the object stays in the schema, so a type new with the membership takes its own `lifecycle` too. A membership lifecycle wider than its types' changes nothing outside theirs. A type new to a union or interface altogether simply takes `lifecycle added:`.

To change a field, argument or enum value's shape without renaming it, give it two definitions on the same owner, with lifecycles that do not overlap:

```ruby
field :total, Integer, null: false, method: :total_cents, removed: "2025-01-01"   # an Int up to 2024-06-01
field :total, String, null: false, method: :total_text, added: "2025-01-01"      # a String from 2025-01-01

argument :first, Integer, required: false, removed: "2025-01-01"
argument :first, String, required: false, added: "2025-01-01"

value "VOID", "Cancelled.", removed: "2025-01-01"
value "VOID", "Voided by the issuer.", value_method: false, added: "2025-01-01"   # the second skips graphql-ruby's value method
```

Each version sees exactly one of them, in every place graphql-ruby reads the schema. Two definitions that one version would both see raise `ConfigurationError` (an unversioned one beside a versioned one included). [Authorization](authorization.md)'s audit reads them as one member, and each keeps its own rule. Two definitions may also be kept apart by their types' lifecycles. Field twins need graphql 2.4.9 or later, and `value_method: false` on an enum value graphql 2.4.10 or later.

A type changes shape the same way: two classes with one `graphql_name` and lifecycles that do not overlap, each returned by its own field twin:

```ruby
class Types::MoneyV1 < Types::BaseObject
  graphql_name "Money"
  lifecycle removed: "2025-01-01"
  field :cents, Integer, null: false
end

class Types::MoneyV2 < Types::BaseObject
  graphql_name "Money"
  lifecycle added: "2025-01-01"
  field :amount, String, null: false
  field :currency, String, null: false
end

field :total, Types::MoneyV1, null: false, removed: "2025-01-01"
field :total, Types::MoneyV2, null: false, added: "2025-01-01"
```

Each version sees one `Money`. Reference each twin by its class: a `GraphQL::Schema::LateBoundType` naming a type with twins raises `ConfigurationError`, since graphql-ruby binds the name to the first class registered with it in every version. Give both twins a common base without a lifecycle; never subclass one twin from the other (the subclass would be refused as wider than its parent). A `resolve_type` answers the twin of the query's version (see "Data outside the version"), and Authorization's audit judges each twin's rule.

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

For tooling, `GraphQL::Armory::Versioning.types(AppSchema, "2024-06-01")` answers that version's schema: `type(name)`, `all_types`, `fields(type)`, `field(type, name)`, `arguments(field_or_input)`, `possible_types(type)`, `interfaces(type)`, `enum_values(enum)`, and `visible?(type)`. A type answers only when that version lists it, and a member only when its owner does. Pass `context: { current_user: ... }` when other `visible?` methods (such as Authorization's `visible_when:`) need it. It records no signal, and raises the refusal for a version that is not served. The objects it answers are graphql-ruby's own: calling `type.fields` on one, without a context, sees every version.

Without `armory_version:`, the `default:` policy applies: `:latest` dumps the latest version, and `:refuse` makes `to_definition` raise `MissingVersionError`, telling you the context to pass. `context: { armory_full_schema: true }` (Authorization's switch for a full dump) does not widen a version: there is no schema that holds every version at once. `Schema.validate(query, context: { armory_version: ... })` validates against that version the same way.

### Watching the rollout

Pass `sinks:` to see what the plugin decided, one signal per query:

| Signal | Data | When |
|---|---|---|
| `:version_served` | `version` | The request named a served version |
| `:version_defaulted` | `version` | The request named none, and `default:` picked one |
| `:version_refused` | `reason`: `:unknown`, `:retired` or `:missing` | The request was refused |

`version` is the schema's own label, never the client's value. `:version_defaulted` counts the clients that do not send a version yet; `:version_refused` with `:retired` counts the clients still on a version you retired. See [Telemetry](telemetry.md).

### The audit

Most mistakes in a versioned schema are refused with `ConfigurationError`, but only when a query first asks the member, which may be in production. The audit asks every member of every served version before that:

```ruby
report = GraphQL::Armory::Versioning::Audit.(AppSchema)
report.ok?
puts report
```

```ruby
# spec/graphql/versions_spec.rb
require "graphql/armory/versioning/rspec"

RSpec.describe AppSchema do
  it { is_expected.to have_consistent_versions }
end
```

```sh
bin/rake "graphql_armory:versions:audit[AppSchema]"   # prints the report; exit 1 on problems
```

It asks each member with a context that names the version and `armory_full_schema: true`, so Authorization's `visible_when:` never hides a refusal from it; it records no signal. What it reports:

| Kind | What it means |
|---|---|
| `:plugin` | The schema never installed `use GraphQL::Armory::Versioning` |
| `:visibility` | Neither `Schema::Visibility` nor `Schema::Warden` is used |
| `:refused` | A query of a served version would be refused: under `Schema` for the schema's own refusals (a root type or an `extra_types` type with a lifecycle, `AlwaysVisible`, a late-bound name with twins, an abstract load, subscription twins), otherwise at the member that refuses (overlapping twins, a default naming a member outside the version, shadowing, ...) |
| `:duplicate` | Two definitions of one type name that one version both sees (type twins whose lifecycles overlap) |
| `:empty` | An enum with no value in a served version |
| `:undeclared_version` | `added:` or `removed:` names a label that is not in `versions:` |
| `:outside_lifecycle` | A served version lists a type, field, argument, enum value or membership outside its lifecycle: your own `visible?` answers before the plugin's, or graphql-ruby serves it without asking. A client of that version gets it |
| `:unchecked` | Asking the member raised something else (an app `visible?` that needs a user, for example): it was not checked |

`ok?` means: no query of a served version is refused, and no served version lists a member outside its lifecycle. It does not check yet, and the report says so: members hidden in a version because their type is, fields served by a parent or an interface under the Warden, interfaces and unions left with no member, types with no visible field, your own `visible?` methods, defaults of arguments without `Base`, and subscription triggers. A schema-level refusal fails every query, so the audit reports it and asks no member; each schema check reports its first refusal.

### Testing with versioning

`Versioning::Controls` holds a small schema to test against: `Controls::Versions.example` (`2024-01-15` retired, `2024-06-01` and `2025-01-01` served), `Controls::Schema.example(visibility: :visibility | :warden, default:, base:, sinks:)` with a field of each lifecycle, `Controls::Root.example(resolved)` that records what resolved, and `Controls::Context.example(version:)`. For the other members: `Controls::Argument.example` and `Controls::EnumValue.example` (base classes with `Base`), `Controls::Status.example` and `Controls::InvoiceFilter.example` (an enum and an input object with a value or field of each lifecycle), `Controls::MembersQuery.example` (`invoices(filter:, first:, page:)` and `status`) and `Controls::MembersRoot.example(resolved, status:)`. The decision itself is `Versioning::Gate`: `Gate.build(versions:, default:, retired:)` takes `use`'s settings, `gate.(context)` answers a `Decision` and records its signal, and `gate.resolve(label)` answers it recording nothing. `Gate.new`, with nothing wired, refuses every request. `Gate::Substitute` answers the decision you tell it (`answer(decision)`) and records the contexts and labels it was asked about.

## Reference

`use GraphQL::Armory::Versioning, versions:, default:, retired: [], sinks: [], on_sink_error: nil`

- `versions:` an Array of non-empty String labels, oldest first, with no duplicate; ascending when every label is a date (`YYYY-MM-DD`).
- `retired:` an Array: the oldest labels of `versions:`, leaving at least one served.
- `default:` `:latest`, a served label, or `:refuse`. Required.
- `sinks:` an Array of callables taking `(signal, data)` or `(signal, data, context)`; `on_sink_error:` a callable `(error, signal)`. See [Telemetry](telemetry.md).
- Anything else raises `Versioning::ConfigurationError` when the schema loads.
- Works with your own `query_class`, set before `use`, after it, or in a child schema: the plugin subclasses it. `use` it once per schema hierarchy: a second `use`, on the same schema or a child, raises.

`include GraphQL::Armory::Versioning::Base` goes in a field, argument or enum value class (a subclass of `GraphQL::Schema::Field`, `Argument` or `EnumValue`); anywhere else it raises `ArgumentError` in this part. It adds `added:` and `removed:` to `field`, `argument` and `value`, each a non-empty String: anything else, or the same label for both, raises `ConfigurationError` when the member is defined. A label `versions:` does not hold, or a `removed:` before its `added:`, raises `ConfigurationError`, naming the member, every time a query asks about it: types load before `use`, so it cannot be checked earlier. `member.armory_lifecycle.to_h` answers `{ added:, removed: }`.

`include GraphQL::Armory::Versioning::Base` in an object, interface (after `include GraphQL::Schema::Interface`), union, enum, scalar, input object, resolver or mutation class adds the class method `lifecycle added:, removed:`, with the same rules; `Type.armory_lifecycle.to_h` answers it, inherited as described in "How to use it". `GraphQL::Armory::Versioning.types(schema, label, context: {})` answers a `Versioning::View`; `View.new` with nothing answers nothing.

These raise `ConfigurationError` when a query of the schema is built (a `GraphQL::Query` built by hand included), and from `Versioning.types`; a root or `extra_types` changed later is checked again:

- Two definitions of one argument name or enum value on a subscription field's arguments, or in an input object or enum they take: graphql-ruby's `trigger` reads those arguments with no version, where two definitions raise.

- A lifecycle on the query, mutation or subscription root type: a version without it would have no root. Version its fields.
- A type with a lifecycle in `extra_types`: `__type` and the SDL read `extra_types` without asking `visible?`.

These raise `ConfigurationError` when the class is defined, before anything is added, because graphql-ruby would ignore the keywords, apply them partly or add memberships without them: `implements` or `possible_types` with `added:` or `removed:` when the abstract type's `type_membership_class` does not include `Base`, when a member is named by a String, when the implemented interface implements other interfaces (implement each one directly), or when the class implementing is an interface. A membership class with `Base` also refuses a lifecycle between types that do not both include `Base` (an object class, and an interface or union), since the checks below run from those types.

This raises `ConfigurationError` when the argument is asked, and, under the legacy Warden, when any query of the schema is built, whatever the argument's class: an argument that `loads:` an interface or union with a versioned membership, because graphql-ruby checks the loaded object against the members with no context. Load the object types instead.

These raise `ConfigurationError` the first time a query asks about the type, because graphql-ruby would serve the membership or the interface's definitions where it does not live:

- An object or union with a versioned membership and another membership to the same abstract type or object (a parent's, or a repeated one), or, for an object, to an interface that includes the versioned one.
- A field, argument or enum value defined more than once on one owner, with lifecycles that overlap in the query's version.
- An object that implements an interface with a lifecycle whose field another of its interfaces or a parent class declares differently. Declare the field on the object, or rename one.


These raise `ConfigurationError`, naming the member, the first time a query asks about it, because graphql-ruby would otherwise serve the member outside its version:

- A type that lives in a version where one of its versioned ancestors does not.

- A `default_value:` that names an input field or enum value the query's version does not have, by its own lifecycle or its type's. Introspection would print it, and the field would run without it. Use a default that every version of the argument has. An enum value renamed across versions with the same Ruby `value:` counts as one: the default is fine in every version where either name lives. The check runs only on argument classes that include `Base`: an argument class without it can still print, in an older version's SDL, a default naming a value added later.
- A versioned argument or enum value with the same name as one its parent class defines (an input object, enum, resolver or mutation subclass, or a field's own argument over its resolver's). graphql-ruby serves the parent's definition where the local one is hidden. Version the parent's definition, or rename it.
- On a directive used in the SDL (any location such as `FIELD_DEFINITION` or `OBJECT`, on the directive or on a subclass of it), an argument with a lifecycle, or one whose type reaches a versioned type, enum value or input field: the SDL prints applied directive arguments as the latest version sees them, without asking `visible?`. Arguments of directives used only in queries (`FIELD`, `QUERY` and the rest) can be versioned and can use versioned enums; graphql-ruby's built-in directives cannot be versioned.

Context key: `armory_version` (a String naming a served version).

Errors: `Versioning::ConfigurationError` (a server-side setup mistake), `UnknownVersionError` (a label the list does not hold, a `ConfigurationError`), `RefusedVersionError` with `code`, and `MissingVersionError` (one of those, for a missing version).

## Guarantees and limits

**What is guaranteed.** A client that names version V gets V's schema on every path that reads the query's schema: selection and aliases, fragments, validation and its suggestions, introspection (`__schema`, `__type`, `fields`), `to_definition` and `Schema.validate` with V in the context, on the interpreter and on `Execution::Next`, and each query of a multiplex sees its own version. A refused version runs nothing, even with `validate: false`, and even when the query brings its own `static_validator:` (the plugin replaces it; a [persisted queries](persisted-queries.md) refusal is kept, since it runs nothing either). The version lives in the query's context: one query's version cannot reach another's. What this part covers is types, fields, arguments (input fields and directive arguments included), enum values and memberships (`implements`, `possible_types`).

**Limits.**

- **Lookups with no context see every field and argument.** With two definitions of one name, they raise graphql-ruby's `DuplicateNamesError` instead (`Types::Invoice.get_field("total")`, and the default values graphql-ruby checks when the schema boots). `Types::Invoice.get_field("amount")`, `Types::Invoice.fields`, `get_argument`, a union's `possible_types`, an object's `interfaces` and other lookups without a query answer the member whatever its lifecycle: graphql-ruby answers them without asking `visible?`. Enum values asked without a query (`Types::Status.values`) and, under `Schema::Visibility`, `AppSchema.get_type` answer the latest version. Read a version's schema through `Versioning.types(schema, label)` or `to_definition(context: { armory_version: ... })`.
- **Subscription triggers** build their query with `context: {}` unless you pass one, so the `default:` policy applies to them: under `default: :refuse` a trigger that reaches a versioned field raises `MissingVersionError`, and under `:latest` it cannot name a field removed in the latest version. Pass `context: { armory_version: ... }` to every `trigger`. Subscriptions are not tested with versioning yet.
- **Queries built outside `query_class`.** A `Query::Partial` (`run_partials`) sees its parent's version, because it reads its parent's schema, and so does the second context `Schema::Visibility`'s `migration_errors: true` builds for a query; neither records a signal. A `GraphQL::Query` your code builds itself skips `query_class`: it is decided from its own `armory_version` the first time a versioned field is asked about, and records no signal. A refused version raises `RefusedVersionError` there instead of answering a validation error, and such a query that touches no field of a class that includes `Base` runs.
- **`validate: false` with a field outside the version** raises graphql-ruby's own error ("No field definition found", or a `NoMethodError` on graphql 2.4) quoting the client's selection; nothing resolves.
- **The legacy `Schema::Warden` falls back.** When a type's own definition of a field is hidden in V, the Warden serves a parent class's or an interface's definition of the same name instead. `Schema::Visibility` never does: use it. For arguments and enum values, where graphql-ruby falls back on every path, the plugin refuses the shape instead (see Reference).
- **Data outside the version fails the response.** A resolver that returns an enum value the client's version does not have raises graphql-ruby's `GraphQL::Schema::Enum::UnresolvedValueError`, and a `resolve_type` that answers a type outside it raises `GraphQL::UnresolvedTypeError`, the twin of another version included; neither is turned into `null`. Filter or map the data in the resolver with `GraphQL::Armory::Versioning.version(context)`:

  ```ruby
  def docs                                            # Doc's member Contract arrived in 2025-01-01
    docs = Doc.all
    docs = docs.reject { |doc| doc.is_a?(Contract) } if GraphQL::Armory::Versioning.version(context) < "2025-01-01"
    docs
  end
  ```

  The plugin decides the schema, never the data.
- **Type twins whose lifecycles overlap** are not refused by the plugin: graphql-ruby raises its `DuplicateNamesError` wherever the name is looked up in a version both live in (introspection, the SDL, fragments, variables), but fields that return each class still run there. Keep their lifecycles apart.
- **Type twins outside a query.** Lookups with no context answer one twin: `AppSchema.get_type("Money")` and Warden's `AppSchema.types` the one the latest version sees (none, when no twin lives there). A `LateBoundType` is refused only when the field, argument or type naming it includes `Base`. Two mutations sharing a `graphql_name` generate two payload and input types sharing one too, so they are type twins as well, each with its mutation's lifecycle. Under the legacy Warden, a union's members are matched by name, so a union listing one twin makes the other findable by name. Authorization's check of an interface's implementers (an implementer that bypasses the interface's rule) reads every twin in every version: a bypass on one twin denies the interface's fields in all of them.
- **A type reachable only through types outside the version** is not listed, introspected or selectable there, but its name can still be found: a fragment or variable naming it gets a different error than an unknown name. Version such types together.
- **A type reachable only through a hidden membership** stays findable by name (`__type`, `__schema.types`, the SDL, `Versioning.types`) under `Schema::Visibility`, while the legacy Warden drops it. Give it its own `lifecycle`.
- **An interface or union left with no member in V.** The legacy Warden hides an interface with no visible implementer, with every field that returns it; `Schema::Visibility` keeps it, and an empty union prints as an invalid `union X` in the SDL. Give the abstract type the lifecycle its members have.
- **A required argument hidden in V is not required in V.** A client of a version where the argument does not exist cannot send it, so the field runs without it: the resolver needs a Ruby default for it. An input field hidden in V is absent from the input object, and a `validates required: { one_of: }` whose every option is hidden in V fails every request in V.
- **Default values that graphql-ruby checks at boot.** graphql-ruby validates every `default_value:` against the latest version when the schema loads, so a default naming an enum value removed in the latest version raises its `InvalidDefaultValueError` at boot, whatever the argument's own lifecycle.
- **An enum with every value hidden in V** raises graphql-ruby's `MissingValuesError` on any query that reaches it in V, introspection included. Give the enum the lifecycle instead.
- **Named `Schema::Visibility` profiles** (`profiles:`) are not supported yet: any field of a class that includes `Base` asked under one raises `ConfigurationError`. Dynamic profiles (`dynamic: true`, or no profiles) work.
- **`Schema::AlwaysVisible`** never asks `visible?`, so nothing would be versioned: the first query and `Versioning.types` raise `ConfigurationError` instead, even when it was added after `use`.
- **Your own `visible?`** on a base class must call `super`, or the plugin is skipped for those members.
- **Two refusing plugins.** With persisted queries, a request both refuse gets the persisted query's code. Either way nothing runs.
- **Signals.** `to_definition`, `Schema.validate` and subscription triggers go through `query_class` too, so each records one signal.
- **Cost.** A member without a lifecycle costs nothing (an argument's default value is read once). A versioned member costs a few Hash lookups each time graphql-ruby asks `visible?` (once per member per query). Not measured yet.
