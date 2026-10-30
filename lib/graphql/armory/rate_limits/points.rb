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

        def self.use(schema, store:, limit:, window: 60, soft: true, key: nil, on_store_error: nil, extensions: false)
          points = new(store: store, limit: limit, window: window, soft: soft, key: key, on_store_error: on_store_error, extensions: extensions)
          schema.query_analyzer(Class.new(Analyzer) { define_method(:points) { points } })
        end

        # HTTP headers for the budget a result recorded: `RateLimit-Limit`, `RateLimit-Remaining` and `RateLimit-Reset`
        # (seconds until the bucket is full again). Empty when the query had no limit.
        def self.headers(result)
          info = result.context[CONTEXT_KEY]
          return {} unless info && info[:limit]

          { "RateLimit-Limit" => info[:limit].to_s, "RateLimit-Remaining" => info[:remaining].to_s, "RateLimit-Reset" => reset_in(info).to_s }
        end

        def self.reset_in(info)
          ((info[:limit] - info[:remaining]) * info[:window] / info[:limit].to_f).ceil
        end

        def initialize(store:, limit:, window:, soft:, key:, on_store_error:, extensions: false)
          unless Settings.store_answers?(store, take: %i[cost limit window force])
            raise ConfigurationError, "store: must answer take(key, cost:, limit:, window:, force:), like a MemoryStore"
          end

          @store = store
          @limit = Settings.limit(limit)
          @window = Settings.seconds(:window, window)
          @soft = Settings.soft(soft)
          @key = Settings.key_reader(key)
          @on_store_error = Settings.store_error_handler(on_store_error)
          raise ConfigurationError, "extensions: must be true or false, got #{extensions.inspect}" unless extensions == true || extensions == false

          @extensions = extensions
        end

        # The refusal for a query that costs `cost`, or nil to let it run.
        def charge(query, cost)
          key = Settings.key_for(@key, query)
          limit = Settings.limit_for(@limit, key, query)
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
          taken, remaining = Settings.checked(answer, :take, "the Integer points left")

          info = record(query, key: key, cost: cost, limit: limit, remaining: remaining, limited: !taken)
          if @extensions
            query.context.response_extensions["rateLimit"] =
              { "cost" => cost, "limit" => limit, "remaining" => remaining, "resetIn" => self.class.reset_in(info) }
          end
          refusal(cost, limit, remaining) unless taken || @soft
        end

        private

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
