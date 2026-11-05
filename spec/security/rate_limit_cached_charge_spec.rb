# frozen_string_literal: true

# Until the integration branch requires it from caching.rb.
require "graphql/armory/caching/charge"

# A cached response runs no analyzer, so the response cache charges it through `Caching::Charge`, which calls
# `Points#charge_cached` on every Points limiter of the schema. A hit must cost the client exactly what the run cost:
# same keys, limits, soft mode and store, the same records, extension and headers, and the same refusal. Otherwise
# a hit is a bypass of the budget, and a budget that does not move tells the client someone else asked first.
#
# Each example builds twin schemas, one per store, brings both to the same balance with the same runs, then runs the
# query on one and charges it as a hit on the other, and compares what each recorded and answered.
RSpec.describe "Rate limits: a cached response is charged like a run" do
  let(:limits) { GraphQL::Armory::RateLimits }
  let(:charge) { GraphQL::Armory::Caching::Charge }
  let(:root) { limits::Controls::Root.example([]) }
  let(:data) { { "report" => "big" } }

  def schema_with(store: limits::Store::Substitute.new, query_type: limits::Controls::Query.example, **options)
    Class.new(ArmoryEngine.base_schema) do
      query query_type
      use GraphQL::Armory::RateLimits::Points, store: store, **{ limit: 100, window: 60, soft: false }.merge(options)
    end
  end

  def run(schema, document = "{ report }", key: "user:1")
    execute_query(schema, document, root_value: root, context: { rate_limit_key: key })
  end

  # A query built and never run, as the cache holds it on a hit.
  def built(schema, document = "{ report }", key: "user:1")
    GraphQL::Query.new(schema, document, root_value: root, context: { rate_limit_key: key })
  end

  # Brings two schemas to the same balance with `before` runs, then `prepare`s both stores, runs the query on one and
  # charges it as a hit on the other.
  def twins(before: 0, cost: 40, client: "user:1", prepare: ->(_store) {}, **options)
    ran_store = limits::Store::Substitute.new
    hit_store = limits::Store::Substitute.new
    ran = schema_with(store: ran_store, **options)
    cached = schema_with(store: hit_store, **options)
    before.times { [ran, cached].each { |schema| run(schema, key: client) } }
    [ran_store, hit_store].each { |store| prepare.call(store) }
    query = built(cached, key: client)

    { result: run(ran, key: client), query: query, refusal: charge.build(cached).(query, cost), ran_store: ran_store, hit_store: hit_store }
  end

  def points_record(context)
    context.namespace(:graphql_armory)[:points]
  end

  describe "a client within its budget" do
    it "charges the recorded cost to the same bucket, with the run's records, extension and headers" do
      twin = twins(before: 1, extensions: true)
      hit = charge.result(twin[:query], "data" => data)

      expect(twin[:refusal]).to be_nil
      expect(twin[:query].context[:rate_limit_points]).to eq(key: "user:1", cost: 40, limit: 100, remaining: 20, window: 60, soft: false, limited: false)
      expect(twin[:query].context[:rate_limit_points]).to eq(twin[:result].context[:rate_limit_points])
      expect(points_record(twin[:query].context)).to eq(points_record(twin[:result].context))
      expect(hit.to_h).to eq(twin[:result].to_h)
      expect(hit.to_h["extensions"]).to eq("rateLimit" => { "cost" => 40, "limit" => 100, "remaining" => 20, "resetIn" => 48 })
      expect(limits::Points.headers(hit)).to eq(limits::Points.headers(twin[:result]))
      expect(twin[:hit_store].calls).to eq(twin[:ran_store].calls)
    end

    it "answers no extensions when the limiter announces none, as a run does" do
      twin = twins

      expect(charge.result(twin[:query], "data" => data).to_h).to eq(twin[:result].to_h)
      expect(twin[:result].to_h).to eq("data" => data)
    end

    it "records an exempt client like a run, and charges nothing" do
      twin = twins(limit: ->(_key, _query) {})

      expect([twin[:refusal], twin[:query].context[:rate_limit_points]]).to eq([nil, twin[:result].context[:rate_limit_points]])
      expect(twin[:hit_store].calls).to eq([])
    end
  end

  describe "a client over its budget" do
    it "answers the run's own RATE_LIMITED refusal, nothing from the cache, and charges nothing" do
      [true, false].each do |extensions|
        twin = twins(before: 2, extensions: extensions)

        expect(twin[:refusal]).to be_a(GraphQL::Query::Result)
        expect(twin[:refusal].to_h).to eq(twin[:result].to_h)
        expect(twin[:refusal].to_h.key?("data")).to be(false)
        expect(twin[:refusal].to_h["errors"]).to eq([{
          "message" => "Rate limit exceeded: this query costs 40 points and 20 remain (100 every 60 seconds). Retry in 12 seconds.",
          "extensions" => { "code" => "RATE_LIMITED", "cost" => 40, "remaining" => 20, "retryAfter" => 12 }
        }])
        expect(twin[:query].context[:rate_limit_points]).to eq(twin[:result].context[:rate_limit_points])
        expect(twin[:hit_store].calls).to eq(twin[:ran_store].calls)
        expect(limits::Points.headers(twin[:refusal])).to eq(limits::Points.headers(twin[:result]))
      end
    end

    it "answers the run's refusal for a query that can never run" do
      twin = twins(limit: 30)

      expect(twin[:refusal].to_h).to eq(twin[:result].to_h)
      expect(twin[:refusal].to_h["errors"].first["extensions"]).to eq("code" => "RATE_LIMITED", "cost" => 40, "limit" => 30)
    end

    it "charges and serves in soft mode, recording the overdraft, as a run does" do
      twin = twins(before: 3, soft: true)

      expect(twin[:refusal]).to be_nil
      expect(twin[:query].context[:rate_limit_points]).to include(remaining: 0, limited: true, soft: true)
      expect(twin[:query].context[:rate_limit_points]).to eq(twin[:result].context[:rate_limit_points])
      expect(twin[:hit_store].calls).to eq(twin[:ran_store].calls)
    end
  end

  describe "several keys" do
    let(:keys) { ["user:1", "ip:1"] }

    it "charges every bucket, with the run's record" do
      twin = twins(before: 1, client: keys, extensions: true)

      expect(twin[:refusal]).to be_nil
      expect(twin[:query].context[:rate_limit_points]).to eq(twin[:result].context[:rate_limit_points])
      expect(twin[:query].context[:rate_limit_points][:keys].map { |budget| budget[:remaining] }).to eq([20, 20])
      expect(charge.result(twin[:query], "data" => data).to_h).to eq(twin[:result].to_h)
      expect(twin[:hit_store].calls).to eq(twin[:ran_store].calls)
    end

    it "refuses when one bucket cannot pay, and charges none, as a run does" do
      twin = twins(client: keys, prepare: ->(store) { store.take("ip:1", cost: 90, limit: 100, window: 60, force: true) })

      expect(twin[:refusal].to_h).to eq(twin[:result].to_h)
      expect(twin[:query].context[:rate_limit_points]).to eq(twin[:result].context[:rate_limit_points])
      expect(twin[:hit_store].calls).to eq(twin[:ran_store].calls)
    end
  end

  describe "a store that fails" do
    it "lets the hit through uncharged and reports it to on_store_error, as a run does" do
      heard = []
      twin = twins(before: 1, on_store_error: ->(error, query) { heard << [error.class, query] },
                   prepare: ->(store) { store.fail_with(IOError.new("down")) })

      expect([twin[:refusal], twin[:query].context[:rate_limit_points], twin[:result].context[:rate_limit_points]]).to eq([nil, nil, nil])
      expect(heard.map(&:first)).to eq([IOError, IOError])
      expect(heard.last.last).to equal(twin[:query])
      expect(limits::Points.headers(charge.result(twin[:query], "data" => data))).to eq(limits::Points.headers(twin[:result]))
    end
  end

  describe "a key: callable that raises an ExecutionError" do
    def raising(error)
      ->(_query) { raise error }
    end

    it "refuses with RATE_LIMIT_NOT_CHARGED in hard mode, as a run does" do
      twin = twins(key: raising(GraphQL::ExecutionError.new("sign in")))

      expect(twin[:refusal].to_h).to eq(twin[:result].to_h)
      expect(twin[:refusal].to_h["errors"].map { |error| error["extensions"] }).to eq([{ "code" => "RATE_LIMIT_NOT_CHARGED" }])
      expect(twin[:query].context[:rate_limit_points]).to eq(twin[:result].context[:rate_limit_points])
    end

    it "refuses with the raised AnalysisError itself in hard mode, as a run does" do
      twin = twins(key: raising(GraphQL::AnalysisError.new("no client", extensions: { "code" => "NO_CLIENT" })))

      expect(twin[:refusal].to_h).to eq(twin[:result].to_h)
      expect(twin[:refusal].to_h["errors"].map { |error| error["message"] }).to eq(["no client"])
    end

    it "serves the hit uncharged in soft mode, recording charged: false, as a run does" do
      twin = twins(soft: true, key: raising(GraphQL::ExecutionError.new("sign in")))

      expect(twin[:refusal]).to be_nil
      expect(twin[:query].context[:rate_limit_points]).to eq(limit: nil, soft: true, limited: false, charged: false)
      expect(twin[:query].context[:rate_limit_points]).to eq(twin[:result].context[:rate_limit_points])
    end
  end

  describe "the cost a run recorded" do
    def multiplex(schema, queries)
      ArmoryEngine.next? ? schema.multiplex_next(queries) : schema.multiplex(queries)
    end

    it "is the query's own, even when a multiplex's shared context hash holds another query's record" do
      store = limits::Store::Substitute.new
      schema = schema_with(store: store)
      shared = { rate_limit_key: "user:1" }
      results = multiplex(schema, [{ query: "{ report }", context: shared, root_value: root }, { query: "{ cheap }", context: shared, root_value: root }])

      expect(results.map { |result| charge.recorded_cost(result.query) }).to eq([40, 1])
      expect(shared[:rate_limit_points]).to include(cost: 1)

      query = built(schema)
      charge.build(schema).(query, charge.recorded_cost(results.first.query))

      expect(query.context[:rate_limit_points]).to include(cost: 40, remaining: 19)
    end

    it "is unknown for a query that was not charged" do
      store = limits::Store::Substitute.new
      schema = schema_with(store: store, on_store_error: ->(_error, _query) {})
      store.fail_with(IOError.new("down"))

      expect([charge.recorded_cost(run(schema).query), charge.recorded_cost(built(schema))]).to eq([nil, nil])
    end

    it "is unknown for an invalid query, whatever it was charged" do
      expect(charge.recorded_cost(run(schema_with, "{ nope }").query)).to be_nil
    end
  end

  describe "finding the Points limiters" do
    let(:points_store) { limits::Store::Substitute.new }
    let(:other_store) { limits::Store::Substitute.new }

    it "charges nothing when built with new, which is inert" do
      inert = charge.new

      expect([inert.(built(schema_with(store: points_store)), 40), inert.limited?]).to eq([nil, false])
      expect(points_store.calls).to eq([])
    end

    it "charges only the Points limiters: Time is not charged and Concurrency takes no slot" do
      points_store = self.points_store
      other_store = self.other_store
      schema = Class.new(ArmoryEngine.base_schema) do
        query GraphQL::Armory::RateLimits::Controls::Query.example
        use GraphQL::Armory::RateLimits::Time, store: other_store, limit: 1_000, soft: false
        use GraphQL::Armory::RateLimits::Concurrency, store: other_store, limit: 1, soft: false
        use GraphQL::Armory::RateLimits::Points, store: points_store, limit: 100, soft: false
      end

      expect(charge.build(schema).(built(schema), 40)).to be_nil
      expect(points_store.calls.size).to eq(1)
      expect(other_store.calls).to eq([])
    end

    it "is not limited, and charges nothing, on a schema without a Points limiter" do
      schema = Class.new(ArmoryEngine.base_schema) { query GraphQL::Armory::RateLimits::Controls::Query.example }

      expect([charge.build(schema).(built(schema), 40), charge.build(schema).limited?]).to eq([nil, false])
    end

    it "finds a Points limiter the schema gets after the charge is built" do
      schema = Class.new(ArmoryEngine.base_schema) { query GraphQL::Armory::RateLimits::Controls::Query.example }
      built_early = charge.build(schema)
      schema.use(GraphQL::Armory::RateLimits::Points, store: points_store, limit: 100, soft: false)

      expect(built_early.limited?).to be(true)
      built_early.(built(schema), 40)
      expect(points_store.calls.size).to eq(1)
    end

    it "charges a subclass's own Points limiters for its queries" do
      parent = schema_with(store: points_store)
      child_store = other_store
      child = Class.new(parent) { use GraphQL::Armory::RateLimits::Points, store: child_store, limit: 100, soft: false }

      charge.build(parent).(built(child), 40)

      expect([points_store.calls.size, child_store.calls.size]).to eq([1, 1])
      expect(charge.build(parent).limited?(built(child))).to be(true)
    end

    it "charges every Points limiter, as a run does, and answers the run's refusal when one refuses" do
      ran = [limits::Store::Substitute.new, limits::Store::Substitute.new]
      hit = [limits::Store::Substitute.new, limits::Store::Substitute.new]
      schemas = [ran, hit].map do |(first, second)|
        Class.new(ArmoryEngine.base_schema) do
          query GraphQL::Armory::RateLimits::Controls::Query.example
          use GraphQL::Armory::RateLimits::Points, store: first, limit: 100, soft: false
          use GraphQL::Armory::RateLimits::Points, store: second, limit: 30, soft: false
        end
      end

      result = run(schemas.first)
      refusal = charge.build(schemas.last).(built(schemas.last), 40)

      expect(refusal.to_h).to eq(result.to_h)
      expect(hit.map(&:calls)).to eq(ran.map(&:calls))
    end

    it "refuses a schema that is not one" do
      expect { charge.build(Object.new) }.to raise_error(GraphQL::Armory::Caching::ConfigurationError, /GraphQL::Schema class/)
    end
  end

  describe "a cost that is not a whole number of points" do
    it "raises instead of charging a guess" do
      schema = schema_with
      [nil, -1, 1.5, "40"].each do |cost|
        expect { charge.build(schema).(built(schema), cost) }.to raise_error(ArgumentError, /cost/)
      end
    end
  end
end
