# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "graphql/armory/caching/redis_store/scripts"

module GraphQL
  module Armory
    module Caching
      # Answers kept in Redis, shared by every process of the app: the store for production.
      #
      #   store = GraphQL::Armory::Caching::RedisStore.build(redis: Redis.new(url: ENV.fetch("CACHE_REDIS_URL")))
      #
      # Keeps the store contract (`Store`): each operation is one Lua script (`Scripts`), so it is atomic and one round
      # trip, and the clock is Redis's own `TIME`. The epoch, the purge sequence and every purge mark live in one hash
      # per prefix, `<prefix>meta`, without a TTL: under a `volatile-*` eviction policy it is never evicted, and under
      # an `allkeys-*` policy it can only be evicted whole, which every store reads as "everything purged".
      #
      # - `max_ttl:` (seconds, default 3600) is the longest TTL it stores; purge marks are pruned once older than the
      #   longest `max_ttl` of the stores sharing the prefix. Set it to the `max_ttl:` given to `use`.
      # - `purge_replicas:` runs `WAIT n` after each purge and raises `PurgeError` when fewer replicas acknowledged it
      #   within `purge_timeout:` seconds. Without it, a purge acknowledged by a primary that fails before replicating
      #   it can be lost.
      # - Redis Cluster: every script touches the meta hash, so the prefix needs a hash tag that puts every key in one
      #   slot, as in `prefix: "graphql-armory:{cache}:"`.
      #
      # Redis errors reach the caller unchanged: the gate runs the query uncached on a lookup or write error, and turns
      # a purge error into `PurgeError`. `redis:` is a redis-rb client (>= 4.8), or anything answering `eval`,
      # `evalsha` and `call` the same way, on Redis 5 or later. This gem does not depend on the redis gem: the app adds
      # it. Keep the cache in a Redis of its own: PersistedQueries and RateLimits keys need `noeviction`.
      class RedisStore
        DEFAULT_PREFIX = "graphql-armory:cache:"
        DEFAULT_MAX_TTL = 3600
        DEFAULT_PURGE_TIMEOUT = 1

        module Client
          # The Redis of a store nobody wired: it holds nothing, stores nothing, and a purge through it raises.
          class Null; end
        end

        # Validates the settings and wires the real Redis client.
        def self.build(redis:, prefix: DEFAULT_PREFIX, purge_replicas: nil, purge_timeout: DEFAULT_PURGE_TIMEOUT, max_ttl: DEFAULT_MAX_TTL)
          unless redis.respond_to?(:eval) && redis.respond_to?(:evalsha) && redis.respond_to?(:call)
            raise ConfigurationError, "redis: must be a Redis client that runs scripts (eval, evalsha and call), like Redis.new from the redis gem"
          end
          raise ConfigurationError, "prefix: must be a non-empty String, got #{prefix.inspect}" unless prefix.is_a?(String) && !prefix.empty?
          unless purge_replicas.nil? || (purge_replicas.is_a?(Integer) && purge_replicas.positive?)
            raise ConfigurationError, "purge_replicas: must be nil or a positive Integer, got #{purge_replicas.inspect}"
          end
          unless purge_timeout.is_a?(Numeric) && purge_timeout.positive?
            raise ConfigurationError, "purge_timeout: must be a positive number of seconds, got #{purge_timeout.inspect}"
          end
          raise ConfigurationError, "max_ttl: must be a positive Integer of seconds, got #{max_ttl.inspect}" unless max_ttl.is_a?(Integer) && max_ttl.positive?

          new(redis: redis, prefix: prefix, purge_replicas: purge_replicas, purge_timeout: purge_timeout, max_ttl: max_ttl)
        end

        attr_reader :prefix, :max_ttl, :purge_replicas, :purge_timeout

        # `new` is inert: with no Redis wired every lookup misses, every write is refused and every purge raises.
        def initialize(redis: Client::Null.new, prefix: DEFAULT_PREFIX, purge_replicas: nil, purge_timeout: DEFAULT_PURGE_TIMEOUT, max_ttl: DEFAULT_MAX_TTL)
          @redis = redis
          @prefix = prefix
          @purge_replicas = purge_replicas
          @purge_timeout = purge_timeout
          @max_ttl = max_ttl
        end

        def lookup(key_digest)
          check_digest!(key_digest, "key_digest")
          return Lookup.miss(seq: 0, epoch: "unwired", now: 0) unless wired?

          blob, tags, marks, seq, epoch, now = script(Scripts::LOOKUP, [meta_key, entry_key(key_digest)], SecureRandom.hex(16), @max_ttl)
          Lookup.new(blob: blob, tags: tags, marks: marks.each_slice(2).to_h { |tag, mark| [tag, Integer(mark)] }, seq: seq, epoch: epoch, now: now)
        end

        def write(key_digest, blob, tags:, ttl:, seq:, epoch:, stored_at:)
          check_write!(key_digest, blob, tags, ttl, seq, epoch, stored_at)
          return false unless wired?

          stored = script(Scripts::WRITE, [meta_key, entry_key(key_digest)], SecureRandom.hex(16), @max_ttl, blob, JSON.generate(tags), ttl, seq, epoch, stored_at)
          stored == 1
        end

        def purge(tag_digests)
          raise ArgumentError, "tag_digests must be an Array" unless tag_digests.is_a?(Array)

          tag_digests.each { |tag| check_digest!(tag, "tag digest") }
          unwired! unless wired?

          seq = script(Scripts::PURGE, [meta_key], SecureRandom.hex(16), @max_ttl, *tag_digests.uniq)
          replicated!
          seq
        end

        def purge_all
          unwired! unless wired?

          epoch = script(Scripts::PURGE_ALL, [meta_key], SecureRandom.hex(16), @max_ttl)
          replicated!
          epoch
        end

        def inspect = "#<#{self.class.name} prefix=#{@prefix.inspect} max_ttl=#{@max_ttl}>"
        alias_method :to_s, :inspect

        private

        def wired?
          !@redis.is_a?(Client::Null)
        end

        def unwired!
          raise PurgeError, "RedisStore has no Redis wired, so nothing was purged: build it with RedisStore.build(redis:)"
        end

        def meta_key = "#{@prefix}meta"
        def entry_key(key_digest) = "#{@prefix}e:#{key_digest}"

        # Only keyed hex digests reach the keyspace: nothing in it names a viewer, a tag or an operation in clear.
        def check_digest!(value, name)
          raise ArgumentError, "#{name} must be 64 hex characters" unless value.is_a?(String) && Key::HEX.match?(value)
        end

        def check_write!(key_digest, blob, tags, ttl, seq, epoch, stored_at)
          check_digest!(key_digest, "key_digest")
          raise ArgumentError, "blob must be a String" unless blob.is_a?(String)
          raise ArgumentError, "tags: must be an Array" unless tags.is_a?(Array)

          tags.each { |tag| check_digest!(tag, "tag digest") }
          raise ArgumentError, "ttl: must be a positive Integer of seconds" unless ttl.is_a?(Integer) && ttl.positive?
          raise ArgumentError, "ttl: #{ttl} is above this store's max_ttl (#{@max_ttl}): purge marks are kept only that long" if ttl > @max_ttl
          raise ArgumentError, "seq: must be a non-negative Integer" unless seq.is_a?(Integer) && seq >= 0
          raise ArgumentError, "epoch: must be a non-empty String" unless epoch.is_a?(String) && !epoch.empty?
          raise ArgumentError, "stored_at: must be Integer milliseconds" unless stored_at.is_a?(Integer) && stored_at >= 0
        end

        # WAIT blocks until `purge_replicas` replicas acknowledged every write of this connection, or the timeout.
        def replicated!
          return unless @purge_replicas

          acknowledged = @redis.call("WAIT", @purge_replicas, (@purge_timeout * 1000).ceil)
          return if acknowledged >= @purge_replicas

          raise PurgeError, "the purge reached #{acknowledged} of #{@purge_replicas} replicas within #{@purge_timeout}s; retry it"
        end

        # EVALSHA sends only the script's digest; Redis forgets scripts on restart or SCRIPT FLUSH, and then EVAL
        # sends it whole once more.
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
