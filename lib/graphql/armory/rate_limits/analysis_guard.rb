# frozen_string_literal: true

module GraphQL
  module Armory
    module RateLimits
      # graphql-ruby discards an ExecutionError raised during analysis, drops what every analyzer answered, and runs the query.
      # A client can choose that by field order when a `complexity:` lambda raises. So on such a raise each limiter still
      # decides: a refusal already given stands, a limiter not asked yet is asked on its own, and a limiter that cannot answer
      # refuses the query in hard mode and records `charged: false` in soft mode. Every other analyzer is asked again too, so
      # a refusal it returns stands, and a `max_depth` or `max_complexity` that cannot answer refuses. Only the analysis of an execution counts: an
      # analysis the app runs itself takes no slot and charges nothing here. It does not cover a trace that takes no modules
      # from the schema (`context[:trace]`, or a class given to `trace_mode`).
      module AnalysisGuard
        ANSWERS = :limiter_answers
        ASKED = :limiter_asked
        ARMED = :limiter_guard_armed
        NOT_CHARGED = "This query could not be charged to its rate limit."
        LIMIT_UNKNOWN = "The limits of this query could not be computed."

        # Runs a limiter, keeping per query and per limiter that it was asked and what it answered. A limiter that raised partway
        # may have charged some of its keys, so it is never asked again.
        def self.answer(query, limiter)
          state = query.context.namespace(Points::NAMESPACE)
          (state[ASKED] ||= {})[limiter] = true
          (state[ANSWERS] ||= {})[limiter] = yield
        end

        def self.decide(query, error)
          refusals = limiter_refusals(query, error)
          # Each new visit gets a whole timeout of its own, and the timeout already refuses the query.
          return refusals if defined?(GraphQL::Analysis::TimeoutError) && error.is_a?(GraphQL::Analysis::TimeoutError)

          kept, unknown = other_answers(query)
          refusals += kept
          refusals.empty? && unknown ? [GraphQL::AnalysisError.new(LIMIT_UNKNOWN, extensions: { "code" => "QUERY_LIMIT_UNKNOWN" })] : refusals
        end

        def self.limiter_refusals(query, error)
          analyzers = query.analyzers.select { |analyzer| analyzer.respond_to?(:armory_limiter) }
          state = query.context.namespace(Points::NAMESPACE)
          answers = (state[ANSWERS] ||= {})
          asked = (state[ASKED] ||= {})
          analyzers.reject { |analyzer| asked.key?(analyzer.armory_limiter) }.each { |analyzer| GraphQL::Analysis.analyze_query(query, [analyzer]) }

          silent = analyzers.map(&:armory_limiter).reject { |limiter| answers.key?(limiter) || exempt?(limiter, query) }
          silent.each { |limiter| query.context[limiter.class::CONTEXT_KEY] = { limit: nil, soft: limiter.soft?, limited: !limiter.soft?, charged: false } }

          refusals = answers.values.compact
          return refusals unless refusals.empty?
          return [] if silent.all?(&:soft?)

          [error.is_a?(GraphQL::AnalysisError) ? error : GraphQL::AnalysisError.new(NOT_CHARGED, extensions: { "code" => "RATE_LIMIT_NOT_CHARGED" })]
        end

        private_class_method :limiter_refusals

        # What the analyzers that are not limiters return, one at a time, and whether a maximum could not answer: `analyze_query`
        # answers an empty list for a raise, and `[nil]` for an analyzer with nothing to refuse.
        def self.other_answers(query)
          unknown = false
          kept = query.analyzers.reject { |analyzer| analyzer.respond_to?(:armory_limiter) }.flat_map do |analyzer|
            results = GraphQL::Analysis.analyze_query(query, [analyzer])
            unknown ||= results.empty? && maximum?(analyzer) && analyzes?(analyzer, query)
            results.flatten.grep(GraphQL::AnalysisError)
          end
          [kept, unknown]
        end
        private_class_method :other_answers

        def self.maximum?(analyzer)
          analyzer <= GraphQL::Analysis::MaxQueryDepth || analyzer <= GraphQL::Analysis::MaxQueryComplexity
        end
        private_class_method :maximum?

        def self.analyzes?(analyzer, query)
          analyzer.new(query).analyze?
        rescue GraphQL::ExecutionError, GraphQL::UnauthorizedError
          true
        end
        private_class_method :analyzes?

        # A limit that cannot be asked for does not exempt anyone.
        def self.exempt?(limiter, query)
          limiter.exempt?(query)
        rescue GraphQL::ExecutionError, GraphQL::UnauthorizedError
          false
        end
        private_class_method :exempt?

        def analyze_multiplex(multiplex:)
          multiplex.queries.each { |query| query.context.namespace(Points::NAMESPACE)[ARMED] = true }
          super
        end

        # The first analysis of each query in an execution. Any other, nested in it or run by the app, passes through, and
        # each analyzer is asked apart, so one that raises leaves the others asked.
        def analyze_query(query:)
          return super unless query.context.namespace(Points::NAMESPACE).delete(ARMED)

          begin
            super
          rescue GraphQL::ExecutionError, GraphQL::UnauthorizedError => error
            decided(query, error)
          end
        end

        private

        def decided(query, error)
          refusals = AnalysisGuard.decide(query, error)
          raise error if refusals.empty?

          refusals
        end
      end
    end
  end
end
