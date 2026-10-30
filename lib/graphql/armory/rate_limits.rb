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
