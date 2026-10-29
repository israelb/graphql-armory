# Research 02 — Pro capabilities (public docs), community gems, name availability

> Phase 0, items 2–3, plus naming. Dates: 2026-10-28 (capabilities, gems, names), 2026-10-29 (Pro/Enterprise feature inventory).
> Clean-room: only **public** documentation was used. Local copies of the public guides live in `graphql-ruby/guides/`. No Pro/Enterprise code was obtained or read.

---

## 1. Observable capabilities of the Pro Pundit / CanCan integration

Sources: `graphql-ruby/guides/authorization/pundit_integration.md` (P), `can_can_integration.md` (C). OSS hooks from `authorization.md`, `scoping.md`, `visibility.md`.

| Capability | Documented DSL (file › heading) | Doable with OSS hooks? |
|---|---|---|
| Per-object-type policy | `include ...PunditIntegration::ObjectIntegration`, class `pundit_role :staff` → `Pundit.policy!(user, obj).staff?` (P › Authorizing Objects; Policies and Methods). CanCan `can_can_action(:read)` (C › Authorizing Objects) | **Yes** — `self.authorized?(obj, ctx)` |
| Inherited config, subclass override | Set on BaseObject, `pundit_role nil` on `Query` (P › Authorizing Objects) | **Yes** — class attribute walking `superclass` |
| Explicit bypass | `pundit_role nil` / `can_can_action(nil)` "will override any inherited configuration and skip" (P › Bypassing Policies; C › Bypassing CanCan) | **Yes** |
| Custom policy class | Type `pundit_policy_class(Klass or "String")`; field option `pundit_policy_class:` (P › Custom Policy Class) | **Yes** |
| Custom lookup hooks | `pundit_policy_class_for(obj, ctx)`, `pundit_role_for(obj, ctx)`, `scope_by_pundit_policy(ctx, items)`; `policy_class_for` (P › Custom Policy Methods; One Policy Per Class) | **Yes** |
| Custom user / ability | `QueryContext#pundit_user` (P › Custom User Lookup); `context[:can_can_ability]` (C › Custom Abilities Class) | **Yes** |
| Scopes on lists/connections | Lists/connections scoped with `Pundit.policy_scope!`; **a missing scope crashes the query rather than leak**; bypass `scope: false`; `UnionIntegration` / `InterfaceIntegration` (P › Scopes; Bypassing scopes). CanCan `.accessible_by` for relations, `.select{can?}` for Arrays (C › Scopes) | **Yes** via `scope_items`; abstract-type scope resolution **unclear** in Pro docs |
| Field authorization | `field ..., pundit_role: :staff` on the **parent object's** policy (P › Authorizing Fields). CanCan `can_can_attribute:`, `can_can_subject: :all`, **skips the check when `object` is nil** (C) | **Yes** — `Field#authorized?` + kwargs |
| Argument authorization | `argument ..., pundit_role: :admin` on parent policy (P › Authorizing Arguments) | **Yes** — `Argument#authorized?` |
| Mutation-level role | `MutationIntegration`, class `pundit_role :admin`, checked "before loading objects or resolving"; policy from mutation class name (P › Mutation-level roles) | **Yes** — `ready?`/`authorized?`; ordering vs `loads:` partially known |
| Loaded objects | `argument :employee_id, ID, loads: Types::Employee, pundit_role: :supervisor`, on top of the read check (P › Authorizing Loaded Objects) | **Yes** |
| Mutation errors | Raises by default; `#unauthorized_by_pundit(owner, value)` returns early value (`nil` or `{errors: [...]}`) (P › Unauthorized Mutations); CanCan `unauthorized_by_can_can` | **Partially** — mechanism yes; exact exception class only in Pro code |
| Unauthorized objects | `Schema.unauthorized_object` (P › Handling Unauthorized Objects) | **Yes** (OSS behavior) |
| Resolvers | `ResolverIntegration` (P › Authorizing Resolvers) | **Yes** |
| Generator | `rails g graphql:pundit:install` (P › Rails Generator) | **Yes** |

**Only knowable from Pro code — we design our own:**
- Exception class on mutation denial; error for missing policy/scope.
- Whether role results are cached per request.
- How union/interface scope resolution works.
- Field-level `pundit_role` when parent object is nil (Pundit guide silent; CanCan documents a skip).
- Whether `reauthorize_scoped_objects` interacts with the integration.
- Whether visibility is tied to roles (neither guide mentions it).

---

## 2. Community gems (rubygems API + GitHub API, 2026-10-28)

| Gem | Latest (date) | Activity | graphql 2.x? | Covers | License |
|---|---|---|---|---|---|
| **action_policy-graphql** ([repo](https://github.com/palkan/action_policy-graphql)) | 0.6.0 (2024-07-08), 2.49M downloads | last push 2026-07-25, ~149★ | **Yes** (`graphql >= 1.9.3`) | Field `authorize:`, `authorize_field:`, `preauthorize:`, `authorized_scope:` for lists/connections, `expose_authorization_rules`, `raise: false`. Mutation `authorize` **deprecated**. No visibility, deny-by-default or audit | MIT |
| graphql-guard ([repo](https://github.com/exAspArk/graphql-guard)) | 2.0.0 (2020-04-20), 2.14M | last push 2022-09, ~466★ | **No** (`>= 1.10, < 2`) | Field/type guard lambdas, policy object, mask, Pundit/CanCan recipes | MIT |
| graphql-pundit ([repo](https://github.com/ontohub/graphql-pundit)) | 0.7.1 (2018-06-20) | **archived** (2020-01), ~111★ | **No** (`< 1.10`, pundit ~> 1.1) | Field authorize/scope with Pundit | MIT |
| graphql_authorize ([repo](https://github.com/anjlab/graphql_authorize)) | 0.4.2 (2018-10-18) | last push 2024-05, ~23★ | Unconstrained, untested on 2.x | Field authorize, Pundit/CanCan adapters | MIT |
| graphql-authorization ([repo](https://github.com/Call9/graphql-authorization)) | 0.0.3 (2017-04-25) | dead, ~11★ | No | Basic permissions | MIT |
| pundit-graphql, graphql-cancancan, graphql-cancan | not published | — | — | — | — |

**Gaps none of them cover (our differentiation):** deny-by-default; schema audit for CI; IDOR-safe `loads:` by default; `visible?` driven by the same policy; missing scope fails closed (documented by Pro, absent from OSS gems); typed errors-as-data for mutations; Pundit **and** CanCanCan on 2.x in one maintained gem.

---

## 3. Name availability

### 3.1 First round (policy-oriented names, 2026-10-28)

Free on rubygems ("could not be found"): `graphql-policy`, `graphql_policy`, `graphql-authz`, `graphql-gatekeeper`, `graphql-warden`, `graphql-sentinel`, `pundit-graphql`, `graphql-cancancan`. **Taken:** `graphql-pundit` (archived 2018 gem). On GitHub, "graphql-policy" only matched action_policy-graphql and a fork (mild confusion risk).

### 3.2 Second round (global names, 2026-10-28)

| Name | rubygems `-` | rubygems `_` | GitHub Ruby repos |
|---|---|---|---|
| graphql-armory | free | free | 0 |
| graphql-forge | free | free | 0 |
| graphql-toolbelt | free | free | 0 |
| graphql-powerpack | free | free | 0 |
| graphql-foundry | free | free | 0 |
| graphql-kit | free | free | 1 |
| graphql-plus, graphql-arsenal, graphql-keystone, graphql-bastion, graphql-citadel, graphql-toolkit, graphql-workshop, graphql-stack, graphql-suite, graphql-ironworks, graphql-lattice | free (`-`) | not checked | not checked |
| graphql-extras | **taken** | — | — |

**Chosen: `graphql-armory`** (user approved 2026-10-28). Not checked: npm, PyPI, Go namespaces. **Re-check right before publishing.**

---

## 4. Pro / Enterprise feature inventory (public guides, 2026-10-29)

Command used: `grep -rlE "GraphQL::Pro|graphql\.pro" guides --include=*.md` and the same for `GraphQL::Enterprise|graphql-enterprise`, inside `graphql-ruby/`.

### Pro

| Feature | Public guides |
|---|---|
| Pundit / CanCan authorization | `authorization/pundit_integration.md`, `can_can_integration.md`, `overview.md` |
| OperationStore (persisted queries, whitelisting) | `operation_store/overview.md`, `getting_started.md`, `access_control.md`, `client_workflow.md`, `server_management.md`, `active_record_backend.md`, `redis_backend.md`; `javascript_client/sync.md` |
| `@defer` / `@stream` | `defer/setup.md`, `usage.md`, `stream.md` |
| Subscriptions over Pusher / Ably | `subscriptions/pusher_implementation.md`, `ably_implementation.md`, `multi_tenant.md` |
| Stable relation connections | `pagination/stable_relation_connections.md` |
| Encrypted, versioned IDs and cursors | `pro/encoders.md` |
| Dashboard | `pro/dashboard.md` |
| Misc. | `pro/home.md`, `pro/installation.md`, `pro/privacy.md`; mentions in `schema/sdl.md`, `execution/migration.md`, `javascript_client/overview.md` |

### Enterprise

| Feature | Public guides |
|---|---|
| ObjectCache (server-side caching, public/private TTL) | `object_cache/overview.md`, `caching.md`, `schema_setup.md`, `redis.md`, `memcached.md` |
| Rate limiting (runtime, active operations) | `limiters/overview.md`, `runtime.md`, `active_operations.md`, `redis.md`, `deployment.md` |
| Changesets (API versioning) | `changesets/overview.md`, `definition.md`, `installation.md`, `releases.md` |

Not software (not replicable): direct support from the gem author. Prices shown in a user screenshot (Pro $1,100/yr, Enterprise $2,400/yr) were **not verified**.

Notable: the open-source `lib/` has **no** incremental-delivery (`@defer`/`@stream`) code (research 07).
