# Research 05 — Feasibility: encrypted IDs, stable connections, OperationStore, rate limiting

> Input to `docs/feasibility.md`. Date: 2026-10-29. graphql-ruby **v2.6.13**, read-only; both engines checked. Paths relative to `graphql-ruby/lib/graphql/`.
> Method: code reading; nothing executed (the timeout spec cited was read, not run). Clean-room: public guides + open-source code only.

**Short answer:** all four can be built with public extension points. No fork, no monkey patching. Gaps are rough edges in `Execution::Next`, not blockers.

---

## 1. Encrypted, versioned IDs and cursors (`guides/pro/encoders.md`)

**Verdict: FULL. Size S.**

- Node IDs: override `Schema.id_from_object` (`schema.rb:1643`) and `Schema.object_from_id` (`schema.rb:1613`). Every ID path goes through them:
  - `id` field: `schema/member/has_fields.rb:190, 194`
  - `loads:`: `schema/member/has_arguments.rb:410-411`
  - `node` / `nodes`: `types/relay/has_node_field.rb`, `has_nodes_field.rb:18`
- Cursors: `Schema.cursor_encoder(enc)` (`schema.rb:1042-1046`); encoder responds to `encode(str, nonce:)` / `decode(str, nonce:)`; only callers `Connection#encode`/`#decode` (`pagination/connection.rb:373-378`, `nonce: true`).
- Per-connection encoding: a subclass can override `encode`/`decode` (below `private` at `connection.rb:330`, still overridable).
- Versioning: gem-side chain encoder (try each decoder, encode with newest). No hook needed.
- Both engines share the path; Next wraps connections via `connections.populate_connection` (`execution/field_resolve_step.rb:306-312`).
- Blockers: none.

## 2. Stable relation connections (`guides/pagination/stable_relation_connections.md`)

**Verdict: FULL. Size M** (SQL/keyset logic, not integration).

- `connections.add(ActiveRecord::Relation, MyStableConn)` (`pagination/connections.rb:39`); lookup walks ancestors (`connections.rb:57-61`). Resolvers can return a connection instance per field.
- Subclass `GraphQL::Pagination::Connection` directly; implement `nodes`, `has_next_page`, `has_previous_page`, `cursor_for(item)` (`connection.rb:255, 276, 286, 322`). `edges`, `start_cursor`, `end_cursor` and edge cursors derive from `cursor_for` (`connection.rb:226, 296, 306`). Inputs `first`, `last`, `before`, `after` (`connection.rb:65-216`).
- **Avoid** subclassing `RelationConnection`: `sliced_nodes`, `limited_nodes`, `relation_offset` are `private` (`pagination/relation_connection.rb:69`).
- Backward compatibility with offset cursors: decode and branch on shape, gem-side.
- `totalCount` not built in (custom connection type, as in OSS today).
- `InvalidRelationError` for unordered grouped relations: gem-side.
- Blockers: none.

## 3. OperationStore (`guides/operation_store/*`, `guides/javascript_client/sync.md`)

**Verdict: FULL for runtime lookup and whitelisting as a schema plugin. Size L** (mostly outside graphql-ruby).

- Lookup from `context[:operation_id]` (guide: `MySchema.execute(context: {operation_id: ...})` with no query string, `guides/operation_store/getting_started.md:96-115`):
  - A `use` plugin installs `trace_with` overriding `execute_multiplex(multiplex:)`; for each query sets `Query#query_string=` (`query.rb:158`, public) then `super`.
  - Parsing is lazy (`prepare_ast`, `query.rb:600-607`), first during analysis/validation inside `execute_multiplex`: legacy `execution/interpreter.rb:52-60`, Next `execution/runner.rb:91-93`. Both build the Query with nil text (`interpreter.rb:37`, `execution/next.rb:89`).
- Pre-parsed documents: `Schema.execute(document: doc)` / `Query.new(document:)` public (`query.rb:213, 257`); no public `document=` after construction. Alternative: override the `parse(query_string:)` trace hook (`tracing/trace.rb:42`, called `language/parser.rb:46`) returning a cached `Document` without `super` *(inferred safe — result is the block's value)*.
- Skip validation: `Query#validate=` public (`query.rb:129`) until validation ran; validator skips rules (`static_validation/validator.rb:53-56`).
- Reject ad-hoc queries: `query_analyzer` (`schema.rb:2029`) returning `GraphQL::AnalysisError` when there is a query string but no stored ID → `analysis_errors` → `valid?` false (`query.rb:508`); both engines skip execution. Or raise in the trace.
- **Caveat *(inferred)*:** Next only checks `valid?` when `query.validate` is true (`runner.rb:99`). If the gem disables validation, the analyzer error is ignored in Next → keep `validate` on, or skip only rules via `static_validator=` (`query.rb:148`).
- Not graphql-ruby's job: sync Rack app, HMAC auth, storage backends, dashboard, usage index. Normalization can use `Document#to_query_string` and the printer.
- Blockers: none. Optional upstream PR: public `Query#document=` or a `resolve_document` hook (S).

## 4. Rate limiting (`guides/limiters/overview.md`, `runtime.md`, `active_operations.md`, `deployment.md`)

**Verdict: FULL with Next caveats. Size M** (Redis dominates).

- Hooks bracketing each stage:
  - Multiplex `execute_multiplex`: legacy `interpreter.rb:52`, Next `runner.rb:91`.
  - Query `execute_query`: legacy `interpreter.rb:85`, Next `runner.rb:116`.
  - Lazy phase `execute_query_lazy`: Next `runner.rb:125`.
  - Field `begin_execute_field`/`end_execute_field`: legacy `execution/interpreter/runtime.rb:492, 505, 971, 988`; Next `field_resolve_step.rb:62, 64, 531, 606`.
  - Analysis `analyze_multiplex`/`analyze_query`.
- Halting mid-query: raise `GraphQL::ExecutionError` from `begin_execute_field` — exactly what `schema/timeout.rb:89-112` does (installed via `trace_with`, `timeout.rb:44-47`). Caught per field: legacy `runtime.rb:491-497`; Next `field_resolve_step.rb:617-631` → `handle_execute_field_error`. `spec/graphql/schema/timeout_spec.rb:226` covers Next.
- Runtime limiter design: measure elapsed in `execute_multiplex` (with `ensure`), charge per-key budget in Redis, stop starting new fields once spent. Running fields are not interrupted (matches the guide's caveat).
- Active-operations limiter: increment/decrement in `execute_multiplex` with `ensure`; reject before execution with a `query_analyzer`/`multiplex_analyzer` returning `AnalysisError` (works in both engines).
  - Caveat: `context.add_error` before `super` stops legacy (`interpreter.rb:72`); Next does not check `context.errors` before running (`runner.rb:99`) *(inferred)*. Use the analyzer route.
- Soft mode and `context[:runtime_limiter]` / `context[:active_operation_limiter]` metadata: gem-side.
- Rough edges:
  - Engines pass different second arguments to `begin_execute_field` (legacy one object, Next an Array). `Timeout` names it `_arguments` while the base trace calls it `object` (`timeout.rb:89` vs `trace.rb:133`). Don't rely on it.
  - Next's lazy-sync path calls `begin_execute_field` at `field_resolve_step.rb:62` inside a method with only `ensure`, no `rescue` — an error raised there may not become a field error *(inferred, untested)*.
- Possible upstream PR: Next skips queries with non-empty `context.errors` (parity), and document/align `begin_execute_field` signature (S).

## Key learnings

1. Node IDs go only through `Schema.id_from_object`/`object_from_id`; cursors only through `Schema.cursor_encoder` via `Connection#encode`/`#decode` (`connection.rb:373-378`).
2. `Query#query_string=` (`query.rb:158`) and `Query#validate=` (`query.rb:129`) are public and parsing is lazy, so an `execute_multiplex` trace can turn `context[:operation_id]` into stored text in both engines.
3. Overriding the `parse(query_string:)` trace hook and returning a cached `Document` without `super` reuses pre-parsed documents.
4. Raising `GraphQL::ExecutionError` from `begin_execute_field` (the `Schema::Timeout` pattern) gives partial results with errors in both engines.
5. Next skips a query only when `query.validate && !query.valid?` (`runner.rb:99`); reject with `AnalysisError` from an analyzer, not `context.add_error`.
