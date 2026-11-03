# frozen_string_literal: true

# Parsing and validating cost the server work, and no analyzer ever sees an invalid query. So the limiters charge it from
# a trace: the client pays on its next valid query. The invalid query's own answer does not change.
RSpec.describe "charging invalid queries" do
  limits = GraphQL::Armory::RateLimits

  let(:store) { limits::Store::Substitute.new }
  let(:resolved) { [] }
  let(:root) { limits::Controls::Root.example(resolved) }
  let(:heard) { [] }
  let(:on_store_error) { ->(error, _query) { heard << error } }
  let(:query_type) { limits::Controls::Query.example }

  define_method(:schema_with) do |&setup|
    query = query_type
    Class.new(ArmoryEngine.base_schema) do
      query query
      class_exec(&setup) if setup
    end
  end

  define_method(:points_schema) do |**options|
    store = self.store
    hook = on_store_error
    schema_with { use limits::Points, store: store, limit: 100, window: 60, on_store_error: hook, **options }
  end

  define_method(:run) do |schema, document, key: "user:1", **options|
    execute_query(schema, document, context: key ? { rate_limit_key: key } : {}, root_value: root, **options)
  end

  define_method(:run_all) do |schema, documents, key: "user:1"|
    queries = documents.map { |document| { query: document, context: { rate_limit_key: key }, root_value: root } }
    ArmoryEngine.next? ? schema.multiplex_next(queries) : schema.multiplex(queries)
  end

  define_method(:left) do |key = "user:1", limit: 100|
    store.take(key, cost: 0, limit: limit, window: 60, force: false).last
  end

  invalid = { "a syntax error" => "{ cheap", "an unknown field" => "{ nothing }", "a missing query string" => nil }

  describe GraphQL::Armory::RateLimits::Points do
    invalid.each do |label, document|
      it "charges 1 point for #{label}, in hard and soft mode" do
        [true, false].each do |soft|
          key = "user:#{soft}"
          run(points_schema(soft: soft), document, key: key)

          expect(left(key)).to eq(99)
        end
      end

      it "leaves the answer to #{label} as it is with no limiter" do
        plain = run(schema_with, document).to_h
        limited = run(points_schema(extensions: true), document).to_h

        expect(limited).to eq(plain)
      end
    end

    it "charges a valid query once" do
      run(points_schema, "{ cheap }")

      expect(left).to eq(99)
      expect(store.calls.size).to eq(2) # the charge, and the read in this spec
    end

    it "does not charge again a query it refused" do
      schema = points_schema(soft: false, limit: 5)

      result = run(schema, "{ report }")

      expect(result.to_h["errors"].first.dig("extensions", "code")).to eq("RATE_LIMITED")
      expect(left(limit: 5)).to eq(5)
    end

    it "does not take a query another analyzer refused for an invalid one" do
      refusing = Class.new(GraphQL::Analysis::Analyzer) { define_method(:result) { GraphQL::AnalysisError.new("no") } }
      raising = Class.new(GraphQL::Analysis::Analyzer) { define_method(:result) { raise GraphQL::ExecutionError, "raised" } }
      store = self.store
      schema = schema_with do
        query_analyzer raising
        query_analyzer refusing
        use limits::Points, store: store, limit: 100, window: 60
      end

      result = run(schema, "{ cheap }")

      expect(result.to_h).not_to have_key("data")
      expect(result.context[:rate_limit_points]).not_to include(invalid: true)
      expect(left).to eq(99) # its complexity, once
    end

    it "charges the given invalid_cost" do
      run(points_schema(invalid_cost: 7), "{ nothing }")

      expect(left).to eq(93)
    end

    it "charges nothing with invalid_cost: nil" do
      run(points_schema(invalid_cost: nil), "{ nothing }")

      expect(left).to eq(100)
    end

    [0, -1, 1.5, "1", true].each do |value|
      it "refuses invalid_cost: #{value.inspect} at boot" do
        expect { points_schema(invalid_cost: value) }.to raise_error(limits::ConfigurationError, /invalid_cost/)
      end
    end

    it "records what it charged" do
      result = run(points_schema, "{ nothing }")

      expect(result.context[:rate_limit_points]).to include(key: "user:1", cost: 1, limit: 100, remaining: 99, invalid: true)
    end

    it "makes the client pay on its next valid query" do
      schema = points_schema(soft: false, limit: 3)
      3.times { run(schema, "{ nothing }") }

      result = run(schema, "{ cheap }")

      expect(result.to_h["errors"].first.dig("extensions", "code")).to eq("RATE_LIMITED")
      expect(resolved).to eq([])
    end

    it "stops at zero" do
      schema = points_schema(limit: 2)
      5.times { run(schema, "{ nothing }") }

      expect(left(limit: 2)).to eq(0)
    end

    it "takes no charge for a key with no limit" do
      schema = points_schema(limit: ->(_key, _query) {})

      run(schema, "{ nothing }")

      expect(store.calls).to eq([])
    end

    describe "in a multiplex" do
      it "charges the invalid ones once, in one call, and each valid one by its cost" do
        run_all(points_schema, ["{ nothing }", "{ cheap", "{ cheap }"])

        expect(left).to eq(97)
        expect(store.calls.size).to eq(3) # the valid query, the invalid ones together, the read in this spec
      end

      it "charges a query whose key differs apart" do
        schema = points_schema
        queries = %w[user:1 user:2].map { |key| { query: "{ nothing }", context: { rate_limit_key: key }, root_value: root } }

        ArmoryEngine.next? ? schema.multiplex_next(queries) : schema.multiplex(queries)

        expect([left("user:1"), left("user:2")]).to eq([99, 99])
      end
    end

    describe "with several keys" do
      it "charges each key" do
        run(points_schema, "{ nothing }", key: ["user:1", "ip:1"])

        expect([left("user:1"), left("ip:1")]).to eq([99, 99])
      end

      it "stops at the first key with no points, so an exhausted client cannot drain a shared bucket" do
        schema = points_schema(limit: ->(key, _query) { key == "user:1" ? 1 : 100 })
        3.times { run(schema, "{ nothing }", key: ["user:1", "shared"]) }

        expect(left("user:1", limit: 1)).to eq(0)
        expect(left("shared")).to eq(99)
      end

      it "still charges the other keys when a store call fails on one" do
        store.fail_with(IOError.new("down"), on: :take, times: 1)

        run(points_schema, "{ nothing }", key: ["user:1", "ip:1"])

        expect(heard.map(&:class)).to eq([IOError])
        expect(left("ip:1")).to eq(99)
      end
    end

    describe "when something fails" do
      let(:plain) { run(schema_with, "{ nothing }").to_h }

      it "tells on_store_error when the store fails, and answers as usual" do
        store.fail_with(IOError.new("down"))

        expect(run(points_schema, "{ nothing }").to_h).to eq(plain)
        expect(heard.map(&:class)).to eq([IOError])
      end

      it "answers as usual when on_store_error raises" do
        store.fail_with(IOError.new("down"))
        raising = ->(_error, _query) { raise "hook is down" }

        expect { @result = run(points_schema(on_store_error: raising), "{ nothing }") }.to output(/hook is down/).to_stderr
        expect(@result.to_h).to eq(plain)
      end

      it "tells on_store_error when there is no key, and answers as usual" do
        expect(run(points_schema, "{ nothing }", key: nil).to_h).to eq(plain)
        expect(heard.map(&:class)).to eq([limits::ConfigurationError])
      end

      it "tells on_store_error when a limit callable raises, and answers as usual" do
        schema = points_schema(limit: ->(_key, _query) { raise ArgumentError, "no limit today" })

        expect(run(schema, "{ nothing }").to_h).to eq(plain)
        expect(heard.map(&:class)).to eq([ArgumentError])
      end
    end

    it "still raises for a valid query with no key" do
      expect { run(points_schema, "{ cheap }", key: nil) }.to raise_error(limits::ConfigurationError)
    end
  end

  describe "with persisted queries" do
    define_method(:strict_schema) do
      store = self.store
      gate_store = GraphQL::Armory::PersistedQueries::Store::Substitute.new("{ cheap }")
      schema_with do
        use GraphQL::Armory::PersistedQueries, store: gate_store, strict: true
        use limits::Points, store: store, limit: 100, window: 60
      end
    end

    it "charges a raw query refused in strict mode" do
      result = run(strict_schema, "{ cheap }")

      expect(result.to_h["errors"].first.dig("extensions", "code")).to eq("RAW_QUERY_REFUSED")
      expect(left).to eq(99)
    end

    it "charges an unknown operation in strict mode" do
      result = execute_query(strict_schema, nil, context: { rate_limit_key: "user:1", operation_id: "nope" }, root_value: root)

      expect(result.to_h["errors"].first.dig("extensions", "code")).to eq("UNKNOWN_OPERATION")
      expect(left).to eq(99)
    end
  end

  describe GraphQL::Armory::RateLimits::Time do
    let(:clock) { limits::Clock::Substitute.new }

    define_method(:time_left) do |key = "user:1", limit: 1_000|
      store.take("time:#{key}", cost: 0, limit: limit, window: 60, force: false).last
    end

    # Parsing and validating take `seconds` on the clock.
    define_method(:time_schema) do |seconds: 0.25, **options|
      store = self.store
      hook = on_store_error
      clock = self.clock
      schema_with do
        use limits::Time, store: store, limit: 1_000, window: 60, clock: clock, on_store_error: hook, **options
        trace_with(Module.new do
          define_method(:validate) do |**kwargs, &block|
            clock.advance(seconds)
            super(**kwargs, &block)
          end
          define_method(:parse) do |**kwargs, &block|
            clock.advance(seconds)
            super(**kwargs, &block)
          end
        end)
      end
    end

    it "charges the time an invalid query took" do
      run(time_schema, "{ nothing }")

      expect(time_left).to be < 1_000
    end

    it "records what it charged" do
      result = run(time_schema, "{ nothing }")

      expect(result.context[:rate_limit_time]).to include(key: "user:1", limit: 1_000, invalid: true)
      expect(result.context[:rate_limit_time][:remaining]).to eq(time_left)
    end

    it "splits a multiplex equally among valid and invalid queries" do
      schema = time_schema(seconds: 0.1)
      queries = [["user:1", "{ nothing }"], ["user:2", "{ cheap }"]].map { |key, query| { query: query, context: { rate_limit_key: key }, root_value: root } }

      ArmoryEngine.next? ? schema.multiplex_next(queries) : schema.multiplex(queries)

      expect(time_left("user:1")).to be < 1_000
      expect(time_left("user:1")).to eq(time_left("user:2"))
    end

    it "takes no charge for a key with no limit" do
      run(time_schema(limit: ->(_key, _query) {}), "{ nothing }")

      expect(store.calls).to eq([])
    end

    it "stops at the first key that cannot pay, so an exhausted client cannot drain a shared bucket" do
      schema = time_schema(limit: ->(key, _query) { key == "user:1" ? 1 : 1_000 })

      run(schema, "{ nothing }", key: ["user:1", "shared"])

      expect(time_left("shared")).to eq(1_000)
    end

    it "tells on_store_error when the store fails, and answers as usual" do
      plain = run(schema_with, "{ nothing }").to_h
      store.fail_with(IOError.new("down"))

      expect(run(time_schema, "{ nothing }").to_h).to eq(plain)
      expect(heard.map(&:class)).to include(IOError)
    end

    it "tells on_store_error when there is no key, and answers as usual" do
      plain = run(schema_with, "{ nothing }").to_h

      expect(run(time_schema, "{ nothing }", key: nil).to_h).to eq(plain)
      expect(heard.map(&:class)).to eq([limits::ConfigurationError])
    end

    it "shares a store with Points on separate buckets" do
      store = self.store
      clock = self.clock
      schema = schema_with do
        use limits::Points, store: store, limit: 100, window: 60
        use limits::Time, store: store, limit: 1_000, window: 60, clock: clock
      end

      run(schema, "{ nothing }")

      expect(left).to eq(99)
      expect(time_left).to eq(1_000)
    end
  end

  describe GraphQL::Armory::RateLimits::Concurrency do
    it "holds no slot for an invalid query" do
      store = self.store
      schema = schema_with { use limits::Concurrency, store: store, limit: 1, stale_after: 30, soft: false }

      run(schema, "{ nothing }")

      expect(store.held("user:1")).to eq(0)
    end
  end
end
