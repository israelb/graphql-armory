# frozen_string_literal: true

module GraphQL
  module Armory
    module PersistedQueries
      # Operations a client's CI published with `Publisher`, read while the server runs, so a new frontend needs no
      # server deploy.
      #
      #   store = GraphQL::Armory::PersistedQueries::RedisStore.build(redis: Redis.new(url: ENV.fetch("REDIS_URL")))
      #
      # An operation it read stays in memory: published operations never change, so what it already knows keeps working
      # when Redis fails. An id it cannot find, or cannot check, is unknown: nothing runs. This gem does not depend on
      # the redis gem: the app adds it.
      class RedisStore
        DEFAULT_PREFIX = "graphql-armory:persisted-queries:"
        DEFAULT_ON_ERROR = ->(error) { warn "graphql-armory: persisted query store failed (#{error.class})" }

        # A stored value that does not parse, or is not the digest of its id. The message quotes neither.
        class CorruptOperation < Armory::Error; end

        # What the store and the publisher need from Redis.
        module Client
          # The Redis of a store nobody wired: it holds nothing and stores nothing.
          class Null
            def get(_key)
              nil
            end

            def set(_key, _value, nx: false)
              nil
            end
          end

          # Holds its keys in memory like Redis, records its calls and fails when told: for tests.
          class Substitute
            attr_reader :calls

            def initialize
              @data = {}
              @calls = []
              @failure = nil
            end

            # Raises `error` from every call until `recover`.
            def fail_with(error)
              @failure = error
            end

            def recover
              @failure = nil
            end

            def get(key)
              @calls << [:get, key]
              raise @failure if @failure

              @data[key]
            end

            def set(key, value, nx: false)
              @calls << [:set, key]
              raise @failure if @failure
              return false if nx && @data.key?(key)

              @data[key] = value
              true
            end
          end
        end

        # Validates the settings and wires the real Redis client.
        def self.build(redis:, prefix: DEFAULT_PREFIX, digest: :sha256, on_error: DEFAULT_ON_ERROR)
          raise ConfigurationError, "redis: must answer get and set, like Redis.new from the redis gem" unless redis.respond_to?(:get) && redis.respond_to?(:set)
          raise ConfigurationError, "prefix: must be a non-empty String, got #{prefix.inspect}" unless prefix.is_a?(String) && !prefix.empty?
          unless digest == false || Manifest::DIGESTS.key?(digest)
            raise ConfigurationError, "unknown digest #{digest.inspect}: use #{Manifest::DIGESTS.keys.map(&:inspect).join(", ")} or false"
          end
          raise ConfigurationError, "on_error: must be a callable that takes the error" unless on_error.respond_to?(:call)

          new(redis: redis, prefix: prefix, digest: digest, on_error: on_error)
        end

        # `new` is inert: with no Redis wired it holds no operation, so every id is unknown.
        def initialize(redis: Client::Null.new, prefix: DEFAULT_PREFIX, digest: :sha256, on_error: DEFAULT_ON_ERROR)
          @redis = redis
          @prefix = prefix
          @digest = digest && Manifest::DIGESTS.fetch(digest)
          @on_error = on_error
          @operations = {}
          @mutex = Mutex.new
        end

        def fetch(id)
          return unless id.is_a?(String) && id.match?(Manifest::ID_LIKE)

          @operations[id] || read(id)
        end

        # Only an unwired store is known to be empty: `strict: false` refuses it at boot, as it does the Null store.
        def empty?
          @redis.is_a?(Client::Null)
        end

        private

        # Only what it found is remembered: an unknown id may be published a moment later.
        def read(id)
          body = @redis.get("#{@prefix}#{id}")
          return if body.nil?

          operation = operation(id, body)
          @mutex.synchronize { @operations[id] ||= operation }
        rescue StandardError => error
          @on_error.call(error)
          nil
        end

        def operation(id, stored)
          raise CorruptOperation, "operation #{id} is not text" unless stored.is_a?(String)

          # redis-rb may answer in another encoding; a query compares as text with what the client sends.
          body = stored.dup.force_encoding(Encoding::UTF_8).freeze
          raise CorruptOperation, "operation #{id} is not the digest of its query" if @digest && @digest.hexdigest(body) != id

          Manifest::Operation.new(id: id.dup.freeze, body: body, document: parse(id, body)).freeze
        end

        def parse(id, body)
          GraphQL.parse(body)
        rescue GraphQL::ParseError
          raise CorruptOperation, "operation #{id} does not parse"
        end
      end
    end
  end
end
