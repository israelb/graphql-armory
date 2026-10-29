# Research 07 — Feasibility: `@defer` / `@stream`

> Input to `docs/feasibility.md`. Date: 2026-10-29. graphql-ruby **v2.6.13**, read-only; both engines checked. Paths relative to `graphql-ruby/lib/graphql/`.
> Method: code reading. Clean-room: public guides `guides/defer/setup.md`, `usage.md`, `stream.md` + open-source code.

## Verdict

| Engine | Verdict | Size |
|---|---|---|
| Legacy `Interpreter::Runtime` | **PARTIAL, works in practice.** Public directive hooks + a continuation block the directive keeps. Error containment and context handling rely on undocumented runtime behavior | M (defer), +M (stream) |
| `Execution::Next` (`Runner`) | **PARTIAL, leaning private API.** Hooks can skip work and omit keys; no continuation, no reliable object↔result link; later work via `run_partials` and fragile order-based mapping | L |

**No fork needed.** `lib/` has **no** incremental-delivery code: grepping defer/stream/incremental/hasNext/patch finds only unrelated hits (`pagination/relation_connection.rb:349` hasNextPage, `static_validation/rules/fields_will_merge.rb:269` "deferred_spreads", ActionCable stream code, perfetto `trace.proto:113 is_incremental`).
The public guide says Pro's `Defer` is a `Schema::Directive` subclass overriding `self.resolve(obj, args, ctx, &block)` with a `Deferral#resolve` that "resume[s] GraphQL execution" (`guides/defer/setup.md:87, 129-147`) — consistent with the continuation design below *(inferred)*.

## 1. Directive hooks

`schema/directive.rb`: `include?` :69, `static_include?` :74, `resolve` :79 (yield to continue), `resolve_each` :84; Next-only `resolve_field` / `resolve_fragment_spread` / `resolve_inline_fragment` / `resolve_operation` :88-91.

**Legacy**
- Runtime directives found by checking whether `resolve` is overridden (`execution/interpreter/runtime.rb:51-59`).
- Invocation: operation `runtime.rb:108`; fragments gathered `:251-253`, wrapped at `evaluate_selections` `:320`; fields `:481`; list items (`resolve_each`) `:842`; chain `run_directive` `:858-889`, `public_send(method_name, object, dir_args, context) { ... }` at `:884` (**spot-checked** `:880-886`); `include?` checks `:892-921`.
- A directive can skip the yield, keep `&block`, call it later; the closure holds `selections_result`, `target_result`, field definition, arguments.
- `context[:current_path]` (`query/context.rb:104-115`) gives the path. The directive does **not** receive the AST node.

**Next**
- Runtime directives via `dir_class.runtime?` (`execution/runner.rb:19-31`). Operation hook `runner.rb:284-287`; mutation-root directives raise (`runner.rb:330-331`).
- Fragments: `execution/selections_step.rb:43-64`, hook gets `(node, parent_type, objects, args, ctx)`; returning `HaltExecution` (`execution/next.rb:33`) leaves keys out and queues no steps.
- Fields: `field_resolve_step.rb:550-588`, `resolve_field(ast_nodes, parent_type, field_defn, objects, args, ctx)`; may return `Finalizer`, `PostProcessor`, `HaltExecution` (`next.rb:15-42`).
- **No block/continuation, no per-object path.** `Finalizer#path` set only at finalize time (`execution/finalize.rb:86-93`).
- These modules sit under `#--` (hidden from rdoc) — semi-public *(inferred)*.

## 2. Running a sub-selection later

`GraphQL::Query#run_partials` (`query.rb:374-381`, **spot-checked**) with `Query::Partial.new(path:, object:, fragment_node:, type:, context:)` (`query/partial.rb:28`) — public, documented, both engines (`query.rb:376-379`, `next.rb:91`). Legacy `run_eager` handles `base_path` (`runtime.rb:87-92`) → absolute error paths. Integer index + `object: item` runs one list item (`partial.rb:157-160`).

Lost:
- Context: fresh `Context` from a copy of `context.to_h` (`partial.rb:33-37`) — writes don't flow back; scoped context likely not carried *(inferred)*.
- Analysis: analyzers skipped (`partial.rb:125`).
- Authorization: root-type auth may run again on `object` *(inferred)*.
- Fragment lookup: legacy `resolve` doesn't know its fragment node — must rediscover it.

## 3. Omitting the deferred part from the initial result

**Legacy:** not yielding means nothing writes the key; only `set_result` with nil propagates non-null failures (`runtime.rb:523-549`), so an absent key is fine. Problems later:
- Running the kept block writes into the **live** result hashes (`set_leaf` / `set_child_result` / `merge_into`, `execution/interpreter/runtime/graphql_result.rb:77-162`) — deep-copy the initial payload first.
- A non-null failure inside deferred work propagates into already-sent parents (`runtime.rb:534-541`), possibly `@response = nil` (`runtime.rb:112, 535-536`).
- No "patch boundary" hook; the gem must rewrite as a patch with `data: null` + errors *(inferred)*.

**Next:** `SelectionsStep` clobbers results with the prototype (`selections_step.rb:78-85`), so a halted field leaves `key => nil`. A `Finalizer` can `result_data.delete(key)`; `Finalize` then treats it as `:unassigned` and skips the non-null check (`finalize.rb:120, 144-148`). Finalize runs only when finalizers exist (`runner.rb:137`) — the directive returning one guarantees it.

## 4. `@stream`

- Legacy: `resolve_each` per item with `current_result_name = idx` (`runtime.rb:836-851`) → yield for `idx < initialCount`, keep the rest. The list is still enumerated eagerly (`value.each`, `:790`); only per-item sub-resolution is chunkable.
- Next: `PostProcessor#after_resolve(field_results)` (`field_resolve_step.rb:349-351`) can cut lists to N and stash tails; a directive `Finalizer` attached to each `list_result` (`field_resolve_step.rb:747`) gets the concrete path at finalize time; tails run as `run_partials` with `[..., idx]`. Mapping tails to lists relies on order *(inferred, fragile)*.

## 5. Dataloader

`Dataloader#run` (`dataloader.rb:250-293`) can run again; `append_job` (`dataloader.rb:176`) is `:nodoc:`. After `Interpreter.run_all`, a kept legacy block can `@dataloader.append_job` then `context.dataloader.run`. Caveats: `delete_all_interpreter_context` (`interpreter.rb:144-149`, `runtime.rb:1016`) clears per-fiber state but `get_current_runtime_state` rebuilds it (`runtime.rb:923-926`); `Fiber[:__graphql_current_multiplex]` reset (`interpreter.rb:153`) → tracing during resume has no trace *(inferred)*; source caches survive unless cleared; one `run` per deferral. Next `Runner#execute` is synchronous (`runner.rb:125-132`) → deferred work is a new `run_all` or partials.

## Smallest upstream hooks

1. Next: pass `SelectionsStep` / `FieldResolveStep`, or `(object, result, path)` triples, to `resolve_field` / `resolve_fragment_*`, or give each Finalizer its object.
2. Both: a "null boundary" (option on `Partial` or result flag) stopping non-null propagation at a patch root (legacy: a check in `set_result`, `runtime.rb:534`).
3. Legacy: pass the directive's AST node to `resolve`; officially support calling the kept block after `run_all`; public `runtime.resume` re-binding multiplex and trace.
4. Next: public `Runner` API to queue more steps against an existing result.

## Degraded design (public hooks only)

1. Skip the fragment (legacy: `resolve` without yield; Next: `HaltExecution` + key-deleting `Finalizer`).
2. Record `(object, path, fragment node, parent type)`.
3. After the initial result, run each deferral via `query.run_partials`; emit `{path, data, errors, hasNext}`.
4. Nested `@defer` inside a partial fires again → recursive patches.

Gives up: context writes from deferred resolvers, scoped context, shared trace span, strict dataloader batching across initial/deferred work, a possible second authorization pass, per-object mapping in Next (approximate), lazy list sources for `@stream`.

## Key learnings

1. In the legacy interpreter, a `Schema::Directive.resolve` override receives a continuation block (`runtime.rb:884`) it can keep and call after the initial result.
2. `Query#run_partials` with `Query::Partial(path:, object:, fragment_node:, type:)` is a public API that runs a sub-selection at a path on both engines.
3. Next directives can skip a fragment/field via `HaltExecution` and drop its key with a `Finalizer`; Finalize treats deleted keys as `:unassigned`.
4. Neither engine has incremental delivery or a patch boundary in OSS `lib/`; legacy non-null propagation would corrupt already-sent parents unless the gem contains it.
5. Next's directive hooks get object batches but no per-object result or path — the main missing piece for `@defer`/`@stream` on Next.
