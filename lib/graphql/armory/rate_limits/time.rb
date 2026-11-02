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

        def self.use(schema, store:, limit:, window: 60, soft: true, key: nil, on_store_error: nil, sinks: [], clock: Clock.monotonic, extensions: false)
          build(store: store, limit: limit, window: window, soft: soft, key: key, on_store_error: on_store_error, sinks: sinks, clock: clock, extensions: extensions).install(schema)
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
        def self.build(store:, limit:, window: 60, soft: true, key: nil, on_store_error: nil, sinks: [], clock: Clock.monotonic, extensions: false)
          new(store: store, limit: limit, window: window, soft: soft, key: key, on_store_error: on_store_error, sinks: sinks, clock: clock, extensions: extensions)
        end

        # `new` is inert: with no store wired it refuses every query. It checks every setting, so no partial
        # configuration lets a query through either.
        def initialize(store: Store::Null.new, limit: 1, window: 60, soft: false, key: nil, on_store_error: nil, sinks: [], clock: Clock.monotonic, extensions: false)
          unless Settings.store_answers?(store, take: %i[cost limit window force])
            raise ConfigurationError, "store: must answer take(key, cost:, limit:, window:, force:), like a MemoryStore"
          end

          @store = store
          @limit = Settings.wired_limit(limit, store)
          @window = Settings.seconds(:window, window)
          @soft = Settings.wired_soft(soft, store)
          @key = Settings.key_reader(key)
          @on_store_error = Settings.store_error_handler(on_store_error, limiter: :time, sinks: sinks)
          @clock = Settings.clock(clock)
          now # a clock that answers anything but a finite number fails here, not by charging nothing
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
          return call_several(query, key) if key.is_a?(Array)

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
          extension = announce(query, info) if @extensions
          return refusal(limit) if limited && !@soft

          owe(query, key, limit, info, extension)
          nil
        end

        # The clock's reading, for the trace. A reading that is not a finite number would make the charge
        # impossible, so it raises instead of letting operations run uncharged.
        def now
          reading = @clock.call
          return reading if reading.is_a?(Numeric) && reading.finite?

          raise ConfigurationError, "clock: answered #{reading.inspect}: it must answer a finite number of seconds"
        end

        # Charges the elapsed time since `started`, split equally among the queries of the multiplex that ran.
        def charge(multiplex, started)
          return if started.nil?

          # A clock that stands still or goes backwards charges nothing.
          seconds = [now - started, 0].max
          # Each limiter takes only its own debts: a schema may `use` several, with different stores and keys.
          owed = multiplex.queries.filter_map do |query|
            debt = query.context.namespace(NAMESPACE)[:time_charges]&.delete(self)
            [query, debt] if debt
          end
          return if owed.empty?

          share = (seconds * 1000 / owed.size.to_f).ceil
          # Every query is charged even if one hook raises; the first such error is raised afterwards.
          failure = nil
          owed.each do |query, debt|
            charge_one(query, debt, share)
          rescue StandardError => error
            failure ||= error
          end
          raise failure if failure
        end

        private

        # Each key is charged on its own: a store failure on one, or a hook that raises for it, leaves the others charged. The
        # first error a hook raises is raised afterwards.
        def charge_one(query, debt, cost)
          failure = nil
          charged = (debt[:others] || {}).to_h do |key, limit|
            [key, charge_key(key, limit, cost)]
          rescue StandardError => error
            failure ||= heard(query, error)
            [key, nil]
          end
          begin
            settle(query, debt, cost, charge_key(debt[:key], debt[:limit], cost), charged)
          rescue StandardError => error
            failure ||= heard(query, error)
          end
          raise failure if failure
        end

        def charge_key(key, limit, cost)
          answer = @store.take(key, cost: cost, limit: limit, window: @window, force: true)
          Settings.checked(answer, :take, "the Integer milliseconds left").last
        end

        # What the hook raised for this error, if it did.
        def heard(query, error)
          @on_store_error.call(error, query)
          nil
        rescue StandardError => raised
          raised
        end

        # Reads every balance. A refusal charges none, as with one key; otherwise every key owes the whole time. A key whose
        # store fails at the read still owes it, and the others still decide.
        def call_several(query, keys)
          limits = Settings.limits_for(@limit, keys, query)
          if limits.empty?
            record(query, key: keys.first, limit: nil, remaining: nil, limited: false, keys: [])
            return nil
          end

          budgets = limits.filter_map do |key, limit|
            answer = begin
              @store.take(key, cost: 0, limit: limit, window: @window, force: false)
            rescue StandardError => error
              @on_store_error.call(error, query)
              next
            end
            { key: key, limit: limit, remaining: Settings.checked(answer, :take, "the Integer milliseconds left").last }
          end
          if budgets.empty?
            query.context[CONTEXT_KEY] = nil
            first, *rest = limits.to_a
            owe(query, first[0], first[1], others: rest.to_h)
            return nil
          end

          limited = budgets.any? { |budget| budget[:remaining].zero? }
          binding = budgets.select { |budget| budget[:remaining].zero? }.min_by { |budget| budget[:limit] } || budgets.min_by { |budget| budget[:remaining] }
          info = record(query, key: binding[:key], limit: binding[:limit], remaining: binding[:remaining], limited: limited, keys: budgets)
          extension = announce(query, info) if @extensions
          return refusal(binding[:limit]) if limited && !@soft

          owe(query, binding[:key], binding[:limit], info, extension, others: limits.reject { |key, _limit| key == binding[:key] })
          nil
        end

        # What the client has left once the charge is in, in the record and in the extensions announced earlier.
        def settle(query, debt, cost, remaining, others = {})
          info = (debt[:info] || base_record(key: debt[:key], limit: debt[:limit], limited: false)).merge(remaining: remaining, elapsed: cost)
          if info[:keys]
            current = others.compact.merge(debt[:key] => remaining)
            info[:keys] = info[:keys].map { |budget| budget.merge(remaining: current.fetch(budget[:key], budget[:remaining])) }
            # Keys with different limits refill at different rates during the run, so the binding one may have changed.
            info = info.merge(info[:keys].min_by { |budget| budget[:remaining] })
            remaining = info[:remaining]
          end
          query.context.namespace(NAMESPACE)[:time] = info
          query.context[CONTEXT_KEY] = info
          debt[:extension]&.merge!("limit" => info[:limit], "remaining" => remaining, "elapsed" => cost, "resetIn" => Points.reset_in(info))
        end

        # Per query and per limiter, not in the context hash: queries of a multiplex may share one hash, and a
        # schema may use several limiters.
        def owe(query, key, limit, info = nil, extension = nil, others: {})
          charges = (query.context.namespace(NAMESPACE)[:time_charges] ||= {})
          charges[self] = { key: key, limit: limit, info: info, extension: extension, others: others }
        end

        def record(query, **info)
          info = base_record(**info)
          query.context.namespace(NAMESPACE)[:time] = info
          query.context[CONTEXT_KEY] = info
        end

        # `elapsed` is nil until the operation ends and is charged; it stays nil for a refused one.
        def base_record(key:, limit:, limited:, remaining: nil, keys: nil)
          { key: key, limit: limit, remaining: remaining, elapsed: nil, window: @window, soft: @soft, limited: limited, **(keys ? { keys: keys } : {}) }
        end

        # The budget before the run; the charge completes the same hash, which the response already holds.
        def announce(query, info)
          extension = { "limit" => info[:limit], "remaining" => info[:remaining], "resetIn" => Points.reset_in(info) }
          query.context.response_extensions["rateLimitTime"] = extension
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
