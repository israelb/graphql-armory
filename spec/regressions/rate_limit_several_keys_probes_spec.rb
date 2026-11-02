# frozen_string_literal: true

require "json"
require "set"
require "redis"
require "securerandom"

# Independent verifier's probes. [S] = security (the feature must change the outcome), [K] = preservation.
module SeveralKeysProbes
  L = GraphQL::Armory::RateLimits

  class Scripted < L::Store::Substitute
    def initialize(**options)
      super
      @scripts = {}
    end

    def on(method, key, &behaviour)
      @scripts[[method, key]] = behaviour
      self
    end

    def balance(key, limit, window = 60)
      @memory.take(key, cost: 0, limit: limit, window: window, force: false).last
    end

    def spend(key, cost, limit, window = 60)
      @memory.take(key, cost: cost, limit: limit, window: window, force: true)
    end

    def called(method, key = nil)
      calls.select { |call| call[0] == method && (key.nil? || call[1] == key) }
    end

    def take(key, cost:, limit:, window:, force: false)
      scripted(:take, key, cost: cost, limit: limit, window: window, force: force) { super }
    end

    def acquire(key, token:, limit:, ttl:, force: false)
      scripted(:acquire, key, token: token, limit: limit, ttl: ttl, force: force) { super }
    end

    def release(key, token:)
      scripted(:release, key, token: token) { super }
    end

    private

    def scripted(method, key, **arguments)
      if (behaviour = @scripts[[method, key]])
        answer = begin
          behaviour.call(arguments)
        rescue StandardError
          @calls << [method, key, arguments]
          raise
        end
        unless answer == :pass
          @calls << [method, key, arguments]
          return answer
        end
      end
      yield
    end
  end
end

RSpec.describe "Probes: several keys per query" do
  let(:l) { SeveralKeysProbes::L }
  let(:store) { SeveralKeysProbes::Scripted.new }
  let(:resolved) { [] }
  let(:root) { l::Controls::Root.example(resolved) }
  let(:hook) { [] }
  let(:quiet) { ->(error, _query) { hook << error.class } }
  let(:loud) { ->(error, _query) { hook << error.class; raise "hook: #{error.class}" } }
  let(:clock) { l::Clock::Substitute.new }
  let(:timed_root) { l::Controls::Time.example(clock, resolved, seconds: 0.25) }

  def schema_with(*limiters, type: l::Controls::Query.example)
    Class.new(ArmoryEngine.base_schema) do
      query type
      limiters.each { |limiter, options| use limiter, **options }
    end
  end

  def run(schema, document = "{ report }", key: %w[a b], root_value: root, **context)
    execute_query(schema, document, root_value: root_value, context: { rate_limit_key: key, **context })
  end

  def mux(schema, queries)
    ArmoryEngine.next? ? schema.multiplex_next(queries) : schema.multiplex(queries)
  end

  def by_operation(map)
    ->(query) { map.fetch(query.selected_operation_name) }
  end

  def refused?(result)
    result["errors"]&.any? { |error| error.dig("extensions", "code") == "RATE_LIMITED" } && result["data"].nil?
  end

  def concurrency(**options)
    [l::Concurrency, { store: store, limit: 1, soft: false, on_store_error: quiet, **options }]
  end

  def points(**options)
    [l::Points, { store: store, limit: 100, soft: false, on_store_error: quiet, **options }]
  end

  def time(**options)
    [l::Time, { store: store, limit: 1000, soft: false, on_store_error: quiet, clock: clock, **options }]
  end

  describe "malformed lists" do
    bad = {
      "empty" => [], "nil member" => ["a", nil], "symbol member" => ["a", :b], "empty String member" => ["a", ""],
      "duplicate" => %w[a a], "six" => %w[a b c d e f], "nested" => ["a", ["b"]],
      "Set" => Set.new(%w[a b]), "Hash" => { "a" => 1 }, "Symbol" => :a, "Integer" => 1
    }
    %i[concurrency time].each do |limiter|
      bad.each do |name, value|
        it "M1/M2 [S] #{limiter} raises and runs nothing on #{name}" do
          schema = schema_with(send(limiter))
          expect { run(schema, key: value, root_value: limiter == :time ? timed_root : root) }.to raise_error(l::ConfigurationError, /key/)
          expect(resolved).to be_empty
          expect(store.calls).to be_empty
        end
      end
    end

    { "Set" => Set.new(%w[a b]), "Hash" => { "a" => 1 }, "Symbol" => :a, "nested" => ["a", ["b"]] }.each do |name, value|
      it "M2 [S] points raises and runs nothing on #{name}" do
        expect { run(schema_with(points), key: value) }.to raise_error(l::ConfigurationError, /key/)
        expect(resolved).to be_empty
        expect(store.calls).to be_empty
      end
    end

    it "M3 [S] a malformed list in a multiplex runs nothing and releases the slots of the valid query" do
      schema = schema_with(concurrency(key: by_operation("Q1" => %w[a b], "Q2" => %w[c c])))
      queries = [{ query: "query Q1 { cheap }", root_value: root }, { query: "query Q2 { cheap }", root_value: root }]
      expect { mux(schema, queries) }.to raise_error(l::ConfigurationError)
      expect(resolved).to be_empty
      expect([store.held("a"), store.held("b")]).to eq([0, 0])
    end
  end

  describe "odd lists" do
    it "L2 [S] mutating the list and a member in a resolver does not change what Time charges" do
      member = +"a"
      keys = [member, "b"]
      mutating = Class.new do
        define_method(:cheap) do
          member << "-changed"
          keys.clear
          "ok"
        end
      end.new
      schema = schema_with(time)
      run(schema, "{ cheap }", key: keys, root_value: mutating)
      expect(store.called(:take, "a").size).to eq(2)
      expect(store.called(:take, "b").size).to eq(2)
      expect(store.called(:take, "a-changed")).to be_empty
    end

    it "L2 [S] mutating a member in a resolver does not leak the Concurrency slot" do
      member = +"a"
      mutating = Class.new { define_method(:cheap) { member << "-changed"; "ok" } }.new
      run(schema_with(concurrency), "{ cheap }", key: [member, "b"], root_value: mutating)
      expect(store.held("a")).to eq(0)
      expect(store.held("b")).to eq(0)
    end

    it "L3 [S] an Array subclass lying in uniq is still refused as a duplicate" do
      lying = Class.new(Array) { def uniq = self }.new(%w[a a b])
      expect { run(schema_with(points), key: lying) }.to raise_error(l::ConfigurationError)
      expect(store.calls).to be_empty
    end

    it "L3 [S] an Array subclass lying in size cannot exceed MAX_KEYS" do
      lying = Class.new(Array) { def size = 1 }.new(%w[a b c d e f g])
      begin
        run(schema_with(points), key: lying)
      rescue l::ConfigurationError
        nil
      end
      expect(store.calls.map { |call| call[1] }.uniq.size).to be <= 5
    end

    it "L4 [S] odd bytes are separate buckets in MemoryStore and charged once each" do
      keys = ["a\0b", "line\nbreak", "\xFF".dup.force_encoding("UTF-8"), " "]
      run(schema_with(points), key: keys)
      keys.each { |key| expect(store.balance(key, 100)).to eq(60) }
      expect(resolved).to eq([:report])
    end

    it "L4b [S] the same bytes under two encodings are refused, not charged twice in Redis" do
      skip "no redis" if ENV["REDIS_URL"].to_s.empty?
      now = [1000.0]
      redis_store = l::RedisStore.new(redis: Redis.new(url: ENV.fetch("REDIS_URL")), prefix: "probe-#{SecureRandom.hex(6)}:", clock: -> { now[0] })
      schema = schema_with([l::Points, { store: redis_store, limit: 100, soft: false }])
      expect { run(schema, key: ["é", "é".b]) }.to raise_error(l::ConfigurationError)
      expect(redis_store.take("é", cost: 0, limit: 100, window: 60, force: false).last).to eq(100)
    end
  end

  describe "Concurrency" do
    it "C1 [S] a sibling query sees key 1's slot free right after the refusal" do
      store.occupy("b")
      seen = []
      this_store = store
      sibling = Class.new { define_method(:cheap) { seen << this_store.held("a"); "ok" } }.new
      schema = schema_with(concurrency(key: by_operation("Q1" => %w[a b], "Q2" => %w[c])))
      results = mux(schema, [{ query: "query Q1 { cheap }", root_value: root }, { query: "query Q2 { cheap }", root_value: sibling }])
      expect(refused?(results[0])).to be_truthy
      expect(seen).to eq([0])
      expect(resolved).to be_empty
    end

    it "C2 [S] limit: raising on key 2 raises with no store call" do
      schema = schema_with(concurrency(limit: ->(key, _q) { key == "b" ? raise("boom") : 1 }))
      expect { run(schema) }.to raise_error("boom")
      expect(store.calls).to be_empty
      expect(resolved).to be_empty
    end

    it "C4 [S] on_store_error raising in the inline release: other slots released, each once, nothing runs" do
      store.occupy("b")
      store.on(:release, "a") { raise IOError, "down" }
      schema = schema_with(concurrency(on_store_error: loud))
      expect { run(schema, key: %w[a c b]) }.to raise_error(/hook/)
      expect(resolved).to be_empty
      expect(store.held("c")).to eq(0)
      expect(store.called(:release, "a").size).to eq(1)
      expect(store.called(:release, "c").size).to eq(1)
      expect(hook).to eq([IOError])
    end

    it "C5 [S] on_store_error raising in the trace release: others released, each once, error raised" do
      store.on(:release, "a") { raise IOError, "down" }
      schema = schema_with(concurrency(on_store_error: loud))
      expect { run(schema, key: %w[a b c]) }.to raise_error(/hook/)
      expect([store.held("b"), store.held("c")]).to eq([0, 0])
      expect(store.called(:release).size).to eq(3)
    end

    it "C6 [S] a failed inline release with a quiet handler still refuses and releases the rest" do
      store.occupy("b")
      store.on(:release, "a") { raise IOError, "down" }
      result = run(schema_with(concurrency), key: %w[a c b])
      expect(refused?(result)).to be_truthy
      expect(resolved).to be_empty
      expect(store.held("c")).to eq(0)
      expect(hook).to eq([IOError])
    end

    it "C7 [S] the refused query's tokens are released exactly once in total" do
      store.occupy("c")
      run(schema_with(concurrency), key: %w[a b c])
      tokens = store.called(:release).map { |call| call[2][:token] }
      expect(tokens.size).to eq(2)
      expect(tokens.uniq.size).to eq(2)
    end

    it "C8 [S] key 1 refuses and the store raises on key 2: must not run (R1)" do
      store.occupy("a")
      store.on(:acquire, "b") { raise IOError, "down" }
      result = run(schema_with(concurrency))
      expect(resolved).to be_empty
      expect(refused?(result)).to be_truthy
    end

    it "C9 [K] key 1 acquired and the store raises on key 2: handler once, runs, slot released" do
      store.on(:acquire, "b") { raise IOError, "down" }
      run(schema_with(concurrency))
      expect(resolved).to eq([:report])
      expect(hook).to eq([IOError])
      expect(store.held("a")).to eq(0)
    end

    it "C9b [S] the store raising on key 2 with key 3 healthy still takes key 3" do
      store.on(:acquire, "b") { raise IOError, "down" }
      run(schema_with(concurrency), key: %w[a b c])
      expect(store.called(:acquire, "c").size).to eq(1)
    end

    it "C10 [S] multiplex sharing one context hash: q1 refused, q2 runs, all released" do
      store.occupy("b")
      seen = []
      this_store = store
      sibling = Class.new { define_method(:cheap) { seen << this_store.held("a"); "ok" } }.new
      schema = schema_with(concurrency(key: by_operation("Q1" => %w[a b], "Q2" => %w[a c])))
      shared = {}
      results = mux(schema, [
        { query: "query Q1 { cheap }", root_value: root, context: shared },
        { query: "query Q2 { cheap }", root_value: sibling, context: shared }
      ])
      expect(refused?(results[0])).to be_truthy
      expect(results[1]["data"]).to eq("cheap" => "ok")
      expect(seen).to eq([1])
      expect([store.held("a"), store.held("b"), store.held("c")]).to eq([0, 1, 0])
    end

    it "C11 [S] two limiters, String and list, the second refuses: the first's slot is released, nothing runs" do
      other = SeveralKeysProbes::Scripted.new
      other.occupy("b")
      schema = schema_with(concurrency(key: ->(_q) { "u" }), concurrency(store: other, key: ->(_q) { %w[a b] }))
      result = run(schema, key: nil)
      expect(refused?(result)).to be_truthy
      expect(resolved).to be_empty
      expect(store.held("u")).to eq(0)
      expect(other.held("a")).to eq(0)
    end

    it "C11b [S] two limiters of one String each, both released on a normal run (B overwrites one slot)" do
      other = SeveralKeysProbes::Scripted.new
      schema = schema_with(concurrency, concurrency(store: other))
      run(schema, key: "u")
      expect(resolved).to eq([:report])
      expect(store.held("u")).to eq(0)
      expect(other.held("u")).to eq(0)
    end

    it "C13 [S] limit nil for some keys: no store call for them; for all keys: no store call at all, runs" do
      schema = schema_with(concurrency(limit: ->(key, _q) { key == "a" ? 1 : nil }))
      run(schema)
      expect(store.called(:acquire, "b")).to be_empty
      expect(store.held("a")).to eq(0)
      calls = store.calls.size
      run(schema_with(concurrency(limit: ->(_key, _q) {})))
      expect(store.calls.size).to eq(calls)
      expect(resolved).to eq(%i[report report])
    end

    it "C14 [S] a resolver raising releases every slot" do
      expect { run(schema_with(concurrency), "{ broken }") }.to raise_error(IOError)
      expect([store.held("a"), store.held("b")]).to eq([0, 0])
    end

    it "C15 [S] the record's active matches what the store really holds while running" do
      store.occupy("b")
      seen = {}
      this_store = store
      observing = Class.new { define_method(:cheap) { seen.merge!("a" => this_store.held("a"), "b" => this_store.held("b")); "ok" } }.new
      result = run(schema_with(concurrency(limit: 3)), "{ cheap }", root_value: observing)
      record = result.context[:rate_limit_concurrency]
      expect(seen).to eq("a" => 1, "b" => 2)
      expect(record).to include(key: "b", limit: 3, active: 2, limited: false)
      expect(record[:keys]).to eq([{ key: "a", limit: 3, active: 1 }, { key: "b", limit: 3, active: 2 }])
    end

    it "C16 [S] no key in the response JSON" do
      store.occupy("SECRET-b")
      result = run(schema_with(concurrency), key: %w[SECRET-a SECRET-b])
      expect(refused?(result)).to be_truthy
      expect(result.to_h.to_json).not_to include("SECRET")
    end

    it "C17 [S] RedisStore: refusal leaves no slot, end state empty" do
      skip "no redis" if ENV["REDIS_URL"].to_s.empty?
      redis = Redis.new(url: ENV.fetch("REDIS_URL"))
      prefix = "probe-#{SecureRandom.hex(6)}:"
      redis_store = l::RedisStore.new(redis: redis, prefix: prefix)
      redis_store.acquire("b", token: "elsewhere", limit: 1, ttl: 60)
      schema = schema_with(concurrency(store: redis_store))
      expect(refused?(run(schema))).to be_truthy
      expect(redis.zcard("#{prefix}slots:a")).to eq(0)
      expect(redis.zcard("#{prefix}slots:b")).to eq(1)
      seen = []
      observing = Class.new { define_method(:cheap) { seen << [redis.zcard("#{prefix}slots:c"), redis.zcard("#{prefix}slots:d")]; "ok" } }.new
      run(schema, "{ cheap }", key: %w[c d], root_value: observing)
      expect(seen).to eq([[1, 1]])
      expect([redis.zcard("#{prefix}slots:c"), redis.zcard("#{prefix}slots:d")]).to eq([0, 0])
    end

    it "C18 [S] a list with its own trace raises" do
      schema = schema_with(concurrency)
      expect { run(schema, trace: GraphQL::Tracing::Trace.new) }.to raise_error(l::ConfigurationError, /trace/)
      expect(store.calls).to be_empty
    end
  end

  describe "Points" do
    let(:free_type) do
      Class.new(GraphQL::Schema::Object) do
        graphql_name "Query"
        field :free, String, null: false, complexity: 0
        field :half, String, null: false, complexity: 0.5
      end
    end
    let(:free_root) { Class.new { def free = "ok"; def half = "ok" }.new }

    it "P3 [S] cost 0 runs on empty buckets and charges nothing" do
      store.spend("a", 100, 100)
      store.spend("b", 100, 100)
      result = run(schema_with(points, type: free_type), "{ free }", root_value: free_root)
      expect(result["data"]).to eq("free" => "ok")
      expect(store.balance("a", 100)).to eq(0)
    end

    it "P3b [S] cost 0 on the Null store refuses" do
      result = run(schema_with([l::Points, { store: l::Store::Null.new, limit: 10, soft: false }], type: free_type), "{ free }", root_value: free_root)
      expect(refused?(result)).to be_truthy
    end

    it "P4 [S] fractional complexity charges a whole point on each key" do
      run(schema_with(points, type: free_type), "{ half }", root_value: free_root)
      expect(store.balance("a", 100)).to eq(99)
      expect(store.balance("b", 100)).to eq(99)
    end

    it "P5 [S] limit nil for all keys: runs, no store call, no headers, no extensions" do
      result = run(schema_with(points(limit: ->(_k, _q) {}, extensions: true)))
      expect(resolved).to eq([:report])
      expect(store.calls).to be_empty
      expect(l::Points.headers(result)).to eq({})
      expect(result.to_h).not_to have_key("extensions")
    end

    it "P7 [S] soft: an empty key runs, each charged, limited true, extensions honest" do
      store.spend("a", 90, 100)
      result = run(schema_with(points(soft: true, extensions: true)))
      expect(resolved).to eq([:report])
      expect(store.balance("a", 100)).to eq(0)
      expect(store.balance("b", 100)).to eq(60)
      expect(result.context[:rate_limit_points]).to include(key: "a", remaining: 0, limited: true)
      expect(result.to_h["extensions"]["rateLimit"]).to eq("cost" => 40, "limit" => 100, "remaining" => 0, "resetIn" => 60)
    end

    it "P8 [S] extensions and headers match the store when allowed, and when refused" do
      schema = schema_with(points(limit: ->(key, _q) { key == "a" ? 100 : 1000 }, extensions: true))
      result = run(schema)
      expect(result.to_h["extensions"]["rateLimit"]).to eq("cost" => 40, "limit" => 100, "remaining" => 60, "resetIn" => 24)
      expect(l::Points.headers(result)).to eq("RateLimit-Limit" => "100", "RateLimit-Remaining" => "60", "RateLimit-Reset" => "24")
      run(schema)
      refused = run(schema)
      expect(refused?(refused)).to be_truthy
      expect(refused.to_h["extensions"]["rateLimit"]).to eq("cost" => 40, "limit" => 100, "remaining" => 20, "resetIn" => 48)
      expect(store.balance("a", 100)).to eq(20)
      expect(store.balance("b", 1000)).to eq(920)
    end

    it "P9 [S] a lost race at the charge really stops the query, and says the store's numbers" do
      store.on(:take, "b") { |args| args[:cost].positive? ? [false, 3] : :pass }
      result = run(schema_with(points(extensions: true)))
      expect(resolved).to be_empty
      expect(refused?(result)).to be_truthy
      expect(result["errors"][0]["extensions"]).to include("remaining" => 3, "retryAfter" => 23)
      expect(result.context[:rate_limit_points]).to include(key: "b", remaining: 3, limited: true)
      expect(store.balance("a", 100)).to eq(60) # documented limit
    end

    it "P11 [S] key 1 exhausted and the store raises at the read of key 2: must not run (R1)" do
      store.spend("a", 100, 100)
      store.on(:take, "b") { raise IOError, "down" }
      result = run(schema_with(points))
      expect(resolved).to be_empty
      expect(refused?(result)).to be_truthy
    end

    it "P11b [S] the store raises at the read of key 2: healthy key 1 is still charged" do
      store.on(:take, "b") { raise IOError, "down" }
      run(schema_with(points))
      expect(resolved).to eq([:report])
      expect(store.balance("a", 100)).to eq(60)
    end

    it "P12 [K] the store raises at the charge of key 2: handler once, runs, key 1 charged once" do
      store.on(:take, "b") { |args| args[:cost].positive? ? raise(IOError, "down") : :pass }
      run(schema_with(points))
      expect(resolved).to eq([:report])
      expect(hook).to eq([IOError])
      expect(store.balance("a", 100)).to eq(60)
    end

    it "P12b [S] the store raises at the charge of key 2: healthy key 3 is still charged" do
      store.on(:take, "b") { |args| args[:cost].positive? ? raise(IOError, "down") : :pass }
      run(schema_with(points), key: %w[a b c])
      expect(store.balance("c", 100)).to eq(60)
    end

    it "P13 [S] nonsense at the read raises and runs nothing, charging nothing" do
      store.on(:take, "b") { [0, 0] }
      expect { run(schema_with(points)) }.to raise_error(l::ConfigurationError, /answered/)
      expect(resolved).to be_empty
      expect(store.balance("a", 100)).to eq(100)
      expect(hook).to be_empty
    end

    it "P13b [S] nonsense at the charge raises and runs nothing" do
      store.on(:take, "b") { |args| args[:cost].positive? ? [true, "many"] : :pass }
      expect { run(schema_with(points)) }.to raise_error(l::ConfigurationError, /answered/)
      expect(resolved).to be_empty
      expect(hook).to be_empty
    end

    it "P14 [S] retryAfter is honest: refused a second earlier, allowed after it" do
      store.spend("a", 980, 1000)
      store.spend("b", 70, 100)
      schema = schema_with(points(limit: ->(key, _q) { key == "a" ? 1000 : 100 }))
      wait = run(schema)["errors"][0]["extensions"]["retryAfter"]
      expect(wait).to eq(6)
      store.now += wait - 1
      expect(refused?(run(schema))).to be_truthy
      store.now += 1
      expect(run(schema)["data"]).to eq("report" => "big")
    end

    it "P15 [S] a multiplex charges cumulatively across lists that share a key" do
      schema = schema_with(points(limit: 50, key: by_operation("Q1" => %w[a b], "Q2" => %w[b c])))
      results = mux(schema, [{ query: "query Q1 { report }", root_value: root }, { query: "query Q2 { report }", root_value: root }])
      expect(results[0]["data"]).to eq("report" => "big")
      expect(refused?(results[1])).to be_truthy
      expect([store.balance("a", 50), store.balance("b", 50), store.balance("c", 50)]).to eq([10, 10, 50])
    end

    it "P16 [S] a shared context hash keeps each query's own headers" do
      schema = schema_with(points(key: by_operation("Q1" => %w[a b], "Q2" => %w[c d])))
      store.spend("c", 50, 100)
      shared = {}
      results = mux(schema, [
        { query: "query Q1 { report }", root_value: root, context: shared },
        { query: "query Q2 { report }", root_value: root, context: shared }
      ])
      expect(l::Points.headers(results[0])["RateLimit-Remaining"]).to eq("60")
      expect(l::Points.headers(results[1])["RateLimit-Remaining"]).to eq("10")
    end

    it "P17 [S] two limiters, String then list: the list refuses, nothing runs, the String was charged once" do
      other = SeveralKeysProbes::Scripted.new
      other.spend("b", 100, 100)
      schema = schema_with(points(key: ->(_q) { "u" }), points(store: other, key: ->(_q) { %w[a b] }))
      result = run(schema, key: nil)
      expect(refused?(result)).to be_truthy
      expect(resolved).to be_empty
      expect(store.called(:take, "u").size).to eq(1)
      expect(other.balance("a", 100)).to eq(100)
    end

    it "P20 [S] RedisStore: refused leaves balances, allowed charges once, the record matches" do
      skip "no redis" if ENV["REDIS_URL"].to_s.empty?
      now = [1000.0]
      redis_store = l::RedisStore.new(redis: Redis.new(url: ENV.fetch("REDIS_URL")), prefix: "probe-#{SecureRandom.hex(6)}:", clock: -> { now[0] })
      balance = ->(key) { redis_store.take(key, cost: 0, limit: 100, window: 60, force: false).last }
      schema = schema_with(points(store: redis_store))
      result = run(schema)
      expect([balance["a"], balance["b"]]).to eq([60, 60])
      expect(result.context[:rate_limit_points][:keys]).to eq([{ key: "a", limit: 100, remaining: 60 }, { key: "b", limit: 100, remaining: 60 }])
      redis_store.take("b", cost: 50, limit: 100, window: 60, force: true)
      refused = run(schema)
      expect(refused?(refused)).to be_truthy
      expect([balance["a"], balance["b"]]).to eq([60, 10])
    end

    it "P21 [S] rotating the IP does not refill the user's key, and a refused query spends no fresh IP" do
      schema = schema_with(points)
      2.times { |i| expect(run(schema, key: ["user:1", "ip:#{i}"])["data"]).to eq("report" => "big") }
      expect(refused?(run(schema, key: ["user:1", "ip:9"]))).to be_truthy
      expect(store.balance("ip:9", 100)).to eq(100)
    end

    it "P23 [S] on_store_error raising at the read: nothing runs" do
      store.on(:take, "b") { raise IOError, "down" }
      expect { run(schema_with(points(on_store_error: loud))) }.to raise_error(/hook/)
      expect(resolved).to be_empty
    end

    it "P24 [K] a store failure on one key leaves that key out of the record" do
      store.on(:take, "b") { raise IOError, "down" }
      result = run(schema_with(points(extensions: true)))
      expect(result.context[:rate_limit_points][:keys].map { |budget| budget[:key] }).to eq(%w[a])
      expect(result.context[:rate_limit_points][:key]).to eq("a")
    end

    it "P24b [K] a store failure on every key leaves no record, headers or extensions" do
      store.on(:take, "a") { raise IOError, "down" }
      store.on(:take, "b") { raise IOError, "down" }
      result = run(schema_with(points(extensions: true)))
      expect(result.context[:rate_limit_points]).to be_nil
      expect(l::Points.headers(result)).to eq({})
      expect(result.to_h).not_to have_key("extensions")
    end
  end

  describe "Time" do
    def cheap(schema, key: %w[a b], **context)
      run(schema, "{ cheap }", key: key, root_value: timed_root, **context)
    end

    it "T3 [S] the store fails at the read: handler once, every key still charged at the end" do
      store.on(:take, "a") { |args| args[:cost].zero? ? raise(IOError, "down") : :pass }
      result = cheap(schema_with(time))
      expect(resolved).to eq([:cheap])
      expect(hook).to eq([IOError])
      expect(store.balance("a", 1000)).to eq(750)
      expect(store.balance("b", 1000)).to eq(750)
      expect(result.context[:rate_limit_time]).to include(elapsed: 250)
    end

    it "T4 [S] key 1 empty and the store raises at the read of key 2: must not run (R1)" do
      store.spend("a", 1000, 1000)
      store.on(:take, "b") { |args| args[:cost].zero? ? raise(IOError, "down") : :pass }
      result = cheap(schema_with(time))
      expect(resolved).to be_empty
      expect(refused?(result)).to be_truthy
    end

    it "T6 [S] a charge fails on one key and the hook raises: the other keys are still charged, hook once" do
      store.spend("a", 100, 1000)
      store.on(:take, "b") { |args| args[:cost].positive? ? raise(IOError, "down") : :pass }
      expect { cheap(schema_with(time(on_store_error: loud)), key: %w[a b c]) }.to raise_error(/hook/)
      expect(store.balance("c", 1000)).to eq(750)
      expect(store.balance("a", 1000)).to eq(650)
      expect(hook).to eq([IOError])
    end

    it "T7 [S] the charge fails on the binding key: the others charged, hook once" do
      store.spend("a", 100, 1000)
      store.on(:take, "a") { |args| args[:cost].positive? ? raise(IOError, "down") : :pass }
      cheap(schema_with(time))
      expect(store.balance("b", 1000)).to eq(750)
      expect(hook).to eq([IOError])
    end

    it "T8 [S] soft: an empty key runs, every key charged, limited true" do
      store.spend("a", 1000, 1000)
      result = cheap(schema_with(time(soft: true, extensions: true)))
      expect(resolved).to eq([:cheap])
      expect(store.balance("a", 1000)).to eq(0)
      expect(store.balance("b", 1000)).to eq(750)
      expect(result.context[:rate_limit_time]).to include(key: "a", remaining: 0, elapsed: 250, limited: true)
      expect(result.to_h["extensions"]["rateLimitTime"]).to include("remaining" => 0, "elapsed" => 250, "resetIn" => 60)
    end

    it "T9 [S] extensions, headers and the record match the store after the charge" do
      store.spend("b", 100, 2000)
      result = cheap(schema_with(time(limit: ->(key, _q) { key == "a" ? 500 : 2000 }, extensions: true)))
      expect(store.balance("a", 500)).to eq(250)
      expect(store.balance("b", 2000)).to eq(1650)
      expect(result.context[:rate_limit_time]).to include(key: "a", limit: 500, remaining: 250, elapsed: 250)
      expect(result.context[:rate_limit_time][:keys]).to eq([{ key: "a", limit: 500, remaining: 250 }, { key: "b", limit: 2000, remaining: 1650 }])
      expect(result.to_h["extensions"]["rateLimitTime"]).to eq("limit" => 500, "remaining" => 250, "elapsed" => 250, "resetIn" => 30)
      expect(l::Time.headers(result)).to eq("RateLimit-Time-Limit" => "500", "RateLimit-Time-Remaining" => "250", "RateLimit-Time-Reset" => "30")
    end

    it "T10 [S] limit nil for some: not charged; for all: no store call, runs, no headers" do
      cheap(schema_with(time(limit: ->(key, _q) { key == "a" ? 1000 : nil })))
      expect(store.called(:take, "b")).to be_empty
      expect(store.balance("a", 1000)).to eq(750)
      calls = store.calls.size
      result = cheap(schema_with(time(limit: ->(_k, _q) {}, extensions: true)))
      expect(store.calls.size).to eq(calls)
      expect(l::Time.headers(result)).to eq({})
      expect(result.to_h).not_to have_key("extensions")
    end

    it "T11 [S] zero duration charges 0 and answers a complete record" do
      result = run(schema_with(time), "{ cheap }")
      expect(store.balance("a", 1000)).to eq(1000)
      expect(result.context[:rate_limit_time]).to include(elapsed: 0, remaining: 1000)
    end

    it "T12 [S] a multiplex splits the time, excludes a refused query, and shared keys pay each query's share" do
      store.spend("d", 1000, 1000)
      schema = schema_with(time(key: by_operation("Q1" => %w[a b], "Q2" => %w[b c], "Q3" => %w[e d])))
      results = mux(schema, [
        { query: "query Q1 { cheap }", root_value: timed_root },
        { query: "query Q2 { cheap }", root_value: timed_root },
        { query: "query Q3 { cheap }", root_value: timed_root }
      ])
      expect(refused?(results[2])).to be_truthy
      expect(store.balance("a", 1000)).to eq(750)
      expect(store.balance("b", 1000)).to eq(500)
      expect(store.balance("c", 1000)).to eq(750)
      expect(store.balance("e", 1000)).to eq(1000)
    end

    it "T13 [S] the headers name the lowest balance after the run, when refill reordered the keys" do
      store.spend("a", 50, 100)
      store.spend("b", 99_960, 100_000)
      this_store = store
      this_clock = clock
      slow = Class.new do
        define_method(:cheap) do
          this_store.now += 1
          this_clock.advance(1)
          "ok"
        end
      end.new
      schema = schema_with(time(limit: ->(key, _q) { key == "a" ? 100 : 100_000 }))
      result = run(schema, "{ cheap }", root_value: slow)
      lowest = [store.balance("a", 100), store.balance("b", 100_000)].min
      expect(l::Time.headers(result)["RateLimit-Time-Remaining"]).to eq(lowest.to_s)
    end

    it "T14 [S] retryAfter is honest: refused before it, allowed after" do
      store.spend("a", 60, 60)
      store.spend("b", 6, 6)
      schema = schema_with(time(limit: ->(key, _q) { key == "a" ? 60 : 6 }))
      wait = cheap(schema)["errors"][0]["extensions"]["retryAfter"]
      expect(wait).to eq(10)
      store.now += wait - 1
      expect(refused?(cheap(schema))).to be_truthy
      store.now += 1
      expect(cheap(schema)["data"]).to eq("cheap" => "ok")
    end

    it "T15 [S] nonsense at the read raises with no debt" do
      store.on(:take, "b") { [0, 0] }
      expect { cheap(schema_with(time)) }.to raise_error(l::ConfigurationError, /answered/)
      expect(resolved).to be_empty
      expect(store.balance("a", 1000)).to eq(1000)
    end

    it "T15b [S] nonsense at the charge of one key goes to the hook and the others are charged" do
      store.on(:take, "b") { |args| args[:cost].positive? ? [0, 0] : :pass }
      store.spend("a", 10, 1000)
      cheap(schema_with(time), key: %w[a b c])
      expect(hook).to eq([l::ConfigurationError])
      expect(store.balance("a", 1000)).to eq(740)
      expect(store.balance("c", 1000)).to eq(750)
    end

    it "T16 [S] two Time limiters, String and list, charge only their own" do
      other = SeveralKeysProbes::Scripted.new
      schema = schema_with(time(key: ->(_q) { "u" }), time(store: other, key: ->(_q) { %w[a b] }))
      cheap(schema, key: nil)
      expect(store.balance("u", 1000)).to eq(750)
      expect(other.balance("a", 1000)).to eq(750)
      expect(other.balance("b", 1000)).to eq(750)
      expect(store.called(:take, "a")).to be_empty
    end

    it "T17 [S] RedisStore: each key charged the share, refused charges none, the record matches" do
      skip "no redis" if ENV["REDIS_URL"].to_s.empty?
      now = [1000.0]
      redis_store = l::RedisStore.new(redis: Redis.new(url: ENV.fetch("REDIS_URL")), prefix: "probe-#{SecureRandom.hex(6)}:", clock: -> { now[0] })
      balance = ->(key) { redis_store.take(key, cost: 0, limit: 1000, window: 60, force: false).last }
      schema = schema_with(time(store: redis_store))
      result = cheap(schema)
      expect([balance["a"], balance["b"]]).to eq([750, 750])
      expect(result.context[:rate_limit_time][:keys].map { |budget| budget[:remaining] }).to eq([750, 750])
      redis_store.take("b", cost: 1000, limit: 1000, window: 60, force: true)
      expect(refused?(cheap(schema))).to be_truthy
      expect(balance["a"]).to eq(750)
    end

    it "T18 [S] a resolver raising: every key charged" do
      expect { run(schema_with(time), "{ broken }", root_value: timed_root) }.to raise_error(IOError)
      expect(store.balance("a", 1000)).to eq(750)
      expect(store.balance("b", 1000)).to eq(750)
    end

    it "T19 [S] a list with its own trace raises" do
      expect { cheap(schema_with(time), trace: GraphQL::Tracing::Trace.new) }.to raise_error(l::ConfigurationError, /trace/)
      expect(store.calls).to be_empty
    end

    it "T20 [S] no key in the response JSON, allowed and refused" do
      store.spend("SECRET-b", 1000, 1000)
      schema = schema_with(time(extensions: true))
      refused = cheap(schema, key: %w[SECRET-a SECRET-b])
      allowed = cheap(schema, key: %w[SECRET-c SECRET-d])
      expect(refused?(refused)).to be_truthy
      expect(refused.to_h.to_json + allowed.to_h.to_json).not_to include("SECRET")
    end
  end

  describe "added after the first run" do
    # A redis client whose keys of one kind live on a shard that is down, as with Redis Cluster.
    let(:redis) { Redis.new(url: ENV.fetch("REDIS_URL", "redis://redis:6379/0")) }
    let(:shard_down) do
      real = redis
      Class.new do
        define_method(:evalsha) do |sha, keys:, argv:|
          raise IOError, "shard down" if keys.first.include?("ip:dead")

          real.evalsha(sha, keys: keys, argv: argv)
        end
        define_method(:eval) do |source, keys:, argv:|
          raise IOError, "shard down" if keys.first.include?("ip:dead")

          real.eval(source, keys: keys, argv: argv)
        end
      end.new
    end

    it "P11c [S] Redis, one shard down: an exhausted user rotating onto a dead-shard IP runs, unmetered, every time" do
      skip "no redis" if ENV["REDIS_URL"].to_s.empty?
      now = [1000.0]
      redis_store = l::RedisStore.new(redis: shard_down, prefix: "probe-#{SecureRandom.hex(6)}:", clock: -> { now[0] })
      schema = schema_with(points(store: redis_store))
      2.times { run(schema, key: ["user:1", "ip:alive"]) }
      expect(refused?(run(schema, key: ["user:1", "ip:alive"]))).to be_truthy
      resolved.clear
      3.times { run(schema, key: ["user:1", "ip:dead"]) }
      expect(resolved).to be_empty
    end

    it "C9c [S] on_store_error raising at the acquire of key 2: nothing runs, key 1 released" do
      store.on(:acquire, "b") { raise IOError, "down" }
      expect { run(schema_with(concurrency(on_store_error: loud))) }.to raise_error(/hook/)
      expect(resolved).to be_empty
      expect(store.held("a")).to eq(0)
    end

    it "T3b [S] on_store_error raising at the read: nothing runs, nothing owed" do
      store.on(:take, "b") { raise IOError, "down" }
      expect { run(schema_with(time(on_store_error: loud)), "{ cheap }", root_value: timed_root) }.to raise_error(/hook/)
      expect(resolved).to be_empty
      expect(store.called(:take, "a").map { |call| call[2][:cost] }).to eq([0])
    end

    it "T6b [S] a raising hook on one query's charge still charges the next query of the multiplex" do
      store.on(:take, "b") { |args| args[:cost].positive? ? raise(IOError, "down") : :pass }
      schema = schema_with(time(on_store_error: loud, key: by_operation("Q1" => %w[a b], "Q2" => %w[c d])))
      queries = %w[Q1 Q2].map { |name| { query: "query #{name} { cheap }", root_value: timed_root } }
      expect { mux(schema, queries) }.to raise_error(/hook/)
      expect(store.balance("c", 1000)).to eq(500 + 250)
      expect(store.balance("d", 1000)).to eq(500 + 250)
    end

    it "T6c [S] a raising hook on one key's charge hears that failure once" do
      store.on(:take, "b") { |args| args[:cost].positive? ? raise(IOError, "down") : :pass }
      expect { run(schema_with(time(on_store_error: loud)), "{ cheap }", root_value: timed_root) }.to raise_error(/hook/)
      expect(hook).to eq([IOError])
    end

    it "T6d [K] with one String a raising hook on the charge hears it once (the single-key stance)" do
      store.on(:take, "a") { |args| args[:cost].positive? ? raise(IOError, "down") : :pass }
      expect { run(schema_with(time(on_store_error: loud)), "{ cheap }", key: "a", root_value: timed_root) }.to raise_error(/hook/)
      expect(hook).to eq([IOError])
    end

    it "C19 [S] threads on Redis: never above the limit while running, nothing held at the end" do
      skip "no redis" if ENV["REDIS_URL"].to_s.empty?
      prefix = "probe-#{SecureRandom.hex(6)}:"
      redis_store = l::RedisStore.new(redis: redis, prefix: prefix)
      schema = schema_with(concurrency(store: redis_store, limit: 2))
      lock = Mutex.new
      running = 0
      peak = 0
      done = 0
      slow = Class.new do
        define_method(:cheap) do
          lock.synchronize { running += 1; peak = [peak, running].max }
          sleep 0.02
          lock.synchronize { running -= 1; done += 1 }
          "ok"
        end
      end.new
      Array.new(16) { Thread.new { 3.times { run(schema, "{ cheap }", root_value: slow) } } }.each(&:join)
      expect(done).to be > 0
      expect(peak).to be <= 2
      expect([redis.zcard("#{prefix}slots:a"), redis.zcard("#{prefix}slots:b")]).to eq([0, 0])
    end

    it "P25 [S] threads on Redis: never more runs than the smallest bucket pays for" do
      skip "no redis" if ENV["REDIS_URL"].to_s.empty?
      now = [1000.0]
      redis_store = l::RedisStore.new(redis: redis, prefix: "probe-#{SecureRandom.hex(6)}:", clock: -> { now[0] })
      schema = schema_with(points(store: redis_store))
      lock = Mutex.new
      runs = 0
      counting = Class.new { define_method(:report) { lock.synchronize { runs += 1 }; "big" } }.new
      Array.new(16) { Thread.new { 3.times { run(schema, root_value: counting) } } }.each(&:join)
      expect(runs).to be_between(1, 2)
    end
  end

  describe "mixed" do
    it "X1 [S] Points, Concurrency and Time on one schema, Points refuses: slots released, nothing runs" do
      store.spend("b", 100, 100)
      slots = l::Store::Substitute.new
      schema = schema_with(points(extensions: true), concurrency(store: slots), time(store: SeveralKeysProbes::Scripted.new))
      result = run(schema, root_value: timed_root)
      expect(refused?(result)).to be_truthy
      expect(resolved).to be_empty
      expect([slots.held("a"), slots.held("b")]).to eq([0, 0])
    end

    it "X2 [S] keys differ per query from a callable: one list, one String, one nil-limit list" do
      limit = ->(key, _q) { key == "free" ? nil : 100 }
      schema = schema_with(points(limit: limit, key: by_operation("Q1" => %w[a b], "Q2" => "c", "Q3" => %w[free a])))
      results = mux(schema, %w[Q1 Q2 Q3].map { |name| { query: "query #{name} { report }", root_value: root } })
      expect(results.map { |result| result["data"] }).to all(eq("report" => "big"))
      expect(results[0].context[:rate_limit_points][:keys].size).to eq(2)
      expect(results[1].context[:rate_limit_points]).not_to have_key(:keys)
      expect(results[2].context[:rate_limit_points][:keys].map { |budget| budget[:key] }).to eq(["a"])
      expect([store.balance("a", 100), store.balance("b", 100), store.balance("c", 100)]).to eq([20, 60, 60])
    end
  end
end
