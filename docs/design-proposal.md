# graphql-armory — Design Proposal

> Status: **Phase 1 proposal, revised after review (`docs/design-review.md`), pending final approval.** Nothing is implemented yet.
> Date: 2026-10-28 · Reference: graphql-ruby **v2.6.13** (commit `23a5d65`), [rmosolgo/graphql-ruby@23a5d65](https://github.com/rmosolgo/graphql-ruby/tree/23a5d6595ef9f6e14d89a05e97e260fc8c9c1962).
> Decisions taken after the review: `Execution::Next` is a first-class target; CanCanCan block-only rules fail with an explicit opt-in; bypass is spelled `authorize :none, reason:`; `default_action` counts as coverage; Ruby >= 3.1; Pundit policies resolved from the model class.

---

## Table of contents

1. [Context and goals](#1-context-and-goals)
2. [Clean-room rules](#2-clean-room-rules)
3. [Phase 0 — Research summary](#3-phase-0--research-summary)
4. [Phase 1 — Design](#4-phase-1--design)
5. [Delivery stages](#5-delivery-stages)
6. [How to verify the claims](#6-how-to-verify-the-claims)
7. [Open decisions](#7-open-decisions)

---

## 1. Context and goals

An open-source Ruby gem that makes authorization in **open-source graphql-ruby** easy and safe, with an experience equivalent to GraphQL-Pro's Pundit/CanCan integration, implemented independently. It is a standalone project: it depends on no app and is tested against a dummy app inside the repo (`spec/dummy`).

The gem name is deliberately global: authorization (Pundit, then CanCanCan) is the first module, and other Pro-like capabilities will follow later as separate modules, each with its own clean-room research.

### Problems it solves

With open-source graphql-ruby, authorization is hand-written `authorized?`, `visible?` and `scope_items` on every type, field and argument. That causes:

1. **Boilerplate.**
2. **Forgotten types** — a type without a check is open by default.
3. **IDOR** — loading by global ID instead of through the user's scope.

### Design paradigm

Written following Eventide's [Doctrine of Useful Objects](https://eventide-project.org/user-guide/useful-objects.html#the-doctrine-of-useful-objects), with the pattern **hand-written** (no `evt-*` runtime dependencies).

---

## 2. Clean-room rules

- Sources allowed: (a) open-source graphql-ruby code, (b) public Pro docs (`guides/authorization/pundit_integration.md`, `can_can_integration.md`) to understand *what* experience is offered, (c) Pundit and CanCanCan docs.
- Never copy, recreate line by line, obtain or decompile graphql-pro code. Anything only knowable from Pro code gets our own design.
- Hook only into graphql-ruby's public extension points (modules included into `BaseObject`, `BaseField`, `BaseArgument`, `BaseMutation`, …). No fork, no modifications, no monkey patching where a public hook exists.
- The graphql-ruby clone is never modified.

---

## 3. Phase 0 — Research summary

### 3.1 graphql-ruby public hooks (v2.6.13)

| Hook | When it is called | Result handling |
|---|---|---|
| `Object.authorized?(obj, ctx)` | When wrapping every object: root, each object-returning field, each list item (`object.rb:95`) | `false`/`nil` → `Schema.unauthorized_object` (default returns `nil`: the field is silently nulled). Raising `ExecutionError` → null + entry in `errors`. Lazy values / Promises are supported |
| `Field#authorized?(obj, args, ctx)` | Inside `Field#resolve` (`field.rb:1168`); by default checks each provided argument | `false` → `Schema.unauthorized_field`, which defaults to `unauthorized_object` |
| `Argument#authorized?(obj, value, ctx)` | Only for explicitly provided arguments — **not called when the default value is used** | **There is no `unauthorized_argument`**; denial goes to `unauthorized_field` |
| `EnumValue#authorized?` / `visible?` | Input and output coercion | Denial raises |
| `visible?(ctx)` + `Schema::Visibility` | Validation and introspection | Hidden members disappear from introspection **and from "did you mean" suggestions** (`validation_context.rb:54-64`) |
| `scope_items(items, ctx)` | Lists and connections, **before pagination** (`ScopeExtension` is registered before the connection extension, `field.rb:1507`) | `totalCount` over the scoped relation is correct |
| `loads:` | `object_from_id` → concrete type's `authorized?` (`has_arguments.rb:469`) | Load failure → `load_application_object_failed`; auth failure → `unauthorized_object` |
| Resolver / Mutation: `ready?` → loads → `authorized?` → `resolve` | `resolver.rb:147-195` | `[false, data]` returns `data` as the field value (errors as data); a plain `false` from `authorized?` → `unauthorized_field` |
| `context.namespace(:gem)` | Per-query Hash | Ideal place to memoize policy results |
| `Schema.trace_with` | Trace hooks `authorized`, `begin_authorized`/`end_authorized`, `resolve_type`, `execute_field` | Usable for auditing/telemetry |
| Schema iteration | `Schema.types`, `root_types`, `possible_types`, `all_field_definitions`, `all_argument_definitions` | `types(ctx)`/`fields(ctx)` are visibility-filtered; `all_*_definitions` include hidden members |

#### Findings that shape the design

- **Interface and Union `authorized?` never runs.** Only the concrete type returned by `resolve_type` is checked. Good against IDOR (every path ends at the concrete type), but a policy declared on an interface would *look* protective and not be.
- **`reauthorize_scoped_objects` defaults to `true` in code** (`scoped.rb:35`), even though CHANGELOG 2.2 says `false`. With `true`, the scope runs *and* `authorized?` runs per item (N+1 risk).
- **Per-user visibility:** named visibility profiles are cached with a static context (`visibility.rb:159-181`). A user-dependent `visible?` needs `dynamic: true` or no profiles; a profile is then built per query and memoized inside it.
- **Two execution engines:** the legacy Interpreter (default) and `Execution::Next` (new in 2.6, files directly under `lib/graphql/execution/`). They differ in ways that matter for security:
  - Next marks any list whose return type *responds to* `scope_items` as "scoped", even when nothing was filtered (`execution/field_resolve_step.rb:321-324`), and then skips `authorized?` if the resolved type has `reauthorize_scoped_objects(false)` (`execution/prepare_object_step.rb:82-86`).
  - Next resolves a lazy returned from `authorized?` only when more than two `lazy_resolve` hooks are registered (`schema.rb:1775-1783`); otherwise the lazy object is truthy and counts as **authorized**.
  - Next invokes `Field#authorized?` only when it detects an override on the field class (`field.rb:1162-1166`).
  - The suite runs on both engines.
- Scalars never go through type authorization.
- `visible?` is consulted by the default `Schema::Warden` too (`schema/warden.rb:588-590`). `use GraphQL::Schema::Visibility` (2.4+) adds profile caching and is required only for the profiles recipe.
- Interfaces and unions **do** receive `scope_items` for list fields (`schema/interface.rb:14`, `schema/member.rb:37`).
- `required_ruby_version >= 2.7.0` (graphql.gemspec).

#### Relevant changes 2.0 → 2.6 (open-source CHANGELOG)

- 2.1: `reauthorize_scoped_objects` added; `return false, nil` allowed from `ready?`/`authorized?`.
- 2.4: Visibility opt-in required; `EnumValue#authorized?` called at runtime; Dataloader works with `loads:` + `authorized?`.
- 2.6: `Execution::Next` added.

### 3.2 Pro Pundit/CanCan integration (public docs only)

**Every observable capability is implementable with open-source hooks:** per-type policy, per-field/argument/mutation role, explicit `nil` bypass, custom policy class, inherited configuration in subclasses, scopes on lists and connections, authorization of `loads:` objects. Mutation error handling is partially implementable: the mechanism yes, but the exception class Pro uses is unknown.

**Only knowable from Pro code — we design our own:**

- The exception class and message when a mutation is denied or a scope is missing.
- Whether policy results are cached per request.
- How scope is resolved for unions and interfaces.
- What happens to a field when the parent object is `nil`.
- Whether visibility is tied to roles (the docs don't mention it).

### 3.3 Community gems

| Gem | Status |
|---|---|
| **action_policy-graphql** 0.6.0 | Only maintained, graphql 2.x–compatible option. Ties you to ActionPolicy; deprecated `authorize` in mutations |
| graphql-guard 2.0.0 | Requires `graphql < 2` — unusable |
| graphql-pundit 0.7.1 | Archived since 2018; name taken |
| graphql_authorize, graphql-authorization | Abandoned |

**Gaps none of them cover (our differentiation):** deny-by-default, schema audit for CI, IDOR-safe `loads:` by default, `visible?` driven by the same policy, fail-closed on missing scope, Pundit and CanCanCan adapters in one maintained gem.

### 3.4 Eventide — Doctrine of Useful Objects

Principles we apply:

- **An object is useful as soon as it is instantiated.** `new` never leaves a dependency `nil`; it gets an inert null object. `self.build` wires the real dependencies.
- **`self.configure(receiver)`:** each dependency knows how to build itself and assign itself onto the receiver.
- **`module Substitute`** inside each dependency, for tests without mocks.
- **Telemetry instead of mocks:** tests inspect what the object recorded, not call expectations.
- **A single actuator, `call`:** `self.call(...)` is `build(...).()`.
- **`Controls::X.example`:** test data lives inside `lib/` so other projects can reuse it.

**Why no `evt-*` dependencies:** `evt-dependency` pulls ~6 transitive gems, its last release is from 2023, and its global activation includes the module into `Object`, which a public gem must not do to the host app. The pattern is ~20 lines by hand.

**RSpec is compatible with the doctrine:** RSpec is the runner; by convention no `instance_double` or `receive` — Substitutes, telemetry sinks and `Controls` instead.

---

## 4. Phase 1 — Design

### 4.0 Name and scope

**Recommended: `graphql-armory`**, namespace `GraphQL::Armory`.

Name availability, checked 2026-10-28:

| Name | RubyGems (`-` and `_`) | GitHub Ruby repos |
|---|---|---|
| `graphql-armory` | free | 0 |
| `graphql-forge` | free | 0 |
| `graphql-toolbelt` | free | 0 |
| `graphql-powerpack` | free | 0 |
| `graphql-foundry` | free | 0 |
| `graphql-extras` | **taken** | — |

"pro" is avoided in the name to prevent confusion with graphql-pro. License: **MIT** (same as graphql-ruby).

**Packaging:** one gem with opt-in modules, each loaded by its own `require`:

- `GraphQL::Armory::Authorization` — first stage.
- Later, each Pro-like capability becomes another module (e.g. `GraphQL::Armory::PersistedQueries`), each with its own clean-room research.

### 4.1 Architecture (Useful Objects, hand-written)

The gem has **three layers**. Every request flows through them left to right:

```
  1. INTEGRATION              2. CORE                     3. ADAPTER
  (talks to graphql-ruby)     (decides, unaware of        (talks to the
                               which library you use)      authorization library)

  Types::Invoice     ──────►  Authorize            ──────►  Pundit:
  authorized?(obj, ctx)       "can this user                InvoicePolicy.new(user, obj).read?
                               :read this object?"
                                                   ◄──────  true / false
                     ◄──────  true / false
```

**1. Integration.** The modules you include in `BaseObject`, `BaseField`, `BaseArgument`, resolvers, interfaces, unions, plus the schema plugin (`use`). They only translate graphql-ruby hooks (`authorized?`, `scope_items`, `visible?`) into a simple question for the core. No permission logic lives here.

**2. Core.** The gem's own logic, agnostic of Pundit or CanCan:

| Object | Responsibility |
|---|---|
| `Authorize.(subject, action, ctx)` | Can this user perform this action on this object? → `true`/`false` |
| `Scope.(items, ctx)` | Filters a list down to what the user may see |
| `Rule` | Immutable value holding what you declared, e.g. `authorize :read` |
| `Memo` | Remembers answers for the request (`context.namespace`) to avoid asking twice |
| `Audit.(schema)` | Walks the schema and returns a `Report` of uncovered members |
| `Telemetry` | Records what happened, for logs and for tests (sinks) |

**3. Adapter.** Translates the core's question for a concrete library: with Pundit, `InvoicePolicy#read?`; with CanCan, `can?(:read, obj)`. Switching libraries means switching adapters without touching the other layers. Available: `Pundit`, `CanCanCan`, `Null` (denies everything), or your own.

**Where Useful Objects comes in:**

- **`Authorize.new` with no configuration gets the `Null` adapter, which denies everything.** A misconfigured object never lets anything through: the doctrine and security point the same way.
- **`Authorize.build` wires the real, configured adapter.** Each object has `self.configure(receiver)`, a `module Substitute`, and test data in `Controls::*.example` inside `lib/`.

#### The adapter contract

The core knows nothing about Pundit or CanCan. It only asks four questions, and any object that answers them is a valid adapter. The contract is neutral: it must fit both Pundit (one policy class per model) and CanCanCan (a single `Ability` holding every rule).

| Method | Question it answers |
|---|---|
| `actor(context)` | Who is asking? Pundit: the user. CanCan: the `Ability` built from the user (`context[:current_ability]` or `Ability.new(user)`) |
| `authorized?(actor, subject, rule)` | Can this actor perform the rule's action on this object? → `true`/`false` (or lazy) |
| `scope(actor, items, rule)` | Of this list, what may this actor see? → scoped items, or raise `MissingScopeError` |
| `check(type, rule)` | What problems can be detected statically for this type and rule? → `[problems]` (used by the audit) |

`rule` is the `Rule` value holding everything you declared: the action, plus optional overrides — `policy:` (Pundit), `subject:` (CanCan, e.g. `:all`) or the field `attribute`. Each adapter reads the parts it needs.

How each adapter answers:

| | Pundit | CanCanCan |
|---|---|---|
| `actor` | `user` | `Ability` |
| `authorized?` | `InvoicePolicy.new(user, obj).read?` | `ability.can?(:read, obj)`; for fields, `ability.can?(:read, obj, :internal_notes)` |
| `scope` | `InvoicePolicy::Scope.new(user, relation).resolve` | `relation.accessible_by(ability, :read)` (still a paginable relation); Arrays filtered with `can?` |
| `check` | Policy class exists (via `Pundit::PolicyFinder`, so `policy_class` overrides are honoured), responds to `read?`, has a `Scope` | Very little: rules depend on the user, and `ability.permissions` needs a concrete user. The audit runs `check` with `Controls` example actors |

**CanCanCan block-only rules.** `accessible_by` **raises** for a rule defined only with a block and no SQL/scope argument ([CanCanCan docs, "Define abilities with blocks → Fetching Records"](https://github.com/CanCanCommunity/cancancan/blob/develop/docs/define_abilities_with_blocks.md)). The adapter rescues that and raises the gem's `MissingScopeError` with guidance ("add an SQL/scope argument to the rule, or declare `scope: :in_memory` on the field"). `scope: :in_memory` is an explicit per-field opt-in that filters with `can?` and **gives up efficient pagination**, with a warning. There is no silent fallback.

**Consequence: with CanCanCan the audit covers less.** It can still report missing rules, bypasses and unscoped `loads:` (that is the gem's own declaration data), but not whether the `Ability` actually grants the action. This is documented, not hidden.

**CanCanCan security note.** With `can :read, User, [:username]`, `can? :read, @user` returns **`true`** even though only one attribute is readable ([CanCanCan docs, "Accessible attributes"](https://github.com/CanCanCommunity/cancancan/blob/develop/docs/accessible_attributes.md)). The CanCan adapter therefore:

- Passes the attribute on field authorization: `can?(:read, obj, :internal_notes)`.
- Documents that an object may be visible because a rule exists on just one of its attributes.

The gem ships the Pundit and CanCanCan adapters. You only write your own adapter when using a custom permission system:

```ruby
class MyAdapter
  def actor(context) = ...
  def authorized?(actor, subject, rule) = ...
  def scope(actor, items, rule) = ...
  def check(type, rule) = []
end
```

#### How Pundit plugs in

There are three pieces.

**1. Your Pundit code, unchanged.** Regular Pundit policies, with no dependency on the gem:

```ruby
class InvoicePolicy < ApplicationPolicy
  def read?   = record.account_id == user.account_id
  def manage? = user.admin?

  class Scope < ApplicationPolicy::Scope
    def resolve = scope.where(account_id: user.account_id)
  end
end
```

**2. The Pundit adapter, shipped by the gem.** It implements the contract using Pundit's public API. Roughly:

```ruby
module GraphQL::Armory::Authorization::Adapters
  class Pundit
    def actor(context) = context[:current_user]

    def authorized?(user, subject, rule)
      rule.policy.new(user, subject).public_send(:"#{rule.action}?")   # :read → read?
    end

    def scope(user, items, rule)
      rule.policy::Scope.new(user, items).resolve       # MissingScopeError if Scope is missing
    end

    def check(type, rule)
      # Policy resolved from the MODEL class (rule.model, default: type.name.demodulize) through
      # Pundit::PolicyFinder, not from the GraphQL name, so namespaced models, STI and `policy_class`
      # overrides work. Reports e.g. "InvoicePolicy not found", "InvoicePolicy#read? not defined",
      # "InvoicePolicy::Scope not defined".
    end
  end
end
```

**3. Your schema picks the adapter and your types declare the action:**

```ruby
class AppSchema < GraphQL::Schema
  use GraphQL::Armory::Authorization, adapter: :pundit
end

class Types::Invoice < Types::BaseObject
  authorize :read                                       # → InvoicePolicy#read?
  field :internal_notes, String, authorize: :manage     # → InvoicePolicy#manage?
end
```

#### What happens in a request

For the query `{ invoices { nodes { internalNotes } } }`:

1. **The list.** graphql-ruby calls `scope_items`. The core asks the adapter for `scope(...)`, which runs `InvoicePolicy::Scope#resolve`, so only invoices from the user's account remain.
2. **Each invoice.** graphql-ruby calls `authorized?`. The adapter runs `InvoicePolicy#read?`, and `Memo` remembers the answer for the rest of the request.
3. **The `internalNotes` field.** The adapter runs `InvoicePolicy#manage?`. If it returns `false`, the client gets `null`.

With CanCanCan **only piece 2 changes**: its adapter calls `ability.can?(:read, obj)` and `Model.accessible_by(ability)`. Your types stay the same.

### 4.2 Public API

Design goal: installing the gem should feel like installing Pundit — one line per base class, convention over configuration, and one word for every concept.

```ruby
class AppSchema < GraphQL::Schema
  use GraphQL::Armory::Authorization, adapter: :pundit
  # defaults: user: ->(ctx) { ctx[:current_user] }, on_unauthorized: :null  (:null | :error | :raise)
end

# One module, included in each base class. It detects the receiver (object, field, argument, resolver).
class Types::BaseObject < GraphQL::Schema::Object
  include GraphQL::Armory::Authorization::Base
  default_action :read                     # every type is checked with <Model>Policy#read? unless it says otherwise
end
class Types::BaseField        < GraphQL::Schema::Field;               include GraphQL::Armory::Authorization::Base; end
class Types::BaseArgument     < GraphQL::Schema::Argument;            include GraphQL::Armory::Authorization::Base; end
class Mutations::BaseMutation < GraphQL::Schema::RelayClassicMutation; include GraphQL::Armory::Authorization::Base; end

class Types::Invoice < Types::BaseObject   # covered: default action + InvoicePolicy#read? exists
  field :total, Integer                    # covered by the type's rule
  field :internal_notes, String, authorize: :manage   # parent object's policy, #manage?
end

class Types::Report < Types::BaseObject
  authorize :view, policy: ReportingPolicy # explicit override of action and policy
end

class Types::Query < Types::BaseObject
  authorize :none, reason: "Root type; each field declares its own rule"
  field :invoice, Types::Invoice, authorize: :read do
    argument :id, ID
  end
  field :status, String, authorize: :none, reason: "Public health check"
end

class Mutations::ApproveInvoice < Mutations::BaseMutation
  authorize :approve, on_denied: :errors   # => { invoice: nil, errors: [{ message: "Not allowed", code: "FORBIDDEN" }] }
  argument :invoice_id, ID, loads: Types::Invoice     # loaded through the user's scope
end
```

The generator (`rails g graphql:armory:install`) writes those `include` lines and the `default_action`.

- **Actions are neutral.** With Pundit, `:read` maps to `read?`. With CanCan, `:read` is the ability.
- **`default_action`** is set once on `BaseObject` and inherited. A type without an explicit `authorize` is checked with it. Explicit `authorize :action` overrides; `policy:` (Pundit) and `subject:` (CanCan) are optional overrides.
- **One word for bypass: `:none`.** `authorize :none, reason:` on types and mutations, `authorize: :none, reason:` on fields and arguments. `reason:` is mandatory; the audit lists every `:none` with its reason; it is greppable.
- **Field shorthand:** `authorize: true` re-checks the parent type's action on the parent object; `authorize: :manage` checks a different action; `authorize: :none, reason:` bypasses.
- **Mutations:** `on_denied: :raise` (default) or `on_denied: :errors` (errors as data, using the schema's error shape). `def unauthorized(error)` remains as the escape hatch for custom payloads.
- **Configuration is inherited by subclasses.** There is no `authorize nil`.
- **Pro's DSL (`pundit_role`) is not copied.** An optional compatibility module for teams migrating from Pro could come later.

### 4.3 Deny-by-default, audit and test helper

**The problem:** a blanket rule inherited by every type would mean no type could ever be "forgotten" — but it would also mean a type is "covered" by a policy nobody wrote. Coverage is therefore defined as follows:

- **An object type is covered when** (a) it declares `authorize :action` or `authorize :none, reason:`, **or** (b) a `default_action` is in effect **and** the adapter's `check` finds the policy/ability for it (Pundit: `<Model>Policy` exists and responds to `read?`). A default action with a **missing policy is not coverage** and is reported.
- **Fields are covered by their type's rule.** If the type is **bypassed (`:none`), coverage does not propagate**: each field must declare its own rule. This covers `Query`: a root field returning a scalar can't be left open.
- **Mutations and resolvers always need an explicit rule.** They are actions, not reads; `default_action` does not apply to them.
- **With Pundit, the policy is resolved statically from the model class** (`Types::Invoice` → model `Invoice` by convention, or `authorize :read, model: Billing::Invoice` → `Pundit::PolicyFinder.new(model).policy`), not per record. This lets the audit verify, **without executing anything**, that the class exists and responds to the action, while honouring Pundit's own `policy_class` overrides. `policy:` is the explicit escape hatch. With CanCanCan this static check is not possible (see 4.1, adapter contract).

**What the audit reports:**

- Types and mutations without a rule.
- Missing policies, or policies that don't respond to the declared action.
- Fields on bypassed types that don't declare a rule.
- Lists whose type has no scope.
- `loads:` arguments that don't load through the scope.
- `authorize` rules declared on interfaces or unions, where they have no effect (verified: graphql-ruby never runs abstract `authorized?`; it does run their `scope_items`).
- Every bypass (`:none`), with its reason.
- **Warnings** (do not fail the audit): non-null object fields on root or `loads:` paths (existence leak under `:null`/`:error`, see 4.6); `authorize:` combined with `default_value:` on an argument (the rule is never checked for the default, see 4.2 notes); scalar fields with arguments on covered types (aggregates the type rule says nothing about).

**Usage:**

- `GraphQL::Armory::Authorization::Audit.(AppSchema)` returns a `Report`.
- `rake graphql_armory:audit[AppSchema]` exits 1 if anything is uncovered — usable as a CI check.
- In RSpec: `expect(AppSchema).to be_fully_authorized`.
- `strict:` mode runs the same check at app boot.

### 4.4 Lists and connections

- `scope_items` calls `adapter.scope`: `policy_scope` with Pundit, `accessible_by` with CanCan. Verified that it **runs before pagination**, so pagination and `totalCount` operate on the scoped relation.
- **A missing scope fails the query with `MissingScopeError`.** It never returns the unscoped list.
- If `items` is an Array rather than a relation, it is filtered by authorizing each element. If a relation comes back converted to an Array, a warning is logged because that breaks efficient pagination.
- **`reauthorize_scoped_objects` stays `true` and the gem exposes no switch for it in 0.1.** In `Execution::Next` the engine marks any list of a scoping-capable type as "scoped" even when nothing was filtered (`execution/field_resolve_step.rb:321-324`), so turning the flag off would skip `authorized?` on `nodes(ids:)` and on custom list resolvers. A future opt-out must rely on the gem's own "actually scoped" flag recorded in `context.namespace(:armory)` by `scope_items`, never on the engine's flag.
- **Lists of interfaces or unions:** abstract types do receive `scope_items`. Default behavior: scope through the adapter for each possible type; when all possible types map to the same model (STI), use that model's scope; otherwise fail closed with a clear message. `scope_with: SomePolicy` is the override.

### 4.5 IDOR prevention

- **Every path ends at the concrete type.** graphql-ruby runs the concrete type's `authorized?` whenever it wraps an object: root field, association, each list item, `loads:`, union and interface resolution. Verified in code.
- **`loads:` loads through the scope by default.** `object_from_id` is replaced by a lookup inside the user's scope (`policy_scope(Model).find_by(id:)`). Another user's object is indistinguishable from one that doesn't exist. It can be disabled with `load_through_scope: false`, and that shows up in the audit.
- **Invariant: a `loads:` id that does not exist and one that is denied produce byte-identical responses.** graphql-ruby's defaults break this: a load miss raises a visible `ExecutionError` (`No object found for \`invoiceId: "…"\``, `load_application_object_failed_error.rb`) while a denial yields a silent `nil`. The resolver integration therefore overrides `load_application_object_failed` and `unauthorized_object` **together**, in every error mode. One security spec per mode pins this.
- **The same helper serves root fields in the MVP:** `field :invoice, Types::Invoice, find_by: :id` (or the `Armory.find(Model, id, ctx)` helper) looks up through the scope, so `invoice(id:)` has no existence oracle either.
- **Static detection of global-ID `find` is not reliable** (it would be a heuristic). Instead:
  - The audit flags `loads:` without scope.
  - A telemetry signal fires when an object arrives through an unscoped path.
  - In `strict:` mode, that is a warning.

### 4.6 Errors

| Mode | What the client sees | Use |
|---|---|---|
| `:null` (default) | `null`, same as if the object didn't exist | Production. Doesn't reveal existence |
| `:error` | `null` plus a generic `NOT_FOUND` error — the same message as for a missing object | APIs that need an error signal |
| `:raise` | Exception | Development and test |

- **Both execution engines are normalized.** On a `nil` denial, `Execution::Next` adds an error and legacy doesn't; handling is centralized in `unauthorized_object` / `unauthorized_field` so both behave the same.
- **Internal log:** a `:denied` telemetry signal with type, field, policy, action and user id — never record attributes. When ActiveSupport is available, `ActiveSupport::Notifications` also emits `authorize.graphql_armory`.
- **Mutations:** `on_denied: :raise` by default; `on_denied: :errors` returns `[false, payload]` (errors as data). `def unauthorized(error)` is the custom escape hatch.
- **Non-null caveat:** a denied object in a non-null position yields graphql-ruby's `Cannot return null for non-nullable field X.y` (`invalid_null_error.rb:50`), which differs from the generic `NOT_FOUND`. Non-null object fields on root or `loads:` paths are incompatible with existence hiding; the audit warns about them.

### 4.7 Visibility (optional, `visibility: true`)

`visible?` uses the same rule at class level, without a concrete object — e.g. `InvoicePolicy.new(user, Invoice).read?`. Verified that hidden members disappear from introspection and "did you mean" suggestions.

Two caching modes:

- **Dynamic:** `use GraphQL::Schema::Visibility, dynamic: true`. Computed and memoized once per query. Precise, but paid on every request.
- **Profiles:** you define `visibility_profile_for(ctx)`, mapping the user to a named profile (`:admin`, `:staff`, `:public`). graphql-ruby caches those profiles **across requests** — also when `dynamic: true` is set. Fastest, but visibility depends on the role, not the individual user. The gem documents this recipe; it does not wrap graphql-ruby's profile API.

Rules the implementation must follow:

- **Context-less calls see a public schema and are cached.** `Schema.types`, `to_definition`, `rake graphql:schema:dump` use a `NullContext` whose `[:current_user]` is `nil`, and that `top_level_profile` is memoized (`visibility.rb:187-191`). The gem's `visible?` returns `true` for `Query::NullContext` explicitly (schema dumps show the full schema) and the **audit never uses `Schema.types(ctx)`**: it walks `all_field_definitions` / `all_argument_definitions` / `Schema.visibility.types`, which are unfiltered.
- Without `use Schema::Visibility`, the default `Warden` still consults `visible?` per query, so hiding works on 2.4–2.6 either way; only profile caching needs the new system.

### 4.8 Performance

- **Per-request memoization** in `context.namespace(:armory)`, keyed by `[policy, action, object]`. The policy instance is reused too.
- **Dataloader: policies must return a boolean.** To batch, call `context.dataloader.with(Source).load(key)` inside the policy — `.load` is synchronous via Fiber (`dataloader/source.rb:93-99`). Do **not** return `.request` lazies: `Execution::Next` does not resolve lazies from `authorized?` unless more than two `lazy_resolve` hooks are registered (`schema.rb:1775-1783`) and would treat the lazy object as *authorized*. The gem raises `GraphQL::Armory::AdapterError` if an adapter returns anything other than `true`, `false` or `nil`.
- **`Field#authorized?` must be a real method on the custom field class.** Next only calls it when it detects an override (`field.rb:1162-1166`); no `define_method` on a shared owner, no `method_missing`.
- **Benchmark** with `benchmark-ips` and `memory_profiler` on the dummy app, on **both engines**: a 1000-item list comparing no authorization vs authorization (with memoization). The README will report measured overhead.

### 4.9 Structure, compatibility and testing

```
lib/graphql/armory.rb
lib/graphql/armory/authorization.rb                # the `use` plugin
lib/graphql/armory/authorization/{rule,authorize,scope,memo,audit,telemetry,errors}.rb
lib/graphql/armory/authorization/integration/{object,field,argument,resolver,interface,union}.rb
lib/graphql/armory/authorization/adapters/{null,pundit,can_can_can}.rb
lib/graphql/armory/authorization/controls/...      # Eventide Controls
lib/graphql/armory/authorization/rspec.rb          # be_fully_authorized
lib/graphql/armory/railtie.rb, lib/tasks/*.rake, lib/generators/graphql/armory/install_generator.rb
spec/unit · spec/integration · spec/security · spec/dummy (minimal Rails + sqlite)
gemfiles/ (Appraisal) · Dockerfile · compose.yml · .github/workflows/ci.yml
```

**Proposed compatibility:**

- Ruby **>= 3.1** (decided; Ruby 3.0 reached end of life in 2024). No 3.2-only syntax (`Data`, anonymous block arguments).
- graphql **2.4 – 2.6** (2.4 is where visibility became opt-in; older versions untested).
- Pundit 2.x, CanCanCan 3.x. Rails optional.
- CI matrix over Ruby × graphql × execution engine, all in Docker. **Both engines are first-class:** the whole suite runs twice, `GRAPHQL_ARMORY_ENGINE=interpreter|next` toggling `default_execution_next(true)` on the dummy schema; CI fails if either leg is skipped.

**Testing follows the doctrine inside RSpec:**

- Unit specs use `.new` (which installs the `Null` adapter), Substitutes and telemetry sinks. No `receive` or `instance_double`.
- Integration specs use `.build`.
- A security suite in `spec/security`:
  - User A reading user B's objects by ID (root field, nested association, `loads:`) fails without revealing existence.
  - Lists never include another user's objects.
  - A type without a policy fails closed and appears in the audit.
  - A field hidden with `visible?` appears neither in introspection nor in error suggestions.

**Shared test kit inside `lib/` (doctrine `Controls`):** `GraphQL::Armory::Authorization::Controls::Schema.example` is a tiny dummy schema, and `spec/support` exposes `shared_examples "an armory adapter"` so third-party adapters run the same security suite.

**Local environment:** Ruby is not installed on the host; everything runs in Docker (`ruby:<version>-slim`), with a named volume for bundled gems.

---

## 5. Delivery stages

| Version | Contents |
|---|---|
| **0.1 MVP** | Core, Pundit adapter, `Base` module, `default_action`, objects, fields, lists and connections, scope-based root lookup (`find_by:`), deny-by-default, audit (rake + RSpec matcher), `Controls` schema + shared adapter examples, security suite on **both engines**, Docker + CI matrix |
| 0.2 | CanCanCan adapter (proves the contract is neutral; block-rule handling), scope-based `loads:`, mutations and resolvers with `on_denied:` |
| 0.3 | Visibility (dynamic + profiles recipe), argument authorization |
| 0.4 | `rails g graphql:armory:install` generator, migration guide from manual `authorized?`, `strict:` boot check |
| Later | Other Pro-like modules, each with its own Phase 0 |

**Out of scope:** Pro-compatible DSL, dashboard, ActionPolicy adapter (the interface allows writing one), Dataloader batching of policies beyond `.load`, an opt-out for `reauthorize_scoped_objects`.

---

## 6. How to verify the claims

All "verified" claims point to the read-only clone:

| Claim | Location |
|---|---|
| Scope runs before pagination | `graphql-ruby/lib/graphql/schema/field.rb:1507-1518` |
| `reauthorize_scoped_objects` defaults to `true` | `graphql-ruby/lib/graphql/schema/member/scoped.rb:30-40` |
| Visibility profile caching | `graphql-ruby/lib/graphql/schema/visibility.rb:159-181` |
| `loads:` goes through the type's `authorized?` | `graphql-ruby/lib/graphql/schema/member/has_arguments.rb:469` |
| Hidden members excluded from suggestions | `graphql-ruby/lib/graphql/static_validation/validation_context.rb:54-64` |
| Next marks lists as scoped without filtering | `graphql-ruby/lib/graphql/execution/field_resolve_step.rb:321-324` |
| Next skips `authorized?` when the flag is false | `graphql-ruby/lib/graphql/execution/prepare_object_step.rb:82-86` |
| Next resolves lazies only with >2 `lazy_resolve` hooks | `graphql-ruby/lib/graphql/schema.rb:1775-1783` |
| `loads:` miss message (visible error) | `graphql-ruby/lib/graphql/load_application_object_failed_error.rb` |
| Interfaces/unions receive `scope_items` | `graphql-ruby/lib/graphql/schema/interface.rb:14`, `schema/member.rb:37` |
| Warden consults `visible?` | `graphql-ruby/lib/graphql/schema/warden.rb:588-590` |
| Pundit `Scope` missing raises | Pundit API docs: `Pundit::PolicyFinder#scope!` → `Pundit::NotDefinedError` |
| CanCanCan block-only rules break `accessible_by` | CanCanCan docs, "Define abilities with blocks → Fetching Records" |
| Pro capabilities | `graphql-ruby/guides/authorization/pundit_integration.md`, `can_can_integration.md` |
| Name availability | `https://rubygems.org/api/v1/gems/graphql-armory.json` → "could not be found" |
| Docker | `docker run --rm ruby:3.3-slim ruby -v` |

---

## 7. Decisions

Taken after the review (2026-10-28):

| Decision | Outcome |
|---|---|
| `default_action` counts as coverage when the policy exists | Yes |
| `Execution::Next` support | First-class in 0.1; suite runs on both engines |
| CanCanCan block-only rules | Fail with `MissingScopeError`; explicit `scope: :in_memory` opt-in |
| Bypass spelling | `authorize :none, reason:` everywhere |
| Ruby minimum | `>= 3.1` |
| Pundit policy lookup | From the model class via `Pundit::PolicyFinder` (honours `policy_class`) |
| `reauthorize_scoped_objects` opt-out | Not exposed in 0.1 |

Still open:

1. **Gem name** — `graphql-armory` recommended (free on RubyGems and GitHub as of 2026-10-28; re-check before publishing).
2. **graphql range** — `2.4 – 2.6` proposed (requirement said `2.x`).
3. **Final approval of this revised design** before starting Phase 2.
