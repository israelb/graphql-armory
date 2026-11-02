# frozen_string_literal: true

# A client that rotates one identity keeps the others: a query can draw from several buckets at once.
RSpec.describe "Rate limits: several keys per query" do
  let(:limits) { GraphQL::Armory::RateLimits }
  let(:store) { limits::Store::Substitute.new }
  let(:resolved) { [] }
  let(:root) { limits::Controls::Root.example(resolved) }
  let(:keys) { ["user:1", "ip:1"] }

  def schema_with(limiter, **options)
    query_type = limits::Controls::Query.example
    Class.new(ArmoryEngine.base_schema) do
      query query_type
      use limiter, **options
    end
  end

  def run(schema, document = "{ report }", key: keys)
    execute_query(schema, document, root_value: root, context: { rate_limit_key: key })
  end

  def balance(key, limit, window: 60)
    store.take(key, cost: 0, limit: limit, window: window, force: false).last
  end

  def spend(key, cost, limit, window: 60)
    store.take(key, cost: cost, limit: limit, window: window, force: true)
  end

  describe "the keys" do
    let(:schema) { schema_with(limits::Points, store: store, limit: 100, soft: false) }

    it "refuses what is not a list of non-empty Strings, and never runs it" do
      [[], [""], ["a", nil], ["a", 1], %w[a a], %w[a b c d e f]].each do |bad|
        expect { run(schema, key: bad) }.to raise_error(limits::ConfigurationError, /key/)
      end
      expect(resolved).to be_empty
    end

    it "takes a frozen list, from a key: callable too" do
      callable = schema_with(limits::Points, store: store, limit: 100, soft: false, key: ->(_query) { %w[a b].freeze })

      expect(run(callable, key: nil).dig("data", "report")).to eq("big")
      expect(balance("a", 100)).to eq(60)
      expect(balance("b", 100)).to eq(60)
    end
  end

  describe "Points" do
    let(:schema) { schema_with(limits::Points, store: store, limit: 100, soft: false) }

    it "charges every key once" do
      expect(run(schema).dig("data", "report")).to eq("big")

      expect(resolved).to eq([:report])
      expect(balance("user:1", 100)).to eq(60)
      expect(balance("ip:1", 100)).to eq(60)
    end

    it "refuses when any key lacks the points, charges none of them, and runs nothing" do
      spend("ip:1", 90, 100)
      response = run(schema)

      expect(response["errors"].first.dig("extensions", "code")).to eq("RATE_LIMITED")
      expect(response["errors"].first.dig("extensions", "remaining")).to eq(10)
      expect(resolved).to be_empty
      expect(balance("user:1", 100)).to eq(100)
      expect(balance("ip:1", 100)).to eq(10)
    end

    it "never puts a key in what the client sees" do
      spend("ip:1", 90, 100)

      expect(run(schema).to_h.to_s).not_to include("ip:1", "user:1")
    end

    it "asks limit: once per key, and a nil answer leaves that key out" do
      asked = []
      limit = lambda do |key, _query|
        asked << key
        key.start_with?("ip:") ? nil : 100
      end
      with_nil = schema_with(limits::Points, store: store, limit: limit, soft: false)

      expect(run(with_nil).dig("data", "report")).to eq("big")
      expect(asked).to eq(keys)
      expect(balance("user:1", 100)).to eq(60)
      expect(store.calls.map { |call| call[1] }.uniq).to eq(["user:1"])
    end

    it "tells when a key can never pay, over a key that only has to wait" do
      limit = ->(key, _query) { key == "ip:1" ? 10 : 100 }
      spend("user:1", 99, 100)
      response = run(schema_with(limits::Points, store: store, limit: limit, soft: false))

      expect(response["errors"].first["message"]).to include("can never run")
      expect(response["errors"].first.dig("extensions", "limit")).to eq(10)
    end

    it "gives the longest wait, whichever key has the fewest points" do
      limit = ->(key, _query) { key == "ip:1" ? 41 : 1_000 }
      spend("user:1", 999, 1_000)
      spend("ip:1", 40, 41)
      response = run(schema_with(limits::Points, store: store, limit: limit, soft: false))

      expect(response["errors"].first.dig("extensions", "retryAfter")).to eq(58)
    end

    it "refuses on the Null store" do
      expect(run(schema_with(limits::Points, store: limits::Store::Null.new, limit: 100, soft: false))["errors"]).not_to be_nil
      expect(resolved).to be_empty
    end

    it "in soft mode charges all, refuses nothing, and marks what it would have refused" do
      spend("ip:1", 90, 100)
      response = run(schema_with(limits::Points, store: store, limit: 100, soft: true))

      expect(response.dig("data", "report")).to eq("big")
      expect(balance("user:1", 100)).to eq(60)
      expect(response.context[:rate_limit_points]).to include(limited: true, key: "ip:1")
    end

    it "records each key, and the binding one as before" do
      spend("ip:1", 50, 100)
      response = run(schema)

      expect(response.dig("data", "report")).to eq("big")
      expect(response.context[:rate_limit_points]).to include(key: "ip:1", limit: 100, remaining: 10)
      expect(response.context[:rate_limit_points][:keys]).to contain_exactly(
        { key: "user:1", limit: 100, remaining: 60 }, { key: "ip:1", limit: 100, remaining: 10 }
      )
      expect(limits::Points.headers(response)["RateLimit-Remaining"]).to eq("10")
    end

    it "lets the query through when the store fails on every key, and calls the hook for each" do
      failures = []
      store.fail_with(IOError.new("down"))
      failing = schema_with(limits::Points, store: store, limit: 100, soft: false, on_store_error: ->(error, _query) { failures << error.class })

      expect(run(failing).dig("data", "report")).to eq("big")
      expect(failures).to eq([IOError, IOError])
    end

    it "keeps a single key as it was: one store call and no keys in the record" do
      response = run(schema, key: "user:1")

      expect(store.calls.size).to eq(1)
      expect(response.context[:rate_limit_points]).not_to have_key(:keys)
    end

    it "treats a list of one as a list" do
      expect(run(schema, key: ["user:1"]).context[:rate_limit_points][:keys]).to eq([{ key: "user:1", limit: 100, remaining: 60 }])
    end
  end

  describe "a store that fails on one key" do
    def failing_on(bad)
      original = store.method(:take)
      store.define_singleton_method(:take) do |key, cost:, limit:, window:, force: false|
        raise IOError, "down" if key == bad

        original.call(key, cost: cost, limit: limit, window: window, force: force)
      end
    end

    it "keeps a refusal from another key, on Points" do
      spend("user:1", 100, 100)
      failing_on("ip:dead")
      schema = schema_with(limits::Points, store: store, limit: 100, soft: false, on_store_error: ->(_error, _query) {})

      expect(run(schema, key: ["ip:dead", "user:1"])["errors"]).not_to be_nil
      expect(resolved).to be_empty
    end

    it "charges the healthy keys, on Points" do
      failing_on("ip:dead")
      heard = []
      schema = schema_with(limits::Points, store: store, limit: 100, soft: false, on_store_error: ->(error, _query) { heard << error.class })

      expect(run(schema, key: ["ip:dead", "user:1"]).dig("data", "report")).to eq("big")
      expect(balance("user:1", 100)).to eq(60)
      expect(heard).to eq([IOError])
    end

    it "keeps a refusal from another key, on Time" do
      clock = limits::Clock::Substitute.new
      spend("user:1", 1_000, 1_000)
      failing_on("ip:dead")
      schema = schema_with(limits::Time, store: store, limit: 1_000, soft: false, clock: clock, on_store_error: ->(_error, _query) {})

      expect(run(schema, key: ["ip:dead", "user:1"])["errors"]).not_to be_nil
      expect(resolved).to be_empty
    end

    it "keeps a refusal from another key, on Concurrency" do
      store.occupy("user:1")
      original = store.method(:acquire)
      store.define_singleton_method(:acquire) do |key, token:, limit:, ttl:, force: false|
        raise IOError, "down" if key == "ip:dead"

        original.call(key, token: token, limit: limit, ttl: ttl, force: force)
      end
      schema = schema_with(limits::Concurrency, store: store, limit: 1, soft: false, on_store_error: ->(_error, _query) {})

      expect(run(schema, key: ["ip:dead", "user:1"])["errors"]).not_to be_nil
      expect(resolved).to be_empty
    end

    it "charges every healthy key on Time when a hook raises on one, and hears it once" do
      clock = limits::Clock::Substitute.new
      time_root = limits::Controls::Time.example(clock, resolved, seconds: 0.25)
      original = store.method(:take)
      store.define_singleton_method(:take) do |key, cost:, limit:, window:, force: false|
        raise IOError, "down" if key == "ip:dead" && cost.positive?

        original.call(key, cost: cost, limit: limit, window: window, force: force)
      end
      heard = []
      hook = lambda do |error, _query|
        heard << error.class
        raise "hook"
      end
      schema = schema_with(limits::Time, store: store, limit: 1_000, soft: false, clock: clock, on_store_error: hook)

      expect do
        execute_query(schema, "{ report }", root_value: time_root, context: { rate_limit_key: ["user:1", "ip:dead", "ip:2"] })
      end.to raise_error(RuntimeError, "hook")
      expect(heard).to eq([IOError])
      expect(original.call("user:1", cost: 0, limit: 1_000, window: 60, force: false).last).to eq(750)
      expect(original.call("ip:2", cost: 0, limit: 1_000, window: 60, force: false).last).to eq(750)
    end
  end

  it "refuses two keys that differ only in encoding: they are one bucket on Redis" do
    schema = schema_with(limits::Points, store: store, limit: 100, soft: false)

    expect { run(schema, key: ["é", "é".b]) }.to raise_error(limits::ConfigurationError)
  end

  describe "Concurrency" do
    let(:schema) { schema_with(limits::Concurrency, store: store, limit: 1, soft: false) }

    it "takes a slot per key and gives them all back" do
      seen = []
      field_root = Class.new do
        define_method(:report) { seen << [store_ref.held("user:1"), store_ref.held("ip:1")]; "big" }
        define_method(:store_ref) { @store_ref }
        attr_writer :store_ref
      end.new
      field_root.store_ref = store

      query_type = limits::Controls::Query.example
      limiter = limits::Concurrency
      options = { store: store, limit: 1, soft: false }
      with_root = Class.new(ArmoryEngine.base_schema) do
        query query_type
        use limiter, **options
      end
      execute_query(with_root, "{ report }", root_value: field_root, context: { rate_limit_key: keys })

      expect(seen).to eq([[1, 1]])
      expect(store.held("user:1")).to eq(0)
      expect(store.held("ip:1")).to eq(0)
    end

    it "refuses when any key is full, and leaves no slot on the others" do
      store.occupy("ip:1")
      response = run(schema)

      expect(response["errors"].first.dig("extensions", "code")).to eq("RATE_LIMITED")
      expect(resolved).to be_empty
      expect(store.held("user:1")).to eq(0)
      expect(store.held("ip:1")).to eq(1)
    end

    it "gives back the slots it took when the store then answers nonsense" do
      answers = store
      limit = ->(_key, _query) { 1 }
      schema = schema_with(limits::Concurrency, store: answers, limit: limit, soft: false)
      answers.answer(:acquire, [true, "nonsense"])

      expect { run(schema) }.to raise_error(limits::ConfigurationError)
    end

    it "attempts every release, even when a hook raises on one" do
      store.occupy("c")
      released = []
      hook = ->(error, _query) { released << error.class; raise error }
      schema = schema_with(limits::Concurrency, store: store, limit: 1, soft: false, on_store_error: hook)
      store.fail_with(IOError.new("down"), on: :release, times: 1)

      expect { run(schema, key: %w[a b c]) }.to raise_error(IOError)
      expect(released).to eq([IOError])
      expect(store.calls.count { |method, _key, _args| method == :release }).to eq(2)
    end

    it "keeps both limiters' slots when a schema uses two" do
      query_type = limits::Controls::Query.example
      limiter = limits::Concurrency
      first = store
      second = limits::Store::Substitute.new
      schema = Class.new(ArmoryEngine.base_schema) do
        query query_type
        use limiter, store: first, limit: 1, soft: false
        use limiter, store: second, limit: 1, soft: false
      end
      run(schema, key: "user:1")

      expect(first.held("user:1")).to eq(0)
      expect(second.held("user:1")).to eq(0)
    end

    it "in soft mode takes them all and refuses nothing" do
      store.occupy("ip:1")
      response = run(schema_with(limits::Concurrency, store: store, limit: 1, soft: true))

      expect(response.dig("data", "report")).to eq("big")
      expect(response.context[:rate_limit_concurrency]).to include(limited: true, key: "ip:1")
    end
  end

  describe "Time" do
    let(:clock) { limits::Clock::Substitute.new }
    let(:root) { limits::Controls::Time.example(clock, resolved, seconds: 0.25) }
    let(:schema) { schema_with(limits::Time, store: store, limit: 1_000, soft: false, clock: clock) }

    it "charges every key the whole time" do
      expect(run(schema).dig("data", "report")).to eq("big")

      expect(balance("user:1", 1_000)).to eq(750)
      expect(balance("ip:1", 1_000)).to eq(750)
    end

    it "refuses when any key has nothing left, and charges none" do
      spend("ip:1", 1_000, 1_000)
      response = run(schema)

      expect(response["errors"].first.dig("extensions", "code")).to eq("RATE_LIMITED")
      expect(resolved).to be_empty
      expect(balance("user:1", 1_000)).to eq(1_000)
    end

    it "attempts every key's charge when the store fails on one" do
      failures = []
      failing = schema_with(limits::Time, store: store, limit: 1_000, soft: false, clock: clock, on_store_error: ->(error, _query) { failures << error.class })
      original_take = store.method(:take)
      store.define_singleton_method(:take) do |key, cost:, limit:, window:, force: false|
        raise IOError, "down" if key == "user:1" && cost.positive?

        original_take.call(key, cost: cost, limit: limit, window: window, force: force)
      end

      expect(run(failing).dig("data", "report")).to eq("big")
      expect(failures).to eq([IOError])
      expect(original_take.call("ip:1", cost: 0, limit: 1_000, window: 60, force: false).last).to eq(750)
    end

    it "records each key after the charge, and a single key as before" do
      spend("ip:1", 500, 1_000)
      response = run(schema)

      expect(response.context[:rate_limit_time]).to include(key: "ip:1", remaining: 250)
      expect(response.context[:rate_limit_time][:keys]).to contain_exactly(
        { key: "user:1", limit: 1_000, remaining: 750 }, { key: "ip:1", limit: 1_000, remaining: 250 }
      )
      expect(run(schema, key: "single").context[:rate_limit_time]).not_to have_key(:keys)
    end
  end
end
