# Research 01 — graphql-ruby authorization and visibility hooks

> Phase 0, item 1. Date: 2026-10-28. Source: graphql-ruby **v2.6.13** (commit `23a5d65`), read-only clone at `graphql-ruby/`. Paths relative to `graphql-ruby/lib/graphql/` unless stated.
> Method: code reading only (nothing executed). Items marked *(inferred)* were not read directly.
> Corrections from later verification (research 04) are marked **[corrected]**.

---

## 0. Gemspec and engines

- `s.required_ruby_version = ">= 2.7.0"` (`graphql.gemspec:16`). License MIT (`graphql.gemspec:15`, `MIT-LICENSE`, Copyright 2015 Robert Mosolgo).
- Two execution engines. `Schema.execute` chooses (`schema.rb:2076-2082`); `default_execution_next` is false unless configured (`schema.rb:2151-2159`).
  - Legacy `Interpreter::Runtime`: `execution/interpreter/runtime.rb`.
  - `Execution::Next`: **directly under** `execution/` — `runner.rb`, `field_resolve_step.rb`, `prepare_object_step.rb`, `load_argument_step.rb`, `finalize.rb`, plus `execution/next.rb`. **[corrected: there is no `execution/next/` directory]**

---

## 1. `Object.authorized?(object, context)`

- Definition: default `true` (`schema/member/base_dsl_methods.rb:165`, `schema/member/has_authorization.rb:18`).
- Call path: `Object.wrap` → `authorized_new` (`schema/object.rb:58-59, 90-136`). `authorized?` at `object.rb:95`, wrapped in trace hooks `begin_authorized`, `authorized`, `authorized_lazy`, `end_authorized`.
- Call sites:
  - Root object: `runtime.rb:100`. If nil, whole response nil (`runtime.rb:102-103`).
  - Every OBJECT-kind field result: `runtime.rb:749-756`.
  - Each list item: `runtime.rb:780-847`.
  - Next: `prepare_object_step.rb:91`.
- Results:
  - truthy → `new(object, ctx)`.
  - `false`/`nil` → `UnauthorizedError` → `schema.unauthorized_object(err)` (`object.rb:119-131`). Returned object replaces the original; nil nulls the field silently; nil in non-null position bubbles up.
  - Raising `UnauthorizedError` inside `authorized?` → `unauthorized_object` (`object.rb:96-97`).
  - Other `StandardError` → `query.handle_or_reraise` / `rescue_from` (`object.rb:98-99`).
  - `ExecutionError` → entry in `errors`, field nulled (`runtime.rb:752, 602-611`).
  - Lazy/Promise is wrapped in `Execution::Lazy` (`object.rb:106-117`). **[corrected for Next: see research 04, H1 — lazies are only resolved when `resolves_lazies?` is true]**
- Next engine on denial: if `unauthorized_object` returns nil, `prepare_object_step.rb:119-128` calls `add_field_error`, but `UnauthorizedError#finalize_graphql_result` only nulls the key (`unauthorized_error.rb:40-42`) → **no** `errors` entry. **[corrected: earlier claim "Next adds an error" was wrong]**
- Abstract types: `resolve_type` first (`runtime.rb:717-746`), then recursion into the concrete type; **Interface/Union `authorized?` is never called at runtime**. Resolved type not in visible `possible_types` → `UnresolvedTypeError` → `schema.type_error` (`runtime.rb:737-744`).
- Never called for scalars/enums (`runtime.rb:703-716`) or input types.

## 2. Field, argument and enum value checks

- `Field#authorized?(object, args, context)` (`schema/field.rb:1168`).
  - With a resolver: delegates to the resolver's class-level `authorized?(object, ctx)` (`field.rb:1171`). Otherwise calls `arg.authorized?` for each explicitly provided argument; defaults skipped (`field.rb:1189`).
  - Called inside `Field#resolve` within `after_lazy` (`field.rb:1232`).
  - `false` → `UnauthorizedFieldError` (`field.rb:1302`) → `schema.unauthorized_field(err)` (`field.rb:1305-1311`).
  - Next: `field_resolve_step.rb:639`, denials `:688-706`. Next calls it **only when it detects an override** (`field.rb:1162-1166`, `has_authorization.rb:33-35`).
- `Argument#authorized?(obj, value, ctx)` (`schema/argument.rb:398`). Default `authorized_as_type?` (`argument.rb:402-423`): nil → true; lists per element; input objects → `InputObject.authorized?` (`schema/input_object.rb:130-135`).
- **No `Schema.unauthorized_argument` exists** anywhere in `lib/`.
- `EnumValue`: `visible?` and `authorized?` default true (`schema/enum_value.rb:88-89`). Input side denial → `UnauthorizedEnumValueError` → `unauthorized_object` (`schema/enum.rb:282-285`; Next `execution/input_values.rb:302`). Output side → `UnresolvedValueError` (`enum.rb:252-255`).

## 3. `visible?` and `Schema::Visibility`

- Defaults true on types (`base_dsl_methods.rb:161`), interfaces (`schema/interface.rb:62`), arguments (`argument.rb:390`), mutations (`schema/mutation.rb:77`). `Field#visible?` delegates to the resolver (`field.rb:1154`).
- Central hook: `Schema.visible?(member, ctx)` → `member.visible?(ctx)` (`schema.rb:1647`).
- Since 2.4.0 the *new* Visibility system is opt-in (`CHANGELOG.md:627`); must be `use`d after root types (`CHANGELOG.md:168`). **[corrected: without `use`, the default `Schema::Warden` still calls `visible?` per query — `schema.rb:832-840, 856-864`, `schema/warden.rb:588-590`]**
- `Visibility.use(schema, dynamic: false, profiles: {}, preload: <true in Rails prod/staging>, migration_errors: false)` (`schema/visibility.rb:27`).
- Cache keying (`profile_for`, `visibility.rb:159-181`):
  - Named profiles cached in `@cached_profiles` by `context[:visibility_profile]`, built with the **frozen profile context from the schema config**, not the request context (`visibility.rb:164`). Cached **even with `dynamic: true`**.
  - Unknown profile with `dynamic: true`, or no profiles: new `Profile` per query (`visibility.rb:169, 179`).
  - Profiles exist, no profile given, not dynamic: `ArgumentError` (`visibility.rb:171-172`).
  - `NullContext` → `top_level_profile`, memoized (`visibility.rb:176-177, 187-191`); `context[:current_user]` is nil there (`query/null_context.rb`).
  - Inside a profile, `visible?` memoized per member (`schema/visibility/profile.rb:93-108`).
  - `execute_next` accepts `visibility_profile:` (`execution/next.rb:48`).
- Hidden members vanish from introspection, validation and "did you mean": `static_validation/rules/fields_are_defined_on_type.rb:10, 38-40`; `arguments_are_defined.rb:11, 17`; suggestions built from filtered lists (`static_validation/validation_context.rb:54-64`).
- An argument is visible only if its type is visible (`profile.rb:103`); interface memberships filtered (`profile.rb:228`); invisible roots become nil (`profile.rb:234-243`).

## 4. Scoping

- `self.scope_items(items, context)` default returns `items` (`schema/member/scoped.rb:26`).
- `reauthorize_scoped_objects(bool)` (`scoped.rb:30-40`): **code default is `true`** (`find_inherited_value(..., true)`), although `CHANGELOG.md:1048` (2.2.0) says "default to false". Verified directly.
- `Field#scoped?` true for list/connection return types or `scope: true`; `scope: false` disables (`field.rb:461-478`).
- **Scope runs before pagination:** `ScopeExtension` added before the connection extension (`field.rb:1507-1518`, verified directly), `after_resolve` in definition order (`field.rb:1426-1433`). Connection types delegate `scope_items` to the node type (`types/relay/connection_behaviors.rb:112-125`). `nodes`/`edges` are not re-scoped (`CHANGELOG.md:1354`).
- Interpreter skip rule: if scoping returned a different object and `reauthorize_scoped_objects` is false, `was_authorized_by_scope_items` is set (`schema/field/scope_extension.rb:13-19`) and items are built with `wrap_scoped`, bypassing `authorized?` (`runtime.rb:751`, `object.rb:53`). **[Next differs — see research 04, C1]**
- Interfaces/unions do get `scope_items` (`schema/interface.rb:14`; Union via `schema/member.rb:37`). **[added by research 04]**

## 5. Schema-level handlers

- `Schema.unauthorized_object(err)` (`schema.rb:1687`): default nil. Returned value replaces the object; raising `ExecutionError` adds to `errors`.
- `Schema.unauthorized_field(err)` (`schema.rb:1711`): default calls `unauthorized_object`. `err` is `UnauthorizedFieldError` (< `UnauthorizedError` < `RuntimeError`) with `.field`. Return value becomes the field value (`runtime.rb:612-621`).
- `err.object`, `err.type`, `err.context` available.

## 6. `loads:` arguments

- `load_application_object(arg, id, ctx)` → `object_from_id(type, id, ctx)` → `Schema.object_from_id(id, ctx)` (`schema/member/has_arguments.rb:410-420`).
- `authorize_application_object` (`has_arguments.rb:427-491`):
  - nil object or type mismatch → `load_application_object_failed(err)`, raising `LoadApplicationObjectFailedError` by default (`has_arguments.rb:508`). Message: `"No object found for \`#{argument.graphql_name}: #{id.inspect}\`"` (`load_application_object_failed_error.rb`) — an `ExecutionError`, visible in `errors`.
  - Loaded object passed through the resolved type's `.authorized?` (`has_arguments.rb:469`), in `after_lazy`.
  - Denial → loader's `unauthorized_object(err)` if defined; `Resolver#unauthorized_object` raises by default (`schema/resolver.rb:283`) → `Schema.unauthorized_object`.
- `Argument#authorized?` then receives the loaded object (`CHANGELOG.md:1733, 2496`).
- `Mutation#call_resolve` calls `dataloader.clear_cache` before resolving (`schema/mutation.rb:70-73`).

## 7. Resolver, Mutation, RelayClassicMutation

- Sequence (`resolve_with_support`, `resolver.rb:147-195`): `ready?(**args)` → `load_arguments` → validators → `authorized?(**loaded_args)` → `resolve`.
- `[false, data]` → `data` is the field value (errors as data). `[true, x]` raises. Plain `false` from `authorized?` → `UnauthorizedFieldError` → `unauthorized_field`. Plain `false` from `ready?` → nil, no hook (`resolver.rb:154-162`). Lazy accepted.
- `ready?` default true (`resolver.rb:238`). Instance `authorized?` checks each argument that is non-nil and differs from its default (`resolver.rb:261-306`) — overrides should call `super`. Class-level `self.authorized?(obj, ctx)` is what `Field#authorized?` calls (`field.rb:1171`).
- Next equivalent: `resolver.rb:80-123`.
- Returned payload objects go through normal OBJECT wrapping (verified in research 04, E).

## 8. Context storage

- `ctx[:k]` reads `scoped_context` first, then execute-time values (`query/context.rb:92, 108`).
- `ctx.namespace(:my_gem)` per-query Hash, auto-created (`context.rb:286`); `namespace?` (`context.rb:300`) — best place for a policy memo.
- `scoped_set!` / `scoped_merge!` apply to the current subtree (`context.rb:312-319`).
- `ctx.types` is the visibility profile (`context.rb:98`).

## 9. Injection points

- `FieldExtension` (`schema/field_extension.rb`): `apply` (:114), `after_define` (:126), `resolve(object:, objects:, arguments:, context:)` (:181), `after_resolve(... value:, memo:)` (:206), `default_argument`, `extras`.
- `field.extension(Klass, **opts)` (`field.rb:926`), `Resolver.extension` (`resolver.rb:569`).
- `field_class` (`schema/member/has_fields.rb:175`; payload types `schema/resolver/has_payload_type.rb:49`), `argument_class` (`has_arguments.rb:289`), `connection_type_class` / `edge_type_class` (`schema/member/relay_shortcuts.rb:11, 29`), `directive(...)` (`schema/member/has_directives.rb:31`).
- Tracing: `Schema.trace_with(mod)` (`schema.rb:1923`); hooks `authorized`, `begin_authorized`/`end_authorized(type, obj, ctx, result)`, `authorized_lazy`, `resolve_type`, `execute_field`, `begin_execute_field` (`tracing/trace.rb:148-244`).

## 10. Iterating the schema (for the audit)

- `Schema.types(ctx = null_context)` (`schema.rb:533`) — with Visibility returns `Profile#all_types_h`, **visibility-filtered**.
- `root_types` (:824), `get_type` (:574), `get_field` (:962), `possible_types` (:879), `union_memberships` (:915), `references_to` (:937), `orphan_types` (:1324), `to_definition(context:)` (:449).
- Unfiltered: `Schema.visibility.all_references` / `.types` after `load_all` (`visibility.rb:79, 89`); per type `all_field_definitions` / `all_argument_definitions` (used at `profile.rb:141-145`). `fields(ctx)` filters (`has_fields.rb:269`).

## Gotchas

1. Named visibility profiles are cached per name with a static context. Per-user `visible?` needs no profiles, or `dynamic: true` with unknown names.
2. `nil` and `false` from `authorized?` both deny. `ExecutionError` puts the reason in `errors`. A denial ending in nil in a non-null position nulls the parent.
3. Interface/Union `authorized?` never runs.
4. Scalars are never type-authorized. Default-valued arguments skip argument auth.
5. Scoping happens before pagination. Turning off `reauthorize_scoped_objects` skips per-item `authorized?` (and much more broadly in Next — research 04).
6. Next's `authorizes?` cache (`execution/runner.rb:42-50`) relies on detecting overridden `authorized?` methods (`has_authorization.rb:33-35`, `field.rb:1162`). Define methods normally; `define_method` on a shared owner may not be detected *(inferred)*.
7. A hidden field/argument becomes a validation error with no "did you mean" leak.

## Changes 2.0 → 2.6 (open-source `CHANGELOG.md`)

- 2.1: `reauthorize_scoped_objects` added (:1148); `return false, nil` allowed from `ready?`/`authorized?` (:1160).
- 2.2: changelog says `reauthorize_scoped_objects` defaults to false (:1048) — code says true.
- 2.3: fix for resolver arguments returning false (:922).
- 2.4: Visibility opt-in (:627); `EnumValue#authorized?` called at runtime (:708); Dataloader works with `loads:` + `authorized?` (:780).
- 2.5: profile context fix (:534).
- 2.6: `Execution::Next` added and calls `ready?` (:10).
