# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      class RedisStore
        # One Lua script per operation, so each one is atomic and one round trip. Layout (`P` is the prefix):
        #
        #   P r:<id>        hash with a PX TTL: sealed, viewer, topics (JSON array of digests), expires_at (ms)
        #   P t:<topic>     sorted set of ids scored by expires_at, trimmed on read, expiring with its longest record
        #   P v:<viewer>    the same per viewer digest
        #   P x             sorted set of every id scored by expires_at, no TTL: what `cleanup` walks
        #
        # The clock is the caller's `now` (Integer ms) in every script, never Redis's `TIME`: the core, MemoryStore
        # and every process then agree on what is live, and the examples can move time. Only the TTLs (relative:
        # `expires_at - now`) are Redis's own countdown; they are a memory bound, never what decides liveness.
        module Scripts
          PRELUDE = <<~LUA
            local function ms(value)
              return string.format("%.0f", value)
            end

            -- Drops what is expired at `now` from a sorted set, then answers the number of live members.
            local function live(key, now)
              redis.call("ZREMRANGEBYSCORE", key, "-inf", now)
              return redis.call("ZCARD", key)
            end

            -- Lets an index live as long as its longest record.
            local function extend(key, now)
              local last = redis.call("ZREVRANGE", key, 0, 0, "WITHSCORES")
              if last[2] then redis.call("PEXPIRE", key, ms(math.max(tonumber(last[2]) - now, 1))) end
            end

            -- Removes the id from the indexes the record names. A record that is gone, or one someone rewrote
            -- into something unreadable, has no names: its index entries then die by score or by TTL.
            local function unindex(prefix, id)
              local fields = redis.call("HMGET", prefix .. "r:" .. id, "viewer", "topics")
              if fields[1] then redis.call("ZREM", prefix .. "v:" .. fields[1], id) end
              if fields[2] then
                local ok, topics = pcall(cjson.decode, fields[2])
                if ok and type(topics) == "table" then
                  for _, topic in ipairs(topics) do
                    if type(topic) == "string" then redis.call("ZREM", prefix .. "t:" .. topic, id) end
                  end
                end
              end
              return redis.call("DEL", prefix .. "r:" .. id)
            end
          LUA

          # KEYS: record, viewer set, expiry set, topic sets... ARGV: id, sealed, viewer, topics (JSON), expires_at,
          # viewer_cap or "", topic_cap or "", now. Answers "ok", "exists", "viewer_cap" or "topic_cap"; a refused
          # write stores nothing (the sets it trimmed held only expired ids).
          WRITE = <<~LUA
            #{PRELUDE}
            local now, expires_at = tonumber(ARGV[8]), ARGV[5]
            if redis.call("EXISTS", KEYS[1]) == 1 or redis.call("ZSCORE", KEYS[3], ARGV[1]) then return "exists" end

            if ARGV[6] ~= "" and live(KEYS[2], now) >= tonumber(ARGV[6]) then return "viewer_cap" end
            if ARGV[7] ~= "" then
              for index = 4, #KEYS do
                if live(KEYS[index], now) >= tonumber(ARGV[7]) then return "topic_cap" end
              end
            end

            redis.call("HSET", KEYS[1], "sealed", ARGV[2], "viewer", ARGV[3], "topics", ARGV[4], "expires_at", expires_at)
            redis.call("PEXPIRE", KEYS[1], ms(tonumber(expires_at) - now))
            redis.call("ZADD", KEYS[3], expires_at, ARGV[1])
            redis.call("ZADD", KEYS[2], expires_at, ARGV[1])
            extend(KEYS[2], now)
            for index = 4, #KEYS do
              redis.call("ZADD", KEYS[index], expires_at, ARGV[1])
              extend(KEYS[index], now)
            end
            return "ok"
          LUA

          # KEYS: topic set. ARGV: now. Answers the live ids, after trimming the expired ones.
          IDS = <<~LUA
            #{PRELUDE}
            redis.call("ZREMRANGEBYSCORE", KEYS[1], "-inf", ARGV[1])
            return redis.call("ZRANGEBYSCORE", KEYS[1], "(" .. ARGV[1], "+inf")
          LUA

          # KEYS: viewer set. ARGV: now. Answers the number of live records.
          COUNT = <<~LUA
            #{PRELUDE}
            return live(KEYS[1], tonumber(ARGV[1]))
          LUA

          # KEYS: expiry set. ARGV: id, prefix. Answers 1 when the id was stored (its record, or only its expiry
          # entry once the TTL took the record), else 0.
          DELETE = <<~LUA
            #{PRELUDE}
            local removed = unindex(ARGV[2], ARGV[1])
            return math.max(removed, redis.call("ZREM", KEYS[1], ARGV[1]))
          LUA

          # KEYS: expiry set. ARGV: now, prefix, batch size. Removes up to `batch` records expired at `now` with their
          # index entries and answers how many.
          CLEANUP = <<~LUA
            #{PRELUDE}
            local expired = redis.call("ZRANGEBYSCORE", KEYS[1], "-inf", ARGV[1], "LIMIT", 0, tonumber(ARGV[3]))
            for _, id in ipairs(expired) do
              unindex(ARGV[2], id)
              redis.call("ZREM", KEYS[1], id)
            end
            return #expired
          LUA
        end
      end
    end
  end
end
