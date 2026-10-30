# frozen_string_literal: true

module GraphQL
  module Armory
    module RateLimits
      # Charges each query its complexity, as graphql-ruby computes it before running it, against a bucket of
      # points per client that refills over a window:
      #
      #   use GraphQL::Armory::RateLimits::Points, store: GraphQL::Armory::RateLimits::MemoryStore.new,
      #     limit: 1_000, window: 60, soft: false
      #
      # A query that costs more than the client has left is refused before any field resolves, and charged
      # nothing. Soft mode (the default) charges and records but refuses nothing. What happened is in
      # `context[:rate_limit_points]`.
      class Points
        CONTEXT_KEY = :rate_limit_points

        def self.use(schema, store:, limit:, window: 60, soft: true, key: nil, on_store_error: nil)
          points = new(store: store, limit: limit, window: window, soft: soft, key: key, on_store_error: on_store_error)
          schema.query_analyzer(Class.new(Analyzer) { define_method(:points) { points } })
        end

        def initialize(store:, limit:, window:, soft:, key:, on_store_error:)
          raise ConfigurationError, "store: must answer take(key, cost:, limit:, window:, force:), like a MemoryStore" unless store_takes?(store)
          unless limit.respond_to?(:call) || positive_integer?(limit)
            raise ConfigurationError, "limit: must be a positive Integer, or a callable taking the key and the query, got #{limit.inspect}"
          end
          raise ConfigurationError, "window: must be a positive number of seconds, got #{window.inspect}" unless window.is_a?(Numeric) && window.positive? && window.finite?

          @store = store
          @limit = limit
          @window = window
          @soft = Settings.soft(soft)
          @key = Settings.key_reader(key)
          @on_store_error = Settings.store_error_handler(on_store_error)
        end

        # The refusal for a query that costs `cost`, or nil to let it run.
        def charge(query, cost)
          key = Settings.key_for(@key, query)
          limit = limit_for(key, query)
          if limit.nil?
            record(query, key: key, cost: cost, limit: nil, remaining: nil, limited: false)
            return nil
          end

          answer = begin
            @store.take(key, cost: cost, limit: limit, window: @window, force: @soft)
          rescue StandardError => error
            @on_store_error.call(error, query)
            return nil
          end
          taken, remaining = checked(answer)

          record(query, key: key, cost: cost, limit: limit, remaining: remaining, limited: !taken)
          refusal(cost, limit, remaining) unless taken || @soft
        end

        private

        def limit_for(key, query)
          return @limit unless @limit.respond_to?(:call)

          limit = @limit.call(key, query)
          return limit if limit.nil? || positive_integer?(limit)

          raise ConfigurationError, "limit: answered #{limit.inspect} for #{key}: it must answer a positive Integer, or nil for no limit"
        end

        # A store answer that is not [true or false, a whole number of points] would let queries through: 0 is truthy.
        def checked(answer)
          taken, remaining = answer if answer.is_a?(Array) && answer.size == 2
          return answer if (taken == true || taken == false) && remaining.is_a?(Integer) && !remaining.negative?

          raise ConfigurationError, "store: take answered #{answer.inspect}: it must answer [true or false, the Integer points left]"
        end

        def store_takes?(store)
          return false unless store.respond_to?(:take)

          parameters = store.method(:take).parameters
          return true if parameters.any? { |type, _| type == :keyrest }

          keywords = parameters.select { |type, _| type == :key || type == :keyreq }.map(&:last)
          (%i[cost limit window force] - keywords).empty?
        end

        def positive_integer?(value)
          value.is_a?(Integer) && value.positive?
        end

        def record(query, **info)
          query.context[CONTEXT_KEY] = { **info.slice(:key, :cost, :limit, :remaining), window: @window, soft: @soft, limited: info[:limited] }
        end

        def refusal(cost, limit, remaining)
          if cost > limit
            return GraphQL::AnalysisError.new(
              "Rate limit exceeded: this query costs #{cost} points and the limit is #{limit} every #{@window} seconds, so it can never run.",
              extensions: { "code" => "RATE_LIMITED", "cost" => cost, "limit" => limit }
            )
          end

          retry_after = ((cost - remaining) * @window / limit.to_f).ceil
          GraphQL::AnalysisError.new(
            "Rate limit exceeded: this query costs #{cost} points and #{remaining} remain (#{limit} every #{@window} seconds). Retry in #{retry_after} seconds.",
            extensions: { "code" => "RATE_LIMITED", "cost" => cost, "remaining" => remaining, "retryAfter" => retry_after }
          )
        end

        # graphql-ruby's own complexity analysis, then the charge.
        class Analyzer < GraphQL::Analysis::QueryComplexity
          def result
            cost = super
            unless cost.is_a?(Numeric) && cost.finite? && !cost.negative?
              raise ConfigurationError, "the query complexity is #{cost.inspect}: field complexities must be numbers of zero or more"
            end

            # Fractional complexities (`complexity: 0.5`) are charged whole points, rounded up.
            points.charge(query, cost.ceil)
          end
        end
      end
    end
  end
end
