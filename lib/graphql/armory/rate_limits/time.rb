# frozen_string_literal: true

module GraphQL
  module Armory
    module RateLimits
      # Charges each client the wall-clock milliseconds its operations take, against a bucket of milliseconds per
      # client that refills over a window:
      #
      #   use GraphQL::Armory::RateLimits::Time, store: GraphQL::Armory::RateLimits::MemoryStore.new,
      #     limit: 10_000, window: 60, soft: false
      #
      # A query analyzer asks the store for the client's balance before the operation runs and refuses it, before any
      # field resolves, when none is left. A trace measures the multiplex with a monotonic clock and charges the
      # elapsed milliseconds when it ends, even when it raises. A running operation is never interrupted: the one
      # that spends the last milliseconds finishes, and the next is refused. Soft mode (the default) charges and
      # records but refuses nothing. What happened is in `context[:rate_limit_time]`.
      class Time
        CONTEXT_KEY = :rate_limit_time
        NAMESPACE = :graphql_armory

        def self.use(schema, store:, limit:, window: 60, soft: true, key: nil, on_store_error: nil, clock: Clock.monotonic, extensions: false)
          build(store: store, limit: limit, window: window, soft: soft, key: key, on_store_error: on_store_error, clock: clock, extensions: extensions).install(schema)
        end

        # HTTP headers for the budget a result recorded: `RateLimit-Time-Limit` and `RateLimit-Time-Remaining` in
        # milliseconds, and `RateLimit-Time-Reset` (seconds until the bucket is full again). Prefixed so they never
        # clash with the `Points` headers. Empty when the query had no limit.
        def self.headers(result)
          info = result.context.namespace(NAMESPACE)[:time]
          return {} unless info && info[:limit] && info[:remaining]

          {
            "RateLimit-Time-Limit" => info[:limit].to_s,
            "RateLimit-Time-Remaining" => info[:remaining].to_s,
            "RateLimit-Time-Reset" => Points.reset_in(info).to_s
          }
        end

        # Wires the app's store with `use`'s defaults (soft mode); `use` goes through here.
        def self.build(store:, limit:, window: 60, soft: true, key: nil, on_store_error: nil, clock: Clock.monotonic, extensions: false)
          new(store: store, limit: limit, window: window, soft: soft, key: key, on_store_error: on_store_error, clock: clock, extensions: extensions)
        end

        # `new` is inert: with no store wired it refuses every query. It checks every setting, so no partial
        # configuration lets a query through either.
        def initialize(store: Store::Null.new, limit: 1, window: 60, soft: false, key: nil, on_store_error: nil, clock: Clock.monotonic, extensions: false)
          unless Settings.store_answers?(store, take: %i[cost limit window force])
            raise ConfigurationError, "store: must answer take(key, cost:, limit:, window:, force:), like a MemoryStore"
          end

          @store = store
          @limit = Settings.wired_limit(limit, store)
          @window = Settings.seconds(:window, window)
          @soft = Settings.wired_soft(soft, store)
          @key = Settings.key_reader(key)
          @on_store_error = Settings.store_error_handler(on_store_error)
          @clock = Settings.clock(clock)
          @extensions = Settings.extensions(extensions)
          @trace = measuring_trace
        end

        # Adds the analyzer and the trace to the schema.
        def install(schema)
          time = self
          schema.query_analyzer(Class.new(Analyzer) { define_method(:time) { time } })
          schema.trace_with(@trace)
        end

        # The refusal for a client with no milliseconds left, or nil to let the operation run (and be charged).
        def call(query)
          unless query.current_trace.is_a?(@trace)
            raise ConfigurationError, "this query runs with its own trace (context[:trace]), so Time could never charge it: remove context[:trace] or add trace_with to that trace"
          end

          key = Settings.key_for(@key, query)
          limit = Settings.limit_for(@limit, key, query)
          if limit.nil?
            record(query, key: key, limit: nil, remaining: nil, limited: false)
            return nil
          end

          answer = begin
            @store.take(key, cost: 0, limit: limit, window: @window, force: false)
          rescue StandardError => error
            # Fail open, and still measure: the charge may find the store back.
            query.context[CONTEXT_KEY] = nil
            @on_store_error.call(error, query)
            owe(query, key, limit)
            return nil
          end
          _taken, remaining = Settings.checked(answer, :take, "the Integer milliseconds left")

          limited = remaining.zero?
          info = record(query, key: key, limit: limit, remaining: remaining, limited: limited)
          announce(query, info) if @extensions
          return refusal(limit) if limited && !@soft

          owe(query, key, limit)
          nil
        end

        # The clock's reading, for the trace.
        def now
          @clock.call
        end

        # Charges the elapsed time since `started`, split equally among the queries of the multiplex that ran.
        def charge(multiplex, started)
          return if started.nil?

          seconds = @clock.call - started
          seconds = 0 unless seconds.is_a?(Numeric) && seconds.finite? && seconds.positive?
          owed = multiplex.queries.filter_map do |query|
            debt = query.context.namespace(NAMESPACE).delete(:time_charge)
            [query, *debt] if debt
          end
          return if owed.empty?

          share = (seconds * 1000 / owed.size.to_f).ceil
          # Every query is charged even if one hook raises; the first such error is raised afterwards.
          failure = nil
          owed.each do |query, _time, key, limit|
            charge_one(query, key, limit, share)
          rescue StandardError => error
            failure ||= error
          end
          raise failure if failure
        end

        private

        def charge_one(query, key, limit, cost)
          answer = @store.take(key, cost: cost, limit: limit, window: @window, force: true)
          _taken, remaining = Settings.checked(answer, :take, "the Integer milliseconds left")
          settle(query, key, limit, cost, remaining)
        rescue StandardError => error
          @on_store_error.call(error, query)
        end

        # What the client has left once the charge is in, in the record and in the extensions announced earlier.
        def settle(query, key, limit, cost, remaining)
          space = query.context.namespace(NAMESPACE)
          info = (space[:time] || base_record(key: key, limit: limit, limited: false)).merge(remaining: remaining, elapsed: cost)
          space[:time] = info
          query.context[CONTEXT_KEY] = info
          space[:time_extension]&.merge!("remaining" => remaining, "elapsed" => cost, "resetIn" => Points.reset_in(info))
        end

        # Per query, not in the context hash: queries of a multiplex may share one hash.
        def owe(query, key, limit)
          query.context.namespace(NAMESPACE)[:time_charge] = [self, key, limit]
        end

        def record(query, **info)
          info = base_record(**info)
          query.context.namespace(NAMESPACE)[:time] = info
          query.context[CONTEXT_KEY] = info
        end

        # `elapsed` is nil until the operation ends and is charged; it stays nil for a refused one.
        def base_record(key:, limit:, limited:, remaining: nil)
          { key: key, limit: limit, remaining: remaining, elapsed: nil, window: @window, soft: @soft, limited: limited }
        end

        # The budget before the run; the charge completes the same hash, which the response already holds.
        def announce(query, info)
          extension = { "limit" => info[:limit], "remaining" => info[:remaining], "resetIn" => Points.reset_in(info) }
          query.context.response_extensions["rateLimitTime"] = extension
          query.context.namespace(NAMESPACE)[:time_extension] = extension
        end

        def refusal(limit)
          retry_after = [(@window / limit.to_f).ceil, 1].max
          GraphQL::AnalysisError.new(
            "Rate limit exceeded: this client used its #{limit} ms of processing time every #{@window} seconds. Retry in #{retry_after} seconds.",
            extensions: { "code" => "RATE_LIMITED", "limit" => limit, "retryAfter" => retry_after }
          )
        end

        # One module per limiter, so the trace reads this limiter's clock and charges this limiter's store.
        def measuring_trace
          time = self
          Module.new do
            # `define_method` does not forward the block implicitly, as `def` with `super` does.
            define_method(:execute_multiplex) do |multiplex:, &block|
              started = time.now
              super(multiplex: multiplex, &block)
            ensure
              time.charge(multiplex, started)
            end
          end
        end

        # Asks for the balance during analysis, before anything runs.
        class Analyzer < GraphQL::Analysis::Analyzer
          def result
            time.(query)
          end
        end
      end
    end
  end
end
