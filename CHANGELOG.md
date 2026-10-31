# Changelog

## Unreleased

- The audit reaches more of what a client can reach: a `PageInfo` subclass with a field of its own, from a parent or from an interface, and a field added to or redefined on a custom `EntryPoints` or `DynamicFields`, with the types behind it. It also checks a Base resolver's arguments, a `RelayClassicMutation`'s included, reporting a missing action and listing `authorize: :none`. (#25)
- The audit no longer trusts `introspection(true)` on an app's type: graphql-ruby serves such a type like any other, so only a flagged type named with the reserved `__` prefix is exempt. It also reports a Base resolver whose own rule or argument asks another policy than the type's `policy:` as `:foreign_policy`: name the same `policy:` on the resolver. Documented limit: `use_visibility_profile: false` on one query, which the audit cannot see. (#24)
- **Breaking.** A Symbol a type wraps no longer names its own policy or CanCanCan rule: only the Symbol written as `model:` does, so client text turned into a Symbol cannot pick one. To upgrade, write `model: :name` on a rule whose subject is that Symbol. A `model:` that is a Symbol or a String with no constant now works with `authorize:`, where it raised `TypeError`. An answer overriding `==` no longer keeps an item in an Array scope, on Pundit and CanCanCan, and telemetry no longer fails on a record whose `class` is a data member (on the interpreter, graphql-ruby itself still refuses one). (#23)
- A `visible_when:` that cannot name its model is now a `:model` problem wherever it is: on a bypassed type or its fields, on arguments, input objects and directives, and on an interface. It raises at request time; the audit only raised on its first run under `Schema::Visibility`, and said ok after that or with no Visibility at all. The audit also follows directive arguments, so an input object only a directive takes is audited. (#22)
- **Breaking.** With Pundit, a record is now judged by both the policy of the model its type declares and the policy of its own class. The audit reads the first and the runtime read only the second, so a resolver returning a record of another class, or a subclass with a laxer policy, served a refused user with the audit ok. Each policy that exists must allow it. To upgrade, make a laxer subclass's type name that subclass as `model:`, or name the policy with `policy:`. A field rule inherited from an interface or a parent cannot read the concrete type's model, so the audit now reports it as `:foreign_model`: redefine the field on the type, or name the same model on the parent. Types named like an unrelated top-level constant now ask its policy: declare `model:`. A subclass of the declared model with no policy of its own now runs under the declared one instead of raising `NotDefinedError`; anything else with no policy still raises it. (#21)
- One `Audit` object can now serve several threads. It kept each run's state in instance variables, so concurrent runs overwrote each other and one could report no problems for a schema that had them. `Audit.(schema)` and `Audit.build(schema).(schema)` build what a run needs on each call. (#20)
- **Breaking.** The Pundit adapter finds a record's policy from its class. Pundit asks the record for `policy_class` and `model_name`, so an object built from client input, such as an `OpenStruct` from JSON, could name a laxer policy and serve a refused user. An Array is no longer read as a namespace, so `[:admin, record]` asks `ArrayPolicy`. To upgrade, move an instance `policy_class` or `model_name` to the class (`def self.policy_class`), or name the policy with `policy:` on the type's `authorize`. A decorator asks the decorator's class. ActiveRecord relations still ask their model; a list that is neither an Array nor a relation, such as a Mongoid criteria, needs `model:` on the rule. (#18)
- A String a type wraps no longer names its own policy: the Pundit adapter read it as a model name, so a type wrapping the client's text let the client pick the policy that judged it. It now asks `StringPolicy`, or raises `Pundit::NotDefinedError`. A String in `model:` still names a model. An app that relied on the old reading must wrap the value in a class with a policy (#17).
- `AdapterError` for a policy that does not answer `true`, `false` or `nil` now names the answer's class instead of quoting `inspect`, which could put a record in a message a client sees and run a relation's query. An app matching that text must update it (#17).
- A record, list or relation with no policy still raises `Pundit::NotDefinedError`, but the message now names its class. Pundit's own message quotes `inspect`, so an app that shows exception text to clients could show the record, and on a relation it ran the query. An app matching that text must update it (#16).
- The audit's `:foreign_policy` also covers connection and edge subclasses that name a `policy:`. A field rule on their parent asked another policy, so a refused user could get the data with the audit silent (#16).
- A field's or argument's `authorize:` and `visible_when:` now ask the `policy:` of the type that defines them, and the audit checks the action there. The `policy:` was dropped, so Pundit asked the policy found from the record: if that one was laxer, a user the type's policy refuses got the data, with the audit ok. An app that relied on this now gets denials, and an `AdapterError` at runtime when that policy lacks the action: add the method to the policy. The audit reports the missing action as an `:adapter` problem, except on a bypassed type and for a resolver's arguments. Under CanCanCan, which refuses `policy:`, such a rule now raises instead of serving. The `policy:` must be on the class that defines the rule (#14). A rule on an interface, on a parent whose subclass names the `policy:`, on an input object's argument or on a plain resolver's argument still asks another policy at runtime, because a field never sees its resolved type; the audit now reports each as a `:foreign_policy` problem until you move the rule or the `policy:`. There is no declaration for it. Only a type that names a `policy:` is checked (#15).
- The authorization audit follows every definition instead of `schema.types`, which is read with no request. A type or field hidden by `visible?`, or one of several definitions of a name, was not audited at all, so a user the rule refuses could get its records while the audit said ok. Such a schema can now report new problems: fix or declare them. A bypassed implementer hidden with no request now counts when an interface field runs, so that field is denied. With no `Schema::Visibility`, a hidden field falls back to another definition of its name, serving it with none of the override's rule, arguments, return type or extensions, so the audit reports every redefinition of a field or argument (on an input object, a resolver or one owner) until you remove one, use `Schema::Visibility` with `dynamic: true` and no `profiles:`, or declare `override_reason:` on the field or argument; a static profile still falls back and is reported, and so are two definitions on one owner under any profile. The definition a declared override shadows is audited too, own checks included, since the fallback serves it. A field a bypassed type inherits from a parent with a rule, or from a parent without `Base`, is served with no check, because a field runs under its owner's rule and the owner's type check never ran there; so is a field whose field class does not include `Base`, since graphql-ruby's own `authorized?` answers true: the audit said these were denied, and now says they are served, and asks you to give the field `authorize:` where it is defined or remove it, or to use a field class that includes `Base`. On a Relay schema without `Schema::Visibility` this reports `global_id_field :id` once per type that implements `Node`. A type listed nowhere, returned only by your own `resolve_type`, is not seen (#11).
- The authorization audit reports `reauthorize_scoped_objects` wherever it is off on an object, interface or union, and an own `self.scope_items`. With reauthorization off, records that came through the scope skip the rule, so a user the rule refuses got them while the audit said ok, and an own `scope_items` could add another account's records. The flag is reported even where it happens to skip nothing, because whether it does depends on the engine and the path. Remove them or declare them in `own_checks:` (#9).
- The authorization audit follows the whole `super` chain of an own check, and also reports an own `self.authorized_new` or `self.wrap`, and an own `visible?` where a `visible_when:` depends on it. Declare every level you keep in `own_checks:`.
- The authorization audit reports a rule on a class that includes `ConnectionBehaviors` or `EdgeBehaviors` as an `:ignored_rule` problem. Those modules answer `authorized?` with true, so the rule never ran. An audit that passed with such a rule now fails until it moves to the field.
- The authorization audit reports a schema that defines its own `unauthorized_field` or `unauthorized_object` as a `:hook` problem. Such a method wins over the plugin's, so `on_unauthorized:` did not apply to that denial and nothing said so. An app that keeps one on purpose declares it, with its reason: `own_denial_hooks: { unauthorized_field: "..." }`, which the audit lists as a bypass. A schema with its own hook that passed the audit now fails it. It also reports, as `:own_check` problems, what an app defines that wins over the plugin and can skip a rule or run code on a refused record: `authorized?` on a base field, argument, resolver, mutation, type or input object, `unauthorized_object` wherever graphql-ruby calls it, and `authorizes?`. Declare one with `own_checks: { Klass => { authorized?: "..." } }`. Docs: `docs/authorization.md`.

## 0.1.0.pre7 (2026-10-30)

Keyset connections (roadmap module 5). Docs: `docs/keyset-connections.md`.

- Keyset connections: `GraphQL::Armory::Keyset.build(relation)`, returned from a resolver, pages an ActiveRecord relation by its ordering columns instead of OFFSET, so rows inserted or deleted between pages neither skip nor repeat items. The primary key breaks ties. Orderings it cannot page raise `Keyset::ConfigurationError`. A cursor holds the ordering values, so the default Base64 encoder is refused unless `plain_cursors: true`. Types with authorization scope the relation inside the connection. Docs: `docs/keyset-connections.md`.
- Docs: new section "Clients that change identity" in `docs/rate-limiting.md`. A limit per key does not stop a client that gets a new IP or a new account for every request; the page now says so, shows how to share one bucket among new accounts or put a ceiling on everyone, and lists what belongs before GraphQL (signup limits, verification, network blocking). No code change.
- Docs: how to count probes against a strict persisted-queries endpoint. Strict mode refuses before validating, so a detector that counts validation errors goes blind; `:operation_refused` with `reason: :raw_query` is the strike to count instead. New section in `docs/persisted-queries.md` and a row in the "What to watch for" table of `docs/telemetry.md`. No code change.

## 0.1.0.pre6 (2026-10-30)

Telemetry for every module, and the processing-time layer of rate limiting. Docs: `docs/telemetry.md`, `docs/rate-limiting.md`.

- Telemetry for every module. `GraphQL::Armory::Telemetry` (the class authorization already used, now shared; `Authorization::Telemetry` is the same class) takes `sinks:` in `use GraphQL::Armory::IDs` and `use GraphQL::Armory::PersistedQueries`, as it does in authorization. IDs record `:id_resolved` and `:id_refused` (with `reason`: `:invalid`, `:malformed`, `:unknown_type`, `:not_found`); persisted queries record `:operation_persisted`, `:operation_refused` (`:unknown_operation`, `:mismatch`, `:raw_query`), `:raw_query_run` and `:raw_query_allowed`. A signal never holds an ID, an operation id or a query. `Telemetry::Notifications` reports them to `ActiveSupport::Notifications` as `<signal>.graphql_armory`. A `sinks:` that is not an Array of callables now raises `Telemetry::ConfigurationError` at boot, also in authorization (before, at the first query); the message names the offending class and never prints the value. Every sink receives the same frozen data. New page `docs/telemetry.md`: every signal, what to watch for, how to test.
- Rate limiting, processing time: `use GraphQL::Armory::RateLimits::Time, store:, limit:, window: 60` charges each client the wall-clock milliseconds its operations took, against a bucket of milliseconds that refills over the window. A query analyzer refuses a client with no milliseconds left before any field resolves (`RATE_LIMITED`, with `retryAfter`); a trace measures the multiplex with a monotonic clock and charges it when it ends, even when it raises, split equally among its queries. Soft mode is the default; `extensions: true` adds `rateLimitTime` to the response and `Time.headers(result)` answers `RateLimit-Time-*`. It needs no store changes. `RateLimits::Clock::Substitute` and `Controls::Time.example` are there for your specs.

## 0.1.0.pre5 (2026-10-29)

Rate limiting (roadmap module 4). Docs: `docs/rate-limiting.md`. All four modules now follow the Useful Objects doctrine.

- Rate limiting, part 1: `use GraphQL::Armory::RateLimits::Points, store:, limit:, window:` charges each query its complexity against a bucket of points per client (`context[:rate_limit_key]`) that refills over the window. Over-limit queries are refused before running, with their cost, what remains and when to retry; soft mode (the default) only records. `RateLimits::MemoryStore` for tests and single processes. Docs: `docs/rate-limiting.md`.
- Rate limiting, part 2: `use GraphQL::Armory::RateLimits::Concurrency, store:, limit:, stale_after: 60` lets each client run at most `limit` operations at the same time. A query analyzer takes a slot before the operation runs (or refuses it, `RATE_LIMITED`); a trace releases every slot when the multiplex ends, even when it raises. Slots expire after `stale_after` seconds. `MemoryStore` gains `acquire` and `release`.
- Rate limiting, part 3: clients can see their budget on every response. `Points` takes `extensions: true` to add `rateLimit` (`cost`, `limit`, `remaining`, `resetIn`) to the response extensions, and `Points.headers(result)` answers `RateLimit-Limit`, `RateLimit-Remaining` and `RateLimit-Reset`.
- Rate limiting, part 4: `RateLimits::RedisStore.new(redis:)` keeps buckets and slots in Redis, shared by every process. Each change is one Lua script and the time comes from Redis, so concurrent requests never race and servers agree on the clock. Keys expire on their own. The app adds the redis gem.
- Rate limiting follows the Useful Objects doctrine like authorization: `Points.new` and `Concurrency.new` are inert and refuse every query (`Store::Null`), `build` checks the settings and wires the store, `call` is the actuator. `RateLimits::Store::Substitute` (a MemoryStore on a test clock that records calls and fails when told) and `RateLimits::Controls` are there for your specs.
- Encrypted IDs and persisted queries follow the same doctrine: `IDs::Lookup.new` is inert (`Encoder::Null`) and `build` wires `Encoder.default`; `PersistedQueries::Gate` holds the decision, with an inert `new` (`Store::Null`, strict) and `build`. `Encoder::Substitute`, `PersistedQueries::Store::Substitute` and `Controls` for both are there for your specs. `IDs` now refuses at boot a `find:` that is not callable and an encoder without `encode` and `decode`.

## 0.1.0.pre4 (2026-10-29)

Persisted queries / operation allowlist (roadmap module 3). Docs: `docs/persisted-queries.md`.

- Persisted queries, part 1: `GraphQL::Armory::PersistedQueries::Manifest` loads Apollo's persisted query manifest or Relay's persisted output, checks every id is the digest of its query (sha256, md5 or sha1) and parses each query once; any problem raises at boot.
- Persisted queries, part 2: `use GraphQL::Armory::PersistedQueries, store:, strict:` runs the stored operation a request names by id (`context[:operation_id]`; `PersistedQueries.operation_id(params)` reads it from `operationId`, `extensions.operationId` or `extensions.persistedQuery.sha256Hash`). Unknown ids and mismatched queries are refused; strict mode refuses raw queries unless the context holds `armory_allow_raw_query: true`. Docs: `docs/persisted-queries.md`.

## 0.1.0.pre3 (2026-10-29)

Encrypted, versioned IDs and cursors (roadmap module 2), and a docs page per module.

- Encrypted IDs and cursors, part 4: `use GraphQL::Armory::IDs` defines `id_from_object` and `object_from_id` with encrypted IDs (default encoder unless `encoder:`); Base types are looked up inside the user's scope, other types through `find:`; every ID it cannot honour answers `null`.
- Encrypted IDs and cursors, part 3: `Encoder.default`, keyed by `GRAPHQL_ARMORY_KEY` or, in Rails, by a key derived with HKDF from `secret_key_base` (not from `Rails.application.key_generator`, whose digest changes during boot); it raises when the schema loads without either.
- Encrypted IDs and cursors, part 2: `Encoder.versioned(newest, ..., oldest)` and `decode_versioned` to rotate keys without breaking clients; `Encoder::Legacy` reads graphql-ruby's default base64 to add encryption to an existing API.
- Encrypted IDs and cursors, part 1: `GraphQL::Armory::Encoder` (AES-256-GCM, HKDF subkeys, stable IDs, random-nonce cursors, `key`, `tag`, `codec`). Works as `cursor_encoder` and inside `object_from_id`; an ID it refuses in `loads:` is answered like a missing record. See `docs/encrypted-ids.md`.
- Docs: each module has its own page in `docs/` (the problem, the solution, how to use it, guarantees and limits). The authorization guide moved from the README to `docs/authorization.md`; the README now lists the modules.

## 0.1.0.pre2 (2026-10-29)

Closes the known gaps of the authorization module.

- `loads:` inside input objects: `include GraphQL::Armory::Authorization::Base` in the base input object loads them through
  the user's scope; the audit reports input objects whose `loads:` skip it.

- Audit of interfaces: an interface field is reported once, on the interface that declares it; `authorize: true` on an
  interface field and interface fields whose field class lacks `Base` (such as Relay `Node.id`) on a bypassed implementer
  are reported.

- Global IDs in `loads:`: when the schema defines `object_from_id`, the id is decoded with it, a record of another model is
  refused, and the record is looked up again inside the user's scope.

## 0.1.0.pre (2026-10-29)

First prerelease on RubyGems: Pundit and CanCanCan adapters, deny-by-default coverage, scoped lists and lookups, schema audit,
visibility, argument rules, mutations and resolvers, interfaces and unions. The entries below describe it.

- Interfaces and unions: an interface field with no rule is denied when an implementing type is a bypass, and the audit
  reports it; `include Base` in an interface or union is refused with a pointer to the possible types.

- Mutations and resolvers: `authorize :action, model:, on_denied:` on a mutation or resolver that includes `Base`. Denied by
  default when it declares no rule; the rule runs on the loaded records; `on_denied: :errors` answers as data;
  `covers_fields: true` lets a payload type be covered by its mutation. The audit lists mutations with no rule.

- Argument rules: `authorize: :action`, `visible_when:` and `authorize: :none, reason:` on arguments. An argument with no rule
  is covered by its field; a declared rule is checked when the client sends it and a denial denies the field.

- Visibility driven by the policy: `authorize :read, visible_when: :export` on a type and `visible_when:` on a field hide
  them from introspection and error suggestions. A schema dump needs `context: { armory_full_schema: true }`.

- CanCanCan adapter (`adapter: :cancan`): `can?` with the field attribute, `accessible_by` for relations, and
  `MissingScopeError` for block-only rules unless the type declares `authorize :read, scope: :in_memory`.

- Black-box security suite (`spec/security`), runnable example (`examples/invoices.rb`), benchmark,
  README and MIGRATING guide.
- Execution::Next is supported from graphql 2.6.2: in 2.5.26 to 2.6.1 a denied field crashes the engine.
  The integration refuses to run there.
- Gem skeleton: gemspec, Docker test image, RSpec with an execution-engine switch
  (`GRAPHQL_ARMORY_ENGINE=interpreter|next`) and a CI matrix.
