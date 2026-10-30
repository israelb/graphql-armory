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
        NAMESPACE = :graphql_armory

        def self.use(schema, store:, limit:, window: 60, soft: true, key: nil, on_store_error: nil, extensions: false)
          points = build(store: store, limit: limit, window: window, soft: soft, key: key, on_store_error: on_store_error, extensions: extensions)
          schema.query_analyzer(Class.new(Analyzer) { define_method(:points) { points } })
        end

        # HTTP headers for the budget a result recorded: `RateLimit-Limit`, `RateLimit-Remaining` and `RateLimit-Reset`
        # (seconds until the bucket is full again). Empty when the query had no limit.
        def self.headers(result)
          info = result.context.namespace(NAMESPACE)[:points]
          return {} unless info && info[:limit]

          { "RateLimit-Limit" => info[:limit].to_s, "RateLimit-Remaining" => info[:remaining].to_s, "RateLimit-Reset" => reset_in(info).to_s }
        end

        def self.reset_in(info)
          ((info[:limit] - info[:remaining]) * info[:window] / info[:limit].to_f).ceil
        end

        # Wires the app's store with `use`'s defaults (soft mode); `use` goes through here.
        def self.build(store:, limit:, window: 60, soft: true, key: nil, on_store_error: nil, extensions: false)
          new(store: store, limit: limit, window: window, soft: soft, key: key, on_store_error: on_store_error, extensions: extensions)
        end

        # `new` is inert: with no store wired it refuses every query. It checks every setting, so no partial
        # configuration lets a query through either.
        def initialize(store: Store::Null.new, limit: 1, window: 60, soft: false, key: nil, on_store_error: nil, extensions: false)
          unless Settings.store_answers?(store, take: %i[cost limit window force])
            raise ConfigurationError, "store: must answer take(key, cost:, limit:, window:, force:), like a MemoryStore"
          end
          raise ConfigurationError, "extensions: must be true or false, got #{extensions.inspect}" unless extensions == true || extensions == false

          @store = store
          @limit = Settings.wired_limit(limit, store)
          @window = Settings.seconds(:window, window)
          @soft = Settings.wired_soft(soft, store)
          @key = Settings.key_reader(key)
          @on_store_error = Settings.store_error_handler(on_store_error)
          @extensions = extensions
        end

        # The refusal for a query that costs `cost`, or nil to let it run.
        def call(query, cost)
          key = Settings.key_for(@key, query)
          limit = Settings.limit_for(@limit, key, query)
          if limit.nil?
            record(query, key: key, cost: cost, limit: nil, remaining: nil, limited: false)
            return nil
          end

          answer = begin
            @store.take(key, cost: cost, limit: limit, window: @window, force: @soft)
          rescue StandardError => error
            # No record: a context hash shared with an earlier query must not keep its numbers.
            query.context[CONTEXT_KEY] = nil
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

        # In the context hash for instrumentation, and per query for `headers`: queries of a multiplex may share one
        # context hash, where the last query's record wins.
        def record(query, **info)
          info = { **info.slice(:key, :cost, :limit, :remaining), window: @window, soft: @soft, limited: info[:limited] }
          query.context.namespace(NAMESPACE)[:points] = info
          query.context[CONTEXT_KEY] = info
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
            points.(query, cost.ceil)
          end
        end
      end
    end
  end
end
