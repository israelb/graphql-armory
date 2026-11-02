# frozen_string_literal: true

module GraphQL
  module Armory
    module RateLimits
      # graphql-ruby discards an ExecutionError raised during analysis, drops what every analyzer answered, and runs the query.
      # A client can choose that by field order when a `complexity:` lambda raises. So on such a raise each limiter still
      # decides: a refusal already given stands, a limiter not asked yet is asked on its own, and a limiter that cannot answer
      # refuses the query in hard mode and records `charged: false` in soft mode. Only the analysis of an execution counts: an
      # analysis the app runs itself takes no slot and charges nothing here. It does not cover a trace that takes no modules
      # from the schema (`context[:trace]`, or a class given to `trace_mode`).
      module AnalysisGuard
        ANSWERS = :limiter_answers
        ASKED = :limiter_asked
        ARMED = :limiter_guard_armed
        NOT_CHARGED = "This query could not be charged to its rate limit."

        # Runs a limiter, keeping per query and per limiter that it was asked and what it answered. A limiter that raised partway
        # may have charged some of its keys, so it is never asked again.
        def self.answer(query, limiter)
          state = query.context.namespace(Points::NAMESPACE)
          (state[ASKED] ||= {})[limiter] = true
          (state[ANSWERS] ||= {})[limiter] = yield
        end

        def self.decide(query, error)
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
