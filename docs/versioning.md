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

A member lives from `added:` (the first version when absent) up to, not including, `removed:` (still here when absent). A member with neither lives in every version. Every field and enum value of a class that includes `Base` still reads the query's version when graphql-ruby asks whether it is visible; an argument reads it only when it, its default value or the type it `loads:` is versioned. `deprecation_reason:` is graphql-ruby's own and works as always: the member is deprecated in every version it exists in. To deprecate it from a given version on, use `deprecated:` (see "Deprecating").

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

### Deprecating

`deprecated:` with `deprecation_reason:` deprecates a member from one version on. Clients of earlier versions see it as it was, with no `@deprecated`; clients of that version and later ones see the reason in introspection, in the SDL, and in `includeDeprecated: false` lists, which leave it out. It works on fields (of objects, interfaces and mutation payloads), arguments (of fields, resolvers and mutations), input fields and enum values, and combines with `added:` and `removed:`:

```ruby
class Types::Invoice < Types::BaseObject
  field :amount, Integer, null: false, deprecated: "2024-06-01", deprecation_reason: "Use `total`",
                 removed: "2025-01-01"                  # plain up to 2024-06-01, deprecated in 2024-06-01, gone after
  field :tags, [String], null: false do
    argument :page, Integer, required: false, deprecated: "2025-01-01", deprecation_reason: "Use `after`"
  end
end

class Types::Status < Types::BaseEnum
  value "CANCELLED", deprecated: "2025-01-01", deprecation_reason: "Use `VOID`"
end
```

graphql-ruby's `deprecation_reason` is the same in every version a definition lives in, so `deprecated: D` is written for you as the two definitions of the section above: one living up to `D` with no reason, and one from `D` with it. The `amount` field above is exactly:

```ruby
field :amount, Integer, null: false, removed: "2024-06-01"
field :amount, Integer, null: false, added: "2024-06-01", removed: "2025-01-01", deprecation_reason: "Use `total`"
```

So everything said about two definitions applies: [Authorization](authorization.md)'s audit reads them as one member (a problem with both is listed once), each keeps the field's keywords (its rule, its `resolver:`), lookups with no query raise graphql-ruby's `DuplicateNamesError` on the name (see "Guarantees and limits"), and field definitions need graphql 2.4.9 or later, enum values 2.4.10 or later. A field's block runs once per definition, so the arguments it declares, with their own lifecycles, belong to both. An enum value's Ruby method (`Types::Status.cancelled`) is defined once, by the first definition.

The class that defines the member writes the two definitions, so `deprecated:` needs `Base` in that class (the object, interface, input object, enum, resolver or mutation, or the field class for a field's arguments) as well as in the member's class. It is refused on a subscription's arguments: graphql-ruby's trigger reads them with no version, where two definitions raise.

To test against it, `Versioning::Controls::Deprecations::Query.example(Bases.example)` is a query type with `deprecated:` on each member kind, deprecated from `2025-01-01`, and `Deprecations::Root.example` its root object.

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
| `:empty` | A served version has an enum with no value, an object, interface or input object with no field (a client can select only `__typename`; a type with `has_no_fields(true)` is not reported), or a union with no member |
| `:orphan_interface` | A served version has no object implementing an interface. The Warden hides the interface and every field that returns it; `Schema::Visibility` serves it with an empty `possibleTypes`, so a fragment on any object fails, and data returned for it raises |
| `:implicit` | A served version hides a required argument or input field because its type is outside the version (for `loads:`, the loaded type): a client of that version can call the field without it, and the resolver runs with no value. An optional member or a field hidden this way is listed as information, and so is an argument with `required: :nullable` |
| `:fallback` | A served version hides a type's own definition of a field while a parent class's or an interface's definition of that name lives there. The legacy Warden serves that other definition, with its type, arguments and resolver; `Schema::Visibility` drops the field, and when an interface declares it the type no longer implements the interface. Also reported: an argument the type's field hides in a version while the interface's field takes it |
| `:own_check` | Your own `visible?` answers before the plugin's: on a type, resolver or mutation class, a field, argument, enum value or membership class, or the schema's `self.visible?`. If it does not call `super`, it serves members outside their lifecycle (on the schema, nothing is versioned). Declare each one you keep in `own_checks:` with a reason: it is then listed as information. A `def self.visible?` on one member (inside a field's block) is reported at that member and cannot be declared. A class named in `own_checks:` with no such method is reported too |
| `:default_value` | A `default_value:` names an enum value the latest version does not have (graphql-ruby prints defaults as the latest version sees them, so `to_definition` raises in every version), or, on an argument class without `Base`, an enum value or input field a served version does not have (that version's introspection raises, and its SDL raises or prints what the version does not have) |
| `:subscription_trigger` | A subscription field's argument or nested input field is in a served version and not in the latest, or the reverse. graphql-ruby's `trigger` fills in the default of every argument whatever its version: with a default, a trigger naming the version without it raises and a trigger naming another version never reaches that version's subscribers; without one, a trigger that passes it raises unless its context names a version that has it. Listed as information: a subscription field the `default:` version does not have, and `default: :refuse`, since a trigger that names no version raises |
| `:undeclared_version` | `added:` or `removed:` names a label that is not in `versions:` |
| `:outside_lifecycle` | A served version lists a type, field, argument, enum value or membership outside its lifecycle: your own `visible?` answers before the plugin's, or graphql-ruby serves it without asking. A client of that version gets it |
| `:unchecked` | Asking the member raised something else (an app `visible?` that needs a user, for example): it was not checked |

`ok?` means: no query of a served version is refused, no served version lists a member outside its lifecycle, and none is left with a required argument it cannot see, a type with nothing in it, or a field or argument that another definition of its name serves or that an interface still declares; no `visible?` of yours answers before the plugin's undeclared; no default names a value or input field its version does not have; and no subscription trigger breaks on an argument that differs between versions. Information (an optional member hidden because its type is, the natural way to version a field with its type, a declared `visible?`, a subscription field outside the `default:` version) is printed under "Information:" and does not fail `ok?`. It does not check yet, and the report says so: whether a type's field or argument in a version has a type its interface's definition allows (covariance). A schema-level refusal fails every query, so the audit reports it and asks no member; each schema check reports its first refusal.

### Evolving a version

A change reaches clients in four steps. Each one is a new label at the end of `versions:` (or a lifecycle that names one you already have), and older clients keep what they had until their version is retired:

1. **Add.** Give the new member `added: "2025-01-01"`. Older versions never see it.
2. **Deprecate.** `deprecation_reason:` labels the member in every version it lives in; `deprecated:` labels it from one version on (see "Deprecating"). Clients still get it.
3. **Remove.** Give it `removed: "2025-06-01"`: clients of the versions before keep it, and only a client that moves to 2025-06-01 loses it. To change a member's shape instead, give it a twin (see "How to use it").
4. **Retire.** Once no client asks for the oldest versions (`:version_served` for them reaches zero), move them to `retired:`. A member whose `removed:` is the oldest served version or earlier is now served nowhere: delete it, and delete a label from `versions:` once nothing names it.

Two tools show what each step changes. The dump writes each served version's SDL to a file, so a pull request shows every version's schema change line by line:

```sh
bin/rake "graphql_armory:versions:dump[AppSchema,schema]"   # schema/2024-06-01.graphql, schema/2025-01-01.graphql, schema/latest.graphql
```

```ruby
GraphQL::Armory::Versioning::Dump.(AppSchema, "schema")      # the paths it wrote
```

Commit the directory, and in CI run the dump and then `git diff --exit-code schema/` to fail a build whose dumps are out of date. Each file is `to_definition(context: { armory_version: label, armory_full_schema: true })`, so Authorization's `visible_when:` hides nothing from it; `latest.graphql` is the latest version's. Retired versions are not written, and the file of a version you retire stays until you delete it. Every SDL is printed before the first file is written. A label becomes a file name, so the dump refuses (`ConfigurationError`, writing nothing) a label with a slash, a backslash or a NUL, one that starts with a dot, `latest` in any case, and two labels that differ only by case.

The diff says what changes between two served versions for a client built against the first:

```ruby
result = GraphQL::Armory::Versioning::Diff.(AppSchema, from: "2024-06-01", to: "2025-01-01")
result.breaking?    # true when a client of 2024-06-01 can break on 2025-01-01
puts result
```

```sh
bin/rake "graphql_armory:versions:diff[AppSchema,2024-06-01,2025-01-01]"   # prints it; exit 1 when something breaks
```

```ruby
# spec/graphql/versions_spec.rb, for a version line that should only grow
require "graphql/armory/versioning/rspec"

RSpec.describe AppSchema do
  it { is_expected.to have_no_breaking_changes(from: "2024-06-01", to: "2025-01-01") }
end
```

```
From 2024-06-01 to 2025-01-01:

Breaking (2):
  Invoice.amount: field removed
  Query.invoices.limit: type changed from Int to Int!

Dangerous (1):
  Status.VOID: value added

Safe (1):
  Invoice.tags: field added
```

| Bucket | What it lists |
|---|---|
| Breaking: a query that worked against `from` can fail against `to` | A type, field, argument, input field, enum value or union member removed; a required argument or input field added (non-null with no default), or a default removed from a non-null one; a type changed (see nullability below); an interface no longer implemented; a type's kind changed (a scalar that became an object) |
| Dangerous: queries still validate, but a client may meet something it does not expect | An enum value, union member or implemented interface added; a deprecation added; a default value added, changed or removed; an output made non-null |
| Safe | A type, field, optional argument or optional input field added; an input made nullable; a deprecation removed or its reason changed; a description changed |

Nullability follows the GraphQL spec's rules for each direction. An output that becomes nullable (`String!` to `String`) is breaking: the client gets a `null` it never handled. An output that becomes non-null (`String` to `String!`) is dangerous: two fields with one response name must have the same shape to merge, so a query selecting it beside a nullable field of the same name on another type stops validating. An input that becomes non-null (`Int` to `Int!`) is breaking; one that becomes nullable (`Int!` to `Int`) is safe, since a `Int!` variable is still allowed where `Int` is expected. The same rules apply inside lists.

Types are compared by name, as a client sees them. A renamed type is a type removed, a type added, and each field or argument that used it changed, all breaking for the old name's clients. Type twins with one name are compared field by field, and field, argument and enum value twins by their type, default and deprecation, so a twin that changes nothing a client sees lists nothing. Each version is read through `Versioning.types` with `armory_full_schema: true`; pass `context:` when your own `visible?` methods need a user. Directives are not compared. A built-in scalar (`Int`, `Float`, ...) that no member of the newer version uses is listed as a type removed, since a query declaring a variable of that type would no longer validate. Two definitions of one name that one version both sees raise graphql-ruby's `DuplicateNamesError`, as in a query: run the audit first.

`Versioning::Controls::Evolution.example(visibility:)` is a schema with one change of each kind from 2024-06-01 to 2025-01-01, and `Evolution::BREAKING`, `DANGEROUS` and `SAFE` list what the diff answers for it.

### Testing with versioning

`Versioning::Controls` holds a small schema to test against: `Controls::Versions.example` (`2024-01-15` retired, `2024-06-01` and `2025-01-01` served), `Controls::Schema.example(visibility: :visibility | :warden, default:, base:, sinks:)` with a field of each lifecycle, `Controls::Root.example(resolved)` that records what resolved, and `Controls::Context.example(version:)`. For the other members: `Controls::Argument.example` and `Controls::EnumValue.example` (base classes with `Base`), `Controls::Status.example` and `Controls::InvoiceFilter.example` (an enum and an input object with a value or field of each lifecycle), `Controls::MembersQuery.example` (`invoices(filter:, first:, page:)` and `status`) and `Controls::MembersRoot.example(resolved, status:)`. The decision itself is `Versioning::Gate`: `Gate.build(versions:, default:, retired:)` takes `use`'s settings, `gate.(context)` answers a `Decision` and records its signal, and `gate.resolve(label)` answers it recording nothing. `Gate.new`, with nothing wired, refuses every request. `Gate::Substitute` answers the decision you tell it (`answer(decision)`) and records the contexts and labels it was asked about.

## Reference

`use GraphQL::Armory::Versioning, versions:, default:, retired: [], sinks: [], on_sink_error: nil, own_checks: {}`

- `versions:` an Array of non-empty String labels, oldest first, with no duplicate; ascending when every label is a date (`YYYY-MM-DD`).
- `retired:` an Array: the oldest labels of `versions:`, leaving at least one served.
- `default:` `:latest`, a served label, or `:refuse`. Required.
- `sinks:` an Array of callables taking `(signal, data)` or `(signal, data, context)`; `on_sink_error:` a callable `(error, signal)`. See [Telemetry](telemetry.md).
- `own_checks:` a Hash mapping each class or module that defines a `visible?` of yours ahead of the plugin's to `{ visible?: "the reason you keep it" }`, for the audit (`:own_check`). Nothing else is accepted: `{ Types::BaseObject => { visible?: "hides drafts from guests, calls super" } }`. A schema's own `self.visible?` is declared under the schema class.
- Anything else raises `Versioning::ConfigurationError` when the schema loads.
- Works with your own `query_class`, set before `use`, after it, or in a child schema: the plugin subclasses it. `use` it once per schema hierarchy: a second `use`, on the same schema or a child, raises.

`include GraphQL::Armory::Versioning::Base` goes in a field, argument or enum value class (a subclass of `GraphQL::Schema::Field`, `Argument` or `EnumValue`); anywhere else it raises `ArgumentError` in this part. It adds `added:` and `removed:` to `field`, `argument` and `value`, each a non-empty String: anything else, or the same label for both, raises `ConfigurationError` when the member is defined. A label `versions:` does not hold, or a `removed:` before its `added:`, raises `ConfigurationError`, naming the member, every time a query asks about it: types load before `use`, so it cannot be checked earlier. `member.armory_lifecycle.to_h` answers `{ added:, removed: }`.

`deprecated:` (a non-empty String naming a version) goes with `deprecation_reason:` on `field` in an object, interface, resolver or mutation class, on `argument` in a field, input object, resolver or mutation class, and on `value` in an enum class, when that class includes `Base`. It defines the member twice, as `removed: D` with no reason and `added: D` with the reason, each keeping the other keywords; the enum value's second definition gets `value_method: false`. It raises `ConfigurationError` when the member is defined: without `deprecation_reason:`, with the label of `added:` or `removed:`, in a class without `Base` (the member's class reports it), on the arguments of a `GraphQL::Schema::Subscription` class, and on a `resolver:` (or `mutation:`, `subscription:`) field whose resolver class has its own `deprecation_reason`, which graphql-ruby would give the field in every version. A `deprecated:` outside `added:`..`removed:` in `versions:` raises the first time a query asks, like any lifecycle out of order.

`include GraphQL::Armory::Versioning::Base` in an object, interface (after `include GraphQL::Schema::Interface`), union, enum, scalar, input object, resolver or mutation class adds the class method `lifecycle added:, removed:`, with the same rules; `Type.armory_lifecycle.to_h` answers it, inherited as described in "How to use it". `GraphQL::Armory::Versioning.types(schema, label, context: {})` answers a `Versioning::View`; `View.new` with nothing answers nothing.

These raise `ConfigurationError` when a query of the schema is built (a `GraphQL::Query` built by hand included), and from `Versioning.types`; a root or `extra_types` changed later is checked again:

- Two definitions of one argument name or enum value on a subscription field's arguments, or in an input object or enum they take: graphql-ruby's `trigger` reads those arguments with no version, where two definitions raise. `deprecated:` makes two definitions, so it is refused there too.

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

- A `default_value:` that names an input field or enum value the query's version does not have, by its own lifecycle or its type's. Introspection would print it, and the field would run without it. Use a default that every version of the argument has. An enum value renamed across versions with the same Ruby `value:` counts as one: the default is fine in every version where either name lives. The check runs only on argument classes that include `Base`: an argument class without it can still print, in an older version's SDL, a default naming a value added later; the audit reports it (`:default_value`).
- A versioned argument or enum value with the same name as one its parent class defines (an input object, enum, resolver or mutation subclass, or a field's own argument over its resolver's). graphql-ruby serves the parent's definition where the local one is hidden. Version the parent's definition, or rename it.
- On a directive used in the SDL (any location such as `FIELD_DEFINITION` or `OBJECT`, on the directive or on a subclass of it), an argument with a lifecycle, or one whose type reaches a versioned type, enum value or input field: the SDL prints applied directive arguments as the latest version sees them, without asking `visible?`. Arguments of directives used only in queries (`FIELD`, `QUERY` and the rest) can be versioned and can use versioned enums; graphql-ruby's built-in directives cannot be versioned.

`GraphQL::Armory::Versioning::Diff.(schema, from:, to:, context: {})` is `Diff.build(schema, context:).(from:, to:)` and answers a `Diff::Result`: `changes`, `breaking`, `dangerous` and `safe` (each a list of `Diff::Change` with `bucket`, `path` and `message`, breaking first, sorted by path), `breaking?`, `from`, `to`, and `to_s`. A label `versions:` does not hold raises `UnknownVersionError`; a retired one, or a schema that never installed the plugin, `ConfigurationError`. `Diff.new` has no schema and raises `ConfigurationError` instead of answering no changes; `Diff.new(reader)` reads each version through `reader.view(label)`. `Diff::Reader::Substitute` answers the views it is told (`answer(label, view)`) and records `labels`; `Diff::Substitute.new(result)` answers `result` and records `calls`.

`GraphQL::Armory::Versioning::Dump.(schema, dir, context: {})` is `Dump.build(dir).(schema, context:)` and answers the paths it wrote: each served version oldest first, then `latest.graphql`. It creates `dir` when missing. An empty `dir` raises `ConfigurationError`. `Dump.new` writes nothing and answers `[]`; `Dump.new(directory)` writes through `directory.write(name, text)`. `Dump::Directory::Substitute` records `written` (file name => SDL) and, told `fail_with(error)`, raises it.

Rake tasks (Rails loads them; elsewhere `load "tasks/graphql_armory.rake"` from the gem):

- `graphql_armory:versions:dump[Schema,dir]`: writes the files (`dir` defaults to `schema`) and prints each path; exit 1 on a missing or unknown schema or a `ConfigurationError`.
- `graphql_armory:versions:diff[Schema,from,to]`: prints the diff; exit 1 when something breaks, on a missing argument, an unknown schema or a version it cannot compare.

Context key: `armory_version` (a String naming a served version).

Errors: `Versioning::ConfigurationError` (a server-side setup mistake), `UnknownVersionError` (a label the list does not hold, a `ConfigurationError`), `RefusedVersionError` with `code`, and `MissingVersionError` (one of those, for a missing version).

## Guarantees and limits

**What is guaranteed.** A client that names version V gets V's schema on every path that reads the query's schema: selection and aliases, fragments, validation and its suggestions, introspection (`__schema`, `__type`, `fields`), `to_definition` and `Schema.validate` with V in the context, on the interpreter and on `Execution::Next`, and each query of a multiplex sees its own version. A refused version runs nothing, even with `validate: false`, and even when the query brings its own `static_validator:` (the plugin replaces it; a [persisted queries](persisted-queries.md) refusal is kept, since it runs nothing either). The version lives in the query's context: one query's version cannot reach another's. What this part covers is types, fields, arguments (input fields and directive arguments included), enum values and memberships (`implements`, `possible_types`).

**Limits.**

- **Lookups with no context see every field and argument.** With two definitions of one name, they raise graphql-ruby's `DuplicateNamesError` instead (`Types::Invoice.get_field("total")`, and the default values graphql-ruby checks when the schema boots). `Types::Invoice.get_field("amount")`, `Types::Invoice.fields`, `get_argument`, a union's `possible_types`, an object's `interfaces` and other lookups without a query answer the member whatever its lifecycle: graphql-ruby answers them without asking `visible?`. Enum values asked without a query (`Types::Status.values`) and, under `Schema::Visibility`, `AppSchema.get_type` answer the latest version. Read a version's schema through `Versioning.types(schema, label)` or `to_definition(context: { armory_version: ... })`.
- **Subscription triggers** build their query with `context: {}` unless you pass one, so the `default:` policy applies to finding the field: under `default: :refuse` a trigger that reaches a versioned field raises `MissingVersionError`, and under `:latest` it cannot name a field removed in the latest version. Pass `context: { armory_version: ... }` to every `trigger`, naming a version that has the field and the arguments you pass. Its arguments are another matter: graphql-ruby reads them with no query, where every definition counts, fills in the default of every argument and input field whatever its version, and then builds the topic with the trigger's version. So a subscription argument with a default that one served version does not have breaks that version's triggers (a trigger naming it raises, and a trigger naming another version never reaches its subscribers), whatever context you pass. Keep subscription arguments with a default in every version; the audit reports the ones that differ (`:subscription_trigger`). Each subscriber's update runs with the context it stored, so its own version applies there.
- **Queries built outside `query_class`.** A `Query::Partial` (`run_partials`) sees its parent's version, because it reads its parent's schema, and so does the second context `Schema::Visibility`'s `migration_errors: true` builds for a query; neither records a signal. A `GraphQL::Query` your code builds itself skips `query_class`: it is decided from its own `armory_version` the first time a versioned field is asked about, and records no signal. A refused version raises `RefusedVersionError` there instead of answering a validation error, and such a query that touches no field of a class that includes `Base` runs.
- **`validate: false` with a field outside the version** raises graphql-ruby's own error ("No field definition found", or a `NoMethodError` on graphql 2.4) quoting the client's selection; nothing resolves.
- **The legacy `Schema::Warden` falls back.** When a type's own definition of a field is hidden in V, the Warden serves a parent class's or an interface's definition of the same name instead. `Schema::Visibility` never does: use it. Under either, the audit reports the shape (`:fallback`): version the parent's or the interface's definition with the type's. For arguments and enum values, where graphql-ruby falls back on every path, the plugin refuses the shape instead (see Reference).
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
- **Default values that graphql-ruby checks at boot.** graphql-ruby validates every `default_value:` against the latest version when the schema loads, so a default naming an enum value removed in the latest version raises its `InvalidDefaultValueError` at boot, whatever the argument's own lifecycle. An argument defined after the schema loaded (code reloading) escapes that check, and then `to_definition` raises in every version: the audit reports it (`:default_value`).
- **An enum with every value hidden in V** raises graphql-ruby's `MissingValuesError` on any query that reaches it in V, introspection included. Give the enum the lifecycle instead.
- **Named `Schema::Visibility` profiles** (`profiles:`) are not supported yet: any field of a class that includes `Base` asked under one raises `ConfigurationError`. Dynamic profiles (`dynamic: true`, or no profiles) work.
- **`Schema::AlwaysVisible`** never asks `visible?`, so nothing would be versioned: the first query and `Versioning.types` raise `ConfigurationError` instead, even when it was added after `use`.
- **Your own `visible?`** on a base class, or the schema's `self.visible?`, must call `super`, or the plugin is skipped for those members. The audit cannot read whether it does: it reports each one (`:own_check`) until you declare it in `own_checks:`.
- **Two refusing plugins.** With persisted queries, a request both refuse gets the persisted query's code. Either way nothing runs.
- **Signals.** `to_definition`, `Schema.validate` and subscription triggers go through `query_class` too, so each records one signal.
- **Cost.** A member without a lifecycle costs nothing (an argument's default value is read once). A versioned member costs a few Hash lookups each time graphql-ruby asks `visible?` (once per member per query). Not measured yet.
