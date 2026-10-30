# Changelog

## Unreleased

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
