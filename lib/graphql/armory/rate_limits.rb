# frozen_string_literal: true

module GraphQL
  module Armory
    # Rate limits built for GraphQL, where requests differ wildly in cost. Each client is named by
    # `context[:rate_limit_key]` (or a `key:` callable) and limited through a store: `MemoryStore` for tests and
    # a single process, a shared store for several processes.
    module RateLimits
      class ConfigurationError < Armory::Error; end

      KEY = :rate_limit_key

      # The settings every limiter shares, checked at boot.
      module Settings
        module_function

        def key_reader(key)
          return ->(query) { query.context[KEY] } if key.nil?
          raise ConfigurationError, "key: must be a callable that takes the query, got #{key.inspect}" unless key.respond_to?(:call)

          key
        end

        def key_for(reader, query)
          key = reader.call(query)
          return key if key.is_a?(String) && !key.empty?

          raise ConfigurationError, "no client key for this query: put a non-empty String in context[:#{KEY}], or give the limiter a key: callable"
        end

        def soft(value)
          raise ConfigurationError, "soft: must be true or false, got #{value.inspect}" unless value == true || value == false

          value
        end

        def limit(limit)
          return limit if limit.respond_to?(:call) || positive_integer?(limit)

          raise ConfigurationError, "limit: must be a positive Integer, or a callable taking the key and the query, got #{limit.inspect}"
        end

        def limit_for(limit, key, query)
          return limit unless limit.respond_to?(:call)

          answer = limit.call(key, query)
          return answer if answer.nil? || positive_integer?(answer)

          raise ConfigurationError, "limit: answered #{answer.inspect} for #{key}: it must answer a positive Integer, or nil for no limit"
        end

        def positive_integer?(value)
          value.is_a?(Integer) && value.positive?
        end

        def seconds(name, value)
          return value if value.is_a?(Numeric) && value.positive? && value.finite?

          raise ConfigurationError, "#{name}: must be a positive number of seconds, got #{value.inspect}"
        end

        # Whether `store` answers each method with the keywords this gem passes, so a wrong signature fails at
        # boot instead of failing open on every query.
        def store_answers?(store, methods)
          methods.all? do |name, keywords|
            next false unless store.respond_to?(name)

            parameters = store.method(name).parameters
            next true if parameters.any? { |type, _| type == :keyrest }

            (keywords - parameters.select { |type, _| type == :key || type == :keyreq }.map(&:last)).empty?
          end
        end

        # A store answer that is not [true or false, a whole number] would let queries through: 0 is truthy.
        def checked(answer, method, meaning)
          granted, count = answer if answer.is_a?(Array) && answer.size == 2
          return answer if (granted == true || granted == false) && count.is_a?(Integer) && !count.negative?

          raise ConfigurationError, "store: #{method} answered #{answer.inspect}: it must answer [true or false, #{meaning}]"
        end

        def store_error_handler(handler)
          return ->(error, _query) { warn("graphql-armory rate limit store failed, query let through: #{error.class}: #{error.message}") } if handler.nil?
          raise ConfigurationError, "on_store_error: must be a callable that takes the error and the query" unless handler.respond_to?(:call)

          handler
        end
      end
    end
  end
end

require "graphql/armory/rate_limits/memory_store"
require "graphql/armory/rate_limits/points"
require "graphql/armory/rate_limits/concurrency"
