# frozen_string_literal: true

# graphql-ruby discards an ExecutionError raised during analysis and runs the query. A limiter that had not answered
# yet must still decide, and a limiter's refusal already given must survive.
RSpec.describe "a raise during analysis, with rate limits" do
  limits = GraphQL::Armory::RateLimits
  error_class = GraphQL::ExecutionError

  let(:store) { limits::Store::Substitute.new }
  let(:resolved) { [] }
  let(:root) { limits::Controls::Root.example(resolved) }
  let(:query_type) do
    Class.new(limits::Controls::Query.example) do
      field :guarded, String, null: false, method: :cheap, complexity: ->(_context, _arguments, _child) { raise error_class, "lambda says no" }
    end
  end

  define_method(:raiser) do |error = error_class|
    Class.new(GraphQL::Analysis::Analyzer) { define_method(:result) { raise error, "analyzer says no" } }
  end

  define_method(:schema_with) do |&setup|
    query = query_type
    Class.new(ArmoryEngine.base_schema) do
      query query
      class_exec(&setup)
    end
  end

  define_method(:run) do |schema, document = "{ cheap }", key: "user:1"|
    execute_query(schema, document, context: key ? { rate_limit_key: key } : {}, root_value: root)
  end

  define_method(:codes) do |result|
    Array(result.to_h["errors"]).map { |error| error.dig("extensions", "code") }
  end

  define_method(:left) do |key = "user:1", prefix: ""|
    store.take("#{prefix}#{key}", cost: 0, limit: 100, window: 60, force: false).last
  end

  context "when complexity itself raises, so Points can never count" do
    it "refuses a hard limiter's query, whatever the order of the fields" do
      store = self.store
      schema = schema_with { use limits::Points, store: store, limit: 100, window: 60, soft: false }

      ["{ guarded cheap }", "{ cheap guarded }"].each do |document|
        result = run(schema, document)

        expect(codes(result)).to eq(["RATE_LIMIT_NOT_CHARGED"])
        expect(result.to_h).not_to have_key("data")
      end
      expect(resolved).to eq([])
    end

    it "does not show the raised message" do
      store = self.store
      schema = schema_with { use limits::Points, store: store, limit: 100, window: 60, soft: false }

      expect(run(schema, "{ guarded }").to_h.to_s).not_to include("lambda says no")
    end

    it "lets a soft limiter's query run and records it was not charged" do
      store = self.store
      schema = schema_with { use limits::Points, store: store, limit: 100, window: 60, soft: true }

      result = run(schema, "{ guarded }")

      expect(resolved).to eq([:cheap])
      expect(result.context[:rate_limit_points]).to include(charged: false, limit: nil, limited: false)
      expect(limits::Points.headers(result)).to eq({})
    end

    it "lets a client with no limit run" do
      store = self.store
      schema = schema_with { use limits::Points, store: store, limit: ->(_key, _query) {}, window: 60, soft: false }

      run(schema, "{ guarded }")

      expect(resolved).to eq([:cheap])
    end

    it "lets several keys with no limit run" do
      store = self.store
      schema = schema_with { use limits::Points, store: store, limit: ->(_key, _query) {}, window: 60, soft: false }

      execute_query(schema, "{ guarded }", context: { rate_limit_key: %w[a b] }, root_value: root)

      expect(resolved).to eq([:cheap])
    end

    it "refuses when asking for the limit raises too" do
      store = self.store
      schema = schema_with { use limits::Points, store: store, limit: ->(_key, _query) { raise error_class, "no" }, window: 60, soft: false }

      expect(codes(run(schema, "{ guarded }"))).to eq(["RATE_LIMIT_NOT_CHARGED"])
      expect(resolved).to eq([])
    end

    it "raises for a query with no key, as every other query does" do
      store = self.store
      schema = schema_with { use limits::Points, store: store, limit: 100, window: 60, soft: false }

      expect { run(schema, "{ guarded }", key: nil) }.to raise_error(limits::ConfigurationError, /no client key/)
    end
  end

  context "when another analyzer raises" do
    it "still charges Points when it sits before Points" do
      store = self.store
      other = raiser
      schema = schema_with do
        query_analyzer other
        use limits::Points, store: store, limit: 100, window: 60, soft: false
      end

      result = run(schema)

      expect(resolved).to eq([:cheap])
      expect(codes(result)).to eq([])
      expect(left).to eq(99)
    end

    it "charges once when it sits after Points" do
      store = self.store
      other = raiser
      schema = schema_with do
        use limits::Points, store: store, limit: 100, window: 60, soft: false
        query_analyzer other
      end

      run(schema)

      expect(resolved).to eq([:cheap])
      expect(left).to eq(99)
    end

    it "refuses an exhausted client when it sits before Points" do
      store = self.store
      other = raiser
      schema = schema_with do
        query_analyzer other
        use limits::Points, store: store, limit: 100, window: 60, soft: false
      end
      store.take("user:1", cost: 100, limit: 100, window: 60, force: true)

      expect(codes(run(schema))).to eq(["RATE_LIMITED"])
      expect(resolved).to eq([])
    end

    it "asks the second Points when it sits between the two" do
      first = limits::MemoryStore.new
      second = store
      other = raiser
      schema = schema_with do
        use limits::Points, store: first, limit: 100, window: 60, soft: false
        query_analyzer other
        use limits::Points, store: second, limit: 100, window: 60, soft: false
      end
      second.take("user:1", cost: 100, limit: 100, window: 60, force: true)

      expect(codes(run(schema))).to eq(["RATE_LIMITED"])
      expect(resolved).to eq([])
    end

    it "keeps a refusal Time gave before the raise" do
      store = self.store
      other = raiser
      schema = schema_with do
        use limits::Time, store: store, limit: 100, window: 60, soft: false
        query_analyzer other
      end
      store.take(limits::Time.bucket_key("user:1"), cost: 100, limit: 100, window: 60, force: true)

      expect(codes(run(schema))).to eq(["RATE_LIMITED"])
      expect(resolved).to eq([])
    end

    it "asks Time when it sits before Time, so the client is charged the time" do
      clock = limits::Clock::Substitute.new
      store = self.store
      other = raiser
      schema = schema_with do
        query_analyzer other
        use limits::Time, store: store, limit: 1000, window: 60, soft: false, clock: clock
      end
      timed = limits::Controls::Time.example(clock, resolved, seconds: 0.25)

      result = execute_query(schema, "{ cheap }", context: { rate_limit_key: "user:1" }, root_value: timed)

      expect(resolved).to eq([:cheap])
      expect(result.context[:rate_limit_time]).to include(elapsed: 250)
    end

    it "keeps a refusal Concurrency gave before the raise" do
      store = self.store
      other = raiser
      schema = schema_with do
        use limits::Concurrency, store: store, limit: 1, soft: false
        query_analyzer other
      end
      store.occupy("user:1")

      expect(codes(run(schema))).to eq(["RATE_LIMITED"])
      expect(resolved).to eq([])
    end

    it "takes and gives back a Concurrency slot when it sits before Concurrency" do
      store = self.store
      other = raiser
      schema = schema_with do
        query_analyzer other
        use limits::Concurrency, store: store, limit: 1, soft: false
      end

      result = run(schema)

      expect(resolved).to eq([:cheap])
      expect(result.context[:rate_limit_concurrency]).to include(limit: 1, limited: false)
      expect(store.held("user:1")).to eq(0)
    end

    it "keeps a validation timeout's refusal, with a hard limiter that could not answer" do
      store = self.store
      other = raiser(GraphQL::Analysis::TimeoutError)
      slow = Class.new(limits::Controls::Query.example) do
        field :late, String, null: false, method: :cheap, complexity: ->(_context, _arguments, _child) { raise GraphQL::Analysis::TimeoutError }
      end
      schema = Class.new(ArmoryEngine.base_schema) do
        query slow
        query_analyzer other
        use limits::Points, store: store, limit: 100, window: 60, soft: false
      end

      result = run(schema, "{ late }")

      expect(result.to_h).not_to have_key("data")
      expect(resolved).to eq([])
    end

    it "decides per query in a multiplex" do
      store = self.store
      schema = schema_with { use limits::Points, store: store, limit: 100, window: 60, soft: false }
      queries = [{ query: "{ guarded }" }, { query: "{ cheap }" }].map { |query| query.merge(context: { rate_limit_key: "user:1" }, root_value: root) }

      results = ArmoryEngine.next? ? GraphQL::Execution::Next.run_all(schema, queries, context: {}) : schema.multiplex(queries)

      expect(results.map { |result| codes(result) }).to eq([["RATE_LIMIT_NOT_CHARGED"], []])
      expect(resolved).to eq([:cheap])
    end
  end

  context "outside the analysis of an execution" do
    it "takes no slot and charges nothing for an analysis the app runs itself" do
      store = self.store
      schema = schema_with do
        use limits::Concurrency, store: store, limit: 3, soft: false
        use limits::Points, store: store, limit: 100, window: 60, soft: false
      end
      query = GraphQL::Query.new(schema, "{ guarded }", context: { rate_limit_key: "user:1" }, root_value: root)

      GraphQL::Analysis.analyze_query(query, [GraphQL::Analysis::QueryComplexity])

      expect(store.held("user:1")).to eq(0)
      expect(left).to eq(100)
    end

    it "charges once when an analyzer runs an analysis of its own during an execution" do
      store = self.store
      nested = Class.new(GraphQL::Analysis::Analyzer) do
        define_method(:result) do
          GraphQL::Analysis.analyze_query(query, [Class.new(GraphQL::Analysis::Analyzer) { define_method(:result) { raise error_class, "inner" } }])
          nil
        end
      end
      schema = schema_with do
        query_analyzer nested
        use limits::Points, store: store, limit: 100, window: 60, soft: false
      end

      run(schema)

      expect(resolved).to eq([:cheap])
      expect(left).to eq(99)
    end
  end

  context "when a hook raises partway through several keys" do
    let(:failing) do
      Class.new(limits::MemoryStore) do
        def take(key, **options) = key == "b" ? raise(IOError, "down") : super
        def acquire(key, **options) = key == "b" ? raise(IOError, "down") : super
      end.new
    end
    let(:hook) { ->(_error, _query) { raise error_class, "hook says no" } }

    it "does not charge the keys already charged again" do
      failing = self.failing
      hook = self.hook
      schema = schema_with { use limits::Points, store: failing, limit: 100, window: 60, soft: true, on_store_error: hook }

      execute_query(schema, "{ cheap }", context: { rate_limit_key: %w[a b] }, root_value: root)

      expect(failing.take("a", cost: 0, limit: 100, window: 60, force: false).last).to eq(99)
    end

    it "does not take a second slot for a key that holds one, and refuses" do
      failing = self.failing
      hook = self.hook
      held = []
      schema = schema_with { use limits::Concurrency, store: failing, limit: 1, soft: false, on_store_error: hook }

      result = execute_query(schema, "{ cheap }", context: { rate_limit_key: %w[a b] }, root_value: root)
      held << failing.acquire("a", token: "probe", limit: 1, ttl: 60, force: false).first

      expect(codes(result)).to eq(["RATE_LIMIT_NOT_CHARGED"])
      expect(held).to eq([true])
    end

    it "calls the hook once" do
      failing = self.failing
      calls = []
      hook = ->(_error, _query) { calls << :called; raise error_class, "hook says no" }
      schema = schema_with { use limits::Points, store: failing, limit: 100, window: 60, soft: false, on_store_error: hook }

      execute_query(schema, "{ cheap }", context: { rate_limit_key: "b" }, root_value: root)

      expect(calls.size).to eq(1)
    end
  end

  it "records that the limiter was not charged when another limiter refuses" do
    store = self.store
    full = limits::MemoryStore.new
    schema = schema_with do
      use limits::Points, store: store, limit: 100, window: 60, soft: true
      use limits::Time, store: full, limit: 100, window: 60, soft: false
    end
    full.take(limits::Time.bucket_key("user:1"), cost: 100, limit: 100, window: 60, force: true)

    result = run(schema, "{ guarded }")

    expect(codes(result)).to eq(["RATE_LIMITED"])
    expect(result.context[:rate_limit_points]).to include(charged: false)
  end

  it "refuses when a hook of a hard limiter raises an ExecutionError, instead of serving" do
    hook = ->(_error, _query) { raise error_class, "hook says no" }
    broken = Class.new(limits::MemoryStore) { def take(*, **) = raise(IOError, "down") }.new
    schema = schema_with { use limits::Points, store: broken, limit: 100, window: 60, soft: false, on_store_error: hook }

    expect(codes(run(schema))).to eq(["RATE_LIMIT_NOT_CHARGED"])
    expect(resolved).to eq([])
  end
end
