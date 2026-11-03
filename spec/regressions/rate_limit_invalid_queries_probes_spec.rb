# frozen_string_literal: true

# Probes kept from the verification of C3 (charge invalid queries), PR #51. Each `it` is labelled security or preservation.
require "spec_helper"

RSpec.describe "C3 probes: charging invalid queries" do

  let(:store) { GraphQL::Armory::RateLimits::Store::Substitute.new }
  let(:root) { GraphQL::Armory::RateLimits::Controls::Root.example }

  def schema_with(store:, limit: 100, extra: nil, **options)
    schema = base_schema
    schema.query(GraphQL::Armory::RateLimits::Controls::Query.example)
    extra&.call(schema, :before)
    schema.use GraphQL::Armory::RateLimits::Points, store: store, limit: limit, **options
    extra&.call(schema, :after)
    schema
  end

  def run_one(schema, query, key: "user:1", **options)
    execute_query(schema, query, root_value: root, context: GraphQL::Armory::RateLimits::Controls::Context.example(key: key), **options)
  end

  def run_many(schema, list, **kwargs)
    ArmoryEngine.next? ? schema.multiplex_next(list, **kwargs) : schema.multiplex(list, **kwargs)
  end

  def opts(query, key: "user:1", **rest)
    { query: query, root_value: root, context: GraphQL::Armory::RateLimits::Controls::Context.example(key: key), **rest }
  end

  def balance(store, key, limit: 100)
    store.take(key, cost: 0, limit: limit, window: 60).last
  end

  def takes(store, key = nil)
    store.calls.select { |method, k, args| method == :take && (key.nil? || k == key) && args[:cost].positive? }
  end

  def plain_errors(query)
    plain = base_schema
    plain.query(GraphQL::Armory::RateLimits::Controls::Query.example)
    execute_query(plain, query, root_value: root, context: {}).to_h
  end

  # --- Requirement 1: each invalid form costs invalid_cost exactly once ---

  {
    "a parse error" => "{ cheap",
    "a validation error" => "{ nope }",
    "an empty document" => "",
    "a document of only comments" => "# just a comment\n",
    "several operations and no operation_name" => "query A { cheap } query B { cheap }",
    "a variable of the wrong type" => "query($n: Int!) { cheap }"
  }.each do |form, query|
    [true, false].each do |soft|
      it "security: #{form} costs 1 point once (soft: #{soft})" do
        schema = schema_with(store: store, soft: soft)
        run_one(schema, query, variables: { "n" => "not an int" })
        expect(takes(store, "user:1").size).to eq(1)
        expect(balance(store, "user:1")).to eq(99)
      end
    end
  end

  it "security: an operation_name that does not exist costs 1" do
    schema = schema_with(store: store)
    run_one(schema, "query A { cheap }", operation_name: "Missing")
    expect(balance(store, "user:1")).to eq(99)
  end

  it "security: no query string at all costs 1" do
    schema = schema_with(store: store)
    execute_query(schema, nil, root_value: root, context: GraphQL::Armory::RateLimits::Controls::Context.example)
    expect(balance(store, "user:1")).to eq(99)
  end

  it "security: a missing required variable costs 1" do
    schema = schema_with(store: store)
    run_one(schema, "query($n: Int!) { cheap }")
    expect(balance(store, "user:1")).to eq(99)
  end

  it "security: a strict PersistedQueries raw-query refusal costs 1 (PQ used before Points)" do
    schema = schema_with(store: store, extra: ->(s, at) { s.use(GraphQL::Armory::PersistedQueries, store: GraphQL::Armory::PersistedQueries::Store::Null.new, strict: true) if at == :before })
    result = run_one(schema, "{ cheap }")
    expect(result["errors"].first["message"]).to eq(GraphQL::Armory::PersistedQueries::RAW_QUERY_REFUSED)
    expect(balance(store, "user:1")).to eq(99)
  end

  it "security: an unknown operation id costs 1 (PQ used after Points)" do
    schema = schema_with(store: store, extra: ->(s, at) { s.use(GraphQL::Armory::PersistedQueries, store: GraphQL::Armory::PersistedQueries::Store::Null.new, strict: true) if at == :after })
    execute_query(schema, nil, root_value: root, context: GraphQL::Armory::RateLimits::Controls::Context.example(operation_id: "nope"))
    expect(balance(store, "user:1")).to eq(99)
  end

  it "security: in a multiplex, valid(1) + parse error + validation error cost 1 + 1 + 1 to the right key" do
    schema = schema_with(store: store)
    run_many(schema, [opts("{ cheap }"), opts("{ cheap"), opts("{ nope }")])
    expect(balance(store, "user:1")).to eq(97)
  end

  it "security: invalid_cost: 3 charges 3 per invalid query" do
    schema = schema_with(store: store, invalid_cost: 3)
    run_many(schema, [opts("{ cheap"), opts("{ nope }")])
    expect(balance(store, "user:1")).to eq(94)
  end

  # --- Requirement 2: valid queries and analyzer refusals are not charged again ---

  it "preservation: a valid query is charged exactly once, by the analyzer" do
    schema = schema_with(store: store)
    run_one(schema, "{ report }")
    expect(takes(store).map { |_m, k, a| [k, a[:cost], a[:force]] }).to eq([["user:1", 40, true]])
  end

  it "preservation: a RATE_LIMITED refusal (hard) is charged nothing, not even as invalid" do
    schema = schema_with(store: store, soft: false, limit: 10)
    result = run_one(schema, "{ report }")
    expect(result["errors"].first.dig("extensions", "code")).to eq("RATE_LIMITED")
    expect(balance(store, "user:1", limit: 10)).to eq(10)
  end

  it "preservation: a max_depth refusal is charged its complexity once" do
    schema = schema_with(store: store, extra: ->(s, at) { s.max_depth(0) if at == :before })
    run_one(schema, "{ cheap }")
    expect(takes(store).size).to eq(1)
  end

  it "preservation: a custom analyzer refusal is charged once, not as invalid" do
    refuser = Class.new(GraphQL::Analysis::Analyzer) { def result = GraphQL::AnalysisError.new("no") }
    schema = schema_with(store: store, extra: ->(s, at) { s.query_analyzer(refuser) if at == :after })
    run_one(schema, "{ cheap }")
    expect(takes(store).map { |_m, _k, a| a[:cost] }).to eq([1])
    expect(store.calls.map { |_m, _k, a| a[:force] }.uniq).to eq([true])
  end

  it "preservation: an analyzer raising ExecutionError leaves the query charged once" do
    raiser = Class.new(GraphQL::Analysis::Analyzer) { def result = raise(GraphQL::ExecutionError, "x") }
    schema = schema_with(store: store, extra: ->(s, at) { s.query_analyzer(raiser) if at == :before })
    run_one(schema, "{ cheap }")
    expect(takes(store).size).to eq(1)
  end

  it "security: a multiplex max_complexity refusal does not hide the invalid queries of the multiplex" do
    schema = schema_with(store: store, limit: 1000)
    run_many(schema, [opts("{ report }"), opts("{ report }"), opts("{ cheap"), opts("{ cheap"), opts("{ cheap")], max_complexity: 50)
    # The two reports are charged 40 each by the analyzer; the three invalid queries 1 each.
    expect(balance(store, "user:1", limit: 1000)).to eq(1000 - 80 - 3)
  end

  # --- Requirement 3: the invalid query's answer never changes ---

  [true, false].each do |soft|
    it "preservation: the answer of an invalid query is unchanged (soft: #{soft}, extensions: true)" do
      schema = schema_with(store: store, soft: soft, extensions: true)
      expect(run_one(schema, "{ nope }").to_h).to eq(plain_errors("{ nope }"))
      expect(run_one(schema, "{ cheap").to_h).to eq(plain_errors("{ cheap"))
    end
  end

  it "security: a store that raises: the answer stands, on_store_error hears it, nothing raises" do
    heard = []
    store.fail_with(IOError.new("redis down"), on: :take)
    schema = schema_with(store: store, on_store_error: ->(e, q) { heard << [e.class, q.class] })
    expect(run_one(schema, "{ nope }").to_h).to eq(plain_errors("{ nope }"))
    expect(heard.map(&:first)).to eq([IOError])
  end

  it "security: a store answering a malformed value: the answer stands and it is reported" do
    heard = []
    store.answer(:take, "garbage")
    schema = schema_with(store: store, on_store_error: ->(e, _q) { heard << e.class })
    expect(run_one(schema, "{ nope }").to_h).to eq(plain_errors("{ nope }"))
    expect(heard).to eq([GraphQL::Armory::RateLimits::ConfigurationError])
  end

  it "security: a key proc that raises for an invalid query never replaces the answer" do
    heard = []
    schema = schema_with(store: store, key: ->(q) { q.selected_operation.name.upcase }, on_store_error: ->(e, _q) { heard << e.class })
    expect(run_one(schema, "{ nope }").to_h).to eq(plain_errors("{ nope }"))
    expect(heard).to eq([NoMethodError])
  end

  it "security: a limit proc that raises never replaces the answer" do
    heard = []
    schema = schema_with(store: store, limit: ->(_k, _q) { raise "limit down" }, on_store_error: ->(e, _q) { heard << e.message })
    expect(run_one(schema, "{ nope }").to_h).to eq(plain_errors("{ nope }"))
    expect(heard).to eq(["limit down"])
  end

  it "security: an invalid query with no key does not raise (docs), a valid one still raises" do
    heard = []
    schema = schema_with(store: store, on_store_error: ->(e, _q) { heard << e.class })
    expect(execute_query(schema, "{ nope }", root_value: root, context: {}).to_h).to eq(plain_errors("{ nope }"))
    expect(heard).to eq([GraphQL::Armory::RateLimits::ConfigurationError])
    expect { execute_query(schema, "{ cheap }", root_value: root, context: {}) }.to raise_error(GraphQL::Armory::RateLimits::ConfigurationError)
  end

  it "security: an exception from another query's resolver keeps its class; the invalid query is still charged" do
    schema = schema_with(store: store)
    expect { run_many(schema, [opts("{ broken }"), opts("{ cheap")]) }.to raise_error(IOError, /disk on fire/)
    expect(balance(store, "user:1")).to eq(98) # broken costs 1, the invalid query 1
  end

  it "security: a store failure in the ensure does not replace a propagating exception" do
    key = ->(q) { q.valid? ? "user:1" : raise(KeyError, "key down") }
    schema = schema_with(store: store, key: key, on_store_error: ->(_e, _q) { raise ArgumentError, "hook" })
    expect { run_many(schema, [opts("{ broken }"), opts("{ cheap")]) }.to raise_error(IOError, /disk on fire/)
  end

  it "preservation: an exception raised before validation propagates unchanged" do
    boom = Module.new { def analyze_multiplex(multiplex:) = raise(RuntimeError, "boom") }
    schema = schema_with(store: store, extra: ->(s, at) { s.trace_with(boom) if at == :after })
    expect { run_many(schema, [opts("{ cheap }"), opts("{ cheap")]) }.to raise_error(RuntimeError, "boom")
    # Informational: was the never-answered invalid query charged?
    warn "PROBE-INFO raised-before-validation invalid charges=#{takes(store).size}"
  end

  # --- Requirement 4: no force, order, never below zero ---

  it "security: a multiplex of more invalid queries than the client has left still drains the bucket" do
    schema = schema_with(store: store, limit: 10)
    run_many(schema, Array.new(7) { opts("{ cheap }") }) # 3 left
    run_many(schema, Array.new(5) { opts("{ cheap") })   # 5 invalid, 3 left
    expect(balance(store, "user:1", limit: 10)).to eq(0)
  end

  it "security: the same five invalid queries one at a time drain the bucket (control)" do
    schema = schema_with(store: store, limit: 10)
    run_many(schema, Array.new(7) { opts("{ cheap }") })
    5.times { run_one(schema, "{ cheap") }
    expect(balance(store, "user:1", limit: 10)).to eq(0)
  end

  it "security: invalid_cost above what is left still takes what is left (docs: stops at zero)" do
    schema = schema_with(store: store, limit: 10, invalid_cost: 5)
    run_many(schema, Array.new(7) { opts("{ cheap }") }) # 3 left
    run_one(schema, "{ cheap")
    expect(balance(store, "user:1", limit: 10)).to eq(0)
  end

  # --- Grouping and other clients ---

  it "security: different limits per key group apart and each pays" do
    schema = schema_with(store: store, limit: ->(key, _q) { key == "ip:1" ? 50 : 100 })
    run_many(schema, [opts("{ cheap", key: "user:1"), opts("{ cheap", key: "ip:1"), opts("{ cheap", key: %w[user:1 ip:1])])
    expect(balance(store, "user:1")).to eq(98)
    expect(balance(store, "ip:1", limit: 50)).to eq(48)
  end

  it "security: an empty key list for an invalid query charges no one and does not raise" do
    heard = []
    schema = schema_with(store: store, on_store_error: ->(e, _q) { heard << e.class })
    run_one(schema, "{ cheap", key: [])
    expect(takes(store)).to be_empty
    expect(heard).to eq([GraphQL::Armory::RateLimits::ConfigurationError])
  end

  # --- Requirement 5: Time ---

  def time_schema(store, clock, soft: true, limit: 10_000)
    schema = base_schema
    schema.query(GraphQL::Armory::RateLimits::Controls::Query.example)
    schema.use GraphQL::Armory::RateLimits::Time, store: store, limit: limit, clock: clock, soft: soft
    schema
  end

  def time_balance(store, key = "user:1", limit: 10_000)
    store.take(GraphQL::Armory::RateLimits::Time.bucket_key(key), cost: 0, limit: limit, window: 60).last
  end

  it "security: Time charges the time of a multiplex with a valid query to that query, not to the invalid one" do
    clock = GraphQL::Armory::RateLimits::Clock::Substitute.new
    schema = time_schema(store, clock)
    slow = GraphQL::Armory::RateLimits::Controls::Time.example(clock, seconds: 1.0)
    run_many(schema, [{ query: "{ cheap }", root_value: slow, context: GraphQL::Armory::RateLimits::Controls::Context.example },
                      { query: "{ cheap", root_value: slow, context: GraphQL::Armory::RateLimits::Controls::Context.example(key: "user:2") }])
    expect(time_balance(store, "user:1")).to eq(9_000)
    expect(time_balance(store, "user:2")).to eq(10_000)
  end

  it "security: Time charges a refused query no share" do
    clock = GraphQL::Armory::RateLimits::Clock::Substitute.new
    schema = time_schema(store, clock, soft: false)
    slow = GraphQL::Armory::RateLimits::Controls::Time.example(clock, seconds: 1.0)
    store.take(GraphQL::Armory::RateLimits::Time.bucket_key("user:3"), cost: 10_000, limit: 10_000, window: 60)
    run_many(schema, [{ query: "{ cheap }", root_value: slow, context: GraphQL::Armory::RateLimits::Controls::Context.example },
                      { query: "{ cheap }", root_value: slow, context: GraphQL::Armory::RateLimits::Controls::Context.example(key: "user:3") },
                      { query: "{ cheap", root_value: slow, context: GraphQL::Armory::RateLimits::Controls::Context.example(key: "user:2") }])
    expect(time_balance(store, "user:1")).to eq(9_000)
    expect(time_balance(store, "user:2")).to eq(10_000)
  end

  it "security: padding a multiplex with invalid queries never lowers what a client pays for its time" do
    clock = GraphQL::Armory::RateLimits::Clock::Substitute.new
    schema = time_schema(store, clock)
    first = GraphQL::Armory::RateLimits::Controls::Time.example(clock, seconds: 9.0)
    execute_query(schema, "{ cheap }", root_value: first, context: GraphQL::Armory::RateLimits::Controls::Context.example)
    expect(time_balance(store)).to eq(1_000)
    slow = GraphQL::Armory::RateLimits::Controls::Time.example(clock, seconds: 2.0)
    run_many(schema, [{ query: "{ cheap }", root_value: slow, context: GraphQL::Armory::RateLimits::Controls::Context.example }] +
                     Array.new(9) { { query: "{ cheap", root_value: slow, context: GraphQL::Armory::RateLimits::Controls::Context.example } })
    # Without the padding the 2 s query alone would leave 0 (forced charge).
    expect(time_balance(store)).to eq(0)
  end

  it "security: Time with keys [user, shared] stops at an exhausted user and leaves shared alone" do
    clock = GraphQL::Armory::RateLimits::Clock::Substitute.new
    schema = time_schema(store, clock)
    store.take(GraphQL::Armory::RateLimits::Time.bucket_key("user:1"), cost: 10_000, limit: 10_000, window: 60)
    slow = GraphQL::Armory::RateLimits::Controls::Time.example(clock, seconds: 1.0)
    run_many(schema, [{ query: "{ cheap }", root_value: slow, context: GraphQL::Armory::RateLimits::Controls::Context.example(key: "user:9") },
                      { query: "{ cheap", root_value: slow, context: GraphQL::Armory::RateLimits::Controls::Context.example(key: %w[user:1 shared]) }])
    expect(time_balance(store, "shared")).to eq(10_000)
  end

  # --- Requirement 6 and settings ---

  it "preservation: invalid_cost: nil charges nothing and makes no store call for invalid queries" do
    schema = schema_with(store: store, invalid_cost: nil)
    ctx = GraphQL::Armory::RateLimits::Controls::Context.example
    execute_query(schema, "{ nope }", root_value: root, context: ctx)
    expect(store.calls).to be_empty
    expect(ctx[:rate_limit_points]).to be_nil
  end

  [0, -1, 1.0, "1", true, 2**70 * 0.5].each do |bad|
    it "security: invalid_cost: #{bad.inspect} is refused at boot" do
      expect { schema_with(store: store, invalid_cost: bad) }.to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, /invalid_cost/)
    end
  end

  it "preservation: invalid_cost on Time or Concurrency is not silently accepted" do
    expect { base_schema.use(GraphQL::Armory::RateLimits::Time, store: store, limit: 10, invalid_cost: 1) }.to raise_error(ArgumentError)
    expect { base_schema.use(GraphQL::Armory::RateLimits::Concurrency, store: store, limit: 1, invalid_cost: 1) }.to raise_error(ArgumentError)
  end

  it "security: an exhausted client's invalid query is recorded limited and stays at zero" do
    schema = schema_with(store: store, limit: 1)
    run_one(schema, "{ cheap }")
    ctx = GraphQL::Armory::RateLimits::Controls::Context.example
    execute_query(schema, "{ nope }", root_value: root, context: ctx)
    expect(ctx[:rate_limit_points]).to include(remaining: 0, limited: true, invalid: true)
  end

  # --- Several limiters, inheritance, trace owners ---

  it "security: two Points on one schema each charge an invalid query once" do
    other = GraphQL::Armory::RateLimits::Store::Substitute.new
    schema = schema_with(store: store, extra: ->(s, at) { s.use(GraphQL::Armory::RateLimits::Points, store: other, limit: 100) if at == :after })
    run_one(schema, "{ nope }")
    expect([balance(store, "user:1"), balance(other, "user:1")]).to eq([99, 99])
  end

  it "security: a subclass schema charges an invalid query once, not once per level" do
    parent = schema_with(store: store)
    child = Class.new(parent)
    grandchild = Class.new(child)
    execute_query(grandchild, "{ nope }", root_value: root, context: GraphQL::Armory::RateLimits::Controls::Context.example)
    expect(balance(store, "user:1")).to eq(99)
  end

  it "preservation: the trace modules: each limiter's module appears once in the trace ancestors" do
    schema = schema_with(store: store)
    child = Class.new(schema)
    trace = child.new_trace
    owners = trace.class.ancestors.select { |m| m.instance_methods(false).include?(:execute_multiplex) }
    warn "PROBE-INFO execute_multiplex owner=#{trace.method(:execute_multiplex).owner.inspect} owners=#{owners.size}"
    expect(owners.uniq.size).to eq(owners.size)
  end

  it "security: a query run with its own context[:trace] is not charged (documented limit, informational)" do
    schema = schema_with(store: store)
    execute_query(schema, "{ nope }", root_value: root, context: GraphQL::Armory::RateLimits::Controls::Context.example(trace: GraphQL::Tracing::Trace.new))
    warn "PROBE-INFO own-trace invalid charges=#{takes(store).size}"
    expect(true).to be(true)
  end

  it "preservation: skip/include that leaves nothing is valid and charged as before" do
    schema = schema_with(store: store)
    ctx = GraphQL::Armory::RateLimits::Controls::Context.example
    execute_query(schema, "{ cheap @skip(if: true) }", root_value: root, context: ctx)
    expect(ctx[:rate_limit_points]).not_to include(:invalid)
  end
end
