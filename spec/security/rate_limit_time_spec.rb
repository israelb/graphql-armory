# frozen_string_literal: true

# `use GraphQL::Armory::RateLimits::Time` charges each client the wall-clock milliseconds its operations took. A
# client with no milliseconds left is refused before any field resolves; every operation that ran is charged,
# even when it raised.
RSpec.describe "use GraphQL::Armory::RateLimits::Time" do
  let(:store) { GraphQL::Armory::RateLimits::Store::Substitute.new }
  let(:clock) { GraphQL::Armory::RateLimits::Clock::Substitute.new }
  let(:resolved) { [] }
  # Every field takes a quarter of a second on `clock`.
  let(:root) { GraphQL::Armory::RateLimits::Controls::Time.example(clock, resolved, seconds: 0.25) }

  def schema_for(**options)
    query = GraphQL::Armory::RateLimits::Controls::Query.example
    store = self.store
    clock = self.clock
    Class.new(ArmoryEngine.base_schema) do
      query query
      use GraphQL::Armory::RateLimits::Time, **{ store: store, clock: clock, limit: 1_000, window: 60, soft: false }.merge(options)
    end
  end

  def run(schema, query = "{ cheap }", key: "user:1", **context)
    context = context.merge(rate_limit_key: key) if key
    result = execute_query(schema, query, context: context, root_value: root)
    [result.to_h, result.context[:rate_limit_time]]
  end

  def multiplex(schema, count, context: nil)
    queries = Array.new(count) { { query: "{ cheap }", context: context || { rate_limit_key: "user:1" }, root_value: root } }
    ArmoryEngine.next? ? schema.multiplex_next(queries) : schema.multiplex(queries)
  end

  # The milliseconds the client has left, read without charging anything.
  def balance(key = "user:1", limit: 1_000)
    store.take(key, cost: 0, limit: limit, window: 60).last
  end

  def drain(key = "user:1", limit: 1_000)
    store.take(key, cost: limit, limit: limit, window: 60, force: true)
  end

  def charges
    store.calls.select { |method, _key, arguments| method == :take && arguments[:force] }.map { |_method, key, arguments| [key, arguments[:cost]] }
  end

  it "runs an operation under the limit and charges the milliseconds it took" do
    response, = run(schema_for)

    expect(response).to eq("data" => { "cheap" => "ok" })
    expect(charges).to eq([["user:1", 250]])
    expect(balance).to eq(750)
  end

  it "refuses an operation when the client has no milliseconds left, running nothing" do
    drain
    response, info = run(schema_for)

    expect([response.key?("data"), resolved, info[:limited]]).to eq([false, [], true])
    expect(response["errors"].first).to include(
      "message" => "Rate limit exceeded: this client used its 1000 ms of processing time every 60 seconds. Retry in 1 seconds.",
      "extensions" => { "code" => "RATE_LIMITED", "limit" => 1_000, "retryAfter" => 1 }
    )
  end

  it "charges a refused operation nothing" do
    drain
    run(schema_for)

    expect([charges, clock.now]).to eq([[["user:1", 1_000]], 0.0])
  end

  it "asks for the balance before running with a take of zero that charges nothing" do
    run(schema_for)

    expect(store.calls.first).to eq([:take, "user:1", { cost: 0, limit: 1_000, window: 60, force: false }])
  end

  it "charges the milliseconds of an operation that raises" do
    expect { run(schema_for, "{ broken }") }.to raise_error(IOError)

    expect(charges).to eq([["user:1", 250]])
  end

  it "lets the client in again once the milliseconds refill" do
    drain
    store.now = 60.0

    expect(run(schema_for).first).to eq("data" => { "cheap" => "ok" })
  end

  it "never takes the balance below zero: the operation that spends the last milliseconds finishes, the next is refused" do
    schema = schema_for(limit: 100)
    first, = run(schema)
    second, = run(schema)

    expect([first, second.key?("errors"), balance(limit: 100)]).to eq([{ "data" => { "cheap" => "ok" } }, true, 0])
  end

  it "measures wall-clock time, so waiting on a slow dependency is charged like computing" do
    slow = GraphQL::Armory::RateLimits::Controls::Time.example(clock, resolved, seconds: 2.0)
    execute_query(schema_for, "{ cheap }", context: { rate_limit_key: "user:1" }, root_value: slow)

    expect(charges).to eq([["user:1", 2_000]])
  end

  it "keeps separate balances per client" do
    drain("user:1")

    expect(run(schema_for, key: "user:2").first).to eq("data" => { "cheap" => "ok" })
  end

  it "splits the time of a multiplex equally among its queries" do
    multiplex(schema_for, 2)

    expect(charges).to eq([["user:1", 250], ["user:1", 250]])
  end

  it "charges every query of a multiplex that share one context hash, as batched requests do" do
    multiplex(schema_for, 2, context: { rate_limit_key: "user:1" })

    expect(charges.size).to eq(2)
  end

  it "charges a client with no limit nothing, and asks the store nothing" do
    schema = schema_for(limit: ->(key, _query) { key == "admin" ? nil : 1_000 })

    expect([run(schema, key: "admin").first, store.calls]).to eq([{ "data" => { "cheap" => "ok" } }, []])
  end

  it "refuses to measure a query that brings its own trace, since it could never charge it" do
    expect { run(schema_for, trace: GraphQL::Tracing::Trace.new) }
      .to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, /trace/)
  end

  it "raises when the context has no key" do
    expect { run(schema_for, key: nil) }.to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, /rate_limit_key/)
  end

  describe "what it tells the client" do
    def result_for(schema, key: "user:1")
      execute_query(schema, "{ cheap }", context: { rate_limit_key: key }, root_value: root)
    end

    it "records the milliseconds charged and what is left once the operation ends" do
      _response, info = run(schema_for)

      expect(info).to eq(key: "user:1", limit: 1_000, remaining: 750, elapsed: 250, window: 60, soft: false, limited: false)
    end

    it "records a refused operation with nothing charged" do
      drain
      _response, info = run(schema_for)

      expect(info).to eq(key: "user:1", limit: 1_000, remaining: 0, elapsed: nil, window: 60, soft: false, limited: true)
    end

    it "records the share of each query of a multiplex" do
      results = multiplex(schema_for, 2)

      expect(results.map { |result| result.context[:rate_limit_time][:elapsed] }).to eq([250, 250])
    end

    it "adds nothing to the response unless asked" do
      expect(result_for(schema_for).to_h.key?("extensions")).to be(false)
    end

    it "adds the budget to the response extensions when asked" do
      response = result_for(schema_for(extensions: true)).to_h

      expect(response["extensions"]).to eq(
        "rateLimitTime" => { "limit" => 1_000, "remaining" => 750, "elapsed" => 250, "resetIn" => 15 }
      )
    end

    it "gives the HTTP headers for the budget" do
      expect(GraphQL::Armory::RateLimits::Time.headers(result_for(schema_for))).to eq(
        "RateLimit-Time-Limit" => "1000", "RateLimit-Time-Remaining" => "750", "RateLimit-Time-Reset" => "15"
      )
    end

    it "gives no headers to a client with no limit" do
      schema = schema_for(limit: ->(_key, _query) { nil })

      expect(GraphQL::Armory::RateLimits::Time.headers(result_for(schema))).to eq({})
    end
  end

  describe "several limiters on one schema" do
    it "keeps each limiter's own store, key and limit: the second never replaces the first" do
      other = GraphQL::Armory::RateLimits::Store::Substitute.new
      schema = schema_for
      schema.use(GraphQL::Armory::RateLimits::Time, store: other, clock: clock, limit: 100, soft: false, key: ->(_query) { "ip:1" })

      responses = Array.new(3) { run(schema).first }

      expect(responses.map { |response| response.key?("errors") }).to eq([false, true, true])
      # The refused runs reach the first limiter too (graphql-ruby runs every analyzer) and cost it 0 ms.
      expect(charges).to eq([["user:1", 250], ["user:1", 0], ["user:1", 0]])
      expect(other.calls.select { |_method, _key, arguments| arguments[:force] }.map { |_method, key, arguments| [key, arguments[:cost]] })
        .to eq([["ip:1", 250]])
    end
  end

  describe "a clock that does not answer a finite number" do
    def clock_answering(*readings)
      -> { readings.size > 1 ? readings.shift : readings.first }
    end

    it "is refused at boot instead of letting operations run uncharged" do
      [nil, "1", Float::NAN, Float::INFINITY].each do |reading|
        expect { schema_for(clock: -> { reading }) }.to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, /clock/)
      end
    end

    it "stops an operation before it runs when the clock breaks after boot" do
      schema = schema_for(clock: clock_answering(0.0, "later"))

      expect { run(schema) }.to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, /clock/)
      expect(resolved).to eq([])
    end

    it "raises when the clock breaks while the operation runs, rather than charging nothing quietly" do
      schema = schema_for(clock: clock_answering(0.0, 0.0, nil))

      expect { run(schema) }.to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, /clock/)
    end

    it "charges nothing when the clock stands still or goes backwards" do
      schema = schema_for(clock: clock_answering(5.0, 5.0, 4.0))
      run(schema)

      expect(charges).to eq([["user:1", 0]])
    end
  end

  it "carries the time of a query with no limit on the limited queries of its multiplex" do
    schema = schema_for(limit: ->(key, _query) { key == "admin" ? nil : 1_000 })
    queries = %w[admin u].map { |key| { query: "{ cheap }", context: { rate_limit_key: key }, root_value: root } }
    ArmoryEngine.next? ? schema.multiplex_next(queries) : schema.multiplex(queries)

    expect(charges).to eq([["u", 500]])
  end

  describe "soft mode, the default" do
    it "runs operations with no milliseconds left, charges them and records them as limited" do
      query = GraphQL::Armory::RateLimits::Controls::Query.example
      store = self.store
      clock = self.clock
      schema = Class.new(ArmoryEngine.base_schema) do
        query query
        use GraphQL::Armory::RateLimits::Time, store: store, clock: clock, limit: 1_000
      end
      drain

      response, info = run(schema)

      expect([response, info[:soft], info[:limited], charges.last]).to eq([{ "data" => { "cheap" => "ok" } }, true, true, ["user:1", 250]])
    end
  end

  describe "when the store fails" do
    it "lets the operation run when the balance cannot be read, and reports the error" do
      store.fail_with(IOError.new("connection refused"), on: :take)
      seen = []
      schema = schema_for(on_store_error: ->(error, _query) { seen << error.message })

      expect([run(schema).first, seen]).to eq([{ "data" => { "cheap" => "ok" } }, ["connection refused", "connection refused"]])
    end

    it "never raises into the query when the charge fails" do
      store.fail_with(IOError.new("flaky"), on: :take, times: 2)
      seen = []
      schema = schema_for(on_store_error: ->(error, _query) { seen << error.message })

      expect(run(schema).first).to eq("data" => { "cheap" => "ok" })
      expect(seen).to eq(["flaky", "flaky"])
    end

    it "raises on a balance that is not [true or false, Integer]" do
      [[0, 1], nil, [true, "1"]].each do |answer|
        store.answer(:take, answer)

        expect { run(schema_for) }.to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, /store/)
      end
    end
  end

  describe "the object itself" do
    it "refuses every query when nothing is wired" do
      time = GraphQL::Armory::RateLimits::Time.new
      query = GraphQL::Armory::RateLimits::Controls::Query.example
      schema = Class.new(ArmoryEngine.base_schema) { query query }
      time.install(schema)

      response, = run(schema)

      expect([response.key?("data"), resolved]).to eq([false, []])
      expect(response["errors"].first["extensions"]).to include("code" => "RATE_LIMITED")
    end
  end

  describe "what it refuses at boot" do
    def refused(pattern, &block)
      expect(&block).to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, pattern)
    end

    it "refuses a bad limit, window, soft, clock or store" do
      refused(/limit/) { schema_for(limit: 0) }
      refused(/limit/) { schema_for(limit: nil) }
      refused(/window/) { schema_for(window: 0) }
      refused(/window/) { schema_for(window: Float::INFINITY) }
      refused(/soft/) { schema_for(soft: nil) }
      refused(/clock/) { schema_for(clock: 5) }
      refused(/extensions/) { schema_for(extensions: "yes") }
      refused(/store/) { schema_for(store: Object.new) }
      refused(/store/) { schema_for(store: Class.new { def take(_key, cost:, limit:, window:) = [true, 1] }.new) }
    end
  end
end
