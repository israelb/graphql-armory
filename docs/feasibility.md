# graphql-armory — Feasibility: public hooks vs fork

> Question: can each GraphQL-Pro / Enterprise capability be built as an original, open-source gem on top of **unmodified** graphql-ruby, or does it need a fork?
> Reference: graphql-ruby **v2.6.13**, [rmosolgo/graphql-ruby@23a5d65](https://github.com/rmosolgo/graphql-ruby/tree/23a5d6595ef9f6e14d89a05e97e260fc8c9c1962). Paths are relative to `graphql-ruby/lib/graphql/`. Both execution engines checked: the legacy Interpreter (`execution/interpreter/`) and `Execution::Next` (`execution/runner.rb`, `field_resolve_step.rb`, `prepare_object_step.rb`, `finalize.rb`).
> Clean-room: only open-source code and the public guides under `graphql-ruby/guides/` were read. No Pro/Enterprise code.
> Date: 2026-10-29.

---

## 1. Conclusion

**No capability requires a fork.** Seven of ten are fully buildable with public extension points. Two (ObjectCache, `@defer`/`@stream`) depend on one or two undocumented-but-public methods, which is a maintenance risk, not a blocker. Each of those risks can be removed by a small upstream PR.

**Decision proposed: one gem, `graphql-armory`, no fork.** A fork would have to be renamed, could not satisfy the `graphql` dependency other gems declare (Bundler would install both, and both define the `GraphQL` constant), and would carry the cost of tracking every upstream release and two execution engines. None of that is justified by the findings below.

Licensing: graphql-ruby is MIT (`graphql-ruby/MIT-LICENSE`, Copyright 2015 Robert Mosolgo). A fork or commercial use would be legally allowed with the notice preserved; the decision against a fork is technical, not legal.

---

## 2. Summary table

| # | Capability | Tier | Verdict | Size | Semi-private dependency | Upstream PR that would help |
|---|---|---|---|---|---|---|
| 1 | Pundit / CanCanCan authorization | Pro | **Full** | M | — | — |
| 2 | Encrypted, versioned IDs and cursors | Pro | **Full** | S | — | — |
| 3 | OperationStore (persisted queries, whitelisting) | Pro | **Full** | L (mostly storage/sync, outside graphql-ruby) | — | Optional: public `Query#document=` |
| 4 | Rate limiting (runtime + active operations) | Enterprise | **Full**, Next caveats | M | — | Align Next with legacy on `context.errors`; align `begin_execute_field` signature |
| 5 | Stable relation connections (keyset) | Pro | **Full** | M | — | — |
| 6 | Subscriptions over Pusher / Ably + Redis | Pro | **Full** | M | — | — |
| 7 | ObjectCache (whole-response cache) | Enterprise | **Partial** | L | `Query#result_values=` (`# :nodoc:`) | Public `Query#skip_execution!(result)` |
| 8 | Changesets (API versioning) | Enterprise | **Full** | M | — | — |
| 9 | `@defer` / `@stream` | Pro | **Partial** (legacy works; Next fragile) | L–XL | Kept directive block called after `run_all`; Next directive hooks under `#--` | Per-object result/path in Next directive hooks; a "null boundary" for patches |
| 10 | Dashboard | Pro | **Full** (Rails engine over 3, 4, 6) | M | — | — |

---

## 3. Evidence per capability

### 3.1 Authorization
See `docs/design-proposal.md` and `docs/design-review.md`.

### 3.2 Encrypted, versioned IDs and cursors (`guides/pro/encoders.md`)
- Node IDs only go through `Schema.id_from_object` / `Schema.object_from_id` (`schema.rb:1643`, `schema.rb:1613`), used by the `id` field, `loads:` (`schema/member/has_arguments.rb:410-411`) and `node`/`nodes` (`types/relay/has_node_field.rb`, `has_nodes_field.rb`).
- Cursors only go through `Schema.cursor_encoder` (`schema.rb:1042-1046`), called from `Pagination::Connection#encode`/`#decode` (`pagination/connection.rb:373-378`).
- Versioning (try each decoder, encode with the newest) is plain gem-side Ruby.

### 3.3 OperationStore (`guides/operation_store/*`, `guides/javascript_client/sync.md`)
- A `use` plugin installs a `trace_with` module overriding `execute_multiplex`, resolves `context[:operation_id]` to stored text and sets the public `Query#query_string=` (`query.rb:158`) before `super`. Parsing is lazy, so this works in both engines.
- Cached parse: override the `parse(query_string:)` trace hook (`tracing/trace.rb:42`) and return a stored `Document`.
- Skip validation for pre-validated operations: public `Query#validate=` (`query.rb:129`).
- Reject ad-hoc queries: a `query_analyzer` returning `GraphQL::AnalysisError` makes `valid?` false in both engines. **Do not** disable `validate` on those queries: `Execution::Next` only checks `valid?` when `validate` is true (`execution/runner.rb:99`).
- Storage backends, sync endpoint, HMAC and usage index are plain Ruby/Rails.

### 3.4 Rate limiting (`guides/limiters/*`)
- `execute_multiplex`, `execute_query`, `begin_execute_field` / `end_execute_field` trace hooks bracket execution in both engines.
- Halting mid-query: raise `GraphQL::ExecutionError` from `begin_execute_field` — the same pattern `schema/timeout.rb:89-112` uses; partial data plus errors in both engines.
- Reject before execution with an analyzer returning `AnalysisError` (not `context.add_error`, which `Execution::Next` ignores before running).
- Caveat: the second argument of `begin_execute_field` differs between engines (one object vs an Array); the gem must not depend on it.

### 3.5 Stable relation connections (`guides/pagination/stable_relation_connections.md`)
- Subclass `GraphQL::Pagination::Connection` and register with `connections.add(ActiveRecord::Relation, ...)` (`pagination/connections.rb:39`). Implement `nodes`, `has_next_page`, `has_previous_page`, `cursor_for` (`connection.rb:255,276,286,322`).
- Avoid subclassing `RelationConnection`: its helpers are private (`relation_connection.rb:69`).

### 3.6 Subscriptions over Pusher / Ably (`guides/subscriptions/*`)
- A `GraphQL::Subscriptions` subclass implements five public methods: `execute_all`, `read_subscription`, `deliver`, `write_subscription`, `delete_subscription` (`subscriptions.rb:222-292`). Prior art: `subscriptions/action_cable_subscriptions.rb`.
- Both engines call `write_subscription` through `finish_subscriptions`.
- Webhooks (Pusher "channel vacated", Ably "presence leave") are plain Rack endpoints.

### 3.7 ObjectCache (`guides/object_cache/*`)
- Serve a cached response: a trace overriding `execute_multiplex` can return results without calling `super`; both engines return that value (`execution/interpreter.rb:52`, `execution/runner.rb:91`).
- **Semi-private dependency:** the query must be marked as executed or a later `query.result` re-runs it; the only setter is `Query#result_values=`, marked `# :nodoc:` (`query.rb:335`).
- Multiplex with mixed hits/misses needs the trace to remove hits from `multiplex.queries` in place (fragile, inferred).
- Observing every object read: legacy fires the `authorized` trace hook (`schema/object.rb:91-93`); Next fires `objects(type, objects, ctx)` (`execution/runner.rb:282`, `field_resolve_step.rb:467,480`). Two engine-specific paths.

### 3.8 Changesets (`guides/changesets/*`)
- graphql-ruby stores same-named definitions as arrays: types `schema/addition.rb:203-210`, fields `schema/member/has_fields.rb:153-161`, arguments `has_arguments.rb:102`, enum values `schema/enum.rb:95-100`.
- It picks the single visible one and raises only when two are visible in the same context: `schema/visibility/profile.rb:364-378, 399-407`; legacy `schema/warden.rb:47-61`.
- So `added_in:` / `removed_in:` on custom field/argument/enum value/type-membership classes, driving `visible?` from `context[:changeset_version]`, is fully public.

### 3.9 `@defer` / `@stream` (`guides/defer/*`)
- No incremental-delivery code exists in open-source `lib/`.
- **Legacy Interpreter:** a `Schema::Directive.resolve` override receives a continuation block (`execution/interpreter/runtime.rb:880-886`) it can keep and call after the initial result. Containment of non-null failures inside deferred work is not provided: `set_result` would propagate nulls into already-sent parents (`runtime.rb:523-541`); the gem must deep-copy the initial payload and contain errors itself.
- **Execution::Next:** directive hooks (`resolve_field`, `resolve_fragment_*`) can halt work and a `Finalizer` can drop keys (`execution/finalize.rb:120,146`), but they receive object batches with no per-object result or path. Later work must go through `Query#run_partials` (public, `query.rb:374-381`) with order-based mapping (fragile). These hooks sit under `#--` (hidden from rdoc).
- Degraded but public-only design: skip the fragment, record `(object, path, fragment, type)`, run each deferral via `run_partials`, emit `{path, data, errors, hasNext}`. Loses context writes, scoped context, shared tracing, cross-patch dataloader batching, lazy list sources for `@stream`.
- Recommendation: keep last in the roadmap; ship legacy-only first if at all; propose the upstream hooks before building the Next variant.

### 3.10 Dashboard (`guides/pro/dashboard.md`)
- A mountable Rails engine reading the gem's own stores (OperationStore, limiters, subscriptions). No graphql-ruby hooks needed beyond those features.

---

## 4. Upstream PRs worth proposing (instead of a fork)

| PR | Removes | Size |
|---|---|---|
| Public `Query#skip_execution!(result)` respected by both engines | ObjectCache's `# :nodoc:` dependency | S |
| `Execution::Next` skips queries with non-empty `context.errors` (parity with legacy); document `begin_execute_field` argument shape | Rate-limiting caveats | S |
| Public `Query#document=` | Optional nicety for OperationStore | S |
| Per-object `(object, result, path)` in Next directive hooks; a "null boundary" option for partial results | `@defer` / `@stream` fragility | M |

Proposing these is optional and depends on the maintainer's acceptance; the gem must work without them.

---

## 5. Recommended roadmap (unchanged by this analysis)

| Order | Capability |
|---|---|
| 1 | Authorization (Pundit, CanCanCan) |
| 2 | Encrypted IDs and cursors |
| 3 | OperationStore |
| 4 | Rate limiting |
| 5 | Stable connections |
| 6 | Subscriptions Pusher / Ably |
| 7 | ObjectCache |
| 8 | Changesets |
| 9 | `@defer` / `@stream` |
| 10 | Dashboard |

Each capability starts with its own clean-room Phase 0 (public guide + open-source code + community gems) before design.
