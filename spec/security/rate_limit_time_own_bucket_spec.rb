# frozen_string_literal: true

# `Points` and `Time` on one store and one client key keep separate budgets. They used to share a bucket: milliseconds
# spent the client's points, and each limiter capped and refilled the balance with its own limit.
RSpec.describe "Rate limits: Points and Time on one store and key" do
  let(:limits) { GraphQL::Armory::RateLimits }
  let(:store) { limits::Store::Substitute.new }
  let(:clock) { limits::Clock::Substitute.new }
  let(:resolved) { [] }
  # Every field takes a quarter of a second on `clock`.
  let(:root) { limits::Controls::Time.example(clock, resolved, seconds: 0.25) }

  def schema_for(points: 100, time: 1_500, window: 3_600, time_window: window)
    query = limits::Controls::Query.example
    store = self.store
    clock = self.clock
    limits = self.limits
    Class.new(ArmoryEngine.base_schema) do
      query query
      use limits::Points, store: store, limit: points, window: window, soft: false
      use limits::Time, store: store, clock: clock, limit: time, window: time_window, soft: false
    end
  end

  def run(schema, key: "user:1")
    execute_query(schema, "{ cheap }", context: { rate_limit_key: key }, root_value: root)
  end

  it "keeps the points of a client whose operations took time" do
    schema = schema_for
    results = Array.new(2) { run(schema) }

    expect(results.map { |result| result.context[:rate_limit_points][:remaining] }).to eq([99, 98])
    expect(results.map { |result| result.context[:rate_limit_time][:remaining] }).to eq([1_250, 1_000])
  end

  it "keeps the milliseconds of a client out of points" do
    schema = schema_for(points: 1)
    run(schema)
    refused = run(schema)

    expect(refused.to_h["errors"].first["extensions"]["code"]).to eq("RATE_LIMITED")
    expect(refused.to_h["errors"].first["extensions"]).to include("cost" => 1)
    expect(store.take(limits::Time.bucket_key("user:1"), cost: 0, limit: 1_500, window: 3_600).last).to eq(1_250)
  end

  it "does not give points back at the rate Time refills" do
    schema = schema_for(points: 1, time: 100_000, time_window: 60)
    run(schema)
    store.now += 1
    refused = run(schema)

    expect(refused.to_h["errors"].first["extensions"]["code"]).to eq("RATE_LIMITED")
    expect(resolved.size).to eq(1)
  end

  it "uses its own bucket for every key of a list, and leaves Points' keys as they were" do
    run(schema_for, key: ["user:1", "ip:1"])
    keys = ->(limiter_force) { store.calls.select { |method, _key, arguments| method == :take && arguments[:force] == limiter_force }.map { |_method, key, _arguments| key }.uniq }

    expect(keys.(true)).to contain_exactly("time:user:1", "time:ip:1")
    expect(store.calls.map { |_method, key, _arguments| key }.uniq).to contain_exactly("user:1", "ip:1", "time:user:1", "time:ip:1")
  end

  it "shows the client's own key in the record" do
    result = run(schema_for)

    expect(result.context[:rate_limit_time][:key]).to eq("user:1")
    expect(result.context[:rate_limit_points][:key]).to eq("user:1")
  end
end
