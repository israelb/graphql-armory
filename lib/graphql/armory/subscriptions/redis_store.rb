# frozen_string_literal: true

require "digest"
require "json"
require "graphql/armory/subscriptions/redis_store/scripts"

module GraphQL
  module Armory
    module Subscriptions
      # Subscriptions kept in Redis, shared by every process of the app: the store for production.
      #
      #   store = GraphQL::Armory::Subscriptions::RedisStore.build(redis: Redis.new(url: ENV.fetch("SUBSCRIPTIONS_REDIS_URL")))
      #
      # Keeps the store contract (`Store`): `write`, `ids`, `count`, `delete` and `cleanup` are each one Lua script
      # (`Scripts`), atomic and one round trip, and `read` is one `HGET`. Both caps are counted inside `write`'s script,
      # over unexpired records only, so no number of processes can go over them; a refused write stores nothing.
      #
      # The clock is the `now:` the caller passes (Integer ms), not Redis's `TIME`: the core, `MemoryStore` and every
      # process then agree on what is live, and a record is live exactly while `now < expires_at` whatever clock skew
      # lies between app servers and Redis. Redis's own clock only runs the keys' TTLs, which bound memory and never
      # decide liveness. Run NTP on the app servers: skew moves when a subscription ends.
      #
      # Keyspace (see `Scripts`): a hash per record, a sorted set per topic digest and per viewer digest scored by
      # `expires_at` (trimmed on read, with the TTL of their longest record), and one sorted set of every id by expiry
      # that `cleanup` walks. A record holds the sealed blob, the viewer digest and the topic digests, nothing in clear.
      #
      # - `cleanup(now:)` removes the records the app's schedule finds expired, up to `CLEANUP_BATCH` per script call.
      #   Call it periodically: the key TTL frees a record's memory, but only `cleanup` frees the id in the expiry set.
      # - Redis Cluster: a script touches several keys, so the prefix needs a hash tag that puts every key in one slot,
      #   as in `prefix: "graphql-armory:{subscriptions}:"`.
      #
      # Redis errors reach the caller unchanged. `redis:` is a redis-rb client (>= 4.8), or anything answering `eval`,
      # `evalsha` and `call` the same way, on Redis 5 or later. This gem does not depend on the redis gem: the app adds
      # it. Keep subscriptions in a Redis whose eviction policy is `noeviction` or `volatile-*`.
      class RedisStore
        DEFAULT_PREFIX = "graphql-armory:subscriptions:"
        CLEANUP_BATCH = 500
        ANSWERS = %w[ok viewer_cap topic_cap exists].freeze

        module Client
          # The Redis of a store nobody wired: it holds nothing and every write is refused.
          class Null; end
        end

        # Validates the settings and wires the real Redis client.
        def self.build(redis:, prefix: DEFAULT_PREFIX)
          unless redis.respond_to?(:eval) && redis.respond_to?(:evalsha) && redis.respond_to?(:call)
            raise ConfigurationError, "redis: must be a Redis client that runs scripts (eval, evalsha and call), like Redis.new from the redis gem"
          end
          raise ConfigurationError, "prefix: must be a non-empty String, got #{prefix.inspect}" unless prefix.is_a?(String) && !prefix.empty?

          new(redis: redis, prefix: prefix)
        end

        attr_reader :prefix

        # `new` is inert, like `Store::Null`: no Redis is wired, so every write is refused and nothing is held.
        def initialize(redis: Client::Null.new, prefix: DEFAULT_PREFIX)
          @redis = redis
          @prefix = prefix
        end

        def write(id, sealed, topics:, viewer:, expires_at:, viewer_cap:, topic_cap:, now:)
          check_write!(id, sealed, topics, viewer, expires_at, viewer_cap, topic_cap, now)
          return :refused unless wired?

          topics = topics.uniq
          keys = [record_key(id), viewer_key(viewer), expiry_key, *topics.map { |topic| topic_key(topic) }]
          answer = script(Scripts::WRITE, keys, id, sealed, viewer, JSON.generate(topics), expires_at, viewer_cap, topic_cap, now)
          raise Error, "unexpected answer from the subscriptions store: #{answer.inspect}" unless ANSWERS.include?(answer)

          answer.to_sym
        end

        def read(id)
          return nil unless wired?

          @redis.call("HGET", record_key(id), "sealed")
        end

        def ids(topic, now:)
          check_now!(now)
          return [] unless wired?

          script(Scripts::IDS, [topic_key(topic)], now)
        end

        def delete(id)
          return false unless wired?

          script(Scripts::DELETE, [expiry_key], id, @prefix) == 1
        end

        def count(viewer, now:)
          check_now!(now)
          return 0 unless wired?

          script(Scripts::COUNT, [viewer_key(viewer)], now)
        end

        def cleanup(now:)
          check_now!(now)
          return 0 unless wired?

          total = 0
          loop do
            removed = script(Scripts::CLEANUP, [expiry_key], now, @prefix, CLEANUP_BATCH)
            total += removed
            break if removed < CLEANUP_BATCH
          end
          total
        end

        def inspect = "#<#{self.class.name} prefix=#{@prefix.inspect}>"
        alias_method :to_s, :inspect

        private

        def wired? = !@redis.is_a?(Client::Null)

        def record_key(id) = "#{@prefix}r:#{id}"
        def topic_key(topic) = "#{@prefix}t:#{topic}"
        def viewer_key(viewer) = "#{@prefix}v:#{viewer}"
        def expiry_key = "#{@prefix}x"

        # A caller's bug, never a store answer: the core must hand every store the same shapes.
        def check_write!(id, sealed, topics, viewer, expires_at, viewer_cap, topic_cap, now)
          check_now!(now)
          raise ArgumentError, "id must be a non-empty String" unless id.is_a?(String) && !id.empty?
          raise ArgumentError, "sealed must be a String" unless sealed.is_a?(String)
          raise ArgumentError, "topics: must be a non-empty Array of non-empty Strings" unless topics.is_a?(Array) && !topics.empty? && topics.all? { |topic| topic.is_a?(String) && !topic.empty? }
          raise ArgumentError, "viewer: must be a non-empty String" unless viewer.is_a?(String) && !viewer.empty?
          raise ArgumentError, "expires_at: must be Integer milliseconds after now:" unless expires_at.is_a?(Integer) && expires_at > now

          [viewer_cap, topic_cap].each do |cap|
            raise ArgumentError, "a cap must be nil or a positive Integer, got #{cap.inspect}" unless cap.nil? || (cap.is_a?(Integer) && cap.positive?)
          end
        end

        def check_now!(now)
          raise ArgumentError, "now: must be Integer milliseconds" unless now.is_a?(Integer)
        end

        # EVALSHA sends only the script's digest; Redis forgets scripts on restart or SCRIPT FLUSH, and then EVAL
        # sends it whole once more. A nil argument (an absent cap) travels as an empty string.
        def script(source, keys, *argv)
          argv = argv.map(&:to_s)
          @redis.evalsha(Digest::SHA1.hexdigest(source), keys: keys, argv: argv)
        rescue StandardError => error
          raise unless error.message.start_with?("NOSCRIPT")

          @redis.eval(source, keys: keys, argv: argv)
        end
      end
    end
  end
end
