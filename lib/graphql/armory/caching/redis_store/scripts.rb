# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      class RedisStore
        # One Lua script per operation, so each one is atomic and one round trip. Every script reads the meta hash
        # (KEYS[1]); the entry scripts also read the entry hash (KEYS[2]). Layout:
        #
        #   <prefix>meta            hash, no TTL: epoch, seq, max_ttl (seconds), cursor, and m:<tag digest> => "<seq>:<ms>"
        #   <prefix>e:<key digest>  hash expiring with the entry: blob, tags (JSON array of digests), expires_at (ms)
        #
        # The clock is Redis's own (`TIME`, in Integer milliseconds), so processes on different machines agree on it.
        # Scripts call `TIME` and `HSCAN` before writing, which needs Redis 5 or later (scripts replicate their effects).
        module Scripts
          PRELUDE = <<~LUA
            local function now_ms()
              local time = redis.call("TIME")
              return tonumber(time[1]) * 1000 + math.floor(tonumber(time[2]) / 1000)
            end

            local function ms(value)
              return string.format("%.0f", value)
            end

            -- The meta record. A missing one, or one whose epoch or seq cannot be read, is replaced by a fresh one with
            -- the candidate epoch and seq 0: a lost meta record is "everything purged". It also keeps the longest
            -- max_ttl of every store on this prefix, so a store with a shorter one never prunes a mark another
            -- store's runs still need.
            local function meta(key, candidate, max_ttl)
              local state = redis.call("HMGET", key, "epoch", "seq", "max_ttl")
              local epoch, seq, kept = state[1], tonumber(state[2]), tonumber(state[3])
              if not epoch or epoch == "" or not seq or seq < 0 or seq ~= math.floor(seq) then
                redis.call("DEL", key)
                redis.call("HSET", key, "epoch", candidate, "seq", 0, "max_ttl", max_ttl)
                return candidate, 0
              end
              if not kept or kept < max_ttl then redis.call("HSET", key, "max_ttl", max_ttl) end
              return epoch, seq
            end

            -- A tag's purge mark (the seq of its latest purge), or nil. A mark that does not parse is an error: the
            -- caller runs the query uncached rather than answer an entry without the mark that may reject it.
            local function mark(key, tag)
              local value = redis.call("HGET", key, "m:" .. tag)
              if not value then return nil end
              local seq = tonumber(string.match(value, "^(%d+):%d+$"))
              if not seq then error({ err = "graphql-armory: corrupt purge mark in " .. key }) end
              return seq
            end
          LUA

          # KEYS: meta, entry. ARGV: candidate epoch, max_ttl.
          # Answers { blob or nil, tags, { tag, mark, ... }, seq, epoch, now }. Anything under the entry key that is not
          # one of its records, or is expired, is a miss.
          LOOKUP = <<~LUA
            #{PRELUDE}
            local now = now_ms()
            local epoch, seq = meta(KEYS[1], ARGV[1], tonumber(ARGV[2]))
            local blob, tags, marks = false, {}, {}

            if redis.call("TYPE", KEYS[2]).ok == "hash" then
              local entry = redis.call("HMGET", KEYS[2], "blob", "tags", "expires_at")
              local expires_at = tonumber(entry[3])
              if entry[1] and entry[2] and expires_at and now < expires_at then
                local ok, decoded = pcall(cjson.decode, entry[2])
                local valid = ok and type(decoded) == "table"
                if valid then
                  for _, tag in ipairs(decoded) do
                    if type(tag) ~= "string" then valid = false end
                  end
                end
                if valid then
                  blob, tags = entry[1], decoded
                  for _, tag in ipairs(tags) do
                    local purged = mark(KEYS[1], tag)
                    if purged then
                      table.insert(marks, tag)
                      table.insert(marks, purged)
                    end
                  end
                end
              end
            end

            return { blob, tags, marks, seq, epoch, now }
          LUA

          # KEYS: meta, entry. ARGV: candidate epoch, max_ttl, blob, tags (JSON), ttl, seq, epoch, stored_at.
          # Answers 1 when stored, 0 when refused: another epoch, a seq ahead of the store's, a tag purged after the
          # lookup, or an entry already expired.
          WRITE = <<~LUA
            #{PRELUDE}
            local now = now_ms()
            local epoch, seq = meta(KEYS[1], ARGV[1], tonumber(ARGV[2]))
            local ttl, entry_seq, stored_at = tonumber(ARGV[5]), tonumber(ARGV[6]), tonumber(ARGV[8])

            if ARGV[7] ~= epoch or entry_seq > seq then return 0 end
            for _, tag in ipairs(cjson.decode(ARGV[4])) do
              local purged = mark(KEYS[1], tag)
              if purged and purged > entry_seq then return 0 end
            end
            local expires_at = stored_at + ttl * 1000
            if now >= expires_at then return 0 end

            redis.call("DEL", KEYS[2])
            redis.call("HSET", KEYS[2], "blob", ARGV[3], "tags", ARGV[4], "expires_at", ms(expires_at))
            redis.call("PEXPIRE", KEYS[2], ms(expires_at - now))
            return 1
          LUA

          # KEYS: meta. ARGV: candidate epoch, max_ttl, tag digests...
          # Increments seq, marks each tag with it, then prunes up to 100 marks older than the prefix's max_ttl,
          # walking the hash with a cursor kept in it. Answers the new seq.
          #
          # Pruning is safe: an entry a mark rejects was looked up before that purge, so it was stamped no later than
          # the purge and, its TTL being at most max_ttl, has expired once the mark is older than max_ttl. A write
          # that late is refused as expired.
          PURGE = <<~LUA
            #{PRELUDE}
            local now = now_ms()
            meta(KEYS[1], ARGV[1], tonumber(ARGV[2]))
            local seq = redis.call("HINCRBY", KEYS[1], "seq", 1)
            local stamp = ms(seq) .. ":" .. ms(now)
            for index = 3, #ARGV do
              redis.call("HSET", KEYS[1], "m:" .. ARGV[index], stamp)
            end

            local keep = tonumber(redis.call("HGET", KEYS[1], "max_ttl")) * 1000
            local scan = redis.call("HSCAN", KEYS[1], redis.call("HGET", KEYS[1], "cursor") or "0", "MATCH", "m:*", "COUNT", 100)
            local found, pruned = scan[2], 0
            for index = 1, #found, 2 do
              if pruned >= 100 then break end
              local at = tonumber(string.match(found[index + 1], "^%d+:(%d+)$"))
              if at and now - at > keep then
                redis.call("HDEL", KEYS[1], found[index])
                pruned = pruned + 1
              end
            end
            redis.call("HSET", KEYS[1], "cursor", scan[1])

            return seq
          LUA

          # KEYS: meta. ARGV: the new epoch, max_ttl.
          # Replaces the epoch and drops every mark, keeping seq and the prefix's max_ttl. Answers the new epoch.
          PURGE_ALL = <<~LUA
            #{PRELUDE}
            local _, seq = meta(KEYS[1], ARGV[1], tonumber(ARGV[2]))
            local kept = redis.call("HGET", KEYS[1], "max_ttl")
            redis.call("DEL", KEYS[1])
            redis.call("HSET", KEYS[1], "epoch", ARGV[1], "seq", ms(seq), "max_ttl", kept)
            return ARGV[1]
          LUA
        end
      end
    end
  end
end
