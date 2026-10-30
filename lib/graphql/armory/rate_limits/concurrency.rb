# frozen_string_literal: true

require "securerandom"

module GraphQL
  module Armory
    module RateLimits
      # Lets each client run at most `limit` operations at the same time:
      #
      #   use GraphQL::Armory::RateLimits::Concurrency, store: GraphQL::Armory::RateLimits::MemoryStore.new,
      #     limit: 5, soft: false
      #
      # A query analyzer takes a slot before the operation runs, or refuses it before any field resolves; a trace
      # releases every slot its multiplex took when the multiplex ends, even when it raises. A slot a crashed
      # process never released expires after `stale_after` seconds. Soft mode (the default) records but refuses
      # nothing. What happened is in `context[:rate_limit_concurrency]`.
      class Concurrency
        CONTEXT_KEY = :rate_limit_concurrency
        SLOT_KEY = :armory_concurrency_slot

        def self.use(schema, store:, limit:, stale_after: 60, soft: true, key: nil, on_store_error: nil)
          concurrency = new(store: store, limit: limit, stale_after: stale_after, soft: soft, key: key, on_store_error: on_store_error)
          schema.query_analyzer(Class.new(Analyzer) { define_method(:concurrency) { concurrency } })
          schema.trace_with(Release)
        end

        def initialize(store:, limit:, stale_after:, soft:, key:, on_store_error:)
          unless Settings.store_answers?(store, acquire: %i[token limit ttl force], release: %i[token])
            raise ConfigurationError, "store: must answer acquire(key, token:, limit:, ttl:, force:) and release(key, token:), like a MemoryStore"
          end

          @store = store
          @limit = Settings.limit(limit)
          @stale_after = Settings.seconds(:stale_after, stale_after)
          @soft = Settings.soft(soft)
          @key = Settings.key_reader(key)
          @on_store_error = Settings.store_error_handler(on_store_error)
        end

        # Takes a slot for the query: the refusal when none is free, or nil to let it run.
        def acquire(query)
          key = Settings.key_for(@key, query)
          limit = Settings.limit_for(@limit, key, query)
          if limit.nil?
            record(query, key: key, limit: nil, active: nil, limited: false)
            return nil
          end

          token = SecureRandom.hex(16)
          answer = begin
            @store.acquire(key, token: token, limit: limit, ttl: @stale_after, force: @soft)
          rescue StandardError => error
            @on_store_error.call(error, query)
            return nil
          end
          acquired, active = Settings.checked(answer, :acquire, "the Integer slots held")

          query.context[SLOT_KEY] = [self, key, token] if acquired || @soft
          record(query, key: key, limit: limit, active: active, limited: !acquired)
          refusal(limit, active) unless acquired || @soft
        end

        def release(query, key, token)
          @store.release(key, token: token)
        rescue StandardError => error
          @on_store_error.call(error, query)
        end

        private

        def record(query, **info)
          query.context[CONTEXT_KEY] = { **info.slice(:key, :limit, :active), soft: @soft, limited: info[:limited] }
        end

        def refusal(limit, active)
          GraphQL::AnalysisError.new(
            "Too many operations at the same time: #{active} are already running for this client (limit #{limit}). Retry when one finishes.",
            extensions: { "code" => "RATE_LIMITED", "limit" => limit, "active" => active }
          )
        end

        # Takes the slot during analysis, before anything runs.
        class Analyzer < GraphQL::Analysis::Analyzer
          def result
            concurrency.acquire(query)
          end
        end

        # Releases the slots of every query in the multiplex once it is done, whatever happened. Analysis runs
        # inside `execute_multiplex` on both engines, so every slot taken is released here.
        module Release
          def execute_multiplex(multiplex:)
            super
          ensure
            multiplex.queries.each do |query|
              concurrency, key, token = query.context[SLOT_KEY]
              next unless concurrency

              query.context[SLOT_KEY] = nil
              concurrency.release(query, key, token)
            end
          end
        end
      end
    end
  end
end
