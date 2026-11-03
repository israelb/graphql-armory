# frozen_string_literal: true

# Kept from the independent verification of PR #46. Pending probes describe the first design, a documented limit or a pre-existing finding.

# Independent verification probes for the analysis guard of the rate limiters. Each `it` is labelled security or preservation.
module GuardProbe
  RL = GraphQL::Armory::RateLimits

  KINDS = {
    points: { cls: RL::Points, ctx: :rate_limit_points, opts: { limit: 100, window: 60 } },
    time: { cls: RL::Time, ctx: :rate_limit_time, opts: { limit: 1000, window: 60 } },
    concurrency: { cls: RL::Concurrency, ctx: :rate_limit_concurrency, opts: { limit: 1 } }
  }.freeze

  # Fails only for the keys and the calls it is told to.
  class KeyFailingStore
    attr_reader :memory, :failures

    def initialize(bad:, when_cost: nil, times: nil)
      @memory = RL::Store::Substitute.new
      @bad = bad
      @when_cost = when_cost
      @times = times
      @failures = 0
    end

    def take(key, cost:, limit:, window:, force: false)
      maybe_fail(key, cost)
      @memory.take(key, cost: cost, limit: limit, window: window, force: force)
    end

    def acquire(key, token:, limit:, ttl:, force: false)
      maybe_fail(key, nil)
      @memory.acquire(key, token: token, limit: limit, ttl: ttl, force: force)
    end

    def release(key, token:)
      @memory.release(key, token: token)
    end

    private

    def maybe_fail(key, cost)
      return unless key == @bad
      return if @when_cost && !(cost && cost > 0)
      return if @times && @failures >= @times

      @failures += 1
      raise IOError, "shard down"
    end
  end

  def self.raiser(hook, error_class: GraphQL::ExecutionError, message: "analyzer says no", only: nil)
    Class.new(GraphQL::Analysis::Analyzer) do
      fire = lambda do |query|
        raise error_class, message if only.nil? || only.call(query)
      end
      case hook
      when :initialize
        define_method(:initialize) { |subject| super(subject); fire.call(subject) }
      when :analyze?, :visit?
        define_method(hook) { fire.call(query) || true }
      when :result
        define_method(:result) { fire.call(query); nil }
      else
        define_method(hook) { |_node, _parent, _visitor| fire.call(query) }
      end
      define_method(:result) { fire.call(query); nil } if hook == :result
      define_method(:result) { nil } unless hook == :result
    end
  end
end

RSpec.describe "analysis guard probes" do
  rl = GuardProbe::RL
  kinds = GuardProbe::KINDS

  let(:store) { rl::Store::Substitute.new }
  let(:resolved) { [] }
  let(:holder) { { fn: ->(_c, _a, _ch) { 1 }, during: nil } }
  let(:root) do
    r = resolved
    h = holder
    Class.new do
      define_method(:cheap) { r << :cheap; h[:during]&.call; "ok" }
      define_method(:report) { r << :report; "big" }
      define_method(:boom) { |x: nil, y: nil| r << :boom; "boomed" }
      define_method(:act) { r << :act; "acted" }
      define_method(:tick) { r << :tick; "t" }
      define_method(:failing) { r << :failing; raise GraphQL::ExecutionError, "resolver says no" }
      define_method(:items) { r << :items; ["a"] }
      define_method(:deep) { r << :deep; self }
      define_method(:nest) { r << :nest; h[:nest].call }
    end.new
  end

  let(:query_type) do
    h = holder
    deep_type = Class.new(GraphQL::Schema::Object) do
      graphql_name "Deep"
      field :cheap, String, null: false
    end
    item_type = Class.new(GraphQL::Schema::Object) do
      graphql_name "Item"
      field :name, String, null: true
    end
    Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :cheap, String, null: false
      field :report, String, null: false, complexity: 40
      field :failing, String, null: true
      field :nest, String, null: true
      field :deep, deep_type, null: false
      field :items, item_type.connection_type, null: false
      field :boom, String, null: false, complexity: ->(c, a, ch) { h[:fn].call(c, a, ch) } do
        argument :x, GraphQL::Types::Int, required: false
        argument :y, String, required: false, prepare: ->(value, _ctx) { value == "bad" ? raise(GraphQL::ExecutionError, "prepare says no") : value }
      end
    end
  end

  let(:mutation_type) do
    h = holder
    Class.new(GraphQL::Schema::Object) do
      graphql_name "Mutation"
      field :act, String, null: false, complexity: ->(c, a, ch) { h[:fn].call(c, a, ch) }
    end
  end

  define_method(:build) do |&setup|
    q = query_type
    m = mutation_type
    Class.new(ArmoryEngine.base_schema) do
      query q
      mutation m
      class_exec(&setup) if setup
    end
  end

  define_method(:limiter_schema) do |kind, soft: false, st: store, before: [], after: [], **opts|
    k = kinds.fetch(kind)
    build do
      before.each { |an| query_analyzer an }
      use k[:cls], store: st, soft: soft, **k[:opts], **opts
      after.each { |an| query_analyzer an }
    end
  end

  define_method(:exhaust) do |kind, st: store, key: "user:1"|
    case kind
    when :points then st.take(key, cost: 100, limit: 100, window: 60, force: true)
    when :time then st.take("time:#{key}", cost: 1000, limit: 1000, window: 60, force: true)
    when :concurrency then st.occupy(key)
    end
    st.calls.clear
  end

  define_method(:run) do |schema, doc = "{ cheap }", key: "user:1", ctx: {}, **rest|
    context = key ? { rate_limit_key: key, **ctx } : ctx
    execute_query(schema, doc, context: context, root_value: root, **rest)
  end

  define_method(:mux) do |schema, list, **kw|
    ArmoryEngine.next? ? schema.multiplex_next(list, **kw) : schema.multiplex(list, **kw)
  end

  define_method(:codes) do |result|
    Array(result.to_h["errors"]).map { |e| e.dig("extensions", "code") }
  end

  define_method(:messages) do |result|
    Array(result.to_h["errors"]).map { |e| e["message"] }
  end

  define_method(:left) do |st = store, key = "user:1"|
    st.take(key, cost: 0, limit: 100, window: 60, force: false).last
  end

  define_method(:takes) do |st = store|
    st.calls.count { |m, _k, _a| m == :take }
  end

  define_method(:forced) do |st = store|
    st.calls.count { |m, _k, a| m == :take && a[:force] }
  end

  define_method(:acquires) do |st = store|
    st.calls.count { |m, _k, _a| m == :acquire }
  end

  define_method(:expect_not_run) do |result|
    expect(resolved).to eq([])
    expect(result.to_h["data"]).to be_nil
  end

  err = GraphQL::ExecutionError
  unauthorized = GraphQL::UnauthorizedError
  doc_all = "query Q { ...F ... on Query { cheap } report @include(if: true) boom(x: 1) } fragment F on Query { cheap }"
  sources = %i[initialize analyze? visit? result on_enter_operation_definition on_leave_operation_definition on_enter_field on_leave_field
               on_enter_fragment_spread on_leave_fragment_spread on_enter_inline_fragment on_leave_inline_fragment on_enter_directive on_enter_argument on_enter_fragment_definition]

  # ------------------------------------------------- A: bypass
  kinds.each_key do |kind|
    sources.each do |source|
      it "security A1 #{kind} exhausted, other analyzer raises from #{source} (registered before)" do
        schema = limiter_schema(kind, before: [GuardProbe.raiser(source)])
        exhaust(kind)
        result = run(schema, doc_all)
        expect_not_run(result)
        expect(codes(result)).to include("RATE_LIMITED")
      end
    end

    %i[result on_enter_field on_leave_operation_definition].each do |source|
      it "security A3 #{kind} exhausted, other analyzer raises from #{source} (registered after)" do
        schema = limiter_schema(kind, after: [GuardProbe.raiser(source)])
        exhaust(kind)
        result = run(schema, doc_all)
        expect_not_run(result)
        expect(codes(result)).to include("RATE_LIMITED")
      end

      it "security A2 #{kind} exhausted, UnauthorizedError from #{source}" do
        schema = limiter_schema(kind, before: [GuardProbe.raiser(source, error_class: unauthorized)])
        exhaust(kind)
        result = run(schema, doc_all)
        expect_not_run(result)
        expect(codes(result)).to include("RATE_LIMITED")
      end
    end
  end

  it "security A5 lambda raises on first call only: runs and is charged once" do
    calls = 0
    holder[:fn] = ->(_c, _a, _ch) { (calls += 1) == 1 ? raise(err, "first") : 1 }
    result = run(limiter_schema(:points), "{ boom }")
    expect(result.to_h["data"]).to eq("boom" => "boomed")
    expect(left).to eq(99)
    expect(calls).to eq(2)
  end

  it "security A5b lambda raises on the second call only, two Points: each charged once" do
    s1 = rl::Store::Substitute.new
    s2 = rl::Store::Substitute.new
    calls = 0
    holder[:fn] = ->(_c, _a, _ch) { (calls += 1) == 2 ? raise(err, "second") : 1 }
    schema = build do
      use rl::Points, store: s1, limit: 100, window: 60, soft: false
      use rl::Points, store: s2, limit: 100, window: 60, soft: false
    end
    result = run(schema, "{ boom }")
    expect(result.to_h["data"]).to eq("boom" => "boomed")
    expect([left(s1), left(s2)]).to eq([99, 99])
  end

  it "security A5c lambda raises only for max_complexity's call, exhausted Points still refuses" do
    calls = 0
    holder[:fn] = ->(_c, _a, _ch) { (calls += 1) == 2 ? raise(err, "second") : 1 }
    schema = limiter_schema(:points).tap { |s| s.max_complexity(1000) }
    exhaust(:points)
    result = run(schema, "{ boom }")
    expect_not_run(result)
    expect(codes(result)).to include("RATE_LIMITED")
  end

  it "security A6 lambda raising for a literal argument refuses, other value charges" do
    holder[:fn] = ->(_c, a, _ch) { a[:x] == 1 ? raise(err, "one") : 7 }
    schema = limiter_schema(:points)
    result = run(schema, "{ boom(x: 1) }")
    expect_not_run(result)
    expect(codes(result)).to eq(["RATE_LIMIT_NOT_CHARGED"])
    expect(left).to eq(100)
    expect(run(schema, "{ boom(x: 2) }").to_h["data"]).to eq("boom" => "boomed")
    expect(left).to eq(93)
  end

  it "security A6b lambda raising for a variable refuses, other value charges" do
    holder[:fn] = ->(_c, a, _ch) { a[:x] == 1 ? raise(err, "one") : 7 }
    schema = limiter_schema(:points)
    doc = "query($v: Int) { boom(x: $v) }"
    result = run(schema, doc, variables: { "v" => 1 })
    expect_not_run(result)
    expect(run(schema, doc, variables: { "v" => 2 }).to_h["data"]).to eq("boom" => "boomed")
    expect(left).to eq(93)
  end

  ["{ cheap boom }", "{ boom cheap }", "{ a: boom b: boom }", "{ ...F } fragment F on Query { boom }", "{ ... on Query { boom } }",
   "{ ... { boom } }", "{ cheap ... on Query { ...F } } fragment F on Query { boom report }", "query Named { z: boom cheap }"].each do |doc|
    it "security A7 raising lambda via #{doc}" do
      holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
      result = run(limiter_schema(:points), doc)
      expect_not_run(result)
      expect(codes(result)).to eq(["RATE_LIMIT_NOT_CHARGED"])
      expect(left).to eq(100)
    end

    it "security A7b raising lambda via #{doc}, three hard limiters, nothing held after" do
      holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
      s = store
      schema = build do
        use rl::Time, store: s, limit: 1000, window: 60, soft: false
        use rl::Points, store: s, limit: 100, window: 60, soft: false
        use rl::Concurrency, store: s, limit: 5, soft: false
      end
      result = run(schema, doc)
      expect_not_run(result)
      expect(s.held("user:1")).to eq(0)
      expect(forced).to eq(1) # Time's one charge, Points took nothing
    end
  end

  [["{ cheap boom @skip(if: true) }", {}], ["{ cheap boom @include(if: false) }", {}], ["query($s: Boolean!) { cheap boom @skip(if: $s) }", { "s" => true }],
   ["{ cheap ...F @skip(if: true) } fragment F on Query { boom }", {}], ["{ cheap ... @skip(if: true) { boom } }", {}]].each do |doc, vars|
    it "preservation A8 lambda does not run when skipped: #{doc}" do
      holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
      result = run(limiter_schema(:points), doc, variables: vars)
      expect(result.to_h["data"]).to eq("cheap" => "ok")
      expect(left).to eq(99)
    end
  end

  it "security A8b @skip(if: $s) false: the lambda runs and refuses" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    result = run(limiter_schema(:points), "query($s: Boolean!) { cheap boom @skip(if: $s) }", variables: { "s" => false })
    expect_not_run(result)
  end

  it "security A8c exhausted, raiser, every field skipped: still refused" do
    schema = limiter_schema(:points, before: [GuardProbe.raiser(:result)])
    exhaust(:points)
    result = run(schema, "{ report @skip(if: false) cheap }")
    expect_not_run(result)
    expect(codes(result)).to include("RATE_LIMITED")
  end

  it "preservation A9 raising lambda in the operation not selected does not matter" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    schema = limiter_schema(:points)
    result = run(schema, "query A { boom } query B { cheap }", operation_name: "B")
    expect(result.to_h["data"]).to eq("cheap" => "ok")
    expect(left).to eq(99)
    expect_not_run_a = run(schema, "query A { boom } query B { cheap }", operation_name: "A")
    expect(codes(expect_not_run_a)).to eq(["RATE_LIMIT_NOT_CHARGED"])
  end

  it "security A10 client-chosen value makes prepare raise in a lambda field, exhausted: the field never resolves" do
    holder[:fn] = ->(_c, _a, _ch) { 40 }
    schema = limiter_schema(:points)
    exhaust(:points)
    result = run(schema, '{ boom(y: "bad") }')
    warn "A10 #{result.to_h} left=#{left}"
    expect(resolved).to eq([])
  end

  it "security A10b prepare raises with budget: nothing resolves, and a charge or refusal happens" do
    holder[:fn] = ->(_c, _a, _ch) { 40 }
    result = run(limiter_schema(:points), '{ boom(y: "bad") cheap }')
    expect(resolved).not_to include(:boom)
    expect(left).to be < 100
  end

  it "security A11 a mutation with a raising lambda does not run" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    result = run(limiter_schema(:points), "mutation { act }")
    expect(resolved).to eq([])
    expect(codes(result)).to eq(["RATE_LIMIT_NOT_CHARGED"])
  end

  it "security A12 unsized connection after another analyzer raised" do
    result = run(limiter_schema(:points, before: [GuardProbe.raiser(:on_enter_field)]), "{ items { nodes { name } } }")
    expect_not_run(result)
    expect(codes(result)).to eq(["PAGE_SIZE_REQUIRED"])
    expect(left).to eq(100)
  end

  it "security A13 inert Time.new.install refuses under a raise" do
    schema = build do
      query_analyzer GuardProbe.raiser(:result)
      rl::Time.new.install(self)
    end
    result = run(schema)
    expect_not_run(result)
    expect(codes(result)).to eq(["RATE_LIMITED"])
  end

  xit "security A14 validate: false with a raising lambda under hard" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    result = run(limiter_schema(:points), "{ boom }", validate: false)
    expect(resolved).to eq([])
    expect(codes(result)).to eq(["RATE_LIMIT_NOT_CHARGED"])
  end

  %i[time concurrency].each do |kind|
    it "security A16 #{kind} exhausted first, Points lambda raises: RATE_LIMITED stands" do
      holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
      k = kinds[kind]
      s = store
      schema = build do
        use k[:cls], store: s, soft: false, **k[:opts]
        use rl::Points, store: rl::Store::Substitute.new, limit: 100, window: 60, soft: false
      end
      exhaust(kind)
      result = run(schema, "{ boom }")
      expect_not_run(result)
      expect(codes(result)).to include("RATE_LIMITED")
    end

    it "security A16b Points lambda raises first, #{kind} exhausted after: RATE_LIMITED" do
      holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
      k = kinds[kind]
      s = store
      schema = build do
        use rl::Points, store: rl::Store::Substitute.new, limit: 100, window: 60, soft: false
        use k[:cls], store: s, soft: false, **k[:opts]
      end
      exhaust(kind)
      result = run(schema, "{ boom }")
      expect_not_run(result)
      expect(codes(result)).to include("RATE_LIMITED")
    end
  end

  it "security A17 two limiters refuse together under a raise: both errors, no data" do
    p_store = rl::Store::Substitute.new
    t_store = rl::Store::Substitute.new
    schema = build do
      query_analyzer GuardProbe.raiser(:on_enter_field)
      use rl::Points, store: p_store, limit: 100, window: 60, soft: false
      use rl::Time, store: t_store, limit: 1000, window: 60, soft: false
    end
    exhaust(:points, st: p_store)
    exhaust(:time, st: t_store)
    result = run(schema)
    expect_not_run(result)
    expect(codes(result)).to eq(%w[RATE_LIMITED RATE_LIMITED])
  end

  it "security A18 lambda raising AnalysisError under hard: refused" do
    holder[:fn] = ->(_c, _a, _ch) { raise GraphQL::AnalysisError, "lambda analysis no" }
    result = run(limiter_schema(:points), "{ boom }")
    expect_not_run(result)
    expect(left).to eq(100)
  end

  xit "preservation H7b doc claim: a limiter that cannot answer refuses with RATE_LIMIT_NOT_CHARGED when the lambda raised an AnalysisError" do
    holder[:fn] = ->(_c, _a, _ch) { raise GraphQL::AnalysisError, "lambda analysis no" }
    expect(codes(run(limiter_schema(:points), "{ boom }"))).to eq(["RATE_LIMIT_NOT_CHARGED"])
  end

  # ------------------------------------------------- B: accounting
  %i[on_enter_field on_leave_operation_definition analyze? result].each do |source|
    %i[before after].each do |place|
      it "security B1 Points charged once, raise from #{source} #{place}" do
        raiser = GuardProbe.raiser(source)
        schema = limiter_schema(:points, **{ place => [raiser] })
        result = run(schema, "{ report }")
        expect(result.to_h["data"]).to eq("report" => "big")
        expect(takes).to eq(1)
        expect(left).to eq(60)
      end

      it "security B2 Concurrency one slot, held during, gone after, raise from #{source} #{place}" do
        seen = []
        s = store
        holder[:during] = -> { seen << s.held("user:1") }
        schema = limiter_schema(:concurrency, limit: 3, **{ place => [GuardProbe.raiser(source)] })
        result = run(schema)
        expect(result.to_h["data"]).to eq("cheap" => "ok")
        expect([seen, acquires, s.held("user:1")]).to eq([[1], 1, 0])
      end

      it "security B3 Time charged once, raise from #{source} #{place}" do
        schema = limiter_schema(:time, **{ place => [GuardProbe.raiser(source)] })
        result = run(schema)
        expect(result.to_h["data"]).to eq("cheap" => "ok")
        expect(forced).to eq(1)
        expect(result.context[:rate_limit_time]).to include(key: "user:1", limited: false)
      end
    end
  end

  kinds.each do |kind, k|
    it "security B4 two #{kind} limiters on separate stores, second exhausted, raise from the visit" do
      s1 = rl::Store::Substitute.new
      s2 = rl::Store::Substitute.new
      schema = build do
        query_analyzer GuardProbe.raiser(:on_enter_field)
        use k[:cls], store: s1, soft: false, **k[:opts]
        use k[:cls], store: s2, soft: false, **k[:opts]
      end
      exhaust(kind, st: s2)
      result = run(schema)
      expect_not_run(result)
      expect(codes(result)).to eq(["RATE_LIMITED"])
      if kind == :concurrency
        expect(s1.held("user:1")).to eq(0)
        expect(s2.held("user:1")).to eq(1)
      end
    end
  end

  it "security B5 limiters on parent and subclass both decide, once each" do
    p_store = rl::Store::Substitute.new
    t_store = rl::Store::Substitute.new
    c_store = rl::Store::Substitute.new
    parent = build { use rl::Points, store: p_store, limit: 100, window: 60, soft: false }
    child = Class.new(parent) do
      use rl::Time, store: t_store, limit: 1000, window: 60, soft: false
      use rl::Concurrency, store: c_store, limit: 5, soft: false
      query_analyzer GuardProbe.raiser(:result)
    end
    result = run(child)
    expect(result.to_h["data"]).to eq("cheap" => "ok")
    expect([takes(p_store), forced(t_store), acquires(c_store), c_store.held("user:1")]).to eq([1, 1, 1, 0])
    exhaust(:points, st: p_store)
    resolved.clear
    result = run(child)
    expect_not_run(result)
    expect(codes(result)).to eq(["RATE_LIMITED"])
  end

  it "security B5b parent's limiter with a child-only raising lambda path and child's limiter exhausted" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    t_store = rl::Store::Substitute.new
    p_store = rl::Store::Substitute.new
    parent = build { use rl::Points, store: p_store, limit: 100, window: 60, soft: false }
    child = Class.new(parent) { use rl::Time, store: t_store, limit: 1000, window: 60, soft: false }
    exhaust(:time, st: t_store)
    result = run(child, "{ boom }")
    expect_not_run(result)
    expect(codes(result)).to include("RATE_LIMITED")
    expect(run(parent, "{ boom }").to_h["errors"].first.dig("extensions", "code")).to eq("RATE_LIMIT_NOT_CHARGED")
  end

  it "security B6 analyze? false on the single analyzer run fails closed" do
    schema = limiter_schema(:points, before: [GuardProbe.raiser(:result)])
    own = schema.send(:own_query_analyzers)
    own[-1] = Class.new(own[-1]) { define_method(:analyze?) { false } }
    result = run(schema)
    expect_not_run(result)
  end

  it "security B7 shared context hash: each query of a multiplex is decided alone and exhausts the bucket" do
    schema = limiter_schema(:points, before: [GuardProbe.raiser(:result)])
    shared = { rate_limit_key: "user:1" }
    results = mux(schema, Array.new(3) { { query: "{ report }", context: shared, root_value: root } })
    expect(results.map { |r| r.to_h.key?("data") && !r.to_h["data"].nil? }).to eq([true, true, false])
    expect(results.last.to_h["errors"].first.dig("extensions", "code")).to eq("RATE_LIMITED")
    expect(resolved.size).to eq(2)
  end

  it "security B7b shared hash: raising query between clean ones; guard state is per query and off afterwards" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    schema = limiter_schema(:points)
    shared = { rate_limit_key: "user:1" }
    results = mux(schema, ["{ cheap }", "{ boom }", "{ cheap }"].map { |q| { query: q, context: shared, root_value: root } })
    expect(results.map { |r| r.to_h["errors"]&.first&.dig("extensions", "code") }).to eq([nil, "RATE_LIMIT_NOT_CHARGED", nil])
    expect(left).to eq(98)
    states = results.map { |r| r.query.context.namespace(:graphql_armory) }
    expect(states.map(&:object_id).uniq.size).to eq(3)
    expect(states.map { |n| n[:limiter_guard_active] }).to all(be_falsey)
  end

  it "security B7c the guard's flag cannot be read through the shared hash by a later query's analyzer" do
    seen = []
    watcher = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:result) { seen << query.context.namespace(:graphql_armory)[:limiter_guard_active]; nil }
    end
    schema = limiter_schema(:points, before: [watcher, GuardProbe.raiser(:on_enter_field, only: ->(q) { q.query_string.include?("report") })])
    shared = { rate_limit_key: "user:1" }
    results = mux(schema, ["{ report }", "{ cheap }"].map { |q| { query: q, context: shared, root_value: root } })
    expect(results.map { |r| r.to_h["data"] }).to eq([{ "report" => "big" }, { "cheap" => "ok" }])
    expect(seen).to all(be_falsey)
    expect(left).to eq(59)
  end

  it "security B8 a non-ExecutionError escaping the re-ask leaves the flag off, slots back, nothing run" do
    calls = 0
    holder[:fn] = ->(_c, _a, _ch) { (calls += 1) == 1 ? raise(err, "first") : raise(ArgumentError, "bug") }
    captured = nil
    capture = Class.new(GraphQL::Analysis::Analyzer) { define_method(:result) { captured = query; nil } }
    s = store
    schema = build do
      query_analyzer capture
      use rl::Concurrency, store: s, limit: 5, soft: false
      use rl::Points, store: rl::Store::Substitute.new, limit: 100, window: 60, soft: false
    end
    expect { run(schema, "{ boom }") }.to raise_error(ArgumentError)
    expect(resolved).to eq([])
    expect(s.held("user:1")).to eq(0)
    expect(captured.context.namespace(:graphql_armory)[:limiter_guard_active]).to be_falsey
    holder[:fn] = ->(_c, _a, _ch) { 1 }
    expect(run(schema, "{ boom }").to_h["data"]).to eq("boom" => "boomed")
  end

  xit "security B9 Points several keys, hook raises at key b's charge once: key a charged once" do
    st = GuardProbe::KeyFailingStore.new(bad: "b", when_cost: true, times: 1)
    schema = limiter_schema(:points, st: st, on_store_error: ->(_e, _q) { raise err, "hook" })
    result = run(schema, "{ cheap }", key: %w[a b])
    expect(result.to_h["data"]).to eq("cheap" => "ok")
    expect([left(st.memory, "a"), left(st.memory, "b")]).to eq([99, 99])
  end

  it "security B9b Points several keys soft, hook always raises at key b: key a charged once per query" do
    st = GuardProbe::KeyFailingStore.new(bad: "b")
    schema = limiter_schema(:points, st: st, soft: true, on_store_error: ->(_e, _q) { raise err, "hook" })
    result = run(schema, "{ cheap }", key: %w[a b])
    expect(result.to_h["data"]).to eq("cheap" => "ok")
    expect(left(st.memory, "a")).to eq(99)
  end

  xit "security B9c Concurrency several keys, hook raises at key b once: one slot on a during the run, none after" do
    st = GuardProbe::KeyFailingStore.new(bad: "b", times: 1)
    seen = []
    holder[:during] = -> { seen << st.memory.held("a") }
    schema = limiter_schema(:concurrency, st: st, limit: 5, on_store_error: ->(_e, _q) { raise err, "hook" })
    result = run(schema, "{ cheap }", key: %w[a b])
    expect(result.to_h["data"]).to eq("cheap" => "ok")
    expect(seen).to eq([1])
    expect(st.memory.held("a")).to eq(0)
  end

  xit "preservation B9d Concurrency several keys limit 1, hook raises at key b once: not refused by its own slot" do
    st = GuardProbe::KeyFailingStore.new(bad: "b", times: 1)
    schema = limiter_schema(:concurrency, st: st, limit: 1, on_store_error: ->(_e, _q) { raise err, "hook" })
    result = run(schema, "{ cheap }", key: %w[a b])
    expect(result.to_h["data"]).to eq("cheap" => "ok")
    expect(st.memory.held("a")).to eq(0)
  end

  xit "security B9e Time several keys, hook raises at key b's read once: each key charged once" do
    st = GuardProbe::KeyFailingStore.new(bad: "time:b", times: 1)
    schema = limiter_schema(:time, st: st, on_store_error: ->(_e, _q) { raise err, "hook" })
    result = run(schema, "{ cheap }", key: %w[a b])
    expect(result.to_h["data"]).to eq("cheap" => "ok")
    forced_keys = st.memory.calls.select { |m, _k, a| m == :take && a[:force] }.map { |_m, k, _a| k }
    expect(forced_keys.sort).to eq(%w[time:a time:b])
  end

  kinds.each do |kind, _k|
    xit "security B10 #{kind} store fails once and hook raises: re-ask answers, one charge, hook once" do
      method = kind == :concurrency ? :acquire : :take
      store.fail_with(IOError.new("down"), on: method, times: 1)
      heard = 0
      schema = limiter_schema(kind, limit: kind == :concurrency ? 1 : kinds[kind][:opts][:limit], on_store_error: ->(_e, _q) { heard += 1; raise err, "hook" })
      result = run(schema)
      expect(result.to_h["data"]).to eq("cheap" => "ok")
      expect(heard).to eq(1)
      expect(store.held("user:1")).to eq(0)
    end

    it "security B11 #{kind} store down and hook raises, hard: refused NOT_CHARGED" do
      store.fail_with(IOError.new("down"), on: kind == :concurrency ? :acquire : :take)
      result = run(limiter_schema(kind, on_store_error: ->(_e, _q) { raise err, "hook" }))
      expect_not_run(result)
      expect(codes(result)).to eq(["RATE_LIMIT_NOT_CHARGED"])
    end

    it "security B11b #{kind} store down and hook raises, soft: runs and records charged false" do
      store.fail_with(IOError.new("down"), on: kind == :concurrency ? :acquire : :take)
      result = run(limiter_schema(kind, soft: true, on_store_error: ->(_e, _q) { raise err, "hook" }))
      expect(result.to_h["data"]).to eq("cheap" => "ok")
      expect(result.context[kinds[kind][:ctx]]).to include(charged: false, soft: true, limited: false)
    end

    it "preservation B11c #{kind} store down, hook does not raise: runs as before, no NOT_CHARGED" do
      store.fail_with(IOError.new("down"), on: kind == :concurrency ? :acquire : :take)
      result = run(limiter_schema(kind, on_store_error: ->(_e, _q) {}))
      expect(result.to_h["data"]).to eq("cheap" => "ok")
      expect(codes(result)).to eq([])
    end
  end

  it "security B12 Concurrency several keys, refused, the release hook raises: still refused" do
    st = rl::Store::Substitute.new
    st.occupy("b")
    st.fail_with(IOError.new("down"), on: :release)
    schema = limiter_schema(:concurrency, st: st, limit: ->(_k, _q) { 1 }, on_store_error: ->(_e, _q) { raise err, "hook" })
    begin
      result = run(schema, "{ cheap }", key: %w[a b])
    rescue GraphQL::ExecutionError => e
      result = nil
      raised = e
    end
    expect(resolved).to eq([])
    expect(codes(result)).to include("RATE_LIMITED").or include("RATE_LIMIT_NOT_CHARGED") if result
    expect(raised).to be_nil
  end

  it "security B13 Time debt kept and charged once after Points' NOT_CHARGED refusal, whatever the order" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    [true, false].each do |time_first|
      t_store = rl::Store::Substitute.new
      schema = build do
        use rl::Time, store: t_store, limit: 1000, window: 60, soft: false if time_first
        use rl::Points, store: rl::Store::Substitute.new, limit: 100, window: 60, soft: false
        use rl::Time, store: t_store, limit: 1000, window: 60, soft: false unless time_first
      end
      result = run(schema, "{ boom }")
      expect(codes(result)).to eq(["RATE_LIMIT_NOT_CHARGED"])
      expect(forced(t_store)).to eq(1)
    end
    expect(resolved).to eq([])
  end

  it "security B14 nested execute with a raising lambda is decided on its own; slots back to zero" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    s = store
    schema = build do
      use rl::Concurrency, store: s, limit: 5, soft: false
      use rl::Points, store: rl::Store::Substitute.new, limit: 100, window: 60, soft: false
    end
    inner = nil
    spec = self
    me = root
    holder[:nest] = lambda do
      inner = spec.execute_query(schema, "{ boom }", context: { rate_limit_key: "user:1" }, root_value: me)
      "nested"
    end
    result = run(schema, "{ nest }")
    expect(result.to_h["data"]).to eq("nest" => "nested")
    expect(inner.to_h["errors"].first.dig("extensions", "code")).to eq("RATE_LIMIT_NOT_CHARGED")
    expect(resolved).not_to include(:boom)
    expect(s.held("user:1")).to eq(0)
  end

  kinds.each_key do |kind|
    it "preservation B15 ad hoc analyze_query with a raising analyzer, outside execution: no charge, no slot (#{kind})" do
      schema = limiter_schema(kind, limit: kind == :concurrency ? 5 : kinds[kind][:opts][:limit])
      query = GraphQL::Query.new(schema, "{ cheap }", context: { rate_limit_key: "user:1" }, root_value: root)
      GraphQL::Analysis.analyze_query(query, [GuardProbe.raiser(:result)])
      expect(store.calls).to eq([])
      expect(store.held("user:1")).to eq(0)
    end
  end

  # ------------------------------------------------- C: other errors and timeouts
  it "security C1 RuntimeError from lambda on re-ask only" do
    calls = 0
    holder[:fn] = ->(_c, _a, _ch) { (calls += 1) == 1 ? raise(err, "first") : raise("bug") }
    expect { run(limiter_schema(:points), "{ boom }") }.to raise_error(RuntimeError, "bug")
    expect(resolved).to eq([])
  end

  it "security C2 lambda answering nil on re-ask only: does not run" do
    calls = 0
    holder[:fn] = ->(_c, _a, _ch) { (calls += 1) == 1 ? raise(err, "first") : nil }
    begin
      result = run(limiter_schema(:points), "{ boom }")
      expect(result.to_h["data"]).to be_nil
    rescue StandardError => e
      expect(e).not_to be_a(RSpec::Expectations::ExpectationNotMetError)
    end
    expect(resolved).to eq([])
  end

  kinds.each_key do |kind|
    it "security C3 store answer garbage on re-ask (#{kind}): raises, not run, no slot left" do
      store.answer(kind == :concurrency ? :acquire : :take, "garbage")
      schema = limiter_schema(kind, before: [GuardProbe.raiser(:result)])
      expect { run(schema) }.to raise_error(rl::ConfigurationError)
      expect(resolved).to eq([])
    end
  end

  slow = lambda do |seconds|
    Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:on_enter_field) { |_n, _p, _v| sleep(seconds) }
      define_method(:result) { nil }
    end
  end

  timeout_message = "Timeout on validation of query"

  kinds.each_key do |kind|
    %i[hard soft].each do |mode|
      it "security C4/C5 visit timeout, #{mode} #{kind}: timeout error, not run, charged at most once" do
        schema = limiter_schema(kind, soft: mode == :soft, before: [slow.call(0.12)])
        schema.validate_timeout(0.05)
        result = run(schema, "{ cheap report deep { cheap } }")
        expect(messages(result)).to eq([timeout_message])
        expect_not_run(result)
        expect(store.calls.count { |m, _k, a| m == :take && (a[:cost]).positive? }).to be <= 1
        expect(store.held("user:1")).to eq(0)
      end
    end

    it "security C6 visit timeout, exempt client, #{kind}: still the timeout" do
      schema = limiter_schema(kind, limit: ->(_k, _q) { nil }, before: [slow.call(0.12)])
      schema.validate_timeout(0.05)
      result = run(schema, "{ cheap report deep { cheap } }")
      expect(messages(result)).to eq([timeout_message])
      expect_not_run(result)
    end
  end

  %i[hard soft].each do |mode|
    it "security C7 TimeoutError from a lambda, #{mode}: timeout, not run" do
      holder[:fn] = ->(_c, _a, _ch) { raise GraphQL::Analysis::TimeoutError }
      result = run(limiter_schema(:points, soft: mode == :soft), "{ boom }")
      expect(messages(result)).to eq([timeout_message])
      expect_not_run(result)
    end

    it "security C8 the re-ask's visit also times out, #{mode}: timeout, not run, nothing charged" do
      schema = limiter_schema(:points, soft: mode == :soft)
      own = schema.send(:own_query_analyzers)
      own[-1] = Class.new(own[-1]) do
        define_method(:on_enter_field) { |*a| sleep(0.12); super(*a) }
      end
      schema.validate_timeout(0.05)
      result = run(schema, "{ cheap report deep { cheap } }")
      expect(messages(result)).to eq([timeout_message])
      expect_not_run(result)
      expect(store.calls).to eq([])
    end
  end

  xit "preservation C9 a timed-out query's analysis takes no more than twice the time of a single visit, with three limiters" do
    s = store
    schema = build do
      use rl::Time, store: s, limit: 1000, window: 60, soft: false
      use rl::Points, store: s, limit: 100, window: 60, soft: false
      use rl::Concurrency, store: s, limit: 5, soft: false
    end
    own = schema.send(:own_query_analyzers)
    own.map! { |an| Class.new(an) { define_method(:on_enter_field) { |*a| sleep(0.06); super(*a) if defined?(super) } } }
    schema.validate_timeout(0.1)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = run(schema, "{ cheap report a: cheap b: cheap c: cheap d: cheap e: cheap f: cheap }")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    warn "C9 elapsed=#{elapsed.round(3)} messages=#{messages(result)}"
    expect(messages(result)).to eq([timeout_message])
    expect(elapsed).to be < 0.36 # one visit: 2 fields x 3 limiters x 0.06
  end

  # ------------------------------------------------- D: exemptions
  xit "preservation D1 limit: and key: are asked once on the hook-raises path (docs: limit: is asked once per key)" do
    keys = 0
    limits_asked = 0
    store.fail_with(IOError.new("down"), on: :take)
    schema = limiter_schema(:points, key: ->(_q) { keys += 1; "user:1" }, limit: ->(_k, _q) { limits_asked += 1; 100 }, on_store_error: ->(_e, _q) { raise err, "hook" })
    run(schema)
    warn "D1 keys=#{keys} limits=#{limits_asked}"
    expect([keys, limits_asked]).to eq([1, 1])
  end

  it "security D2 limit: raises on the first two asks, answers nil at exempt?: must not run uncharged" do
    calls = 0
    schema = limiter_schema(:points, limit: ->(_k, _q) { (calls += 1) <= 2 ? raise(err, "lookup failed") : nil })
    result = run(schema)
    warn "D2 calls=#{calls} response=#{result.to_h}"
    expect_not_run(result)
  end

  it "security D3 a list where only some keys have a limit, raising lambda: refused" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    schema = limiter_schema(:points, limit: ->(k, _q) { k == "b" ? 100 : nil })
    result = run(schema, "{ boom }", key: %w[a b])
    expect_not_run(result)
    expect(codes(result)).to eq(["RATE_LIMIT_NOT_CHARGED"])
  end

  it "security D3b a list where only some keys have a limit, exhausted one, other analyzer raises: refused" do
    schema = limiter_schema(:points, limit: ->(k, _q) { k == "b" ? 100 : nil }, before: [GuardProbe.raiser(:on_enter_field)])
    exhaust(:points, key: "b")
    result = run(schema, "{ cheap }", key: %w[a b])
    expect_not_run(result)
    expect(codes(result)).to eq(["RATE_LIMITED"])
  end

  kinds.each_key do |kind|
    [["no key", nil], ["empty", ""], ["six keys", %w[a b c d e f]], ["duplicates", %w[a a]], ["an integer", 7]].each do |label, bad|
      it "security D4 #{kind}, other analyzer raises, #{label}: ConfigurationError, not run" do
        schema = limiter_schema(kind, before: [GuardProbe.raiser(:result)])
        expect { run(schema, "{ cheap }", key: nil, ctx: bad.nil? ? {} : { rate_limit_key: bad }) }.to raise_error(rl::ConfigurationError)
        expect(resolved).to eq([])
      end
    end
  end

  [["no key", nil], ["six keys", %w[a b c d e f]]].each do |label, bad|
    it "security D4b lambda raises and #{label}: ConfigurationError, not run" do
      holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
      expect { run(limiter_schema(:points), "{ boom }", key: nil, ctx: bad.nil? ? {} : { rate_limit_key: bad }) }.to raise_error(rl::ConfigurationError)
      expect(resolved).to eq([])
    end
  end

  it "security D5 limit: answers garbage on the guard path: ConfigurationError, not run" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    schema = limiter_schema(:points, limit: ->(_k, _q) { "lots" })
    expect { run(schema, "{ boom }") }.to raise_error(rl::ConfigurationError)
    expect(resolved).to eq([])
  end

  kinds.each do |kind, k|
    [err, unauthorized].each do |error|
      it "security D6 #{kind} key: raises #{error}, hard: refused, soft: runs charged false" do
        bad_key = ->(_q) { raise error, "who are you" }
        result = run(limiter_schema(kind, key: bad_key), "{ cheap }", key: nil)
        expect_not_run(result)
        expect(codes(result)).to eq(["RATE_LIMIT_NOT_CHARGED"])
        resolved.clear
        result = run(limiter_schema(kind, key: bad_key, soft: true), "{ cheap }", key: nil)
        expect(result.to_h["data"]).to eq("cheap" => "ok")
        expect(result.context[k[:ctx]]).to include(charged: false)
      end
    end
  end

  it "security D9 Points exempt, Time hard cannot answer: refused; Time exempt, Points hard cannot answer: refused" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    t_store = rl::Store::Substitute.new
    t_store.fail_with(IOError.new("down"), on: :take)
    hook = ->(_e, _q) { raise err, "hook" }
    schema = build do
      use rl::Points, store: rl::Store::Substitute.new, limit: ->(_k, _q) { nil }, window: 60, soft: false
      use rl::Time, store: t_store, limit: 1000, window: 60, soft: false, on_store_error: hook
    end
    result = run(schema, "{ boom }")
    expect_not_run(result)
    expect(codes(result)).to eq(["RATE_LIMIT_NOT_CHARGED"])

    p_store = rl::Store::Substitute.new
    schema = build do
      use rl::Time, store: rl::Store::Substitute.new, limit: ->(_k, _q) { nil }, window: 60, soft: false
      use rl::Points, store: p_store, limit: 100, window: 60, soft: false
    end
    result = run(schema, "{ boom }")
    expect_not_run(result)
    expect(codes(result)).to eq(["RATE_LIMIT_NOT_CHARGED"])
  end

  # ------------------------------------------------- E: soft, hard and records
  it "preservation E1 soft Points lambda raises + hard Time: runs, records and headers correct" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    p_store = rl::Store::Substitute.new
    t_store = rl::Store::Substitute.new
    schema = build do
      use rl::Points, store: p_store, limit: 100, window: 60, soft: true, extensions: true
      use rl::Time, store: t_store, limit: 1000, window: 60, soft: false, extensions: true
    end
    result = run(schema, "{ boom }")
    expect(result.to_h["data"]).to eq("boom" => "boomed")
    expect(result.context[:rate_limit_points]).to include(charged: false, soft: true, limited: false)
    expect(result.context[:rate_limit_time]).to include(key: "user:1", limited: false)
    expect(rl::Points.headers(result)).to eq({})
    expect(rl::Time.headers(result)).to include("RateLimit-Time-Limit" => "1000")
    expect(result.to_h["extensions"]).to include("rateLimitTime")
    expect(result.to_h["extensions"]).not_to include("rateLimit")
    expect(forced(t_store)).to eq(1)
    expect(p_store.calls).to eq([])
  end

  it "security E2 hard Points lambda raises + soft Time: refused, Time recorded" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    t_store = rl::Store::Substitute.new
    schema = build do
      use rl::Points, store: rl::Store::Substitute.new, limit: 100, window: 60, soft: false
      use rl::Time, store: t_store, limit: 1000, window: 60, soft: true
    end
    result = run(schema, "{ boom }")
    expect_not_run(result)
    expect(codes(result)).to eq(["RATE_LIMIT_NOT_CHARGED"])
    expect(result.context[:rate_limit_time]).to include(soft: true, key: "user:1")
  end

  it "security E3 soft and hard Points together: hard refuses when neither can answer" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    schema = build do
      use rl::Points, store: rl::Store::Substitute.new, limit: 100, window: 60, soft: true
      use rl::Points, store: rl::Store::Substitute.new, limit: 100, window: 60, soft: false
    end
    result = run(schema, "{ boom }")
    expect_not_run(result)
    expect(codes(result)).to eq(["RATE_LIMIT_NOT_CHARGED"])
  end

  it "preservation E4 hard refusal + soft Points that cannot answer: soft still records charged false" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    t_store = rl::Store::Substitute.new
    schema = build do
      use rl::Time, store: t_store, limit: 1000, window: 60, soft: false
      use rl::Points, store: rl::Store::Substitute.new, limit: 100, window: 60, soft: true
    end
    exhaust(:time, st: t_store)
    result = run(schema, "{ boom }")
    expect_not_run(result)
    expect(codes(result)).to eq(["RATE_LIMITED"])
    expect(result.context[:rate_limit_points]).to include(charged: false)
  end

  it "preservation E5 shared hash: q2's soft raise does not show q1's numbers" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    schema = limiter_schema(:points, soft: true, extensions: true)
    shared = { rate_limit_key: "user:1" }
    r1, r2 = mux(schema, ["{ cheap }", "{ boom }"].map { |q| { query: q, context: shared, root_value: root } })
    expect(rl::Points.headers(r1)).to include("RateLimit-Remaining" => "99")
    expect(rl::Points.headers(r2)).to eq({})
    expect(r2.to_h["extensions"].to_h).not_to include("rateLimit")
    expect(shared[:rate_limit_points]).to include(charged: false)
  end

  xit "preservation E6 shared hash: q2 exempt with a raising lambda does not keep q1's numbers" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    schema = limiter_schema(:points, limit: ->(_k, q) { q.query_string.include?("boom") ? nil : 100 })
    shared = { rate_limit_key: "user:1" }
    r1, r2 = mux(schema, ["{ cheap }", "{ boom }"].map { |q| { query: q, context: shared, root_value: root } })
    expect(r1.to_h["data"]).to eq("cheap" => "ok")
    expect(r2.to_h["data"]).to eq("boom" => "boomed")
    expect(shared[:rate_limit_points].to_h[:remaining]).to be_nil
  end

  it "preservation E6b shared hash: q2 refused by a limiter, soft Points cannot answer, hash does not keep q1's numbers" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    t_store = rl::Store::Substitute.new
    t = rl::Time
    schema = build do
      use rl::Points, store: rl::Store::Substitute.new, limit: 100, window: 60, soft: true
      use t, store: t_store, limit: 1000, window: 60, soft: false, key: ->(q) { q.query_string.include?("boom") ? "gone" : "here" }
    end
    exhaust(:time, st: t_store, key: "gone")
    shared = { rate_limit_key: "user:1" }
    mux(schema, ["{ cheap }", "{ boom }"].map { |q| { query: q, context: shared, root_value: root } })
    expect(shared[:rate_limit_points].to_h[:remaining]).to be_nil
  end

  it "preservation E7 one rate_limit_store_failed per query when the store is down and the hook raises" do
    signals = []
    sink = ->(signal, _data) { signals << signal }
    store.fail_with(IOError.new("down"), on: :take)
    schema = limiter_schema(:points, soft: true, sinks: [sink], on_store_error: ->(_e, _q) { raise err, "hook" })
    run(schema)
    warn "E7 signals=#{signals}"
    expect(signals).to eq([:rate_limit_store_failed])
  end

  it "preservation E8 extensions on a charged query after a re-ask: one charge, right numbers" do
    schema = limiter_schema(:points, extensions: true, before: [GuardProbe.raiser(:on_enter_field)])
    result = run(schema, "{ report }")
    expect(result.to_h["extensions"]["rateLimit"]).to include("cost" => 40, "remaining" => 60)
    expect(rl::Points.headers(result)).to include("RateLimit-Remaining" => "60")
  end

  it "preservation E9 all soft, lambda raises: runs; Time and Concurrency record numbers; Points charged false" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    s = store
    schema = build do
      use rl::Points, store: s, limit: 100, window: 60, soft: true
      use rl::Time, store: s, limit: 1000, window: 60, soft: true
      use rl::Concurrency, store: s, limit: 1, soft: true
    end
    result = run(schema, "{ boom }")
    expect(result.to_h["data"]).to eq("boom" => "boomed")
    expect(result.context[:rate_limit_points]).to include(charged: false, limited: false)
    expect(result.context[:rate_limit_time]).to include(limit: 1000)
    expect(result.context[:rate_limit_concurrency]).to include(limit: 1)
    expect(s.held("user:1")).to eq(0)
  end

  # ------------------------------------------------- F: interplay
  context "with PersistedQueries strict" do
    let(:pq) { GraphQL::Armory::PersistedQueries }
    let(:manifest) { pq::Manifest.new({ "inv" => pq::Controls::Operations.invoices }, digest: false) }
    let(:pq_resolved) { [] }

    define_method(:pq_schema) do |exhausted: false|
      q = pq::Controls::Query.example
      m = manifest
      s = store
      exhaust(:points) if exhausted
      Class.new(ArmoryEngine.base_schema) do
        query q
        use GraphQL::Armory::PersistedQueries, store: m, strict: true
        query_analyzer GuardProbe.raiser(:result)
        use rl::Points, store: s, limit: 100, window: 60, soft: false
      end
    end

    define_method(:pq_run) do |schema, doc, **ctx|
      execute_query(schema, doc, context: { rate_limit_key: "user:1", **ctx }, root_value: pq::Controls::Root.example(pq_resolved))
    end

    it "security F1 raw query refused, not run, not charged" do
      result = pq_run(pq_schema, "{ secret }")
      expect(pq_resolved).to eq([])
      expect(codes(result)).to eq(["RAW_QUERY_REFUSED"])
      expect(store.calls).to eq([])
    end

    it "security F1b known id with a raising analyzer: runs and is charged; exhausted: refused" do
      schema = pq_schema
      result = pq_run(schema, nil, operation_id: "inv")
      expect(result.to_h["data"]).to eq("invoices" => ["A-1"])
      expect(left).to eq(99)
      exhaust(:points)
      pq_resolved.clear
      result = pq_run(schema, nil, operation_id: "inv")
      expect(pq_resolved).to eq([])
      expect(codes(result)).to eq(["RATE_LIMITED"])
    end

    it "security F1c unknown id refused, not charged" do
      result = pq_run(pq_schema, nil, operation_id: "nope")
      expect(pq_resolved).to eq([])
      expect(codes(result)).to eq(["UNKNOWN_OPERATION"])
      expect(store.calls).to eq([])
    end
  end

  it "preservation F2 max_depth refusal still charged" do
    schema = limiter_schema(:points).tap { |s| s.max_depth(1) }
    result = run(schema, "{ deep { cheap } }")
    expect_not_run(result)
    expect(left).to eq(98)
  end

  it "preservation F3 max_complexity refusal still charged" do
    schema = limiter_schema(:points).tap { |s| s.max_complexity(1) }
    result = run(schema, "{ report }")
    expect_not_run(result)
    expect(left).to eq(60)
  end

  it "security F4 max_depth refusal + other analyzer raising: max_depth stands" do
    schema = limiter_schema(:points, before: [GuardProbe.raiser(:result)]).tap { |s| s.max_depth(1) }
    result = run(schema, "{ deep { cheap } }")
    warn "F4 #{result.to_h}"
    expect_not_run(result)
  end

  it "security F4b max_depth refusal + soft Points with a raising lambda the client picks: max_depth stands" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    schema = limiter_schema(:points, soft: true).tap { |s| s.max_depth(1) }
    result = run(schema, "{ boom deep { cheap } }")
    warn "F4b #{result.to_h}"
    expect_not_run(result)
  end

  it "preservation F5 invalid query: no store call" do
    result = run(limiter_schema(:points, before: [GuardProbe.raiser(:result)]), "{ nope }")
    expect(codes(result).size).to eq(1)
    expect(store.calls).to eq([])
  end

  it "preservation F5b invalid variables: no run, no store call" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    result = run(limiter_schema(:points), "query($x: Int!) { boom(x: $x) }")
    expect_not_run(result)
    expect(store.calls).to eq([])
  end

  it "preservation F6 a resolver's ExecutionError unchanged" do
    result = run(limiter_schema(:points), "{ failing cheap }")
    expect(messages(result)).to eq(["resolver says no"])
    expect(result.to_h["data"]).to eq("failing" => nil, "cheap" => "ok")
  end

  it "preservation F6b on_enter AnalysisError rescued by the visitor unchanged, limiter untouched" do
    schema = limiter_schema(:points, before: [GuardProbe.raiser(:on_enter_field, error_class: GraphQL::AnalysisError, message: "visit no")])
    result = run(schema)
    expect_not_run(result)
    expect(messages(result)).to eq(["visit no"])
    expect(store.calls).to eq([])
  end

  it "preservation F6c an analyzer returning an AnalysisError unchanged" do
    returner = Class.new(GraphQL::Analysis::Analyzer) { define_method(:result) { GraphQL::AnalysisError.new("returned no") } }
    result = run(limiter_schema(:points, before: [returner]))
    expect_not_run(result)
    expect(messages(result)).to eq(["returned no"])
    expect(left).to eq(99)
  end

  it "preservation F6d AnalysisError raised from result, client fine: discarded and run, as graphql-ruby does" do
    schema = limiter_schema(:points, before: [GuardProbe.raiser(:result, error_class: GraphQL::AnalysisError, message: "raised no")])
    result = run(schema)
    expect(result.to_h["data"]).to eq("cheap" => "ok")
    expect(messages(result)).to eq([])
    expect(left).to eq(99)
  end

  kinds.each_key do |kind|
    it "preservation F7 other analyzer raises, client fine, #{kind}: same data, no errors" do
      result = run(limiter_schema(kind, before: [GuardProbe.raiser(:on_enter_field)]))
      expect(result.to_h).to eq("data" => { "cheap" => "ok" })
    end
  end

  it "preservation F8 a partial runs and costs nothing more" do
    skip "no run_partials" unless GraphQL::Query.method_defined?(:run_partials)
    s = store
    schema = build do
      use rl::Points, store: s, limit: 100, window: 60, soft: false
      use rl::Concurrency, store: s, limit: 5, soft: false
      query_analyzer GuardProbe.raiser(:result)
    end
    query = GraphQL::Query.new(schema, "{ deep { cheap } }", context: { rate_limit_key: "user:1" }, root_value: root)
    parts = query.run_partials([{ path: ["deep"], object: root }])
    expect(parts.first.to_h).to eq("data" => { "cheap" => "ok" })
    expect(store.calls).to eq([])
  end

  context "with subscriptions" do
    let(:written) { [] }

    define_method(:sub_schema) do |soft: false|
      h = holder
      w = written
      sub_type = Class.new(GraphQL::Schema::Object) do
        graphql_name "Subscription"
        field :tick, String, null: true, complexity: ->(c, a, ch) { h[:fn].call(c, a, ch) }
      end
      subs = Class.new(GraphQL::Subscriptions) do
        define_method(:write_subscription) { |_query, events| w << events; nil }
        define_method(:execute_all) { |_e, _o| nil }
        define_method(:read_subscription) { |_id| nil }
        define_method(:delete_subscription) { |_id| nil }
      end
      s = store
      build do
        subscription sub_type
        use subs
        use rl::Points, store: s, limit: 100, window: 60, soft: soft
      end
    end

    it "security F9 subscribing with a raising lambda, hard: refused, nothing written" do
      holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
      result = run(sub_schema, "subscription { tick }")
      expect(written).to eq([])
      expect(codes(result)).to eq(["RATE_LIMIT_NOT_CHARGED"])
    end

    it "preservation F9b subscribing, soft raising lambda: subscribes, charged false" do
      holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
      result = run(sub_schema(soft: true), "subscription { tick }")
      expect(written.size).to eq(1)
      expect(result.context[:rate_limit_points]).to include(charged: false)
    end

    it "preservation F9c subscribing, ok lambda: charged, written" do
      run(sub_schema, "subscription { tick }")
      expect(written.size).to eq(1)
      expect(left).to eq(99)
    end

    it "security F10 a subscription update with a raising lambda, hard: refused" do
      holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
      result = run(sub_schema, "subscription { tick }", subscription_topic: ":tick:")
      expect(resolved).to eq([])
      expect(codes(result)).to eq(["RATE_LIMIT_NOT_CHARGED"])
    end
  end

  it "preservation F11 a schema with no limiter is unaffected" do
    result = run(build { query_analyzer GuardProbe.raiser(:result) })
    expect(result.to_h).to eq("data" => { "cheap" => "ok" })
  end

  # ------------------------------------------------- G: multiplex analyzers
  it "security G1 multiplex analyzer raises during the visit: exhausted limiter refuses; multiplex analyzer not re-run" do
    enters = 0
    results = 0
    counter = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:on_enter_field) { |_n, _p, _v| enters += 1 }
      define_method(:result) { results += 1; nil }
    end
    s = store
    schema = build do
      multiplex_analyzer counter
      multiplex_analyzer GuardProbe.raiser(:on_leave_operation_definition)
      use rl::Points, store: s, limit: 100, window: 60, soft: false
    end
    exhaust(:points)
    result = mux(schema, [{ query: "{ cheap report }", context: { rate_limit_key: "user:1" }, root_value: root }]).first
    expect_not_run(result)
    expect(result.to_h["errors"].first.dig("extensions", "code")).to eq("RATE_LIMITED")
    expect([enters, results]).to eq([2, 1])
  end

  it "preservation G1b multiplex analyzer raises during the visit, client fine: runs and is charged once" do
    s = store
    schema = build do
      multiplex_analyzer GuardProbe.raiser(:on_enter_field)
      use rl::Points, store: s, limit: 100, window: 60, soft: false
    end
    result = mux(schema, [{ query: "{ report }", context: { rate_limit_key: "user:1" }, root_value: root }]).first
    expect(result.to_h["data"]).to eq("report" => "big")
    expect(left).to eq(60)
  end

  it "security G2 multiplex analyzer raising from result: nothing runs, slots released" do
    s = store
    schema = build do
      multiplex_analyzer GuardProbe.raiser(:result)
      use rl::Concurrency, store: s, limit: 5, soft: false
    end
    outcome = begin
      mux(schema, [{ query: "{ cheap }", context: { rate_limit_key: "user:1" }, root_value: root }]).first.to_h
    rescue GraphQL::ExecutionError => e
      e.class
    end
    warn "G2 #{outcome}"
    expect(resolved).to eq([])
    expect(s.held("user:1")).to eq(0)
  end

  it "security G3 multiplex-level max_complexity and a raising lambda: nothing runs, nothing held" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    s = store
    schema = build do
      use rl::Concurrency, store: s, limit: 5, soft: false
      use rl::Points, store: rl::Store::Substitute.new, limit: 100, window: 60, soft: false
    end
    outcome = begin
      mux(schema, [{ query: "{ boom }", context: { rate_limit_key: "user:1" }, root_value: root }], max_complexity: 1000).first.to_h
    rescue GraphQL::ExecutionError => e
      e.class
    end
    warn "G3 #{outcome}"
    expect(resolved).to eq([])
    expect(s.held("user:1")).to eq(0)
  end

  it "security G3b multiplex-level max_complexity, soft Points, raising lambda: no slot left; records what ran" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    s = store
    schema = build do
      use rl::Concurrency, store: s, limit: 5, soft: true
      use rl::Points, store: rl::Store::Substitute.new, limit: 100, window: 60, soft: true
    end
    outcome = begin
      mux(schema, [{ query: "{ boom }", context: { rate_limit_key: "user:1" }, root_value: root }], max_complexity: 1000).first.to_h
    rescue GraphQL::ExecutionError => e
      e.class
    end
    warn "G3b #{outcome}"
    expect(s.held("user:1")).to eq(0)
  end

  # ------------------------------------------------- H: trace wiring
  it "preservation H1 the real trace: guard once in the ancestors and the owner of analyze_query" do
    s = store
    schema = build do
      use rl::Points, store: s, limit: 100, window: 60, soft: false
      use rl::Time, store: s, limit: 1000, window: 60, soft: false
      use rl::Concurrency, store: s, limit: 5, soft: false
    end
    trace = schema.new_trace
    guard = rl.const_get(:AnalysisGuard)
    warn "H1 #{trace.class.ancestors.first(8)}"
    expect(trace.method(:analyze_query).owner).to eq(guard)
    expect(trace.class.ancestors.count(guard)).to eq(1)
    expect(trace.method(:analyze_query).super_method.owner).to eq(GraphQL::Tracing::Trace)
  end

  [true, false].each do |app_first|
    it "security H2 an app trace overriding analyze_query, #{app_first ? "before" : "after"} the limiter: still refused" do
      seen = []
      mod = Module.new do
        define_method(:analyze_query) { |query:, &block| seen << :in; super(query: query, &block) }
      end
      s = store
      schema = build do
        trace_with(mod) if app_first
        query_analyzer GuardProbe.raiser(:result)
        use rl::Points, store: s, limit: 100, window: 60, soft: false
        trace_with(mod) unless app_first
      end
      exhaust(:points)
      result = run(schema)
      expect_not_run(result)
      expect(codes(result)).to eq(["RATE_LIMITED"])
      expect(seen).not_to be_empty
    end
  end

  it "security H3 trace_with(mod, mode: :x) and context trace_mode: protected" do
    mod = Module.new
    schema = limiter_schema(:points, before: [GuardProbe.raiser(:result)]).tap { |s| s.trace_with(mod, mode: :x) }
    exhaust(:points)
    result = run(schema, "{ cheap }", ctx: { trace_mode: :x })
    expect_not_run(result)
  end

  xit "security H4 trace_mode(:x, own class) and Points: protected or refuses to run, like Time and Concurrency" do
    schema = limiter_schema(:points, before: [GuardProbe.raiser(:result)]).tap { |s| s.trace_mode(:x, Class.new(GraphQL::Tracing::Trace)) }
    exhaust(:points)
    outcome = begin
      run(schema, "{ cheap }", ctx: { trace_mode: :x })
      "ran-or-refused"
    rescue rl::ConfigurationError
      "configuration-error"
    end
    warn "H4 #{outcome} resolved=#{resolved}"
    expect(resolved).to eq([])
  end

  xit "security H5 child schema replaces the default trace class over a parent's Points: protected or refuses to run" do
    s = store
    parent = build do
      query_analyzer GuardProbe.raiser(:result)
      use rl::Points, store: s, limit: 100, window: 60, soft: false
    end
    child = Class.new(parent) { trace_mode(:default, Class.new(GraphQL::Tracing::Trace)) }
    exhaust(:points)
    begin
      run(child)
    rescue rl::ConfigurationError
      nil
    end
    expect(resolved).to eq([])
  end

  it "security H6 context[:trace] = schema.new_trace: protected" do
    schema = limiter_schema(:points, before: [GuardProbe.raiser(:result)])
    exhaust(:points)
    result = run(schema, "{ cheap }", ctx: { trace: schema.new_trace })
    expect_not_run(result)
  end

  xit "preservation H7 docs: a query on this path is visited twice, a lambda can run twice (two Points)" do
    calls = 0
    holder[:fn] = ->(_c, _a, _ch) { calls += 1; raise err, "no" }
    schema = build do
      use rl::Points, store: rl::Store::Substitute.new, limit: 100, window: 60, soft: false
      use rl::Points, store: rl::Store::Substitute.new, limit: 100, window: 60, soft: false
    end
    run(schema, "{ boom }")
    warn "H7 calls=#{calls}"
    expect(calls).to be <= 2
  end

  # ------------------------------------------------- X: added after the first run
  it "security X1 preflight with graphql-ruby's QueryComplexity outside execution, raising lambda the client picks: no slot stays held" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    s = store
    schema = build do
      use rl::Concurrency, store: s, limit: 5, soft: false
      use rl::Points, store: rl::Store::Substitute.new, limit: 100, window: 60, soft: false
    end
    3.times do
      query = GraphQL::Query.new(schema, "{ boom }", context: { rate_limit_key: "user:1" }, root_value: root)
      GraphQL::Analysis.analyze_query(query, [GraphQL::Analysis::QueryComplexity])
    end
    warn "X1 held=#{s.held("user:1")}"
    expect(s.held("user:1")).to eq(0)
  end

  it "security X2 preflight whose analyzer raises, then the same request executes: Points charged once" do
    schema = limiter_schema(:points)
    query = GraphQL::Query.new(schema, "{ report }", context: { rate_limit_key: "user:1" }, root_value: root)
    GraphQL::Analysis.analyze_query(query, [GuardProbe.raiser(:result)])
    run(schema, "{ report }")
    warn "X2 left=#{left}"
    expect(left).to eq(60)
  end

  it "security X3 trace_class set after use on the same schema, exhausted Points, raiser: refused or ConfigurationError" do
    schema = limiter_schema(:points, before: [GuardProbe.raiser(:result)])
    schema.trace_class(Class.new(GraphQL::Tracing::Trace))
    exhaust(:points)
    begin
      result = run(schema)
      warn "X3 #{result.to_h}"
    rescue rl::ConfigurationError => e
      warn "X3 #{e.class}"
    end
    expect(resolved).to eq([])
  end

  it "security X3b trace_class set before use: protected" do
    s = store
    schema = build do
      trace_class Class.new(GraphQL::Tracing::Trace)
      query_analyzer GuardProbe.raiser(:result)
      use rl::Points, store: s, limit: 100, window: 60, soft: false
    end
    exhaust(:points)
    expect_not_run(run(schema))
  end

  it "security X3c same-schema trace_class after use with a Points-only raising lambda: refused or ConfigurationError" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    schema = limiter_schema(:points)
    schema.trace_class(Class.new(GraphQL::Tracing::Trace))
    begin
      run(schema, "{ boom }")
    rescue rl::ConfigurationError
      nil
    end
    warn "X3c left=#{left} resolved=#{resolved}"
    expect(resolved).to eq([])
  end

  it "security X4 a built Query's result with a raising lambda" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    schema = limiter_schema(:points)
    result = GraphQL::Query.new(schema, "{ boom }", context: { rate_limit_key: "user:1" }, root_value: root).result
    expect(resolved).to eq([])
    expect(codes(result)).to eq(["RATE_LIMIT_NOT_CHARGED"])
  end

  it "security X5 nested analyze_query from an analyzer with a raising inner analyzer: the limiter charges once" do
    inner = GuardProbe.raiser(:result)
    outer = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:result) { GraphQL::Analysis.analyze_query(query, [inner]); nil }
    end
    schema = limiter_schema(:points, before: [outer])
    result = run(schema, "{ report }")
    warn "X5 left=#{left}"
    expect(result.to_h["data"]).to eq("report" => "big")
    expect(left).to eq(60)
  end

  it "security X1b the same preflight, repeated: a clean query of that client is refused until stale_after" do
    holder[:fn] = ->(_c, _a, _ch) { raise err, "no" }
    s = store
    schema = build do
      use rl::Concurrency, store: s, limit: 3, stale_after: 60, soft: false
      use rl::Points, store: rl::Store::Substitute.new, limit: 100, window: 60, soft: false
    end
    3.times do
      query = GraphQL::Query.new(schema, "{ boom }", context: { rate_limit_key: "user:1" }, root_value: root)
      GraphQL::Analysis.analyze_query(query, [GraphQL::Analysis::QueryComplexity])
    end
    locked = codes(run(schema, "{ cheap }"))
    s.now += 61
    later = run(schema, "{ cheap }").to_h["data"]
    warn "X1b locked=#{locked} later=#{later}"
    expect(locked).to eq([])
  end

  it "preservation X7 Time soft, store down, hook raises: headers empty, no extension" do
    store.fail_with(IOError.new("down"), on: :take)
    result = run(limiter_schema(:time, soft: true, extensions: true, on_store_error: ->(_e, _q) { raise err, "hook" }))
    expect(result.to_h).to eq("data" => { "cheap" => "ok" })
    expect(rl::Time.headers(result)).to eq({})
  end
end
