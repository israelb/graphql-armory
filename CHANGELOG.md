# Changelog

## Unreleased

- The authorization audit follows every definition instead of `schema.types`, which is read with no request. A type or field hidden by `visible?`, or one of several definitions of a name, was not audited at all, so a user the rule refuses could get its records while the audit said ok. Such a schema can now report new problems: fix or declare them. A type listed nowhere, returned only by your own `resolve_type`, is not seen (#11).
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
