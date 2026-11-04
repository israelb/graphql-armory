# frozen_string_literal: true

# Kept from the independent verification of PR #61: AnalysisGuard drops the state an analysis the app ran itself left behind.
# Each probe is labelled "security" or "preservation". Probe list written from the diff, analysis_guard.rb and
# docs/rate-limiting.md before reading the existing specs; duplicates were dropped afterwards.
#
# The asymmetric raise (the app's analysis does not raise, the execution's does) comes two ways:
#   (M) a client-chosen field (`report`) makes a schema multiplex analyzer raise ExecutionError during the visit: the app's
#       analyze_query runs no multiplex analyzer, so only the execution raises;
#   (L) the `boom` complexity lambda raises from its second evaluation on (the app's analysis evaluates it once).
module R4Probes
  RL = GraphQL::Armory::RateLimits

  BOOM = lambda do |ctx, _args, child|
    calls = ctx[:r4_boom_calls] = ctx[:r4_boom_calls].to_i + 1
    raise GraphQL::ExecutionError, "lambda says no" if calls >= 2

    child + 1
  end

  LIMITER_DEFAULTS = {
    points: { limit: 100, soft: false },
    time: { limit: 1000, soft: false },
    concurrency: { limit: 5, soft: false }
  }.freeze

  ALWAYS = ->(_ctx, _args, _child) { raise GraphQL::ExecutionError, "always no" }

  def self.query_type
    @query_type ||= Class.new(RL::Controls::Query.example) do
      field :boom, String, null: false, complexity: BOOM
      field :always, String, null: false, complexity: ALWAYS
      field :echo, String, null: false do
        argument :n, Integer, required: false
      end
    end
  end

  def self.mux_raiser
    Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:on_enter_field) do |node, _parent, _visitor|
        raise GraphQL::ExecutionError, "multiplex says no" if node.name == "report"
      end
      define_method(:result) { nil }
    end
  end

  # An app trace that logs each query's complexity from inside analyze_multiplex, with its own analysis.
  def self.complexity_logger(log)
    Module.new do
      define_method(:analyze_multiplex) do |multiplex:, &block|
        multiplex.queries.each { |q| log << GraphQL::Analysis.analyze_query(q, [GraphQL::Analysis::QueryComplexity]) }
        super(multiplex: multiplex, &block)
      end
    end
  end
end

RSpec.describe "Regression probes: R4 app-run analysis before the execution" do
  let(:rl) { R4Probes::RL }
  let(:store) { rl::Store::Substitute.new }
  let(:clock) { rl::Clock::Substitute.new }
  let(:resolved) { [] }
  let(:held_during) { [] }
  let(:root) do
    r = rl::Controls::Time.example(clock, resolved)
    res = resolved
    st = store
    during = held_during
    r.define_singleton_method(:boom) { res << :boom; "boom" }
    r.define_singleton_method(:always) { res << :always; "always" }
    r.define_singleton_method(:echo) { |n: nil| res << :echo; n.to_s }
    r.define_singleton_method(:held_now) { during << st.held("user:1") }
    r
  end

  def build(limiters, mux: false, max_complexity: nil, before: nil, after: nil)
    st = store
    ck = clock
    qt = R4Probes.query_type
    Class.new(ArmoryEngine.base_schema) do
      query qt
      max_complexity(max_complexity) if max_complexity
      multiplex_analyzer R4Probes.mux_raiser if mux
      class_exec(&before) if before
      limiters.each do |kind, opts|
        settings = R4Probes::LIMITER_DEFAULTS.fetch(kind).merge(opts || {})
        case kind
        when :points then use R4Probes::RL::Points, store: st, window: 60, **settings
        when :time then use R4Probes::RL::Time, store: st, clock: ck, window: 60, **settings
        when :concurrency then use R4Probes::RL::Concurrency, store: st, **settings
        end
      end
      class_exec(&after) if after
    end
  end

  def query(schema, doc, key: "user:1", **options)
    GraphQL::Query.new(schema, doc, context: rl::Controls::Context.example(key: key), root_value: root, **options)
  end

  def app_analyzes(q, analyzers = q.analyzers)
    GraphQL::Analysis.analyze_query(q, analyzers)
  end

  def execute(schema, queries, max_complexity: nil)
    engine = ArmoryEngine.next? ? GraphQL::Execution::Next : GraphQL::Execution::Interpreter
    engine.run_all(schema, queries, context: {}, max_complexity: max_complexity)
  end

  def codes(result)
    Array(result.to_h["errors"]).map { |error| error.dig("extensions", "code") }
  end

  def takes(key = "user:1", from: 0, force: nil)
    store.calls[from..].count { |call| call[0] == :take && call[1] == key && (force.nil? || call[2][:force] == force) }
  end

  def log(label, value)
    warn "  [#{ArmoryEngine.current} #{GraphQL::VERSION}] #{label}: #{value.inspect}" if ENV["PROBE_LOG"]
  end

  def expect_refused(result, code)
    expect(result.to_h["data"]).to be_nil
    expect(codes(result)).to include(code)
  end

  # ---- (M) raise during the execution's visit, the app analyzed the Query first: each limiter alone and together

  { time: [:time], concurrency: [:concurrency], all: %i[points time concurrency] }.each do |label, kinds|
    it "security S2-S4 (#{label}) app analysis, then a multiplex analyzer raise the client chose: refused, no data, no slot" do
      schema = build(kinds.to_h { |k| [k, {}] }, mux: true)
      baseline = execute(schema, [query(schema, "{ cheap report }", key: "user:9")]).first
      q = query(schema, "{ cheap report }")
      app_analyzes(q)
      result = execute(schema, [q]).first
      log("S2-4 #{label}", [baseline.to_h, result.to_h, resolved])
      expect(codes(baseline)).to eq(["QUERY_LIMIT_UNKNOWN"])
      expect(result.to_h).to eq(baseline.to_h)
      expect(resolved).to be_empty
      expect(store.held("user:1")).to eq(0)
    end
  end

  it "security S4b app analysis with schema.query_analyzers (not query.analyzers), Points hard, (M): refused" do
    schema = build({ points: {} }, mux: true)
    q = query(schema, "{ cheap report }")
    app_analyzes(q, schema.query_analyzers)
    result = execute(schema, [q]).first
    expect_refused(result, "QUERY_LIMIT_UNKNOWN")
    expect(resolved).to be_empty
  end

  # ---- (L) the Points lambda raises only in the execution

  it "security S5 hard Points, lambda raises in the execution only: RATE_LIMIT_NOT_CHARGED, no data" do
    schema = build({ points: {} })
    q = query(schema, "{ boom cheap }")
    app_analyzes(q)
    result = execute(schema, [q]).first
    log("S5", [result.to_h, q.context[:rate_limit_points]])
    expect_refused(result, "RATE_LIMIT_NOT_CHARGED")
    expect(resolved).to be_empty
    expect(q.context[:rate_limit_points]).to include(charged: false, limited: true)
  end

  it "security S5b hard Points+Time+Concurrency, lambda raises in the execution only: refused, no slot, Time not charged twice" do
    schema = build({ points: {}, time: {}, concurrency: {} })
    q = query(schema, "{ boom cheap }")
    app_analyzes(q)
    result = execute(schema, [q]).first
    log("S5b", [result.to_h, store.calls.map { |c| [c[0], c[1], c[2][:force]] }])
    expect_refused(result, "RATE_LIMIT_NOT_CHARGED")
    expect(resolved).to be_empty
    expect(store.held("user:1")).to eq(0)
    expect(takes("time:user:1", force: true)).to be <= 1
  end

  it "security S6 soft Points, lambda raises in the execution only: runs and records charged: false" do
    schema = build({ points: { soft: true } })
    q = query(schema, "{ boom cheap }")
    app_analyzes(q)
    result = execute(schema, [q]).first
    log("S6", [result.to_h, q.context[:rate_limit_points]])
    expect(result.to_h["data"]).to eq("boom" => "boom", "cheap" => "ok")
    expect(q.context[:rate_limit_points]).to include(charged: false)
  end

  # ---- Time's debt

  it "security S7 Time: the app's analysis owes, the client's bucket is drained, the execution is refused: nothing charged" do
    schema = build({ time: {} })
    q = query(schema, "{ cheap }")
    app_analyzes(q)
    store.take("time:user:1", cost: 1000, limit: 1000, window: 60, force: true)
    mark = store.calls.size
    result = execute(schema, [q]).first
    log("S7", [result.to_h, store.calls[mark..]])
    expect_refused(result, "RATE_LIMITED")
    expect(takes("time:user:1", from: mark, force: true)).to eq(0)
    expect(q.context[:rate_limit_time]).to include(elapsed: nil)
  end

  it "security S7b Time in a multiplex: the refused app-analyzed query takes no share of the other query's time" do
    schema = build({ time: {} })
    q = query(schema, "{ cheap }")
    app_analyzes(q)
    store.take("time:user:1", cost: 1000, limit: 1000, window: 60, force: true)
    mark = store.calls.size
    other = query(schema, "{ report }", key: "user:2")
    results = execute(schema, [q, other])
    log("S7b", [results.map(&:to_h), store.calls[mark..]])
    expect_refused(results[0], "RATE_LIMITED")
    expect(takes("time:user:1", from: mark, force: true)).to eq(0)
    expect(other.context[:rate_limit_time][:elapsed]).to eq(250)
  end

  it "security S8 Time on the raise path (M): the app's debt is dropped when the execution's Time refuses" do
    schema = build({ time: {} }, mux: true)
    q = query(schema, "{ cheap report }")
    app_analyzes(q)
    store.take("time:user:1", cost: 1000, limit: 1000, window: 60, force: true)
    mark = store.calls.size
    result = execute(schema, [q]).first
    log("S8", [result.to_h, store.calls[mark..]])
    expect(result.to_h["data"]).to be_nil
    expect(codes(result)).to eq(["RATE_LIMITED"])
    expect(takes("time:user:1", from: mark, force: true)).to eq(0)
  end

  it "preservation P6 Time: an accepted execution after the app's analysis is charged once, for the execution" do
    schema = build({ time: {} })
    q = query(schema, "{ cheap report }")
    app_analyzes(q)
    mark = store.calls.size
    result = execute(schema, [q]).first
    expect(result.to_h["data"]).to eq("cheap" => "ok", "report" => "big")
    expect(takes("time:user:1", from: mark, force: true)).to eq(1)
    expect(q.context[:rate_limit_time]).to include(elapsed: 500, remaining: 500)
  end

  # ---- Concurrency slots

  it "security S9 Concurrency: app analysis + accepted execution releases every slot" do
    schema = build({ concurrency: {} })
    q = query(schema, "{ cheap }")
    app_analyzes(q)
    expect(store.held("user:1")).to eq(1)
    result = execute(schema, [q]).first
    log("S9", [result.to_h, store.held("user:1")])
    expect(result.to_h["data"]).to eq("cheap" => "ok")
    expect(store.held("user:1")).to eq(0)
  end

  it "security S10 Concurrency: app analysis + execution refused by Points releases every slot" do
    schema = build({ points: { limit: 40 }, concurrency: {} })
    q = query(schema, "{ report }")
    app_analyzes(q) # takes the 40 points and one slot
    result = execute(schema, [q]).first
    expect_refused(result, "RATE_LIMITED")
    expect(store.held("user:1")).to eq(0)
  end

  it "security S11 Concurrency: app analysis + raise-path execution (L) refused releases every slot" do
    schema = build({ points: {}, concurrency: {} })
    q = query(schema, "{ boom }")
    app_analyzes(q)
    result = execute(schema, [q]).first
    expect_refused(result, "RATE_LIMIT_NOT_CHARGED")
    expect(store.held("user:1")).to eq(0)
  end

  it "preservation S12 Concurrency limit 1: the app's analysis holds the slot, so the execution is refused; nothing stays held" do
    schema = build({ concurrency: { limit: 1 } })
    q = query(schema, "{ cheap }")
    app_analyzes(q)
    result = execute(schema, [q]).first
    log("S12", [result.to_h, store.held("user:1")])
    expect_refused(result, "RATE_LIMITED")
    expect(store.held("user:1")).to eq(0)
  end

  it "preservation P9 app analysis with no execution holds its slot until stale_after (documented: takes a slot)" do
    schema = build({ concurrency: { stale_after: 30 } })
    q = query(schema, "{ cheap }")
    app_analyzes(q)
    expect(store.held("user:1")).to eq(1)
    store.now += 31
    expect(store.held("user:1")).to eq(0)
  end

  # ---- ARMED: who consumes it

  # The inner variant is pending: on main and on this branch, an app trace added before `use` that analyzes inside
  # analyze_multiplex takes ARMED, so the execution's own analysis passes unguarded (documented limit, in the backlog).
  [true, false].each do |inner|
    send(inner ? :xit : :it, "security S13 an app trace analyzing each query inside analyze_multiplex (#{inner ? "inner" : "outer"} to the guard), (L): refused") do
      seen = []
      logger = R4Probes.complexity_logger(seen)
      schema = build({ points: {} }, before: (inner ? -> { trace_with(logger) } : nil), after: (inner ? nil : -> { trace_with(logger) }))
      q = query(schema, "{ boom cheap }")
      result = execute(schema, [q]).first
      ancestors = q.multiplex.current_trace.class.ancestors
      log("S13 #{inner}", [result.to_h, ancestors.index(logger), ancestors.index(R4Probes::RL::AnalysisGuard), resolved])
      expect(seen.size).to eq(1)
      expect_refused(result, "RATE_LIMIT_NOT_CHARGED")
      expect(resolved).to be_empty
    end
  end

  it "security S18 the trace the app's analysis memoized and the multiplex's trace both route analysis through the guard" do
    schema = build({ points: {} })
    q = query(schema, "{ cheap }")
    app_analyzes(q)
    standalone = q.current_trace
    execute(schema, [q])
    guard = R4Probes::RL::AnalysisGuard
    log("S18", [standalone.method(:analyze_query).owner, q.multiplex.current_trace.method(:analyze_multiplex).owner, standalone.equal?(q.multiplex.current_trace)])
    expect(standalone.method(:analyze_query).owner).to eq(guard)
    expect(q.multiplex.current_trace.method(:analyze_multiplex).owner).to eq(guard)
    expect(q.multiplex.current_trace.method(:analyze_query).owner).to eq(guard)
  end

  # ---- Second execution, twice-analyzed

  it "security S14 a second execution of the same Query: refused or raised, never decided by the first execution's answers (L)" do
    schema = build({ points: {} })
    q = query(schema, "{ boom cheap }")
    first = execute(schema, [q]).first
    first_h = first.to_h
    resolved.clear
    second = begin
      execute(schema, [q]).first.to_h
    rescue RuntimeError => e
      e
    end
    log("S14", [first_h, second, resolved, takes])
    expect(first_h["data"]).to eq("boom" => "boom", "cheap" => "ok")
    expect(resolved).to be_empty
    if second.is_a?(Exception)
      expect(second.message).to match(/reassign result/)
    else
      expect(second["data"]).to be_nil
    end
  end

  it "security S15 the app analyzes twice, then executes, (M) with Points, Time and Concurrency: refused, nothing held, Time once" do
    schema = build({ points: { limit: 200 }, time: {}, concurrency: {} }, mux: true)
    q = query(schema, "{ cheap report }")
    app_analyzes(q)
    app_analyzes(q)
    expect(store.held("user:1")).to eq(2)
    result = execute(schema, [q]).first
    expect_refused(result, "QUERY_LIMIT_UNKNOWN")
    expect(store.held("user:1")).to eq(0)
    expect(takes("time:user:1", force: true)).to eq(1)
    expect(takes).to eq(3)
  end

  # ---- Invalid queries

  it "security S17 an invalid query the app analyzed with a raising lambda is still charged invalid_cost" do
    schema = build({ points: {} })
    # A missing required variable: graphql 2.4.18 with json 3.1 raises ArgumentError serializing a wrong-typed String.
    q = query(schema, "query($n: Int!) { always echo(n: $n) }", variables: {})
    # q.analyzers is nil on an invalid query (graphql-ruby raises NoMethodError), so the app passes the schema's list.
    app_analyzes(q, schema.query_analyzers)
    mark = store.calls.size
    result = execute(schema, [q]).first
    log("S17", [result.to_h, q.validation_pipeline.valid?, store.calls])
    expect(result.to_h["data"]).to be_nil
    expect(takes(from: mark)).to be >= 1
  end

  it "preservation S17b an invalid query the app analyzed (no raise) is charged once overall, not twice" do
    schema = build({ points: {} })
    q = query(schema, "query($n: Int!) { cheap echo(n: $n) }", variables: {})
    app_analyzes(q, schema.query_analyzers)
    result = execute(schema, [q]).first
    log("S17b", [result.to_h, store.calls])
    expect(result.to_h["data"]).to be_nil
    expect(takes).to eq(1)
  end

  # ---- Multiplex, REASK

  it "preservation P1 app analysis + normal execution: runs, Points charged twice (documented)" do
    schema = build({ points: {} })
    q = query(schema, "{ report }")
    app_analyzes(q)
    result = execute(schema, [q]).first
    expect(result.to_h["data"]).to eq("report" => "big")
    expect(takes).to eq(2)
    expect(q.context[:rate_limit_points]).to include(remaining: 20, limited: false)
  end

  it "preservation P3 multiplex of an app-analyzed query and a fresh one under a multiplex max_complexity" do
    schema = build({ points: {} })
    q1 = query(schema, "{ report }")
    app_analyzes(q1)
    q2 = query(schema, "{ cheap }", key: "user:2")
    ok = execute(schema, [q1, q2], max_complexity: 50)
    expect(ok.map { |r| r.to_h["data"] }).to eq([{ "report" => "big" }, { "cheap" => "ok" }])

    q3 = query(schema, "{ report }")
    app_analyzes(q3)
    q4 = query(schema, "{ cheap }", key: "user:2")
    refused = execute(schema, [q3, q4], max_complexity: 40)
    log("P3", refused.map(&:to_h))
    expect(refused.map { |r| r.to_h["data"] }).to eq([nil, nil])
  end

  it "preservation P7 REASK after the app's analysis: a max_complexity refusal still stands on the raise path (M)" do
    schema = build({ points: {} }, mux: true, max_complexity: 10)
    q = query(schema, "{ cheap report }")
    app_analyzes(q)
    result = execute(schema, [q], max_complexity: nil).first
    log("P7", result.to_h)
    expect(result.to_h["data"]).to be_nil
    expect(result.to_h["errors"].map { |e| e["message"] }).to include(match(/exceeds max complexity of 10/))
  end

  it "preservation P8 (advisory) Points.headers of a query refused RATE_LIMIT_NOT_CHARGED do not report the app's analysis" do
    schema = build({ points: {} })
    baseline_q = query(schema, "{ always }", key: "user:9")
    baseline = execute(schema, [baseline_q]).first
    q = query(schema, "{ boom }")
    app_analyzes(q)
    result = execute(schema, [q]).first
    log("P8", [rl::Points.headers(baseline), rl::Points.headers(result)])
    expect(codes(baseline)).to include("RATE_LIMIT_NOT_CHARGED")
    expect(codes(result)).to include("RATE_LIMIT_NOT_CHARGED")
    expect(rl::Points.headers(result)).to eq(rl::Points.headers(baseline))
  end
end
