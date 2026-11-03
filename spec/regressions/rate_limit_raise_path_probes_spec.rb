# frozen_string_literal: true

# Independent verifier's probes for PR #53 (analysis refusals on the raise path), kept as regressions.
# Each probe is labelled "security" (the feature must change the outcome) or "preservation".
# Probe list written from the diff, docs/rate-limiting.md and the design before reading the existing specs; duplicates of
# existing specs were dropped afterwards.
module VerifierRaiseProbes
  RL = GraphQL::Armory::RateLimits
  NS = RL::Points::NAMESPACE

  Inner = Class.new(GraphQL::Schema::Object) do
    graphql_name "Inner"
    field :cheap, String, null: false
  end

  QueryType = Class.new(GraphQL::Schema::Object) do
    graphql_name "Query"
    field :cheap, String, null: false
    field :report, String, null: false, complexity: 40
    # An app analyzer raises when it sees this field: the client chooses it.
    field :trap, String, null: false
    field :boom, String, null: false, complexity: ->(_ctx, _args, _child) { raise GraphQL::ExecutionError, "lambda says no" }
    field :boom_ae, String, null: false, complexity: ->(_ctx, _args, _child) { raise GraphQL::AnalysisError, "too big" }
    field :deep, Inner, null: false
  end

  def self.root(resolved)
    Class.new do
      %i[cheap report trap boom boom_ae].each { |name| define_method(name) { resolved << name; "ok" } }
      define_method(:deep) { resolved << :deep; self }
    end.new
  end

  # A query analyzer that raises ExecutionError when it enters `trap`; with `once`, only the first visit of each query.
  def self.trap_raiser(once: false, error: GraphQL::ExecutionError)
    Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:on_enter_field) do |node, _parent, visitor|
        return unless node.name == "trap"

        seen = visitor.query.context.namespace(:verifier)
        count = (seen[:trap_raises] = (seen[:trap_raises] || 0) + 1)
        raise error, "trap says no" if !once || count == 1
      end
      define_method(:result) { nil }
    end
  end

  # A multiplex analyzer that counts fields and refuses nothing.
  def self.multiplex_counter
    Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:on_enter_field) { |_n, _p, _v| (@seen ||= 0); @seen += 1 }
      define_method(:result) { nil }
    end
  end
end

RSpec.describe "Verifier probes: analysis refusals on the raise path" do
  let(:rl) { VerifierRaiseProbes::RL }
  let(:store) { rl::Store::Substitute.new }
  let(:resolved) { [] }
  let(:root) { VerifierRaiseProbes.root(resolved) }

  def build(max_complexity: nil, max_depth: nil, soft: true, limit: 1000, &setup)
    query = VerifierRaiseProbes::QueryType
    s = store
    Class.new(ArmoryEngine.base_schema) do
      query query
      max_complexity(max_complexity) if max_complexity
      max_depth(max_depth) if max_depth
      use GraphQL::Armory::RateLimits::Points, store: s, limit: limit, window: 60, soft: soft
      class_exec(&setup) if setup
    end
  end

  def run(schema, doc, key: "user:1", **options)
    execute_query(schema, doc, context: { rate_limit_key: key }, root_value: root, **options)
  end

  def mux(schema, list, **kw)
    ArmoryEngine.next? ? schema.multiplex_next(list, **kw) : schema.multiplex(list, **kw)
  end

  def q(doc, key: "user:1", context: nil, **rest)
    { query: doc, context: context || { rate_limit_key: key }, root_value: root, **rest }
  end

  def codes(result)
    Array(result.to_h["errors"]).map { |error| error.dig("extensions", "code") }
  end

  def messages(result)
    Array(result.to_h["errors"]).map { |error| error["message"] }
  end

  def takes(key = "user:1")
    store.calls.count { |call| call[0] == :take && call[1] == key }
  end

  def log(label, value)
    warn "  [#{ArmoryEngine.current} #{GraphQL::VERSION}] #{label}: #{value.inspect}" if ENV["PROBE_LOG"]
  end

  # ---- Rule (3): the multiplex rule, both ways

  it "preservation M7 each limiter's analyzer takes result from Visited first, and a clean visit sets VISITED" do
    owners = [rl::Points::Analyzer, rl::Time::Analyzer, rl::Concurrency::Analyzer].map { |klass| klass.instance_method(:result).owner }
    log("owners", owners)
    expect(owners).to all(eq(rl::AnalysisGuard::Visited))

    result = run(build, "{ cheap }")
    expect(result.to_h).to eq("data" => { "cheap" => "ok" })
    expect(result.context.namespace(VerifierRaiseProbes::NS)[rl::AnalysisGuard::VISITED]).to eq(true)
  end

  it "security M3 a multiplex analyzer raising in on_leave_operation_definition keeps a later multiplex analyzer from finishing the query" do
    leave_raiser = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:on_leave_operation_definition) do |_node, _parent, visitor|
        raise GraphQL::ExecutionError, "leave says no" if visitor.query.query_string.include?("trap")
      end
      define_method(:result) { nil }
    end
    # Adds each operation's fields to the batch total when it leaves the operation, and refuses a batch over 3 fields.
    leave_counter = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:on_enter_field) { |_n, _p, _v| @current = (@current || 0) + 1 }
      define_method(:on_leave_operation_definition) { |_n, _p, _v| @total = (@total || 0) + (@current || 0); @current = 0 }
      define_method(:result) { (@total || 0) > 3 ? GraphQL::AnalysisError.new("too many fields in this batch") : nil }
    end
    schema = build do
      multiplex_analyzer leave_raiser
      multiplex_analyzer leave_counter
    end

    control = mux(schema, [q("{ cheap report report report }")]).first
    log("M3 control (no trap)", control.to_h)
    results = mux(schema, [q("{ trap report report report }")])
    log("M3 with trap", results.map(&:to_h))
    expect(control.to_h["data"]).to be_nil
    expect(results.first.to_h["data"]).to be_nil
  end

  it "security M6 (measure) multiplex max_complexity: the other query's outcome when the raising query is undercounted" do
    schema = build(max_complexity: 50) { query_analyzer VerifierRaiseProbes.trap_raiser }
    control = mux(schema, [q("{ report }"), q("{ cheap report }")])
    log("M6 control", control.map(&:to_h))
    resolved.clear
    results = mux(schema, [q("{ report }"), q("{ trap report }")])
    log("M6 raise", results.map(&:to_h))
    expect(codes(results[1])).to eq(["QUERY_LIMIT_UNKNOWN"])
    expect(results[1].to_h).not_to have_key("data")
    # q1 alone costs 40 <= 50; documenting whether it runs although the batch without the raise is refused.
    log("M6 q1 ran", results[0].to_h.key?("data") && !results[0].to_h["data"].nil?)
  end

  it "security M8 a raise-once in a fragment of the selected operation, in a multiplex with a multiplex analyzer: refused" do
    schema = build do
      query_analyzer VerifierRaiseProbes.trap_raiser(once: true)
      multiplex_analyzer VerifierRaiseProbes.multiplex_counter
    end
    doc = "query A { cheap } query B { ...F } fragment F on Query { trap report }"
    result = mux(schema, [q(doc, operation_name: "B")]).first
    log("M8", result.to_h)
    expect(codes(result)).to eq(["QUERY_LIMIT_UNKNOWN"])
    expect(resolved).to eq([])
  end

  it "preservation M8b the same document selecting the clean operation runs" do
    schema = build do
      query_analyzer VerifierRaiseProbes.trap_raiser(once: true)
      multiplex_analyzer VerifierRaiseProbes.multiplex_counter
    end
    doc = "query A { cheap } query B { ...F } fragment F on Query { trap report }"
    result = mux(schema, [q(doc, operation_name: "A")]).first
    expect(result.to_h).to eq("data" => { "cheap" => "ok" })
  end

  it "security M9 (doc: a client with no limit too) the exempt client is refused under rule 3" do
    s = store
    schema = Class.new(ArmoryEngine.base_schema) do
      query VerifierRaiseProbes::QueryType
      use GraphQL::Armory::RateLimits::Points, store: s, limit: ->(_key, _query) { nil }, window: 60, soft: false
      query_analyzer VerifierRaiseProbes.trap_raiser(once: true)
      multiplex_analyzer VerifierRaiseProbes.multiplex_counter
    end
    result = mux(schema, [q("{ trap report }")]).first
    log("M9", result.to_h)
    expect(codes(result)).to eq(["QUERY_LIMIT_UNKNOWN"])
  end

  it "security R2a an explicit multiplex max_complexity (schema has none), raise-once during the visit: the undercounted query does not run" do
    schema = build { query_analyzer VerifierRaiseProbes.trap_raiser(once: true) }
    control = mux(schema, [q("{ report }"), q("{ cheap report report }")], max_complexity: 50)
    log("R2a control", control.map(&:to_h))
    resolved.clear
    results = mux(schema, [q("{ cheap }"), q("{ trap report report }")], max_complexity: 50)
    log("R2a raise", results.map(&:to_h))
    expect(results[1].to_h["data"]).to be_nil
    expect(resolved).not_to include(:report)
  end

  it "preservation R2b Schema.execute with max_complexity on the schema is not a multiplex with analyzers: raise-once runs" do
    schema = build(max_complexity: 500) { query_analyzer VerifierRaiseProbes.trap_raiser(once: true) }
    result = run(schema, "{ trap report }")
    log("R2b", result.to_h)
    expect(result.to_h).to eq("data" => { "trap" => "ok", "report" => "ok" })
    expect(takes).to eq(1)
  end

  xit "pre-existing, in the backlog: security R4 a Query the app analyzed itself before executing keeps a stale VISITED (interpreter only)" do
    skip "multiplex_next takes options, not Query objects" if ArmoryEngine.next?
    raiser = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:on_enter_field) { |node, _p, _v| raise GraphQL::ExecutionError, "multiplex says no" if node.name == "trap" }
      define_method(:result) { nil }
    end
    schema = build { multiplex_analyzer raiser }
    query = GraphQL::Query.new(schema, "{ trap report report }", context: { rate_limit_key: "user:1" }, root_value: root)
    GraphQL::Analysis.analyze_query(query, query.analyzers)
    result = schema.multiplex([query], max_complexity: 50).first
    log("R4", [result.to_h, takes])
    expect(result.to_h["data"]).to be_nil
  end

  # ---- Shared context hash

  it "security C2 one Hash shared by a clean query and a raising one, multiplex analyzer: the raising one is refused, either order" do
    schema = build do
      query_analyzer VerifierRaiseProbes.trap_raiser(once: true)
      multiplex_analyzer VerifierRaiseProbes.multiplex_counter
    end
    shared = { rate_limit_key: "user:1" }
    results = mux(schema, [q("{ cheap }", context: shared), q("{ trap report }", context: shared)])
    log("C2 clean first", results.map(&:to_h))
    expect(results[0].to_h).to eq("data" => { "cheap" => "ok" })
    expect(codes(results[1])).to eq(["QUERY_LIMIT_UNKNOWN"])

    shared2 = { rate_limit_key: "user:1" }
    results = mux(schema, [q("{ trap report }", context: shared2), q("{ cheap }", context: shared2)])
    log("C2 raising first", results.map(&:to_h))
    expect(codes(results[0])).to eq(["QUERY_LIMIT_UNKNOWN"])
    expect(results[1].to_h).to eq("data" => { "cheap" => "ok" })
    expect(takes).to eq(4)
  end

  # ---- Error classes and entry points

  it "security E2 an app gate raising AnalysisError from analyze?, with no other raise: refused with its message" do
    gate = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:analyze?) { raise GraphQL::AnalysisError, "gate says no" if query.query_string.include?("trap"); true }
      define_method(:result) { nil }
    end
    schema = build { query_analyzer gate }
    result = run(schema, "{ trap report }")
    log("E2", result.to_h)
    expect(messages(result)).to eq(["gate says no"])
    expect(resolved).to eq([])
    expect(takes).to eq(1)
  end

  it "security E2b an app gate raising UnauthorizedError from visit? over max_depth: max_depth stands" do
    gate = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:visit?) { raise GraphQL::UnauthorizedError, "visit says no" if query.query_string.include?("trap"); true }
      define_method(:result) { nil }
    end
    schema = build(max_depth: 1) { query_analyzer gate }
    result = run(schema, "{ trap deep { cheap } }")
    log("E2b", result.to_h)
    expect(result.to_h).not_to have_key("data")
    expect(messages(result).join).to match(/depth/)
  end

  it "preservation E10 (doc: soft limiter that cannot answer lets it run) soft Points, no maximum, lambda raises AnalysisError" do
    schema = build
    result = run(schema, "{ boomAe }")
    log("E10", [result.to_h, result.context[:rate_limit_points]])
    expect(result.context[:rate_limit_points]).to include(charged: false)
  end

  it "security E10b hard Points and max_complexity, lambda raises AnalysisError: refused, the app's words, count the errors" do
    schema = build(max_complexity: 500, soft: false)
    result = run(schema, "{ boomAe }")
    log("E10b", result.to_h)
    expect(result.to_h).not_to have_key("data")
    expect(messages(result)).to eq(["too big"])
  end

  it "security E10c a raise from the visit first, then hard Points' lambda raises AnalysisError: refused (log the reason)" do
    schema = build(soft: false) { query_analyzer VerifierRaiseProbes.trap_raiser(once: true) }
    result = run(schema, "{ trap boomAe }")
    log("E10c", result.to_h)
    expect(result.to_h).not_to have_key("data")
  end

  # ---- Bound on the extra work

  it "security T2 every analyzer is analyzed at most twice, and each limiter charged once, when one keeps raising" do
    counts = Hash.new(0)
    counter = lambda do |name|
      Class.new(GraphQL::Analysis::Analyzer) do
        define_method(:initialize) { |subject| super(subject); counts[name] += 1 }
        define_method(:result) { nil }
      end
    end
    ts = rl::Store::Substitute.new
    cs = rl::Store::Substitute.new
    clock = rl::Clock::Substitute.new
    schema = build(max_complexity: 500, max_depth: 10, soft: false) do
      query_analyzer counter.(:a)
      query_analyzer VerifierRaiseProbes.trap_raiser
      query_analyzer counter.(:b)
      query_analyzer counter.(:c)
      use GraphQL::Armory::RateLimits::Time, store: ts, limit: 10_000, window: 60, soft: false, clock: clock
      use GraphQL::Armory::RateLimits::Concurrency, store: cs, limit: 5, soft: false
    end
    result = run(schema, "{ cheap trap report }")
    log("T2", [result.to_h, counts, ts.calls.map { |c| [c[0], c[1], c[2][:cost], c[2][:force]] }, cs.calls.map(&:first)])
    expect(codes(result)).to eq(["QUERY_LIMIT_UNKNOWN"])
    expect(counts.values).to all(be <= 2)
    expect(takes).to eq(1)
    expect(ts.calls.count { |c| c[0] == :take && c[2][:force] == false }).to eq(1)
    expect(cs.calls.count { |c| c[0] == :acquire }).to eq(1)
    expect(cs.held("user:1")).to eq(0)
  end
end
