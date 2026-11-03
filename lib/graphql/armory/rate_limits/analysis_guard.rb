# frozen_string_literal: true

module GraphQL
  module Armory
    module RateLimits
      # graphql-ruby discards an ExecutionError raised during analysis, drops what every analyzer answered, and runs the query.
      # A client can choose that by field order when a `complexity:` lambda raises. So on such a raise each limiter still
      # decides: a refusal already given stands, a limiter not asked yet is asked on its own, and a limiter that cannot answer
      # refuses the query in hard mode and records `charged: false` in soft mode. Every other analyzer is then asked on its
      # own: a refusal it returns or raises stands, and one that raises anything else cannot answer, so unless another refusal
      # stands the query is refused with QUERY_LIMIT_UNKNOWN. A multiplex analyzer cannot be asked again, so when the raise
      # stopped the visit before its end, a query of a multiplex with multiplex analyzers is refused the same way.
      # Only the analysis of an execution decides here. An analysis the app runs itself is not guarded: its limiters still
      # charge and take a slot, and the execution charges again; what it answered is dropped when the execution's analysis
      # starts. It does not cover a trace that takes no modules from the schema (`context[:trace]`, or a class given to
      # `trace_mode`).
      module AnalysisGuard
        ANSWERS = :limiter_answers
        ASKED = :limiter_asked
        ARMED = :limiter_guard_armed
        MULTIPLEXED = :limiter_guard_multiplexed
        # Set just before the guard asks one analyzer again, and taken by that analysis only, so a nested one never sees it.
        REASK = :limiter_guard_reask
        RAISED = :limiter_guard_raised
        VISITED = :limiter_guard_visited
        STALE = [ASKED, ANSWERS, VISITED, RAISED, :time_charges].freeze
        NOT_CHARGED = "This query could not be charged to its rate limit."
        LIMIT_UNKNOWN = "The limits of this query could not be computed."

        # Prepended to the limiters' analyzers: records that a visit of the query reached its end. graphql-ruby calls `result`
        # only after the whole visit, every hook of every analyzer (the multiplex ones too) included; a leave hook is not
        # enough, since the query analyzers leave before the multiplex ones. Marked before computing anything, because a
        # `complexity:` lambda raises inside Points' `result`.
        module Visited
          def result
            query.context.namespace(Points::NAMESPACE)[VISITED] = true
            super
          end
        end

        # Runs a limiter, keeping per query and per limiter that it was asked and what it answered. A limiter that raised partway
        # may have charged some of its keys, so it is never asked again.
        def self.answer(query, limiter)
          state = query.context.namespace(Points::NAMESPACE)
          (state[ASKED] ||= {})[limiter] = true
          (state[ANSWERS] ||= {})[limiter] = yield
        end

        def self.decide(query, error)
          state = query.context.namespace(Points::NAMESPACE)
          # Read before the guard's own visits below. A limiter answers from `result`, after the whole visit.
          visited = state[VISITED] || !(state[ASKED] || {}).empty?
          refusals, late = limiter_refusals(query, error)
          # Each new visit gets a whole timeout of its own, and the timeout already refuses the query.
          return [late] if late
          return refusals if timeout?(error)

          kept, unknown = other_answers(query)
          unknown ||= !visited && state[MULTIPLEXED]
          # A lambda's AnalysisError can come back from a limiter and from a maximum alike: show it once.
          refusals = (refusals + kept).uniq { |refusal| [refusal.message, refusal.extensions] }
          refusals.empty? && unknown ? [GraphQL::AnalysisError.new(LIMIT_UNKNOWN, extensions: { "code" => "QUERY_LIMIT_UNKNOWN" })] : refusals
        end

        # Asks one analyzer on its own and answers `[results, the error it raised or nil]`.
        def self.ask(query, analyzer)
          state = query.context.namespace(Points::NAMESPACE)
          state[REASK] = true
          [GraphQL::Analysis.analyze_query(query, [analyzer]), state.delete(RAISED)]
        ensure
          state.delete(REASK)
        end
        private_class_method :ask

        def self.limiter_refusals(query, error)
          analyzers = query.analyzers.select { |analyzer| analyzer.respond_to?(:armory_limiter) }
          state = query.context.namespace(Points::NAMESPACE)
          answers = (state[ANSWERS] ||= {})
          asked = (state[ASKED] ||= {})
          analyzers.reject { |analyzer| asked.key?(analyzer.armory_limiter) }.each do |analyzer|
            results, raised = ask(query, analyzer)
            late = timeout?(raised) ? raised : results.flatten.find { |answer| timeout?(answer) }
            return [[], late] if late
          end

          silent = analyzers.map(&:armory_limiter).reject { |limiter| answers.key?(limiter) || exempt?(limiter, query) }
          silent.each { |limiter| query.context[limiter.class::CONTEXT_KEY] = { limit: nil, soft: limiter.soft?, limited: !limiter.soft?, charged: false } }

          refusals = answers.values.compact
          return [refusals, nil] unless refusals.empty?
          return [[], nil] if silent.all?(&:soft?)

          [[error.is_a?(GraphQL::AnalysisError) ? error : GraphQL::AnalysisError.new(NOT_CHARGED, extensions: { "code" => "RATE_LIMIT_NOT_CHARGED" })], nil]
        end

        private_class_method :limiter_refusals

        # What the analyzers that are not limiters return or raise, one at a time, and whether one could not answer. Each is
        # asked once more at most, so a raise the client chose costs one more visit per analyzer of the schema.
        def self.other_answers(query)
          kept = []
          unknown = false
          query.analyzers.reject { |analyzer| analyzer.respond_to?(:armory_limiter) }.each do |analyzer|
            results, raised = ask(query, analyzer)
            answers = results.flatten.grep(GraphQL::AnalysisError)
            late = timeout?(raised) ? raised : answers.find { |answer| timeout?(answer) }
            return [[late], false] if late

            if raised.is_a?(GraphQL::AnalysisError)
              # Raised from `result`: a refusal, with the app's own message.
              kept << raised
            elsif raised
              unknown = true
            else
              kept.concat(answers)
            end
          end
          [kept, unknown]
        end
        private_class_method :other_answers

        def self.timeout?(error)
          defined?(GraphQL::Analysis::TimeoutError) && error.is_a?(GraphQL::Analysis::TimeoutError)
        end
        private_class_method :timeout?

        # A limit that cannot be asked for does not exempt anyone.
        def self.exempt?(limiter, query)
          limiter.exempt?(query)
        rescue GraphQL::ExecutionError, GraphQL::UnauthorizedError
          false
        end
        private_class_method :exempt?

        # Mirrors how graphql-ruby builds the multiplex analyzers on both engines.
        def analyze_multiplex(multiplex:)
          multiplexed = !multiplex.max_complexity.nil? || multiplex.schema.multiplex_analyzers.any?
          multiplex.queries.each do |query|
            state = query.context.namespace(Points::NAMESPACE)
            state[ARMED] = true
            state[MULTIPLEXED] = multiplexed
          end
          super
        end

        # The first analysis of each query in an execution, and each analyzer the guard asks again. Any other, nested in them or
        # run by the app, passes through. graphql-ruby swallows a raise outside this hook, so the guard records it here.
        def analyze_query(query:)
          state = query.context.namespace(Points::NAMESPACE)
          return reasked(state) { super } if state.delete(REASK)
          return super unless state.delete(ARMED)

          # An analysis the app ran itself on this Query left its answers and its visit: the execution decides from its own.
          # Time's debt from that analysis goes too, so a query the execution refuses is not charged for it. A Concurrency
          # slot it took stays recorded, so that the end of the execution releases it.
          STALE.each { |key| state.delete(key) }
          begin
            super
          rescue GraphQL::ExecutionError, GraphQL::UnauthorizedError => error
            decided(query, error)
          end
        end

        private

        def reasked(state)
          yield
        rescue GraphQL::ExecutionError, GraphQL::UnauthorizedError => error
          state[RAISED] = error
          raise
        end

        def decided(query, error)
          refusals = AnalysisGuard.decide(query, error)
          raise error if refusals.empty?

          refusals
        end
      end
    end
  end
end
