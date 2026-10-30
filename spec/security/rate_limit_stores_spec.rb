# frozen_string_literal: true

require "redis"
require "securerandom"

# The stores behind the rate limiters. MemoryStore keeps buckets in one process; RedisStore keeps them in Redis,
# so every process of an app shares them, and each change is one atomic script.
RSpec.describe "rate limit stores" do
  let(:now) { [1_000.0] }

  describe GraphQL::Armory::RateLimits::MemoryStore do
    let(:store) { GraphQL::Armory::RateLimits::MemoryStore.new(clock: -> { now[0] }) }

    it_behaves_like "a rate limit store"
  end

  describe GraphQL::Armory::RateLimits::RedisStore do
    before do
      skip "REDIS_URL is not set (docker compose and CI set it)" if ENV["REDIS_URL"].to_s.empty? && ENV["CI"].to_s.empty?
    end

    let(:redis) { Redis.new(url: ENV.fetch("REDIS_URL")) }
    # A fresh prefix per example: runs that share one Redis never see each other's keys.
    let(:prefix) { "graphql-armory-test:#{SecureRandom.hex(8)}:" }
    let(:store) { GraphQL::Armory::RateLimits::RedisStore.new(redis: redis, prefix: prefix, clock: -> { now[0] }) }

    it_behaves_like "a rate limit store"

    it "shares buckets and slots between stores on the same Redis, as processes of one app do" do
      other = GraphQL::Armory::RateLimits::RedisStore.new(redis: Redis.new(url: ENV.fetch("REDIS_URL")), prefix: prefix, clock: -> { now[0] })
      store.take("user:1", cost: 70, limit: 100, window: 60)
      store.acquire("user:1", token: "a", limit: 1, ttl: 60)

      expect(other.take("user:1", cost: 40, limit: 100, window: 60)).to eq([false, 30])
      expect(other.acquire("user:1", token: "b", limit: 1, ttl: 60)).to eq([false, 1])
    end

    it "never hands out more points than the bucket holds when many clients take at once" do
      stores = 8.times.map { GraphQL::Armory::RateLimits::RedisStore.new(redis: Redis.new(url: ENV.fetch("REDIS_URL")), prefix: prefix, clock: -> { now[0] }) }
      answers = stores.map { |each| Thread.new { 10.times.map { each.take("user:1", cost: 3, limit: 100, window: 60) } } }.flat_map(&:value)

      expect(answers.count { |taken, _| taken }).to eq(33)
    end

    it "keeps its keys under the prefix, and lets them expire" do
      store.take("user:1", cost: 1, limit: 100, window: 60)
      store.acquire("user:1", token: "a", limit: 1, ttl: 30)

      keys = redis.keys("#{prefix}*").sort
      expect(keys).to eq(["#{prefix}points:user:1", "#{prefix}slots:user:1"])
      expect(keys.map { |key| redis.ttl(key) }).to all(be_between(1, 61))
    end

    it "never lets a shorter ttl or window cut short a key that still holds live slots or points" do
      store.acquire("user:1", token: "long", limit: 2, ttl: 600)
      store.acquire("user:1", token: "short", limit: 2, ttl: 1)
      store.take("user:1", cost: 1, limit: 100, window: 600)
      store.take("user:1", cost: 1, limit: 100, window: 0.5)

      expect([redis.pttl("#{prefix}slots:user:1"), redis.pttl("#{prefix}points:user:1")]).to all(be > 599_000)
    end

    it "answers as MemoryStore does for a Rational window or ttl, a Time clock and a huge limit" do
      memory = GraphQL::Armory::RateLimits::MemoryStore.new(clock: -> { Time.at(now[0]) })
      redis_store = GraphQL::Armory::RateLimits::RedisStore.new(redis: redis, prefix: prefix, clock: -> { Time.at(now[0]) })
      calls = lambda do |each|
        answers = [each.take("a", cost: 1, limit: 10, window: 1/2r), each.acquire("a", token: "t", limit: 1, ttl: 3/2r)]
        now[0] += 1
        answers + [each.take("a", cost: 1, limit: 10, window: 1/2r), each.acquire("a", token: "u", limit: 1, ttl: 3/2r),
                   each.take("huge", cost: 1, limit: 10**19, window: 60)]
      end

      first = calls.call(memory)
      now[0] -= 1
      expect(calls.call(redis_store)).to eq(first)
    end

    it "reads Redis's own clock when no clock is given, so every process agrees on the time" do
      store = GraphQL::Armory::RateLimits::RedisStore.new(redis: redis, prefix: prefix)

      expect(2.times.map { store.take("user:1", cost: 40, limit: 100, window: 3_600) }).to eq([[true, 60], [true, 20]])
    end

    it "loads its scripts again after Redis forgets them" do
      store.take("user:1", cost: 40, limit: 100, window: 60)
      redis.script(:flush)

      expect(store.take("user:1", cost: 40, limit: 100, window: 60)).to eq([true, 20])
    end

    it "serves the limiters, and lets queries through when Redis is down" do
      query = Class.new(GraphQL::Schema::Object) do
        graphql_name "Query"
        field :report, String, null: false, complexity: 40
      end
      store = self.store
      seen = []
      down = GraphQL::Armory::RateLimits::RedisStore.new(redis: Redis.new(url: "redis://127.0.0.1:1", reconnect_attempts: 0), prefix: prefix)
      schema_for = lambda do |used|
        Class.new(ArmoryEngine.base_schema) do
          query query
          use GraphQL::Armory::RateLimits::Points, store: used, limit: 100, window: 60, soft: false, on_store_error: ->(error, _query) { seen << error.class }
          use GraphQL::Armory::RateLimits::Concurrency, store: used, limit: 1, soft: false, on_store_error: ->(error, _query) { seen << error.class }
        end
      end
      root = Class.new { def report = "big" }.new
      run = ->(schema) { execute_query(schema, "{ report }", context: { rate_limit_key: "user:1" }, root_value: root) }

      results = 3.times.map { run.call(schema_for.call(store)) }
      expect(results.map { |result| result.to_h.dig("errors", 0, "extensions", "code") }).to eq([nil, nil, "RATE_LIMITED"])
      expect(store.acquire("user:1", token: "probe", limit: 1, ttl: 60)).to eq([true, 1])

      expect(run.call(schema_for.call(down)).to_h).to eq("data" => { "report" => "big" })
      expect(seen).not_to be_empty
    end

    it "refuses at boot a redis: that cannot run scripts, or a bad prefix or clock" do
      refused = ->(pattern, **options) { expect { GraphQL::Armory::RateLimits::RedisStore.new(redis: redis, **options) }.to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, pattern) }

      expect { GraphQL::Armory::RateLimits::RedisStore.new(redis: Object.new) }.to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, /redis/)
      refused.call(/prefix/, prefix: "")
      refused.call(/prefix/, prefix: :armory)
      refused.call(/clock/, clock: 5)
    end
  end
end
