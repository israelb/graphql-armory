# frozen_string_literal: true

# `use GraphQL::Armory::RateLimits::Points` charges every query its complexity, computed before it runs, against
# a bucket of points per client that refills over a window. A query that costs more than the client has left is
# refused before any field resolves.
RSpec.describe "use GraphQL::Armory::RateLimits::Points" do
  let(:now) { [0.0] }
  let(:store) { GraphQL::Armory::RateLimits::MemoryStore.new(clock: -> { now[0] }) }
  let(:resolved) { [] }
  let(:root) do
    log = resolved
    Class.new do
      define_method(:cheap) { log << :cheap; "ok" }
      define_method(:report) { log << :report; "big" }
    end.new
  end
  # `cheap` costs 1 point, `report` costs 40.
  let(:cheap) { "{ cheap }" }
  let(:report) { "{ report }" }

  def schema_for(**options)
    query = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :cheap, String, null: false
      field :report, String, null: false, complexity: 40
    end
    store = self.store
    Class.new(ArmoryEngine.base_schema) do
      query query
      use GraphQL::Armory::RateLimits::Points, store: store, **{ limit: 100, window: 60, soft: false }.merge(options)
    end
  end

  def run(schema, query, key: "user:1", **context)
    context = context.merge(rate_limit_key: key) if key
    result = execute_query(schema, query, context: context, root_value: root)
    [result.to_h, result.context[:rate_limit_points]]
  end

  def refusals(response)
    Array(response["errors"]).map { |error| error["extensions"]&.fetch("code", nil) }
  end

  it "runs queries within the budget and records what each one cost" do
    response, info = run(schema_for, report)

    expect(response).to eq("data" => { "report" => "big" })
    expect(info).to eq(key: "user:1", cost: 40, limit: 100, remaining: 60, window: 60, soft: false, limited: false)
  end

  it "refuses a query that costs more than the client has left, running nothing and charging nothing" do
    schema = schema_for
    2.times { run(schema, report) }
    resolved.clear

    response, info = run(schema, report)

    expect([response.key?("data"), resolved, info[:remaining], info[:limited]]).to eq([false, [], 20, true])
    expect(response["errors"].first).to include(
      "message" => "Rate limit exceeded: this query costs 40 points and 20 remain (100 every 60 seconds). Retry in 12 seconds.",
      "extensions" => { "code" => "RATE_LIMITED", "cost" => 40, "remaining" => 20, "retryAfter" => 12 }
    )
    expect(run(schema, cheap).first).to eq("data" => { "cheap" => "ok" })
  end

  it "refills the bucket over the window" do
    schema = schema_for
    2.times { run(schema, report) }
    now[0] = 12.0

    expect(run(schema, report).last).to include(remaining: 0, limited: false)
  end

  it "never refills past the limit" do
    schema = schema_for
    run(schema, report)
    now[0] = 600.0

    expect(run(schema, cheap).last).to include(remaining: 99)
  end

  it "keeps a separate bucket per client" do
    schema = schema_for
    3.times { run(schema, report, key: "user:1") }

    expect(run(schema, report, key: "user:2").last).to include(remaining: 60, limited: false)
  end

  it "refuses a query that costs more than the whole limit, saying it can never run" do
    response, = run(schema_for(limit: 30), report)

    expect(response["errors"].first["message"]).to eq(
      "Rate limit exceeded: this query costs 40 points and the limit is 30 every 60 seconds, so it can never run."
    )
    expect(refusals(response)).to eq(["RATE_LIMITED"])
  end

  it "does not charge a query that fails validation" do
    schema = schema_for
    run(schema, "{ doesNotExist }")

    expect(run(schema, cheap).last).to include(remaining: 99)
  end

  it "charges a fractional complexity in whole points instead of letting it through" do
    query = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :half, String, null: false, complexity: 0.5
    end
    store = self.store
    schema = Class.new(ArmoryEngine.base_schema) do
      query query
      use GraphQL::Armory::RateLimits::Points, store: store, limit: 1, window: 60, soft: false
    end
    result = execute_query(schema, "{ a: half b: half c: half d: half }", context: { rate_limit_key: "u" }, root_value: Class.new { def half = "h" }.new)

    expect(result.to_h["errors"].first["extensions"]["code"]).to eq("RATE_LIMITED")
    expect(result.context[:rate_limit_points]).to include(cost: 2, limited: true)
  end

  it "does not hand out points when the clock goes backwards and forwards again" do
    schema = schema_for
    2.times { run(schema, report) }
    now[0] = -30.0
    run(schema, cheap)
    now[0] = 0.0

    expect(run(schema, cheap).last).to include(remaining: 18)
  end

  describe "soft mode, the default" do
    it "runs over-limit queries and records them as limited" do
      schema = schema_for(soft: true)
      2.times { run(schema, report) }

      response, info = run(schema, report)

      expect([response, info[:soft], info[:limited]]).to eq([{ "data" => { "report" => "big" } }, true, true])
    end

    it "is on when soft: is not given" do
      query = schema_for.query
      store = self.store
      default = Class.new(ArmoryEngine.base_schema) do
        query query
        use GraphQL::Armory::RateLimits::Points, store: store, limit: 1, window: 60
      end

      expect(run(default, report).last).to include(soft: true, limited: true)
    end
  end

  describe "limits per client" do
    it "takes a limit for each key, and nil for no limit" do
      limit = ->(key, _query) { key == "admin" ? nil : 50 }
      schema = schema_for(limit: limit)

      expect(run(schema, report, key: "user:1").last).to include(limit: 50, remaining: 10)
      expect(run(schema, report, key: "admin").last).to include(limit: nil, remaining: nil, limited: false)
    end

    it "raises when a limit callable answers something that is not a positive Integer or nil" do
      ["50", 0, -1, 2.5].each do |bad|
        expect { run(schema_for(limit: ->(_key, _query) { bad }), cheap) }
          .to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, /limit/)
      end
    end
  end

  describe "the client key" do
    it "raises when the context has no key, rather than letting the query through unlimited" do
      [nil, "", 42].each do |key|
        expect { run(schema_for, cheap, key: nil, **(key.nil? ? {} : { rate_limit_key: key })) }
          .to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, /rate_limit_key/)
      end
    end

    it "takes the key from a callable when given" do
      schema = schema_for(key: ->(query) { "ip:#{query.context[:ip]}" })

      expect(run(schema, cheap, key: nil, ip: "10.0.0.1").last).to include(key: "ip:10.0.0.1")
    end
  end

  describe "when the store fails" do
    let(:broken) { Class.new { def take(*, **) = raise(IOError, "connection refused") }.new }

    it "lets the query run and reports the error to the hook" do
      seen = []
      schema = schema_for(store: broken, on_store_error: ->(error, _query) { seen << error.message })

      expect([run(schema, cheap).first, seen]).to eq([{ "data" => { "cheap" => "ok" } }, ["connection refused"]])
    end

    it "raises on a store answer that is not [true or false, Integer], instead of reading it as taken" do
      [[0, 0], true, "no", [true, "x"], nil, [false], [nil, nil], [true, -1]].each do |answer|
        store = Class.new { define_method(:take) { |_key, cost:, limit:, window:, force:| answer } }.new

        expect { run(schema_for(store: store), report) }.to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, /store/)
      end
      expect(resolved).to eq([])
    end

    it "warns by default" do
      expect { run(schema_for(store: broken), cheap) }.to output(/connection refused/).to_stderr
    end
  end

  describe "what it refuses at boot" do
    def refused(pattern, &block)
      expect(&block).to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, pattern)
    end

    it "refuses a bad limit, window, soft or store" do
      refused(/limit/) { schema_for(limit: 0) }
      refused(/limit/) { schema_for(limit: "100") }
      refused(/limit/) { schema_for(limit: nil) }
      refused(/window/) { schema_for(window: 0) }
      refused(/window/) { schema_for(window: "60") }
      refused(/soft/) { schema_for(soft: "no") }
      refused(/store/) { schema_for(store: Object.new) }
      refused(/store/) { schema_for(store: Class.new { def take(key, cost:, limit:, window:) = [true, 0] }.new) }
      refused(/window/) { schema_for(window: Float::INFINITY) }
      refused(/key/) { schema_for(key: "user") }
      refused(/on_store_error/) { schema_for(on_store_error: "log") }
    end
  end
end
