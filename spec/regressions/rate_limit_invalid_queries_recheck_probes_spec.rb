# frozen_string_literal: true

# Probes kept from the recheck of C3 (charge invalid queries), PR #51: several keys, multiplex analyzers, Time padding.
require "spec_helper"

RSpec.describe "C3 recheck probes" do
  let(:store) { GraphQL::Armory::RateLimits::Store::Substitute.new }
  let(:root) { GraphQL::Armory::RateLimits::Controls::Root.example }
  let(:ctl) { GraphQL::Armory::RateLimits::Controls }

  def schema_with(store:, limit: 100, extra: nil, **options)
    schema = base_schema
    schema.query(ctl::Query.example)
    extra&.call(schema, :before)
    schema.use GraphQL::Armory::RateLimits::Points, store: store, limit: limit, **options
    extra&.call(schema, :after)
    schema
  end

  def run_many(schema, list, **kwargs)
    ArmoryEngine.next? ? schema.multiplex_next(list, **kwargs) : schema.multiplex(list, **kwargs)
  end

  def opts(query, key: "user:1", **rest)
    { query: query, root_value: root, context: ctl::Context.example(key: key), **rest }
  end

  def bal(key, limit: 100) = store.take(key, cost: 0, limit: limit, window: 60).last
  def spend(key, n, limit: 100) = store.take(key, cost: n, limit: limit, window: 60)
  def takes(key = nil) = store.calls.select { |m, k, a| m == :take && (key.nil? || k == key) && a[:cost].positive? }

  # ---- Blocker 1 variants: several keys ----

  it "B1 first key partially pays: batch of 5 vs one at a time, second key" do
    schema = schema_with(store: store)
    spend("user:1", 97) # 3 left
    run_many(schema, Array.new(5) { opts("{ cheap", key: %w[user:1 ip:1]) })
    batch_ip = bal("ip:1")
    store2 = GraphQL::Armory::RateLimits::Store::Substitute.new
    schema2 = schema_with(store: store2)
    store2.take("user:1", cost: 97, limit: 100, window: 60)
    5.times { run_many(schema2, [{ query: "{ cheap", root_value: root, context: ctl::Context.example(key: %w[user:1 ip:1]) }]) }
    seq_ip = store2.take("ip:1", cost: 0, limit: 100, window: 60).last
    expect(bal("user:1")).to eq(0)
    expect([batch_ip, seq_ip]).to eq([seq_ip, seq_ip]) # equal if batching never costs less
  end

  it "B1 second key partially pays: user charged in full, ip drained" do
    schema = schema_with(store: store)
    spend("ip:1", 97)
    run_many(schema, Array.new(5) { opts("{ cheap", key: %w[user:1 ip:1]) })
    expect([bal("user:1"), bal("ip:1")]).to eq([95, 0])
  end

  it "B1 last of three keys partially pays" do
    schema = schema_with(store: store)
    spend("c", 98)
    run_many(schema, Array.new(5) { opts("{ cheap", key: %w[a b c]) })
    expect([bal("a"), bal("b"), bal("c")]).to eq([95, 95, 0])
  end

  it "B1 middle key of three partially pays: c pays what b held, as one at a time" do
    schema = schema_with(store: store)
    spend("b", 98)
    run_many(schema, Array.new(5) { opts("{ cheap", key: %w[a b c]) })
    expect([bal("a"), bal("b"), bal("c")]).to eq([95, 0, 98])
  end

  it "B1 narrow key at zero: shared key untouched" do
    schema = schema_with(store: store)
    spend("user:1", 100)
    run_many(schema, Array.new(5) { opts("{ cheap", key: %w[user:1 shared]) })
    expect(bal("shared")).to eq(100)
    expect(takes("shared")).to be_empty
  end

  it "Side: narrow key can pay, shared has less than the cost: shared drained (same as sequential)" do
    schema = schema_with(store: store)
    spend("shared", 97)
    run_many(schema, Array.new(5) { opts("{ cheap", key: %w[user:1 shared]) })
    expect([bal("user:1"), bal("shared")]).to eq([95, 0])
  end

  it "B1 invalid_cost: 4 with 10 left, batch of 5 still drains" do
    schema = schema_with(store: store, invalid_cost: 4)
    spend("user:1", 90)
    run_many(schema, Array.new(5) { opts("{ nope }") })
    expect(bal("user:1")).to eq(0)
  end

  # ---- Blocker 2 variants ----

  it "B2 max_depth refusal across a multiplex: invalid ones still charged, valid ones once" do
    schema = schema_with(store: store, limit: 1000, extra: ->(s, at) { s.max_depth(0) if at == :before })
    run_many(schema, [opts("{ report }"), opts("{ cheap"), opts("{ nope }")])
    expect(bal("user:1", limit: 1000)).to eq(1000 - 40 - 2)
  end

  it "B2 custom multiplex analyzer refusing: invalid charged, valid once, no double charge" do
    refuser = Class.new(GraphQL::Analysis::Analyzer) { def result = GraphQL::AnalysisError.new("multiplex no") }
    schema = schema_with(store: store, limit: 1000, extra: ->(s, at) { s.multiplex_analyzer(refuser) if at == :after })
    res = run_many(schema, [opts("{ report }"), opts("{ cheap }"), opts("{ cheap"), opts("query($n: Int!) { cheap }")])
    expect(res.map { |r| r["errors"]&.first&.dig("message") }.compact.size).to eq(4)
    expect(takes("user:1").map { |_m, _k, a| a[:cost] }.sort).to eq([1, 2, 40])
    expect(bal("user:1", limit: 1000)).to eq(1000 - 40 - 1 - 2)
  end

  it "B2 custom multiplex analyzer before Points refusing" do
    refuser = Class.new(GraphQL::Analysis::Analyzer) { def result = GraphQL::AnalysisError.new("multiplex no") }
    schema = schema_with(store: store, limit: 1000, extra: ->(s, at) { s.multiplex_analyzer(refuser) if at == :before })
    run_many(schema, [opts("{ cheap }"), opts("{ cheap"), opts("{ nope }")])
    expect(bal("user:1", limit: 1000)).to eq(1000 - 1 - 2)
  end

  it "B2 query analyzer refusal + multiplex: refused query not charged twice" do
    refuser = Class.new(GraphQL::Analysis::Analyzer) { def result = GraphQL::AnalysisError.new("no") }
    schema = schema_with(store: store, limit: 1000, extra: ->(s, at) { s.query_analyzer(refuser) if at == :after })
    run_many(schema, [opts("{ report }"), opts("{ cheap")])
    expect(takes("user:1").map { |_m, _k, a| a[:cost] }.sort).to eq([1, 40])
  end

  it "B2 hard RATE_LIMITED refusal in a multiplex with an invalid query: refused not charged as invalid" do
    schema = schema_with(store: store, limit: 10, soft: false)
    run_many(schema, [opts("{ report }"), opts("{ cheap")])
    expect(bal("user:1", limit: 10)).to eq(9)
  end

  # ---- Blocker 3 variants: Time ----

  def time_schema(clock, limit: 10_000)
    schema = base_schema
    schema.query(ctl::Query.example)
    schema.use GraphQL::Armory::RateLimits::Time, store: store, limit: limit, clock: clock, soft: true
    schema
  end

  def tbal(key, limit: 10_000) = store.take(GraphQL::Armory::RateLimits::Time.bucket_key(key), cost: 0, limit: limit, window: 60).last
  def tspend(key, n) = store.take(GraphQL::Armory::RateLimits::Time.bucket_key(key), cost: n, limit: 10_000, window: 60)

  it "B3 Time two keys, first nearly empty: padding lowers what the second key pays" do
    clock = GraphQL::Armory::RateLimits::Clock::Substitute.new
    schema = time_schema(clock)
    tspend("user:1", 9_000) # 1000 left
    slow = ctl::Time.example(clock, seconds: 2.0)
    ctx = -> { ctl::Context.example(key: %w[user:1 ip:1]) }
    run_many(schema, [{ query: "{ cheap }", root_value: slow, context: ctx.call }] +
                     Array.new(9) { { query: "{ cheap", root_value: slow, context: ctx.call } })
    # Without padding: the 2 s query charges both keys 2000 forced -> ip:1 at 8000.
    expect([tbal("user:1"), tbal("ip:1")]).to eq([0, 8_000])
  end

  it "B3 Time control: same query without padding" do
    clock = GraphQL::Armory::RateLimits::Clock::Substitute.new
    schema = time_schema(clock)
    tspend("user:1", 9_000)
    slow = ctl::Time.example(clock, seconds: 2.0)
    run_many(schema, [{ query: "{ cheap }", root_value: slow, context: ctl::Context.example(key: %w[user:1 ip:1]) }])
    expect([tbal("user:1"), tbal("ip:1")]).to eq([0, 8_000])
  end

  it "B3 Time two keys, second nearly empty: padding still drains" do
    clock = GraphQL::Armory::RateLimits::Clock::Substitute.new
    schema = time_schema(clock)
    tspend("ip:1", 9_000)
    slow = ctl::Time.example(clock, seconds: 2.0)
    ctx = -> { ctl::Context.example(key: %w[user:1 ip:1]) }
    run_many(schema, [{ query: "{ cheap }", root_value: slow, context: ctx.call }] +
                     Array.new(9) { { query: "{ cheap", root_value: slow, context: ctx.call } })
    expect([tbal("user:1"), tbal("ip:1")]).to eq([8_000, 0])
  end

  it "B3 Time single key, ample budget: padding costs the same total" do
    clock = GraphQL::Armory::RateLimits::Clock::Substitute.new
    schema = time_schema(clock)
    slow = ctl::Time.example(clock, seconds: 2.0)
    run_many(schema, [{ query: "{ cheap }", root_value: slow, context: ctl::Context.example }] +
                     Array.new(9) { { query: "{ cheap", root_value: slow, context: ctl::Context.example } })
    expect(tbal("user:1")).to eq(8_000)
  end
end
