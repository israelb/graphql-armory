# frozen_string_literal: true

require "redis"
require "json"
require "securerandom"

# Independent verifier's probes for PR #43. [S] security, [K] preservation. Security probes that pass on origin/main are "no coverage".
RSpec.describe "Time's own bucket: probes" do
  l = GraphQL::Armory::RateLimits
  points_class = l::Points
  time_class = l::Time
  concurrency_class = l::Concurrency

  define_method(:lim) { l }
  define_method(:pts) { points_class }
  define_method(:tim) { time_class }
  define_method(:con) { concurrency_class }

  let(:limiter_clock) { l::Clock::Substitute.new }
  let(:store_now) { [1_000.0] }
  let(:memory) { l::MemoryStore.new(clock: -> { store_now[0] }) }
  let(:redis) do
    skip "REDIS_URL is not set (docker compose and CI set it)" if ENV["REDIS_URL"].to_s.empty? && ENV["CI"].to_s.empty?
    Redis.new(url: ENV.fetch("REDIS_URL"))
  end
  let(:prefix) { "armory-probe:#{SecureRandom.hex(8)}:" }
  let(:redis_store) { l::RedisStore.new(redis: redis, prefix: prefix, clock: -> { store_now[0] }) }
  let(:resolved) { [] }

  def root(seconds: 0.3)
    lim::Controls::Time.example(limiter_clock, resolved, seconds: seconds)
  end

  def schema(*uses)
    query_type = lim::Controls::Query.example
    Class.new(base_schema) do
      query(query_type)
      uses.each { |klass, options| use klass, **options }
    end
  end

  def run_query(s, key: "k", query: "{ cheap }", seconds: 0.3, **context)
    execute_query(s, query, root_value: root(seconds: seconds), context: { rate_limit_key: key, **context })
  end

  def multiplex(s, queries)
    ArmoryEngine.next? ? s.multiplex_next(queries) : s.multiplex(queries)
  end

  def refused?(result)
    (result["errors"] || []).any? { |error| error.dig("extensions", "code") == "RATE_LIMITED" }
  end

  def p_opts(store, limit: 1000, window: 60, **rest)
    { store: store, limit: limit, window: window, soft: false, **rest }
  end

  def t_opts(store, limit: 10_000, window: 60, **rest)
    { store: store, limit: limit, window: window, soft: false, clock: limiter_clock, **rest }
  end

  { "MemoryStore" => :memory, "RedisStore" => :redis_store }.each do |name, store_name|
    describe "on #{name}" do
      let(:store) { send(store_name) }

      it "A1 [S] balances read from the store match what each limiter reports" do
        s = schema([pts, p_opts(store)], [tim, t_opts(store)])
        result = run_query(s)
        expect(result.context[:rate_limit_points][:remaining]).to eq(999)
        expect(result.context[:rate_limit_time][:remaining]).to eq(9700)
        expect(store.take("k", cost: 0, limit: 1000, window: 60, force: false).last).to eq(999)
        expect(store.take("time:k", cost: 0, limit: 10_000, window: 60, force: false).last).to eq(9700)
      end

      it "A2 [S] milliseconds never spend points: a slow query leaves the points budget" do
        s = schema([pts, p_opts(store, limit: 100)], [tim, t_opts(store)])
        run_query(s, seconds: 5.0)
        result = run_query(s, seconds: 0.0)
        expect(refused?(result)).to be(false)
        expect(result.context[:rate_limit_points][:remaining]).to eq(98)
      end

      it "A3 [S] points never spend milliseconds" do
        s = schema([pts, p_opts(store)], [tim, t_opts(store, limit: 100)])
        3.times { run_query(s, query: "{ report }", seconds: 0.0) }
        result = run_query(s, seconds: 0.0)
        expect(result.context[:rate_limit_time][:remaining]).to eq(100)
      end

      [%i[points time], %i[time points]].each do |order|
        it "A4 [S] #{order.join(" before ")}: fast-refilling Time never refills exhausted Points" do
          uses = { points: [pts, p_opts(store, limit: 10, window: 3600)], time: [tim, t_opts(store, limit: 1_000_000, window: 1)] }
          s = schema(*order.map { |n| uses[n] })
          10.times { run_query(s, seconds: 0.0) }
          store_now[0] += 1.0
          result = run_query(s, seconds: 0.0)
          expect(refused?(result)).to be(true)
          expect(result.context[:rate_limit_points][:limited]).to be(true)
          expect(resolved.size).to eq(10)
        end

        it "A5 [S] #{order.join(" before ")}: fast-refilling Points never refills exhausted Time" do
          uses = { points: [pts, p_opts(store, limit: 1_000_000, window: 1)], time: [tim, t_opts(store, limit: 10, window: 3600)] }
          s = schema(*order.map { |n| uses[n] })
          run_query(s, seconds: 1.0)
          count = resolved.size
          store_now[0] += 1.0
          result = run_query(s, seconds: 0.0)
          expect(refused?(result)).to be(true)
          expect(resolved.size).to eq(count)
        end

        it "A6 [S] #{order.join(" before ")}: a small Points limit never caps a big Time balance" do
          uses = { points: [pts, p_opts(store, limit: 10)], time: [tim, t_opts(store, limit: 100_000)] }
          s = schema(*order.map { |n| uses[n] })
          run_query(s, seconds: 0.1)
          result = run_query(s, seconds: 0.0)
          expect(result.context[:rate_limit_time][:remaining]).to eq(99_900)
          expect(result.context[:rate_limit_points][:remaining]).to eq(8)
        end
      end

      it "A7 [S] out of Points, Time full: refused, no field runs" do
        s = schema([pts, p_opts(store, limit: 1)], [tim, t_opts(store)])
        run_query(s, seconds: 0.0)
        result = run_query(s, seconds: 0.0)
        expect(refused?(result)).to be(true)
        expect(result["data"]).to be_nil
        expect(resolved.size).to eq(1)
      end

      it "A8 [K] out of Time, Points full: refused, no field runs" do
        s = schema([pts, p_opts(store)], [tim, t_opts(store, limit: 100)])
        run_query(s, seconds: 1.0)
        result = run_query(s, seconds: 0.0)
        expect(refused?(result)).to be(true)
        expect(result.context[:rate_limit_time][:limited]).to be(true)
        expect(resolved.size).to eq(1)
      end

      it "A9 [S] a list of keys: each limiter charges its own bucket per key, nil limits apart" do
        p_limit = ->(key, _q) { key == "u" ? 1000 : nil }
        t_limit = ->(key, _q) { key == "ip" ? 5000 : nil }
        s = schema([pts, p_opts(store, limit: p_limit)], [tim, t_opts(store, limit: t_limit)])
        result = run_query(s, key: %w[u ip])
        expect(result.context[:rate_limit_points][:remaining]).to eq(999)
        expect(result.context[:rate_limit_time][:remaining]).to eq(4700)
        expect(result.context[:rate_limit_time][:key]).to eq("ip")
        expect(store.take("time:ip", cost: 0, limit: 5000, window: 60, force: false).last).to eq(4700)
        expect(store.take("ip", cost: 0, limit: 7, window: 60, force: false).last).to eq(7)
        expect(store.take("time:u", cost: 0, limit: 7, window: 60, force: false).last).to eq(7)
      end

      it "A10 [S] a list of keys sharing both limits stays separate, on every key" do
        s = schema([pts, p_opts(store)], [tim, t_opts(store)])
        run_query(s, key: %w[u ip], seconds: 2.0)
        %w[u ip].each do |key|
          expect(store.take(key, cost: 0, limit: 1000, window: 60, force: false).last).to eq(999)
          expect(store.take("time:#{key}", cost: 0, limit: 10_000, window: 60, force: false).last).to eq(8000)
        end
      end

      it "A11 [K] a limiter's Time key starting with time: does not meet the same limiter's or Points' plain key" do
        s = schema([pts, p_opts(store, limit: 100, key: ->(_q) { "x" })], [tim, t_opts(store, key: ->(_q) { "time:x" })])
        run_query(s, seconds: 1.0)
        result = run_query(s, seconds: 0.0)
        expect(result.context[:rate_limit_points][:remaining]).to eq(98)
        expect(result.context[:rate_limit_time][:remaining]).to eq(9000)
      end

      it "A12 [K] a non-ASCII UTF-8 key and an invalid-bytes key keep working on Time" do
        ["josé", "\xFF\xFE", "ユーザー".encode("Shift_JIS"), "josé".encode("ISO-8859-1"), "josé".b].each do |key|
          s = schema([tim, t_opts(store, limit: 100)])
          run_query(s, key: key, seconds: 1.0)
          count = resolved.size
          result = run_query(s, key: key, seconds: 0.0)
          expect(refused?(result)).to be(true), "key #{key.encoding} was let through"
          expect(resolved.size).to eq(count)
        end
      end

      it "A13 [K] a query refused by each of Points, Concurrency and Time leaves no slot held" do
        s = schema([con, { store: store, limit: 5, soft: false }], [pts, p_opts(store, limit: 2)], [tim, t_opts(store, limit: 100)])
        run_query(s, seconds: 1.0) # Time now empty
        count = resolved.size
        refused = run_query(s, seconds: 0.0)
        expect(refused?(refused)).to be(true)
        expect(resolved.size).to eq(count)
        5.times { |i| expect(store.acquire("k", token: "probe#{i}", limit: 5, ttl: 60, force: false).first).to be(true) }
      end
    end
  end

  describe "Redis specifics" do
    it "R1 [S] docs: the keys are points:<key>, points:time:<key> and slots:<key>, and they all expire" do
      s = schema([con, { store: redis_store, limit: 5, soft: false }], [pts, p_opts(redis_store)], [tim, t_opts(redis_store)])
      run_query(s)
      keys = redis.keys("#{prefix}*").map { |key| key.delete_prefix(prefix) }.sort
      expect(keys).to eq(["points:k", "points:time:k"])
      redis.keys("#{prefix}*").each { |key| expect(redis.pttl(key)).to be_between(1, 61_000) }
      expect(redis.hget("#{prefix}points:k", "level").to_f).to eq(999.0)
      expect(redis.hget("#{prefix}points:time:k", "level").to_f).to eq(9700.0)
    end

    it "R2 [S] a short Time window never shortens the TTL of the long Points bucket" do
      s = schema([pts, p_opts(redis_store, window: 3600)], [tim, t_opts(redis_store, window: 1)])
      run_query(s, seconds: 0.0)
      expect(redis.pttl("#{prefix}points:k")).to be > 3_000_000
      expect(redis.pttl("#{prefix}points:time:k")).to be <= 2000
    end

    it "R3 [K] a UTF-16 key on Redis: same fail-open on Points as on Time (the store's own interpolation raises)" do
      errors = []
      key = "user".encode("UTF-16LE")
      s = schema([pts, p_opts(redis_store, on_store_error: ->(e, _q) { errors << e.class })])
      result = run_query(s, key: key)
      expect(result["data"]).to eq("cheap" => "ok")
      expect(errors).to eq([Encoding::CompatibilityError])
    end

    it "R4 [S] a corrupt Points bucket does not affect Time, and the reverse" do
      errors = []
      redis.hset("#{prefix}points:k", "level", "nope", "at", "nope")
      s = schema([pts, p_opts(redis_store, on_store_error: ->(e, _q) { errors << :points })], [tim, t_opts(redis_store, on_store_error: ->(e, _q) { errors << :time })])
      result = run_query(s)
      expect(errors).to eq([:points])
      expect(result.context[:rate_limit_time][:remaining]).to eq(9700)
    end
  end

  describe "ASCII-incompatible keys on MemoryStore" do
    utf16 = "user".encode("UTF-16LE")

    it "E1 [K] a UTF-16 key out of budget is refused by Time, as on main" do
      errors = []
      s = schema([tim, t_opts(memory, limit: 100, on_store_error: ->(e, _q) { errors << e.class })])
      run_query(s, key: utf16, seconds: 1.0)
      count = resolved.size
      result = run_query(s, key: utf16, seconds: 0.0)
      expect(errors).to eq([])
      expect(refused?(result)).to be(true)
      expect(resolved.size).to eq(count)
    end

    it "E2 [K] a UTF-16 key in a list stays charged and refused by Time, as on main" do
      s = schema([tim, t_opts(memory, limit: 100, on_store_error: ->(_e, _q) {})])
      run_query(s, key: [utf16, "other"], seconds: 1.0)
      result = run_query(s, key: [utf16], seconds: 0.0)
      expect(refused?(result)).to be(true)
    end

    it "E3 [K] Points on MemoryStore still takes a UTF-16 key" do
      s = schema([pts, p_opts(memory, limit: 1)])
      run_query(s, key: utf16, seconds: 0.0)
      expect(refused?(run_query(s, key: utf16, seconds: 0.0))).to be(true)
    end

    it "E4 [K] a UTF-16 key does not take the request down (fails open or refuses, no raise, default hook)" do
      s = schema([tim, t_opts(memory, limit: 100, on_store_error: ->(_e, _q) {})])
      expect { run_query(s, key: utf16) }.not_to raise_error
    end

    it "E5 [K] a list with keys differing only in encoding is still refused at key validation" do
      s = schema([tim, t_opts(memory)])
      expect { run_query(s, key: ["josé", "josé".b]) }.to raise_error(l::ConfigurationError, /no client key/)
    end

    it "E6 [K] same bytes in two encodings stay two buckets on MemoryStore, as on main" do
      s = schema([tim, t_opts(memory, limit: 100)])
      run_query(s, key: "josé", seconds: 1.0)
      expect(refused?(run_query(s, key: "josé".b, seconds: 0.0))).to be(false)
    end
  end

  describe "store failure" do
    let(:sub) { l::Store::Substitute.new }

    # Fails only the read (cost 0) or only the charge (cost > 0).
    def failing_store(on)
      Class.new(lim::Store::Substitute) do
        define_method(:take) do |key, cost:, limit:, window:, force: false|
          raise IOError, "down" if (on == :read && cost.zero? && !force) || (on == :charge && force)

          super(key, cost: cost, limit: limit, window: window, force: force)
        end
      end.new
    end

    it "F1 [K] read and charge both failing: the hook hears two errors, one key" do
      errors = []
      sub.fail_with(IOError.new("down"), on: :take)
      s = schema([tim, t_opts(sub, on_store_error: ->(e, _q) { errors << e.class })])
      result = run_query(s)
      expect(result["data"]).to eq("cheap" => "ok")
      expect(errors).to eq([IOError, IOError])
    end

    it "F2 [K] read and charge both failing: four errors, two keys" do
      errors = []
      sub.fail_with(IOError.new("down"), on: :take)
      s = schema([tim, t_opts(sub, on_store_error: ->(e, _q) { errors << e.class })])
      run_query(s, key: %w[a b])
      expect(errors.size).to eq(4)
    end

    it "F3 [K] read fails, charge finds the store back: charged" do
      errors = []
      sub.fail_with(IOError.new("down"), on: :take, times: 1)
      s = schema([tim, t_opts(sub, on_store_error: ->(e, _q) { errors << e.class })])
      result = run_query(s)
      expect(errors).to eq([IOError])
      expect(result.context[:rate_limit_time][:remaining]).to eq(9700)
    end

    it "F4 [K] only the charge fails: one error, record stays, no raise" do
      errors = []
      store = failing_store(:charge)
      s = schema([tim, t_opts(store, on_store_error: ->(e, _q) { errors << e.class })])
      result = run_query(s)
      expect(result["data"]).to eq("cheap" => "ok")
      expect(errors).to eq([IOError])
    end

    it "F5 [K] a hook raising at the read raises to the caller, nothing resolved" do
      sub.fail_with(IOError.new("down"), on: :take)
      s = schema([tim, t_opts(sub, on_store_error: ->(_e, _q) { raise ArgumentError, "hook" })])
      expect { run_query(s) }.to raise_error(ArgumentError, "hook")
      expect(resolved).to eq([])
    end

    it "F6 [K] a hook raising at the charge raises after the query ran" do
      store = failing_store(:charge)
      s = schema([tim, t_opts(store, on_store_error: ->(_e, _q) { raise ArgumentError, "hook" })])
      expect { run_query(s) }.to raise_error(ArgumentError, "hook")
      expect(resolved).to eq([:cheap])
    end

    it "F7 [S] a Points failure does not affect Time on the same store (only time: fails)" do
      errors = []
      store = Class.new(l::Store::Substitute) do
        define_method(:take) do |key, cost:, limit:, window:, force: false|
          raise IOError, "shard" if key.start_with?("time:")

          super(key, cost: cost, limit: limit, window: window, force: force)
        end
      end.new
      s = schema([pts, p_opts(store, on_store_error: ->(_e, _q) { errors << :points })], [tim, t_opts(store, on_store_error: ->(_e, _q) { errors << :time })])
      result = run_query(s)
      expect(errors).to eq(%i[time time])
      expect(result.context[:rate_limit_points][:remaining]).to eq(999)
    end

    it "F8 [K] sink hears the failure with the limiter and class, never a key" do
      heard = []
      sub.fail_with(IOError.new("down"), on: :take)
      s = schema([tim, t_opts(sub, on_store_error: ->(_e, _q) {}, sinks: [->(signal, data) { heard << [signal, data] }])])
      run_query(s)
      expect(heard.map(&:first)).to eq(%i[rate_limit_store_failed rate_limit_store_failed])
      expect(heard.map { |_s, d| d[:limiter] }.uniq).to eq([:time])
      expect(heard.inspect).not_to include("time:k")
    end
  end

  describe "what clients and hooks see" do
    let(:sub) { l::Store::Substitute.new }

    it "V1 [S] the store sees time:<key>, every read and charge, and Points the plain key" do
      s = schema([pts, p_opts(sub)], [tim, t_opts(sub)])
      run_query(s)
      takes = sub.calls.select { |c| c[0] == :take }
      expect(takes.map { |c| c[1] }.tally).to eq("k" => 1, "time:k" => 2)
    end

    it "V2 [S] records, extensions, headers and limit: callables never show the prefix" do
      seen = []
      limit = lambda { |key, _q|
        seen << key
        10_000
      }
      s = schema([pts, p_opts(sub, extensions: true)], [tim, t_opts(sub, limit: limit, extensions: true)])
      result = run_query(s)
      expect(seen).to eq(["k"])
      expect(result.context[:rate_limit_time][:key]).to eq("k")
      expect(result.context.namespace(:graphql_armory)[:time][:key]).to eq("k")
      expect(result.to_h.to_json).not_to include("time:")
      expect(result.context[:rate_limit_time].inspect).not_to include("time:")
      expect(tim.headers(result)).to eq("RateLimit-Time-Limit" => "10000", "RateLimit-Time-Remaining" => "9700", "RateLimit-Time-Reset" => "2")
      expect(result["extensions"]["rateLimitTime"]).to include("limit" => 10_000, "remaining" => 9700, "elapsed" => 300)
    end

    it "V3 [S] Points.headers still describe points, Time.headers ms, with both on one key" do
      s = schema([pts, p_opts(sub, extensions: true)], [tim, t_opts(sub, extensions: true)])
      result = run_query(s, seconds: 2.0)
      expect(pts.headers(result)).to eq("RateLimit-Limit" => "1000", "RateLimit-Remaining" => "999", "RateLimit-Reset" => "1")
      expect(result["extensions"]["rateLimit"]).to include("remaining" => 999)
      expect(result["extensions"]["rateLimitTime"]).to include("remaining" => 8000)
    end

    it "V4 [K] a list: record keys and hook-visible names are the client's" do
      s = schema([tim, t_opts(sub)])
      result = run_query(s, key: %w[a b])
      expect(result.context[:rate_limit_time][:keys].map { |b| b[:key] }).to eq(%w[a b])
      expect(result.context[:rate_limit_time][:key]).to eq("a").or eq("b")
      expect(result.context[:rate_limit_time][:keys].map { |b| b[:remaining] }).to eq([9700, 9700])
    end

    it "V5 [K] limit: list callable gets client keys, in a refusal too" do
      seen = []
      s = schema([tim, t_opts(sub, limit: lambda { |key, _q|
        seen << key
        1
      })])
      run_query(s, key: %w[a b], seconds: 1.0)
      expect(refused?(run_query(s, key: %w[a b], seconds: 0.0))).to be(true)
      expect(seen.uniq).to eq(%w[a b])
    end

    it "V6 [K] the refusal message names no bucket" do
      s = schema([tim, t_opts(sub, limit: 10)])
      run_query(s, seconds: 1.0)
      expect(run_query(s, seconds: 0.0).to_h.to_json).not_to include("time:")
    end

    it "V7 [K] on a limit nil for the key, Time reads no bucket and records the client's key" do
      s = schema([tim, t_opts(sub, limit: ->(_k, _q) {})])
      result = run_query(s)
      expect(sub.calls).to eq([])
      expect(result.context[:rate_limit_time][:key]).to eq("k")
    end

    it "V8 [K] a non-String key still raises ConfigurationError before the prefix hides it" do
      [nil, "", :sym, 1, [], ["a", :b], ["a", "a"]].each do |bad|
        s = schema([tim, t_opts(sub)])
        expect { run_query(s, key: bad) }.to raise_error(l::ConfigurationError, /no client key/)
      end
      expect(sub.calls).to eq([])
    end
  end

  describe "several limiters and schema shapes" do
    let(:sub) { l::Store::Substitute.new }
    let(:other) { l::Store::Substitute.new }

    it "S1 [S] use Time twice with different stores: each charges its own" do
      s = schema([tim, t_opts(sub, limit: 5000)], [tim, t_opts(other, limit: 7000)])
      run_query(s)
      expect(sub.take("time:k", cost: 0, limit: 5000, window: 60, force: false).last).to eq(4700)
      expect(other.take("time:k", cost: 0, limit: 7000, window: 60, force: false).last).to eq(6700)
    end

    it "S2 [S] use Time twice with different keys on one store" do
      s = schema([tim, t_opts(sub, key: ->(_q) { "u" })], [tim, t_opts(sub, key: ->(_q) { "ip" })])
      run_query(s)
      expect(sub.take("time:u", cost: 0, limit: 10_000, window: 60, force: false).last).to eq(9700)
      expect(sub.take("time:ip", cost: 0, limit: 10_000, window: 60, force: false).last).to eq(9700)
    end

    it "S3 [S] docs: two Time on one store and key share one bucket; each caps it" do
      s = schema([tim, t_opts(sub, limit: 5000)], [tim, t_opts(sub, limit: 100)])
      result = run_query(s, seconds: 0.05)
      expect(result.context[:rate_limit_time][:limit]).to eq(100)
      expect(sub.take("time:k", cost: 0, limit: 5000, window: 60, force: false).last).to be <= 100
    end

    it "S4 [K] docs: a Points key that is time:<key> meets the Time key" do
      s = schema([pts, p_opts(sub, key: ->(_q) { "time:k" })], [tim, t_opts(sub, key: ->(_q) { "k" })])
      run_query(s, seconds: 0.1)
      expect(sub.take("time:k", cost: 0, limit: 10_000, window: 60, force: false).last).to be < 1000
    end

    it "S5 [S] a subclass schema adding Time on a parent's Points keeps budgets apart" do
      parent = schema([pts, p_opts(sub, limit: 100)])
      child = Class.new(parent)
      child.use(tim, **t_opts(sub))
      run_query(child, seconds: 5.0)
      result = run_query(child, seconds: 0.0)
      expect(refused?(result)).to be(false)
      expect(result.context[:rate_limit_points][:remaining]).to eq(98)
      expect(result.context[:rate_limit_time][:remaining]).to eq(5000)
    end

    it "S6 [K] subclass adding Time on a parent's Time, other store: both charged once" do
      parent = schema([tim, t_opts(sub)])
      child = Class.new(parent)
      child.use(tim, **t_opts(other))
      run_query(child)
      expect(sub.calls.count { |c| c[2][:force] }).to eq(1)
      expect(other.calls.count { |c| c[2][:force] }).to eq(1)
    end

    it "S7 [S] soft mode: both over budget run, and balances stay apart" do
      s = schema([pts, { store: sub, limit: 10, window: 60 }], [tim, { store: sub, limit: 100, window: 60, clock: limiter_clock }])
      run_query(s, seconds: 0.05)
      result = run_query(s, seconds: 0.05)
      expect(result["data"]).to eq("cheap" => "ok")
      expect(result.context[:rate_limit_points][:remaining]).to eq(8)
      expect(result.context[:rate_limit_time][:remaining]).to eq(0)
    end

    it "S8 [K] soft Time on empty balance runs, and is reported limited, no refusal" do
      s = schema([tim, { store: sub, limit: 10, window: 60, clock: limiter_clock }])
      run_query(s, seconds: 1.0)
      result = run_query(s, seconds: 0.0)
      expect(result["data"]).to eq("cheap" => "ok")
      expect(result.context[:rate_limit_time][:limited]).to be(true)
    end

    it "S9 [S] an operation that raises is charged in the Time bucket" do
      s = schema([tim, t_opts(sub)])
      broken_root = Class.new do
        define_method(:broken) { raise IOError, "x" }
      end.new
      clock = limiter_clock
      slow = Class.new do
        define_method(:broken) do
          clock.advance(0.5)
          broken_root.broken
        end
      end.new
      expect { execute_query(s, "{ broken }", root_value: slow, context: { rate_limit_key: "k" }) }.to raise_error(IOError)
      expect(sub.take("time:k", cost: 0, limit: 10_000, window: 60, force: false).last).to eq(9500)
    end

    it "S10 [S] a multiplex splits the time in the Time bucket, and points only in the points one" do
      s = schema([pts, p_opts(sub)], [tim, t_opts(sub)])
      queries = Array.new(2) { { query: "{ cheap }", context: { rate_limit_key: "k" }, root_value: root(seconds: 0.5) } }
      results = multiplex(s, queries)
      expect(results.map { |r| r["data"] }).to all(eq("cheap" => "ok"))
      expect(sub.take("k", cost: 0, limit: 1000, window: 60, force: false).last).to eq(998)
      expect(sub.take("time:k", cost: 0, limit: 10_000, window: 60, force: false).last).to eq(9000)
    end

    it "S11 [S] a multiplex with one key out of Time: that query is refused, the other runs" do
      s = schema([pts, p_opts(sub)], [tim, t_opts(sub, limit: 100)])
      run_query(s, key: "a", seconds: 1.0)
      queries = %w[a b].map { |key| { query: "{ cheap }", context: { rate_limit_key: key }, root_value: root(seconds: 0.01) } }
      results = multiplex(s, queries)
      expect(refused?(results[0])).to be(true)
      expect(results[1]["data"]).to eq("cheap" => "ok")
      expect(sub.take("a", cost: 0, limit: 1000, window: 60, force: false).last).to be >= 998
    end

    it "S12 [K] context[:trace] is still refused" do
      s = schema([tim, t_opts(sub)])
      trace = GraphQL::Tracing::Trace.new
      expect { run_query(s, trace: trace) }.to raise_error(l::ConfigurationError, /its own trace/)
    end

    it "S13 [K] Time.new with no store refuses every query" do
      query_type = l::Controls::Query.example
      s = Class.new(base_schema) { query(query_type) }
      tim.new.install(s)
      result = run_query(s)
      expect(refused?(result)).to be(true)
      expect(resolved).to eq([])
    end

    it "S14 [S] graphql-ruby's install template shape (dataloader, max_complexity) with both on one key" do
      store = sub
      clock = limiter_clock
      query_type = l::Controls::Query.example
      t = tim
      po = pts
      s = Class.new(base_schema) do
        query(query_type)
        use GraphQL::Dataloader
        max_query_string_tokens(5000)
        validate_max_errors(100)
        default_max_page_size(50)
        use po, store: store, limit: 100, window: 60, soft: false
        use t, store: store, limit: 1000, window: 60, soft: false, clock: clock
      end
      result = run_query(s, seconds: 0.5)
      expect(result.context[:rate_limit_points][:remaining]).to eq(99)
      expect(result.context[:rate_limit_time][:remaining]).to eq(500)
    end

    it "S15 [S] who answers: bucket_key is Time's own, take is the store's" do
      expect(tim.method(:bucket_key).owner).to eq(tim.singleton_class)
      expect(sub.method(:take).owner).to eq(l::Store::Substitute)
      expect(tim.bucket_key("k")).to eq("time:k")
      expect(tim.bucket_key("time:k")).to eq("time:time:k")
    end
  end

  describe "custom stores" do
    it "C1 [K] a store with the documented take signature boots and enforces Time" do
      klass = Class.new do
        attr_reader :keys

        def initialize
          @memory = GraphQL::Armory::RateLimits::MemoryStore.new(clock: -> { 0.0 })
          @keys = []
        end

        def take(key, cost:, limit:, window:, force: false)
          @keys << key
          @memory.take(key, cost: cost, limit: limit, window: window, force: force)
        end
      end
      store = klass.new
      s = schema([tim, t_opts(store, limit: 100)])
      run_query(s, seconds: 1.0)
      expect(refused?(run_query(s, seconds: 0.0))).to be(true)
      expect(store.keys.uniq.size).to eq(1)
    end

    it "C2 [K] a keyrest store works too, and a wrong answer still raises" do
      store = Class.new do
        def take(_key, **_options)
          [true, -1]
        end
      end.new
      s = schema([tim, t_opts(store)])
      expect { run_query(s) }.to raise_error(l::ConfigurationError, /store: take answered/)
    end
  end

  describe "CHANGELOG claims about upgrading" do
    it "U1 [S] Time starts full after upgrading; old data at <key> does not matter to it" do
      memory.take("k", cost: 9_000, limit: 10_000, window: 60, force: true)
      s = schema([tim, t_opts(memory)])
      expect(run_query(s, seconds: 0.0).context[:rate_limit_time][:remaining]).to eq(10_000)
    end

    it "U2 [K] CHANGELOG: Points keeps its key, so a balance the mix drained stays drained until it refills" do
      # The state a pre-upgrade mix left: Time emptied the shared bucket at the client's key.
      memory.take("k", cost: 1_000_000, limit: 1000, window: 60, force: true)
      s = schema([pts, p_opts(memory)], [tim, t_opts(memory)])
      result = run_query(s, seconds: 0.0)
      expect(refused?(result)).to be(true)
    end
  end
  describe "Points and Concurrency as they were, and refusals in turn" do
    let(:sub) { l::Store::Substitute.new }

    it "P1 [K] Points alone: plain key, same numbers, same headers" do
      s = schema([pts, p_opts(sub, extensions: true)])
      result = run_query(s, query: "{ report }")
      expect(sub.calls.map { |c| c[1] }).to eq(["k"])
      expect(result.context[:rate_limit_points]).to include(key: "k", cost: 40, remaining: 960)
      expect(result["extensions"]["rateLimit"]).to include("cost" => 40, "remaining" => 960)
    end

    it "P2 [K] Concurrency alone: plain key, released" do
      s = schema([con, { store: sub, limit: 1, soft: false }])
      run_query(s)
      expect(sub.calls.map { |c| [c[0], c[1]] }).to eq([[:acquire, "k"], [:release, "k"]])
      expect(sub.held("k")).to eq(0)
    end

    it "P3 [K] Concurrency full: refused, nothing resolved, the other slot still held" do
      sub.occupy("k")
      s = schema([con, { store: sub, limit: 1, soft: false }], [pts, p_opts(sub)], [tim, t_opts(sub)])
      result = run_query(s)
      expect(result["data"]).to be_nil
      expect(resolved).to eq([])
      expect(sub.held("k")).to eq(1)
    end

    it "P4 [K] Points refuses with Concurrency and Time: slot released, nothing resolved" do
      s = schema([con, { store: sub, limit: 5, soft: false }], [pts, p_opts(sub, limit: 1)], [tim, t_opts(sub)])
      run_query(s, seconds: 0.0)
      result = run_query(s, seconds: 0.0)
      expect(refused?(result)).to be(true)
      expect(resolved.size).to eq(1)
      expect(sub.held("k")).to eq(0)
    end

    it "X1 [K] observe: a query Time refuses, does Points still charge it? (report)" do
      s = schema([pts, p_opts(sub)], [tim, t_opts(sub, limit: 1000)])
      run_query(s, key: "a", seconds: 2.0)
      result = run_query(s, key: "a", seconds: 0.0)
      expect(refused?(result)).to be(true)
      expect(result.context[:rate_limit_points][:remaining]).to eq(998)
    end

    it "X2 [K] observe: a query Points refuses is still charged by Time for its elapsed time" do
      ticking = Class.new do
        def initialize = @t = 0.0
        def call = (@t += 0.001)
      end.new
      s = schema([pts, p_opts(sub, limit: 1)], [tim, { store: sub, limit: 10_000, window: 60, soft: false, clock: ticking }])
      execute_query(s, "{ cheap }", root_value: root(seconds: 0.0), context: { rate_limit_key: "k" })
      before = sub.calls.count { |c| c[2][:force] }
      refused = execute_query(s, "{ cheap }", root_value: root(seconds: 0.0), context: { rate_limit_key: "k" })
      expect(refused?(refused)).to be(true)
      expect(sub.calls.count { |c| c[2][:force] }).to eq(before + 1)
    end

    it "R5 [S] a corrupt Time bucket fails open with the hook, Points still enforces" do
      redis.hset("#{prefix}points:time:k", "level", "nope", "at", "nope")
      errors = []
      s = schema([pts, p_opts(redis_store, limit: 1)], [tim, t_opts(redis_store, on_store_error: ->(_e, _q) { errors << :time })])
      run_query(s, seconds: 0.0)
      expect(errors).to eq(%i[time time])
      expect(refused?(run_query(s, seconds: 0.0))).to be(true)
    end
  end
  describe "pre-existing checks, added after the first run" do
    it "E7 [K] Redis: a UTF-16 Time key already fails open on main and on the branch" do
      errors = []
      key = "user".encode("UTF-16LE")
      s = schema([tim, t_opts(redis_store, limit: 100, on_store_error: ->(e, _q) { errors << e.class })])
      run_query(s, key: key, seconds: 1.0)
      expect(refused?(run_query(s, key: key, seconds: 0.0))).to be(false)
      expect(errors.uniq).to eq([Encoding::CompatibilityError])
    end

    it "X3 [K] separate stores: a query Time refuses still spends Points (pre-existing)" do
      a = l::Store::Substitute.new
      b = l::Store::Substitute.new
      s = schema([pts, p_opts(a)], [tim, t_opts(b, limit: 100)])
      run_query(s, seconds: 1.0)
      result = run_query(s, seconds: 0.0)
      expect(refused?(result)).to be(true)
      expect(result.context[:rate_limit_points][:remaining]).to eq(998)
    end
  end
end
