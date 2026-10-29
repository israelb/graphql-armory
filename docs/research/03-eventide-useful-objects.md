# Research 03 — Eventide: Doctrine of Useful Objects and utility libraries

> Phase 0, design paradigm. Date: 2026-10-28.
> Sources: https://eventide-project.org/user-guide/useful-objects.html#the-doctrine-of-useful-objects, https://eventide-project.org/user-guide/libraries.html#utility-libraries, READMEs and source of github.com/eventide-project repos (dependency, configure, telemetry, useful-objects, clock), rubygems metadata.
> **Decision (user, 2026-10-28): implement the pattern by hand, no `evt-*` runtime dependencies.**

---

## 1. Principles

- **Useful as soon as it is instantiated.** "An object must be _useful_ immediately upon instantiation of the object." `new` never leaves a nil dependency; each gets an inert default.
- **`initialize` only captures data; wiring happens in `self.build`.** "The class constructor provides a _convenience interface_." Plain `new` keeps null-object dependencies ("Using the initializer results in null object dependencies"); `build` installs the operational ones.
- **`configure(receiver)` — Tell, Don't Ask.** `build` calls `SomeDependency.configure(instance)`; the dependency's class decides "how it should be constructed and to be assigned" on the receiver via `receiver.some_dependency=`.
- **`dependency` macro.** "By default, the `some_dependency` will be assigned a _strict_ null object." "There is no _real_ instance of a dependency versus a _fake_ instance."
  - `dependency :x, SomeClass` gives a *static mimic* answering only SomeClass's interface and recording calls.
  - An inner `module Substitute` on SomeClass is mixed into that mimic; if it defines `self.build`, its result becomes the default.
  - `Dependency::Substitute.build(SomeClass)` builds it directly.
- **Telemetry instead of mocks.** "Relies on telemetry rather than test doubles (mocks, spies) to inspect an object's execution"; "Transparency is of design"; telemetry README: "mocks are a crude way of working around the lack of observability."
- **One actuator, `call`.** "Once an object is instantiated, it is ready to be actuated, ie: to have its `call` method invoked." Convention: `self.call(...)` = `build(...).()`, plus instance `#call`.
- **`Controls` namespace** (convention seen across the libraries, not on the doctrine page): test data ships inside `lib/` so other projects can reuse it, e.g. `lib/clock/controls/time.rb` → `Clock::Controls::Time.example`, nested `Raw.example`. Every control is a module method named `example`.
- Reference implementation: github.com/eventide-project/useful-objects (`lib/useful_objects/something.rb`, `some_dependency.rb`).

## 2. Utility libraries

All MIT, 4-part versions.

| Gem | Purpose | Latest | Runtime deps |
|---|---|---|---|
| evt-dependency | `dependency` macro with null/mimic/substitute defaults | 2.2.0.0 (2023-05-25) | evt-subst_attr → attribute, mimic, reflect, record_invocation |
| evt-subst_attr | engine of `dependency` | 2.3.0.0 (2023-05) | attribute, mimic, reflect |
| evt-configure | `configure :attr` macro generating `self.configure(receiver, attr_name:)` | 2.0.0.2 (2025-07-30) | ostruct |
| evt-telemetry | `Telemetry.build/configure`, `record(signal, data)`, `Telemetry::Sink` with `record :sig`, `recorded_sig?` | 2.4.0.3 (2025-07-30) | evt-clock, evt-dependency, ostruct |
| evt-mimic | copies a class's interface onto a substitute, records invocations | 2.6.0.0 (2023-07) | evt-record_invocation |
| evt-initializer | generates initializers/attributes | 2.0.0.0 (2019-12) | not checked |
| evt-settings | `setting :x` from JSON/hash | 2.1.1.6 (2022-01) | evt-attribute |
| evt-schema | typed attribute structures | 2.5.0.0 (2024-12) | 6 evt gems |
| evt-virtual | `virtual`/`abstract` declarations | 2.1.0.2 (2023-01) | none |
| evt-template_method | template-method declarations | 2.1.0.0 (2024-04) | not checked |
| evt-log | STDIO logger | 2.1.1.2 (2020-05) | not checked |
| evt-casing | case conversion | 2.0.0.1 (2021-02) | not checked |
| evt-attribute | imperative attribute definition | 2.0.0.0 (2019-12) | not checked |
| evt-set_attributes | sets attributes from a hash | 2.2.0.1 (2022-09) | not checked |
| evt-try, evt-clock, evt-reflect | small helpers | various | not checked |
| test_bench | TestBench framework | 3.0.0.0 (2025-07-15) | test_bench-executable, test_bench-fixture |

**Why not depend on them:** infrequent releases from one small team; `dependency` alone pulls ~6 transitive gems; `Dependency.activate` with no class includes itself into `Object` (the README itself advises against it), which a library must never do to a host app; `Configure.activate` similar. Hand-written cost: ~20 lines.

## 3. Sketch with the real macros (reference only — NOT the chosen approach)

```ruby
module GraphQLAuthz
  class PolicyResolver
    include Dependency            # evt-dependency, activated locally
    extend Configure::Macro       # evt-configure
    configure :policy_resolver

    def self.build = new
    def resolve(type, field) = Policies.fetch([type, field]) { Policies::Deny }

    module Substitute
      include Mimic::Recorder::Predicate
      attr_writer :policy
      record def resolve(_type, _field) = (@policy ||= Policies::Allow)
      def resolved? = invoked?(:resolve)
    end
  end

  class Authorize
    include Dependency
    extend Configure::Macro
    configure :authorize

    dependency :policy_resolver, PolicyResolver
    dependency :telemetry, ::Telemetry

    attr_reader :context
    def initialize(context = {}) = @context = context

    def self.build(context = {})
      new(context).tap do |instance|
        PolicyResolver.configure(instance)
        ::Telemetry.configure(instance)
      end
    end

    def self.call(type, field, context = {}) = build(context).(type, field)

    def call(type, field)
      policy = policy_resolver.resolve(type, field)
      allowed = policy.allow?(context)
      telemetry.record(allowed ? :granted : :denied, field)
      allowed
    end
  end
end
```

Mock-free test style that follows:

```ruby
a = Authorize.new(Controls::Context.example)
sink = Telemetry::Sink.new
a.telemetry.register(sink)
a.(:Query, :secret)
a.policy_resolver.resolved?
sink.recorded_granted?
```

## 4. Testing conventions and RSpec

- Eventide uses **TestBench**: `context "..." do; test "..." do; assert(...); end; end` under `test/automated/*.rb`, fixtures, no mocks.
- `Controls` live in `lib/<gem>/controls/`, not in the test directory.
- Conflict with RSpec: TestBench rejects matcher DSLs, `let`, `before`, and mocking (`allow/expect(...).to receive`).
- Not a conflict: Controls, Substitutes, telemetry sinks and the `.new` vs `.build` split are framework-independent.
- **Adopted compromise (user requires RSpec):** RSpec as runner; no `instance_double`/`receive` by convention; assert on `substitute.asked?` / `sink.recorded_denied?`; build data from `Controls::*.example`; `described_class.new` for inert dependencies, `.build` for integration specs; flat literal expectations.
