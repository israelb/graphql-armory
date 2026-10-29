# graphql-armory — Design Review

> Review of `docs/design-proposal.md` (2026-10-28) against graphql-ruby **v2.6.13** source ([rmosolgo/graphql-ruby@23a5d65](https://github.com/rmosolgo/graphql-ruby/tree/23a5d6595ef9f6e14d89a05e97e260fc8c9c1962)), the Pundit 2.5 docs and the CanCanCan docs. Paths below are relative to `graphql-ruby/lib/graphql/`.
> Clean-room: no graphql-pro code was consulted or reconstructed.

---

## Verdict

**Approve with changes.** The three-layer architecture, the neutral adapter contract and the deny-by-default goal are sound and implementable with public hooks. But the proposal has three defects that must be fixed before Phase 2: (1) it assumes both execution engines behave the same around scoping, and they do not — `Execution::Next` skips type authorization under conditions the proposal calls safe; (2) its default error mode (`:null`) does **not** hide existence, because a `loads:` miss and a `loads:` denial look different to the client; (3) the public API is heavier than Pundit itself, which defeats goal 1 (remove boilerplate). Two further items are "unknown unknowns" the proposal states as facts: lazy `authorized?` support in Next, and the audit's ability to see hidden members. Everything else is Medium/Low and mostly documentation or stage-ordering.

---

## Claim verification table

| # | Claim in the proposal | Status | Evidence |
|---|---|---|---|
| 1 | `Object.authorized?` runs for every object: root, object fields, each list item, connection `nodes`/`edges` | CONFIRMED | Interpreter `execution/interpreter/runtime.rb:749-751, 780-799`; Next `execution/field_resolve_step.rb:749-783`, `execution/prepare_object_step.rb:91`; connections `types/relay/connection_behaviors.rb:212-229`, `edge_behaviors.rb:22-27` |
| 2 | Scope runs **before** pagination | CONFIRMED | `schema/field.rb:1507-1518` (`ScopeExtension` added before the connection extension), `after_resolve` in definition order `field.rb:1426-1433` |
| 3 | `reauthorize_scoped_objects` defaults to `true` | CONFIRMED | `schema/member/scoped.rb:30-39` (`find_inherited_value(..., true)`) |
| 4 | Per-item `authorized?` is skipped only when `reauthorize_scoped_objects(false)` **and** `scope_items` returned a different object | **WRONG for Next** | Interpreter: `schema/field/scope_extension.rb:13-19` (both conditions). Next: `execution/field_resolve_step.rb:321-324` sets `@was_scoped = true` whenever the return type responds to `scope_items`; `execution/prepare_object_step.rb:82-86` then skips `authorized?` if the **resolved** type has the flag false. No "different object" check |
| 5 | Interface/Union `authorized?` never runs; only the concrete type's | CONFIRMED | `runtime.rb:717-751` (resolve_type, then concrete `wrap`); `prepare_object_step.rb:49-91` |
| 6 | Interface/Union `scope_items` is called for lists of abstract types | CONFIRMED (proposal said "to confirm") | `schema/interface.rb:14` includes `Member::Scoped`; Union inherits via `schema/member.rb:37`; `scope_extension.rb:13-15` calls `field.type.unwrap.scope_items` |
| 7 | `loads:` objects pass through the resolved type's `authorized?` | CONFIRMED | `schema/member/has_arguments.rb:469-484` |
| 8 | A failed `loads:` load and a failed `loads:` authorization are indistinguishable to the client | **WRONG** (the proposal implies it) | Load miss: `load_application_object_failed_error.rb` → ExecutionError `"No object found for \`arg: \"id\"\`"`, raised by default at `has_arguments.rb:508-510`. Auth miss: `UnauthorizedError` → `unauthorized_object` → `nil`, **no** error entry (`schema.rb:1687-1689`; Next `prepare_object_step.rb:119-128` + `unauthorized_error.rb:40-42` only nulls) |
| 9 | Lazy/Promise returned from `authorized?` is honoured | CONFIRMED for Interpreter, **WRONG for Next by default** | Interpreter `schema/object.rb:106-119`. Next: `prepare_object_step.rb:97` only syncs when `@runner.resolves_lazies`, which is `schema.rb:1775-1783` → true only when **more than two** `lazy_resolve` methods are registered. Otherwise a truthy lazy object counts as **authorized** (`prepare_object_step.rb:113-117`) |
| 10 | `Argument#authorized?` is skipped when the default value is used | CONFIRMED + nuance | `field.rb:1186-1191` (`default_used?`). Resolver path `resolver.rb:292` also skips when the sent value **equals** the default and when it is `nil` |
| 11 | `Schema::Visibility` named profiles are cached across requests with a static context; `dynamic: true` builds a profile per query and memoizes per member | CONFIRMED, slightly overstated | `schema/visibility.rb:159-181`; `visibility/profile.rb:93`. Named profiles stay cached **even with `dynamic: true`**; `top_level_profile` (NullContext, `context[:current_user] == nil`) is memoized for every context-less call (`visibility.rb:187-191`) |
| 12 | Hidden members vanish from introspection and "did you mean" | CONFIRMED | `static_validation/validation_context.rb:54-64`; `rules/fields_are_defined_on_type.rb:10,38-40` |
| 13 | Without `use Schema::Visibility`, `visible?` is not consulted | **WRONG** | Default is `Schema::Warden` (`schema.rb:832-840, 856-864`), which calls `schema.visible?(member, ctx)` per query (`schema/warden.rb:588-590`). The 2.4 CHANGELOG note is about the *new* system being opt-in, not about `visible?` being ignored |
| 14 | Mutation payload objects are type-authorized | CONFIRMED | Payload is a `Schema::Object` subclass (`schema/resolver/has_payload_type.rb:111-121`), so normal OBJECT wrapping applies |
| 15 | Subscriptions re-run authorization on each update | CONFIRMED | `subscriptions.rb:129-155` runs `schema.execute` with `root_value: object`; root wrap at `runtime.rb:98-100` |
| 16 | `node(id:)` / `nodes(ids:)` go through `object_from_id` then type `authorized?` | CONFIRMED, with the Next gap from #4 | `types/relay/has_node_field.rb`, `has_nodes_field.rb`. `nodes(ids:)` is a list, so in Next `@was_scoped` is true and a type with `reauthorize_scoped_objects(false)` is returned **unauthorized** |
| 17 | Scalars never pass through type authorization; `Field#authorized?` still runs | CONFIRMED | `runtime.rb:703-716`; `field.rb:1232`. In Next, field auth runs only if the field/args/resolver override it (`field.rb:1162-1166`) |
| 18 | Pundit `policy_scope!` raises when `Scope` is missing | CONFIRMED | `Pundit::NotDefinedError`, message `"unable to find scope \`XPolicy::Scope\` for ..."` (Pundit API docs, `PolicyFinder#scope!`) |
| 19 | CanCanCan `accessible_by` works for any rule | **WRONG** | CanCanCan docs, "Define abilities with blocks → Fetching Records": a rule defined **only with a block** makes `accessible_by` **raise**; an SQL string or scope must accompany the block |
| 20 | Community/gem-name facts (action_policy-graphql only maintained 2.x gem; names free) | UNVERIFIABLE here | Web facts from 2026-10-28; re-check right before publishing |

---

## Findings

### Critical

**C1 — `Execution::Next` skips type authorization for any scoped list whose concrete type sets `reauthorize_scoped_objects(false)`** (proposal §4.4, §4.5)

- *Problem:* The proposal says disabling re-authorization is safe "because scope_items already filtered". That is true for the Interpreter only. In Next, `@was_scoped` is set whenever the return type **responds to** `scope_items` — which every Object, Interface, Union and Connection does — regardless of whether anything was filtered (`execution/field_resolve_step.rb:321-324`). `PrepareObjectStep#authorize` then returns the raw object (`prepare_object_step.rb:82-86`).
- *Scenario:* `Types::Invoice` has `reauthorize_scoped_objects(false)` (the proposal exposes this as a performance knob). Schema runs with `default_execution_next(true)`. Query `{ nodes(ids: ["Invoice:42"]) { ... on Invoice { total } } }`. `Node.scope_items` is a no-op, `@was_scoped` is still `true`, `Invoice.authorized?` **never runs** → user A reads user B's invoice. Same for any custom resolver returning `[record]` from a list field without a real scope.
- *Fix:* (a) Never expose `reauthorize_scoped_objects(false)` as a gem option in 0.1; keep the default `true` and let memoization pay for it. (b) If exposed later, the gem's `scope_items` must itself record "I actually scoped this relation" in `context.namespace(:armory)` and the gem's `authorized?` must consult that flag instead of trusting the engine's. (c) Add `nodes(ids:)` + Next to the security suite.

**C2 — The default error mode does not hide existence on `loads:`** (proposal §4.6, §4.5)

- *Problem:* With default graphql-ruby behavior, a `loads:` argument whose id does not exist produces a visible error `No object found for \`invoiceId: "..."\``, while an id that exists but is denied produces a silent `null`. The proposal's "another user's object is indistinguishable from one that doesn't exist" only holds if the gem also overrides `load_application_object_failed` — and the proposal never says so.
- *Scenario:* Mutation `approveInvoice(invoiceId:)`. Attacker enumerates ids: an error means "no such invoice", a silent null means "exists, not mine". Oracle in one request per id.
- *Fix:* The integration module for resolvers/mutations must override **both** `load_application_object_failed` and `unauthorized_object` to produce the same outcome (same `nil`/error payload, same message, same `extensions.code`). Document this invariant and pin it with one security spec per mode (`:null`, `:error`, `:raise`). Also note that loading through the scope (proposal's `load_through_scope`) naturally turns "denied" into "not found" — that is the stronger design; make it the only path when a scope exists.

### High

**H1 — Lazy `authorized?` is silently treated as *authorized* in `Execution::Next`** (§4.8)

- *Problem:* The proposal promises Dataloader support "because graphql-ruby accepts lazy values from `authorized?`". In Next that sync happens only when `resolves_lazies?` is true, i.e. **more than two** `lazy_resolve` registrations (`schema.rb:1775-1783`). A plain schema has `Execution::Lazy` and `Dataloader::Request` → count 2 → false. A policy returning a `Dataloader::Request` is then a truthy object → access granted.
- *Scenario:* `InvoicePolicy#read?` returns `dataloader.with(Sources::Membership).request(user.id)` to batch. Under Next, every object is authorized.
- *Fix:* The gem's `authorized?` must coerce the adapter's answer to a boolean itself: use `context.dataloader.with(...).load` (synchronous via Fiber, `dataloader/source.rb:93-99`) and, defensively, raise `ArmoryError` if the adapter returns a non-boolean, non-nil value. Drop the phrase "lazy values are accepted" from the docs; say "use `.load`, not `.request`".

**H2 — CanCanCan scopes fail at runtime for block-only rules, which the proposal calls "fail closed"** (§4.4, §4.1)

- *Problem:* `accessible_by` raises for rules defined only with a block. Teams using CanCan commonly write `can :read, Invoice do |i| i.account == user.account end`. With the proposal, **every list of that type 500s** the moment the adapter is enabled. That is fail-closed in the narrowest sense, but it is also an outage with no migration path.
- *Fix:* In the CanCan adapter, rescue `CanCan::Error` from `accessible_by` and (a) raise the gem's own `MissingScopeError` with an actionable message ("rule for :read on Invoice has a block without SQL; add an SQL/scope argument or declare `scope: :in_memory` on the field"), and (b) offer an explicit per-field opt-in `scope: :in_memory` that filters with `can?` and **disables efficient pagination with a warning**. Make the audit's `check` detect this where possible (`ability.permissions` needs a user; use `Controls` example users in the audit).

**H3 — Public API is heavier than Pundit itself** (§4.2) — see dedicated section below.

**H4 — Coverage rules create a false sense of safety on root types and on `Field#authorized?` in Next** (§4.3)

- *Problem A:* "Fields are covered by their type's rule" is correct for object-returning fields because the returned type is checked anyway — but the type's rule says nothing about **scalar** fields of a bypassed parent that compute from the object (e.g. `Query.me { email }` is fine, but `Query.invoiceTotalFor(accountId:)` returning `Integer` is uncovered). The proposal handles this only when the parent is bypassed. A non-bypassed parent with a scalar field that aggregates other users' data (`Account.allInvoicesTotal`) is "covered" by `AccountPolicy#read?`, which says nothing about the aggregate.
- *Problem B:* In Next, `Field#authorized?` is only invoked when graphql-ruby detects an override on the field class (`field.rb:1162-1166`, `has_authorization.rb:33-35`). The gem **must** define `authorized?` as a real method on the custom field class (not `define_method` on a shared owner, not `method_missing`), and the suite must assert it runs under Next.
- *Fix:* Keep the rule but add an audit **warning** (not failure) for scalar fields with arguments on covered types, and document that per-field rules are the tool for aggregates. Add a Next-specific spec: a field with `authorize:` denied under `default_execution_next(true)`.

### Medium

**M1 — `:error` mode risks leaking existence through non-null fields** (§4.6). A denied object in a non-null position yields `Cannot return null for non-nullable field X.y` (`invalid_null_error.rb:50`), which differs from the gem's generic `NOT_FOUND`. *Fix:* document that non-null object fields and `:null`/`:error` modes are incompatible for IDOR-sensitive paths; the audit should flag `field :invoice, Types::Invoice, null: false` on root/loads paths.

**M2 — Visibility design mixes two caching stories** (§4.7). Named `profiles:` are cached across requests even with `dynamic: true`; `Schema.types` with no context uses a NullContext (user = nil) and that profile is memoized forever. If the gem's `visible?` reads `context[:current_user]`, then any context-less call (`rake graphql:schema:dump`, the gem's own audit, `to_definition`) sees the **public** schema and caches it. *Fix:* (a) the audit must use `all_field_definitions` / `all_argument_definitions` / `Schema.visibility.types` (unfiltered), never `Schema.types(ctx)`; (b) make `visible?` return `true` for `Query::NullContext` explicitly and say why; (c) correct claim 13 — `visible?` is consulted by Warden too, so the gem works pre-Visibility, just without profile caching.

**M3 — Argument authorization has two different skip rules** (§4.2 / stage 0.2). `Field` path skips defaults; `Resolver` path also skips `nil` and values equal to the default. A rule like `argument :include_archived, Boolean, default_value: false, authorize: :admin` is never checked when the client sends `false` explicitly through a resolver. *Fix:* document that argument rules guard *non-default* values only, and make the audit warn on `authorize:` + `default_value:` combinations.

**M4 — Two engines, one suite.** The proposal says "cover both" but the CI matrix lists Ruby × graphql × engine without saying how the engine is toggled. *Fix:* run the whole security suite twice via `GRAPHQL_ARMORY_ENGINE=next` setting `default_execution_next(true)` on the dummy schema; fail CI if either leg is skipped.

**M5 — `check(type, rule)` for Pundit resolves constants by GraphQL name** (`"#{type.graphql_name}Policy"`). That breaks for namespaced models (`Billing::Invoice` → `InvoicePolicy`?), for types whose `graphql_name` differs from the model, and for STI. *Fix:* resolve the policy from the **model class**, not the GraphQL type: `authorize :read, model: Billing::Invoice` optional, default `type.name.demodulize`, and use `Pundit::PolicyFinder.new(model).policy` so Pundit's own `policy_class` override is honoured. Keep `policy:` as the explicit escape hatch.

**M6 — `MissingScopeError` vs Pundit's own error.** `policy_scope!` already raises `Pundit::NotDefinedError`. Wrapping it is fine, but don't **swallow** it: rescue, re-raise as `GraphQL::Armory::MissingScopeError` with `cause` set, so backtraces still point at Pundit.

### Low

**L1 — Interface/Union scope** (§4.4): since abstract types **do** get `scope_items`, `scope_with:` is unnecessary ceremony. Default: an interface/union list scopes with the adapter's scope for each **possible type** and unions the results only when all possible types resolve to the same model (common STI case); otherwise fail closed with a clear message. Keep `scope_with:` as the override.

**L2 — Telemetry payload** (§4.6): "user id" in the signal is PII under some regimes; make the user key a lambda (`telemetry_actor: ->(actor) { actor.id }`) with a default of `actor.class.name` + `id` and document how to redact.

**L3 — Benchmark scope** (§4.8): also measure the Next engine; it already avoids `authorized?` allocations when the type does not override it, so numbers will differ.

**L4 — Ruby floor** (§4.9): graphql 2.6 still supports Ruby 2.7; the user asked for 3.0. `>= 3.1` is defensible (3.0 EOL) but say so in the README; do not use 3.2-only syntax (`Data`, anonymous block args) if 3.1 is the floor.

---

## Public API review (§4.2) — "Ruby developers like it easy"

Measured against Pundit's install story (one `include`, convention-over-configuration) and action_policy-graphql (one `include`, `authorize:` kwarg), the proposed API has four frictions.

| Friction | Today | Proposed |
|---|---|---|
| Install | Two `include`s **plus** `field_class` / `argument_class` wiring in three base classes | `use GraphQL::Armory::Authorization` in the schema **and** one `include GraphQL::Armory::Authorization::Base` in `BaseObject`, `BaseField`, `BaseArgument`, `BaseResolver` (the same module, it detects the receiver). The generator writes those four lines. No manual `field_class`. |
| Per-type action | `authorize :read` on **every** type | `default_action :read` on `BaseObject` (inheritable). A type with no `authorize` **is covered** when (a) a default action exists **and** (b) the adapter's `check` finds the policy/ability for it. Audit still reports types with no policy. Explicit `authorize :view` overrides. |
| Bypass | `skip_authorization reason: "..."` on types, `skip_authorization: "..."` on fields | One shape: `authorize :none, reason: "..."` on types/mutations and `authorize: :none, reason: "..."` on fields/arguments. Same word everywhere; `:none` is greppable; the audit lists every `:none` with its reason. |
| Field rule | `authorize: :manage` only | Also `authorize: true` (same action as the parent type, re-checked on the parent) and `authorize: :none`. Keep `authorize: :manage` for a different action. |
| Mutations | `def unauthorized(error)` hook | `authorize :approve, on_denied: :errors` (returns `{ errors: [...] }` using the schema's error-type convention) or `on_denied: :raise` (default). The method hook stays as the escape hatch. |

Proposed replacement for §4.2:

```ruby
class AppSchema < GraphQL::Schema
  use GraphQL::Armory::Authorization, adapter: :pundit   # user: ->(ctx) { ctx[:current_user] } is the default
end

class Types::BaseObject < GraphQL::Schema::Object
  include GraphQL::Armory::Authorization::Base
  default_action :read                     # InvoicePolicy#read? unless a type says otherwise
end
class Types::BaseField    < GraphQL::Schema::Field;    include GraphQL::Armory::Authorization::Base; end
class Types::BaseArgument < GraphQL::Schema::Argument; include GraphQL::Armory::Authorization::Base; end
class Mutations::BaseMutation < GraphQL::Schema::RelayClassicMutation; include GraphQL::Armory::Authorization::Base; end

class Types::Invoice < Types::BaseObject   # covered: InvoicePolicy#read? exists
  field :total, Integer
  field :internal_notes, String, authorize: :manage
end

class Types::Query < Types::BaseObject
  authorize :none, reason: "Root type; fields declare their own rules"
  field :invoice, Types::Invoice, authorize: :read do
    argument :id, ID
  end
  field :status, String, authorize: :none, reason: "Public health check"
end

class Mutations::ApproveInvoice < Mutations::BaseMutation
  authorize :approve, on_denied: :errors   # { invoice: nil, errors: [{ message: "Not allowed", code: "FORBIDDEN" }] }
  argument :invoice_id, ID, loads: Types::Invoice
end
```

Things that are already good and should stay: neutral action names (`:read` not `pundit_role`), `reason:` being mandatory on bypasses, `loads:` through scope by default, the RSpec matcher `be_fully_authorized`.

---

## Useful Objects fit

Mostly aligned; three corrections.

1. **`Authorize.(subject, action, ctx)` has three positional arguments and reaches into `ctx` for the actor.** In the doctrine the actuator receives data, and dependencies are attributes. Shape: `Authorize.build(context)` installs `adapter`, `memo`, `telemetry` via `configure`; `#call(subject, rule)` only. The integration layer does `Authorize.build(ctx).(object, rule)` — and `build(ctx)` should itself be memoized in `ctx.namespace(:armory)` so one instance serves the request.
2. **The `Null` adapter is a null object, but the proposal does not give it the `Substitute` role.** Keep `Adapters::Null` (denies, records nothing) as the `new` default **and** add `Adapters::Pundit::Substitute` / `Adapters::CanCanCan::Substitute` with `allow!`/`deny!` and `invoked?(:authorized?)` so integration specs do not need the real policy classes. `Audit` needs its own `Substitute` schema walker for unit tests.
3. **`Rule` is described as "immutable value" but built by class macros that mutate class state.** Fine, but make the macro produce a frozen `Rule` **once** at definition time and store it with `find_inherited_value`; never compute inheritance at request time. Also give `Rule` a `Controls` module (`Controls::Rule.example`, `.bypass`, `.field`) — the audit and the integration specs both need them.

Telemetry: the proposal names a `:denied` signal only. Add `:granted` (cheap, lets tests assert positive paths without mocks) and `:scoped` (`items_class`, `scoped?` boolean) — that is what the Next-engine finding needs to be observable.

---

## Gaps and scope

**Missing for the MVP (0.1):**
- The engine matrix (M4) — without it, C1/H1 are invisible.
- The `load_application_object_failed` override (C2) is listed under 0.2 (loads/mutations) but the **root field** `invoice(id:)` in the MVP has the same oracle if implemented with `Schema.object_from_id`. Ship the "find through scope" helper in 0.1 for root fields.
- A `GraphQL::Armory::Authorization::Controls::Schema.example` — a tiny dummy schema inside `lib/` so adapter authors can run the security suite against their adapter (`shared_examples "an armory adapter"`). This is the doctrine's `Controls` applied to the one thing third parties will need.

**Move between stages:**
- Argument authorization (0.2 → 0.3): low value, two engine-specific skip rules (M3), and no IDOR relevance.
- CanCanCan adapter (0.4 → 0.2): the adapter contract was just made neutral; the only proof that it *is* neutral is shipping the second adapter early. Also the block-rule failure (H2) is a design input, not a late detail.

**Over-engineered:**
- `scope_with:` for abstract types (L1).
- `strict:` boot-time check **and** rake task **and** RSpec matcher **and** telemetry warnings in 0.1. Ship the matcher and the rake task; `strict:` is the same check behind a config flag and can wait.
- The visibility "profiles" mode (0.3): document the recipe (`visibility_profile_for`), don't build an abstraction over graphql-ruby's.

---

## Proposed changes to the doc

1. **§4.4, replace** "`reauthorize_scoped_objects` stays `true` … It can be turned off; the benchmark will quantify the difference." **with:**
   > `reauthorize_scoped_objects` stays `true` and the gem exposes no switch for it in 0.1. In `Execution::Next` the engine marks any list of a scoping-capable type as "scoped" even when nothing was filtered (`execution/field_resolve_step.rb:321-324`), so turning the flag off would skip `authorized?` on `nodes(ids:)` and on custom list resolvers. A future opt-out must rely on the gem's own "actually scoped" flag in `context.namespace(:armory)`.

2. **§4.6, add a row and an invariant:**
   > **Invariant:** for every mode, a `loads:` id that does not exist and a `loads:` id that is denied produce byte-identical responses. The resolver integration overrides `load_application_object_failed` and `unauthorized_object` together. One spec per mode pins this.

3. **§4.8, replace** "a policy may return a lazy value; graphql-ruby accepts it" **with:**
   > Policies must return a boolean. To batch, call `context.dataloader.with(Source).load(key)` inside the policy (synchronous via Fiber). `Execution::Next` does not resolve lazies from `authorized?` unless extra `lazy_resolve` hooks are registered (`schema.rb:1775-1783`), and would treat the lazy object as *authorized*. The gem raises if an adapter returns a non-boolean.

4. **§4.1 CanCanCan column, `scope` row, append:** "Rules defined only with a block make `accessible_by` raise; the adapter converts that to `MissingScopeError` with guidance, and `scope: :in_memory` opts a field into `can?` filtering (no efficient pagination)."

5. **§4.2** — replace with the API block in the "Public API review" section above.

6. **§3.1 findings bullet** "Since 2.4, `visible?` requires `use GraphQL::Schema::Visibility`" → "`visible?` is consulted by the default `Schema::Warden` too; `Schema::Visibility` (2.4+) adds profile caching and is required for the profiles recipe."

7. **§4.3 audit list, add:** "Non-null object fields on root or `loads:` paths (existence leak under `:null`/`:error`)", "`authorize:` combined with `default_value:` (rule never checked for the default)", "Scalar fields with arguments on covered types (warning)".

8. **§6 table, add rows:** Next scope flag `execution/field_resolve_step.rb:321-328`, `execution/prepare_object_step.rb:82-86`; lazy gate `schema.rb:1775-1783`; load-failed message `load_application_object_failed_error.rb`.

---

## Open questions for the author

1. **Default action.** Accept `default_action :read` on `BaseObject` as counting toward coverage when the policy exists? (Trade: less ceremony vs. a type being "covered" by a rule nobody wrote on it.)
2. **Engine support.** Is `Execution::Next` a first-class target for 0.1 (doubles the suite) or "best effort, documented"? Given C1/H1, I recommend first-class.
3. **CanCanCan block rules.** Fail the whole list (`MissingScopeError`) or auto-fallback to in-memory `can?` filtering with a logged warning? I recommend fail + explicit `scope: :in_memory`.
4. **Bypass spelling.** `authorize :none, reason:` (one word everywhere) vs. `skip_authorization` (more explicit, two shapes). 
5. **Ruby floor.** 3.0 as originally requested, or 3.1?
6. **Policy lookup.** From the GraphQL type name (proposal) or from the model class via `Pundit::PolicyFinder` (recommended, honours `policy_class`)?
