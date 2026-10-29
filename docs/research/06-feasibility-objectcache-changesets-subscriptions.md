# Research 06 — Feasibility: ObjectCache, Changesets, Pusher/Ably subscriptions

> Input to `docs/feasibility.md`. Date: 2026-10-29. graphql-ruby **v2.6.13**, read-only; both engines checked. Paths relative to `graphql-ruby/` (note: this report keeps the `lib/graphql/` prefix).
> Method: code reading. Clean-room: public guides + open-source code only.

**Short answer:** none needs a fork. Changesets and subscriptions are fully public. ObjectCache needs one undocumented method; partially-cached multiplexes need an awkward workaround.

---

## 1. ObjectCache (Enterprise — `guides/object_cache/*`)

**Verdict: PARTIAL. Size L** (Redis/Memcached backends, fingerprinting, re-authorization, introspection).

### (a) Return a cached result before execution
- `trace_with` module (`lib/graphql/schema.rb:1923`) overriding `execute_multiplex(multiplex:)` (`lib/graphql/tracing/trace.rb:110`).
- Both engines return whatever the trace call returns: legacy `lib/graphql/execution/interpreter.rb:52`, Next `lib/graphql/execution/runner.rb:91`. Not calling `super` and returning an array of `GraphQL::Query::Result.new(query:, values:)` (`lib/graphql/query/result.rb:12`) makes it the response. **Spot-checked** (`interpreter.rb:52`).
- Cache key from public pieces: `Query#fingerprint` (`lib/graphql/query.rb:476`), schema-defined `fingerprint` / `private_context_fingerprint_for`, a custom AST analyzer run via `GraphQL::Analysis.analyze_query` (`lib/graphql/analysis.rb:73`) collecting `cacheable`/`ttl`/`public` metadata.
- On hit, re-check authorization with public API: `Schema.object_from_id` + `Type.authorized?`.

**Blockers for (a):**
- The query must be marked as executed or a later `query.result` re-runs it (`lib/graphql/query.rb:391-395`). Only setter: `Query#result_values=`, marked **`# :nodoc:`** (`lib/graphql/query.rb:335`) — public in Ruby, undocumented. **Spot-checked.**
- Mixed hit/miss multiplex: remove hits from `multiplex.queries` in place and merge afterwards *(inferred)*; relies on both engines reading the same array (`runner.rb:85`, `interpreter.rb:54`). Fragile.
- Overriding `Schema.multiplex` (`schema.rb:2143`) misses direct `Query#result` calls, and on Next `execute_next` → `multiplex_next` bypasses `multiplex` (`lib/graphql/execution/next.rb:48-77`).

### (b) Observe every object read — different hook per engine
- Legacy: `Object.wrap` → `authorized_new` (`lib/graphql/schema/object.rb:58-59`) fires `begin_authorized` and `authorized(query:, type:, object:)` (`object.rb:91-93`); call sites `runtime.rb:100, 185, 378, 751`. The `objects` hook is never called here.
- Next: `objects(type, objects, context)` (`trace.rb:160`) with batches — root `runner.rb:282, 372`; children `field_resolve_step.rb:467` (abstract), `:480` (concrete). `begin_authorized` fires only sometimes (`prepare_object_step.rb:26, 90`).
- Next's batch field-extension API (`next.rb:~40`, `after_resolve` with `field_results`) would need a second implementation; prefer the trace approach. Manual registration (`cacheable_object`) can write to `context`.

### (c) Store the result after execution
Same trace, after `super`. All public.

**Upstream PR:** a public `Query#skip_execution!(result_hash)` (or documented `result_values=`) respected by both engines.

## 2. Changesets / API versioning (Enterprise — `guides/changesets/*`)

**Verdict: FULL. Size M.** Reusing a type name is explicitly supported when only one definition is visible per request.

- The public install guide only asks for integration modules on custom `argument_class`, `field_class`, `enum_value_class`, `type_membership_class`, plus `context[:changeset_version]`. Extra kwargs reach them: `possible_types(*types, **options)` → `type_membership_class.new(..., **options)` (`lib/graphql/schema/union.rb:14-18`); `implements(*ints, **options)` (`lib/graphql/schema/member/has_interfaces.rb:11-21`).
- `added_in:` / `removed_in:` → `visible?(context)` comparing with the release for `context[:changeset_version]`.
- Duplicates are stored as arrays: types `lib/graphql/schema/addition.rb:203-210` (`@types[name] = [prev_type, type]`); fields `schema/member/has_fields.rb:153-161`; arguments `has_arguments.rb:102`; enum values `schema/enum.rb:95-100`.
- Resolution — first visible wins, two visible raise:
  - `Visibility::Profile#compute_type` (`schema/visibility/profile.rb:364-378`) → `raise_duplicate_definition` only if a second is visible; `compute_field` (`profile.rb:399-407`); `non_duplicate_items` (`profile.rb:418-430`); `load_all_types` (`profile.rb:445-446`).
  - Legacy Warden: `visible_entry?` (`schema/warden.rb:47-61`), reachable types (`warden.rb:679-686`), enum values (`enum.rb:119-130`).
- `Visibility.use(schema, profiles:, preload:, dynamic:)` (`schema/visibility.rb:27`) can preload one profile per release *(inferred)*.
- Upstream PR: none.

## 3. Pusher / Ably subscriptions with Redis (`guides/subscriptions/pusher_implementation.md`, `ably_implementation.md`, `multi_tenant.md`)

**Verdict: FULL. Size M** (Redis model, two webhook Rack apps; Ably encryption and compression add work).

| Must implement | Base definition |
|---|---|
| `execute_all(event, object)` | `lib/graphql/subscriptions.rb:222` |
| `read_subscription(id)` | `:239` |
| `deliver(id, result)` | `:257` |
| `write_subscription(query, events)` | `:275` |
| `delete_subscription(id)` | `:292` |

- Overridable: `build_id` (`:302`), `normalize_name` (`:322`), `validate_update?` (`:180`), `execute` (`:194`), `broadcastable?` (`:332`).
- Provided: `trigger` (`:77`) → `Event` → `execute_all`; `execute_update` (`:129-176`) → `read_subscription`, `@schema.execute(subscription_topic:)`, handles `:no_update`/`:unsubscribed` → `delete_subscription`; `write_subscription` via `finish_subscriptions` (`:372`) in both engines (legacy `interpreter.rb:110-111`, Next finalizer `runner.rb:346-349`); `Subscriptions.use(schema, **options)` (`:26-37`) passes `redis:`, `stale_ttl_s:`, `cleanup_delay_s:` to `initialize(**rest)` (`:46`).
- Prior art: `lib/graphql/subscriptions/action_cable_subscriptions.rb:133-263`; sets `context[:subscription_id]` at `:159` (returned as `X-Subscription-ID`).
- Webhooks: Rack app verifying Pusher signatures (with rotation tokens) for "channel vacated" or Ably "presence leave", then `delete_subscription` *(inferred from public guides: Pusher lines 185-215, Ably 157-199)*. `MySchema.pusher_webhooks_client` is a method the plugin adds.
- Multi-tenant: public `execute_multiplex` trace + serializer hooks (`guides/subscriptions/multi_tenant.md`).
- Upstream PR: none.

## Key learnings

1. Both engines return the `execute_multiplex` trace call's value, so a trace that skips `super` can return cached results.
2. The only way to mark a query executed is `Query#result_values=` (`query.rb:335`, `# :nodoc:`) — the single semi-private dependency for whole-response caching.
3. The hook that sees every object differs: legacy `authorized` via `Object.wrap`; Next `objects(type, objects, ctx)`.
4. graphql-ruby stores same-named definitions as arrays and raises `DuplicateNamesError` only when more than one is visible in the same context.
5. A Redis-backed `GraphQL::Subscriptions` subclass needs only five public methods, and both engines call `write_subscription` through `finish_subscriptions`.
