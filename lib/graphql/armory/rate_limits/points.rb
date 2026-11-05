# frozen_string_literal: true

require "graphql/armory/rate_limits/cached_charge"

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
      # `context[:rate_limit_points]`. An invalid query, which no analyzer sees, costs `invalid_cost:`, charged by a trace.
      # A response the cache answers is charged the points its run cost, through `charge_cached` (CachedCharge).
      #
      # The key, limit and exemption lookups and the limiter's own records go through `Caching.neutral`: who is charged
      # does not change the answer, so the response cache does not count them as inputs of it.
      class Points
        include CachedCharge

        CONTEXT_KEY = :rate_limit_points
        NAMESPACE = :graphql_armory

        def self.use(schema, store:, limit:, window: 60, soft: true, key: nil, on_store_error: nil, sinks: [], extensions: false, invalid_cost: 1)
          points = build(store: store, limit: limit, window: window, soft: soft, key: key, on_store_error: on_store_error, sinks: sinks, extensions: extensions, invalid_cost: invalid_cost)
          schema.query_analyzer(Class.new(Analyzer) do
            define_method(:points) { points }
            define_singleton_method(:armory_limiter) { points }
          end)
          schema.trace_with(AnalysisGuard)
          schema.trace_with(points.invalid_trace)
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
        def self.build(store:, limit:, window: 60, soft: true, key: nil, on_store_error: nil, sinks: [], extensions: false, invalid_cost: 1)
          new(store: store, limit: limit, window: window, soft: soft, key: key, on_store_error: on_store_error, sinks: sinks, extensions: extensions, invalid_cost: invalid_cost)
        end

        # `new` is inert: with no store wired it refuses every query. It checks every setting, so no partial
        # configuration lets a query through either.
        def initialize(store: Store::Null.new, limit: 1, window: 60, soft: false, key: nil, on_store_error: nil, sinks: [], extensions: false, invalid_cost: 1)
          unless Settings.store_answers?(store, take: %i[cost limit window force])
            raise ConfigurationError, "store: must answer take(key, cost:, limit:, window:, force:), like a MemoryStore"
          end
          raise ConfigurationError, "extensions: must be true or false, got #{extensions.inspect}" unless extensions == true || extensions == false

          @store = store
          @limit = Settings.wired_limit(limit, store)
          @window = Settings.seconds(:window, window)
          @soft = Settings.wired_soft(soft, store)
          @key = Settings.key_reader(key)
          @on_store_error = Settings.store_error_handler(on_store_error, limiter: :points, sinks: sinks)
          @extensions = extensions
          unless invalid_cost.nil? || (invalid_cost.is_a?(Integer) && invalid_cost.positive?)
            raise ConfigurationError, "invalid_cost: must be a positive Integer or nil, got #{invalid_cost.inspect}"
          end

          @invalid_cost = invalid_cost
        end

        # One module per limiter, so a schema with several charges each. Inside `ensure`: the answers are already made.
        def invalid_trace
          points = self
          Module.new do
            define_method(:execute_multiplex) do |multiplex:, &block|
              super(multiplex: multiplex, &block)
            ensure
              points.charge_invalid(multiplex)
            end
          end
        end

        # Charges the multiplex's invalid queries, together per client. It never raises over the answers.
        def charge_invalid(multiplex)
          return if @invalid_cost.nil?

          InvalidQueries.grouped(multiplex, self, @key, @limit, @on_store_error).each do |limits, queries|
            budgets, paid = InvalidQueries.charge(@store, limits, @invalid_cost * queries.size, @window, @on_store_error, queries.first)
            next if budgets.empty?

            binding = budgets.min_by { |budget| budget[:remaining] }
            queries.each do |query|
              record(query, key: binding[:key], cost: @invalid_cost, limit: binding[:limit], remaining: binding[:remaining], limited: !paid, invalid: true)
            end
          end
        rescue StandardError => error
          InvalidQueries.report(@on_store_error, error, multiplex.queries.first)
        end

        def soft?
          @soft
        end

        # Whether this query's client has no limit to charge.
        def exempt?(query)
          Caching.neutral(query.context) { Settings.exempt?(@key, @limit, query) }
        end

        # The refusal for a query that costs `cost`, or nil to let it run.
        def call(query, cost)
          key = Caching.neutral(query.context) { Settings.key_for(@key, query) }
          return call_several(query, key, cost) if key.is_a?(Array)

          limit = Caching.neutral(query.context) { Settings.limit_for(@limit, key, query) }
          if limit.nil?
            record(query, key: key, cost: cost, limit: nil, remaining: nil, limited: false)
            return nil
          end

          answer = begin
            @store.take(key, cost: cost, limit: limit, window: @window, force: @soft)
          rescue StandardError => error
            # No record: a context hash shared with an earlier query must not keep its numbers.
            Caching.neutral(query.context) { query.context[CONTEXT_KEY] = nil }
            @on_store_error.call(error, query)
            return nil
          end
          taken, remaining = Settings.checked(answer, :take, "the Integer points left")

          info = record(query, key: key, cost: cost, limit: limit, remaining: remaining, limited: !taken)
          announce(query, info, cost) if @extensions
          refusal(cost, limit, remaining) unless taken || @soft
        end

        private

        # Reads every balance first, so a query one key refuses leaves the others as they were, then charges each key.
        # Two queries can race between the two steps: then the refused one leaves the other keys charged. A key whose store
        # fails is left out, and the others still decide: an attacker who can pick a dead shard must not cancel a refusal.
        def call_several(query, keys, cost)
          limits = Caching.neutral(query.context) { Settings.limits_for(@limit, keys, query) }
          if limits.empty?
            record(query, key: keys.first, cost: cost, limit: nil, remaining: nil, limited: false, keys: [])
            return nil
          end

          read = takes(query, limits, 0, false) unless @soft
          budgets = if read&.any? { |budget| budget[:remaining] < cost }
                      read
                    else
                      takes(query, read ? read.to_h { |budget| budget.values_at(:key, :limit) } : limits, cost, @soft, charging: true)
                    end
          if budgets.empty?
            Caching.neutral(query.context) { query.context[CONTEXT_KEY] = nil }
            return nil
          end

          refused = budgets.select { |budget| budget.fetch(:taken) { budget[:remaining] >= cost } == false }
          binding = binding_budget(refused, cost) || budgets.min_by { |budget| budget[:remaining] }
          limited = !refused.empty?
          info = record(query, key: binding[:key], cost: cost, limit: binding[:limit], remaining: binding[:remaining], limited: limited,
                               keys: budgets.map { |budget| budget.slice(:key, :limit, :remaining) })
          announce(query, info, cost) if @extensions
          refusal(cost, binding[:limit], binding[:remaining]) if limited && !@soft
        end

        # What the store answers for each key, without the keys whose store failed.
        def takes(query, limits, cost, force, charging: false)
          limits.filter_map do |key, limit|
            answer = begin
              @store.take(key, cost: cost, limit: limit, window: @window, force: force)
            rescue StandardError => error
              @on_store_error.call(error, query)
              next
            end
            taken, remaining = Settings.checked(answer, :take, "the Integer points left")
            { key: key, limit: limit, remaining: remaining, **(charging ? { taken: taken } : {}) }
          end
        end

        # What the client is told: a key that can never pay, otherwise the longest wait.
        def binding_budget(refused, cost)
          refused.find { |budget| cost > budget[:limit] } || refused.max_by { |budget| (cost - budget[:remaining]) / budget[:limit].to_f }
        end

        def announce(query, info, cost)
          query.context.response_extensions["rateLimit"] =
            { "cost" => cost, "limit" => info[:limit], "remaining" => info[:remaining], "resetIn" => self.class.reset_in(info) }
        end

        # In the context hash for instrumentation, and per query for `headers`: queries of a multiplex may share one
        # context hash, where the last query's record wins. The limiter's write is not the query's: a resolver that reads
        # the record later reads an input of its answer, and the response cache must see that read.
        def record(query, **info)
          info = { **info.slice(:key, :cost, :limit, :remaining), window: @window, soft: @soft, limited: info[:limited], **info.slice(:keys, :invalid) }
          query.context.namespace(NAMESPACE)[:points] = info
          Caching.neutral(query.context) { query.context[CONTEXT_KEY] = info }
          info
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
          prepend AnalysisGuard::Visited

          # graphql-ruby's words when a connection has no `first:`, `last:` or page size. A client can send that, so it answers
          # an error for the client and not a server error. Nothing is charged, and any other error while scoring still raises.
          UNSIZED_CONNECTION = "Can't calculate complexity for "

          def result
            cost = begin
              super
            rescue GraphQL::Error => error
              raise unless error.instance_of?(GraphQL::Error) && error.message.start_with?(UNSIZED_CONNECTION)

              Caching.neutral(query.context) { query.context[CONTEXT_KEY] = nil }
              return AnalysisGuard.answer(query, points) { GraphQL::AnalysisError.new("This connection needs first: or last:", extensions: { "code" => "PAGE_SIZE_REQUIRED" }) }
            end
            unless cost.is_a?(Numeric) && cost.finite? && !cost.negative?
              raise ConfigurationError, "the query complexity is #{cost.inspect}: field complexities must be numbers of zero or more"
            end

            # Fractional complexities (`complexity: 0.5`) are charged whole points, rounded up.
            AnalysisGuard.answer(query, points) { points.(query, cost.ceil) }
          end
        end
      end
    end
  end
end
