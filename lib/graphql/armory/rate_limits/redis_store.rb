# frozen_string_literal: true

require "digest"

module GraphQL
  module Armory
    module RateLimits
      # Buckets and slots kept in Redis, shared by every process of the app: the store for production.
      #
      #   store = GraphQL::Armory::RateLimits::RedisStore.new(redis: Redis.new(url: ENV.fetch("REDIS_URL")))
      #
      # Each change is one Lua script, so concurrent requests never race, and the time comes from Redis's own clock,
      # so processes on different machines agree on it. Keys live under `prefix` and expire once they no longer
      # matter. `redis:` is a redis-rb client (>= 4.8), or anything answering `eval` and `evalsha` the same way;
      # its errors reach the limiters, which let the query through and call `on_store_error`. This gem does not
      # depend on the redis gem: the app adds it.
      class RedisStore
        DEFAULT_PREFIX = "graphql-armory:rate-limits:"

        # The time in seconds: the one given by the caller (tests), or Redis's own clock.
        CLOCK = <<~LUA
          local function clock(given)
            if given ~= "" then return tonumber(given) end
            local time = redis.call("TIME")
            return tonumber(time[1]) + tonumber(time[2]) / 1000000
          end
        LUA

        # Same token bucket as MemoryStore#take. The bucket expires once a whole window has passed: it is full
        # again by then, the same as no bucket at all. An expiry is only ever pushed later, never brought closer, so
        # a limiter with a shorter window sharing the key cannot cut it short. The points left go back as a string:
        # Redis would truncate a Lua number past 2**63. A bucket whose fields are not numbers is an error, so the
        # limiter calls on_store_error instead of reading it as full.
        TAKE = <<~LUA
          #{CLOCK}
          local cost, limit, window = tonumber(ARGV[1]), tonumber(ARGV[2]), tonumber(ARGV[3])
          local force, now = ARGV[4] == "1", clock(ARGV[5])
          local state = redis.call("HMGET", KEYS[1], "level", "at")
          local level, at = tonumber(state[1]), tonumber(state[2])
          if not (state[1] or state[2]) then
            level, at = limit, now
          elseif not (level and at) or level ~= level or at ~= at or level < 0 or level == math.huge or math.abs(at) == math.huge then
            return redis.error_reply("graphql-armory: corrupt rate limit bucket at " .. KEYS[1])
          end
          level = math.min(level + math.max(now - at, 0) * limit / window, limit)

          local taken = cost <= level
          if taken or force then level = math.max(level - cost, 0) end
          redis.call("HSET", KEYS[1], "level", string.format("%.17g", level), "at", string.format("%.17g", math.max(now, at)))
          local keep = math.ceil(window * 1000) + 1000
          if redis.call("PTTL", KEYS[1]) < keep then redis.call("PEXPIRE", KEYS[1], keep) end

          return { taken and 1 or 0, string.format("%.0f", math.floor(level)) }
        LUA

        # Same slots as MemoryStore#acquire: a sorted set of tokens scored by when they expire. The key lives as long
        # as its latest slot, whatever ttl each acquire passed.
        ACQUIRE = <<~LUA
          #{CLOCK}
          local token, limit, ttl = ARGV[1], tonumber(ARGV[2]), tonumber(ARGV[3])
          local force, now = ARGV[4] == "1", clock(ARGV[5])
          redis.call("ZREMRANGEBYSCORE", KEYS[1], "-inf", string.format("%.17g", now))

          local acquired = redis.call("ZCARD", KEYS[1]) < limit
          if acquired or force then
            redis.call("ZADD", KEYS[1], string.format("%.17g", now + ttl), token)
            local latest = tonumber(redis.call("ZRANGE", KEYS[1], -1, -1, "WITHSCORES")[2])
            redis.call("PEXPIRE", KEYS[1], math.ceil((latest - now) * 1000) + 1000)
          end

          return { acquired and 1 or 0, redis.call("ZCARD", KEYS[1]) }
        LUA

        RELEASE = <<~LUA
          return redis.call("ZREM", KEYS[1], ARGV[1])
        LUA

        def initialize(redis:, prefix: DEFAULT_PREFIX, clock: nil)
          unless redis.respond_to?(:eval) && redis.respond_to?(:evalsha)
            raise ConfigurationError, "redis: must be a Redis client that runs scripts (eval and evalsha), like Redis.new from the redis gem"
          end
          raise ConfigurationError, "prefix: must be a non-empty String, got #{prefix.inspect}" unless prefix.is_a?(String) && !prefix.empty?
          raise ConfigurationError, "clock: must be nil (Redis's clock) or answer call with the time in seconds" unless clock.nil? || clock.respond_to?(:call)

          @redis = redis
          @prefix = prefix
          @clock = clock
        end

        def take(key, cost:, limit:, window:, force: false)
          taken, level = script(TAKE, "#{@prefix}points:#{key}", cost, limit, seconds(window), flag(force), now)
          [taken == 1, Integer(level, 10)]
        end

        def acquire(key, token:, limit:, ttl:, force: false)
          acquired, held = script(ACQUIRE, "#{@prefix}slots:#{key}", token, limit, seconds(ttl), flag(force), now)
          [acquired == 1, held]
        end

        def release(key, token:)
          script(RELEASE, "#{@prefix}slots:#{key}", token)
          nil
        end

        private

        def flag(value)
          value ? "1" : "0"
        end

        # Lua reads decimal numbers only: not "1/2" (a Rational) nor a Time.
        def seconds(value)
          Float(value).to_s
        end

        def now
          @clock ? seconds(@clock.call.to_f) : ""
        end

        # EVALSHA sends only the script's digest; Redis forgets scripts on restart or SCRIPT FLUSH, and then EVAL
        # sends it whole once more.
        def script(source, key, *argv)
          argv = argv.map(&:to_s)
          @redis.evalsha(Digest::SHA1.hexdigest(source), keys: [key], argv: argv)
        rescue StandardError => error
          raise unless error.message.start_with?("NOSCRIPT")

          @redis.eval(source, keys: [key], argv: argv)
        end
      end
    end
  end
end
