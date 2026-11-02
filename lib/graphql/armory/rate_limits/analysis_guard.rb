# frozen_string_literal: true

module GraphQL
  module Armory
    module RateLimits
      # graphql-ruby discards an ExecutionError raised during analysis, drops what every analyzer answered, and runs the query.
      # A client can choose that by field order when a `complexity:` lambda raises. So on such a raise each limiter still
      # decides: a refusal already given stands, a limiter not asked yet is asked on its own, and a limiter that cannot answer
      # refuses the query in hard mode and records `charged: false` in soft mode. It does not cover a `context[:trace]` not
      # built from the schema.
      module AnalysisGuard
        ANSWERS = :limiter_answers
        ACTIVE = :limiter_guard_active
        NOT_CHARGED = "This query could not be charged to its rate limit."

        # What a limiter's analyzer answered, kept per query and per limiter, once the limiter has returned.
        def self.answered(query, limiter, refusal)
          (query.context.namespace(Points::NAMESPACE)[ANSWERS] ||= {})[limiter] = refusal
          refusal
        end

        def self.decide(query, error)
          analyzers = query.analyzers.select { |analyzer| analyzer.respond_to?(:armory_limiter) }
          answers = (query.context.namespace(Points::NAMESPACE)[ANSWERS] ||= {})
          analyzers.reject { |analyzer| answers.key?(analyzer.armory_limiter) }.each { |analyzer| ask(query, analyzer) }

          refusals = answers.values.compact
          return refusals unless refusals.empty?

          silent = analyzers.map(&:armory_limiter).reject { |limiter| answers.key?(limiter) || exempt?(limiter, query) }
          silent.each { |limiter| query.context[limiter.class::CONTEXT_KEY] = { limit: nil, soft: limiter.soft?, limited: !limiter.soft?, charged: false } }
          return [] if silent.all?(&:soft?)

          [error.is_a?(GraphQL::AnalysisError) ? error : GraphQL::AnalysisError.new(NOT_CHARGED, extensions: { "code" => "RATE_LIMIT_NOT_CHARGED" })]
        end

        # One at a time, so an analyzer that raises leaves the others asked.
        def self.ask(query, analyzer)
          state = query.context.namespace(Points::NAMESPACE)
          state[ACTIVE] = true
          GraphQL::Analysis.analyze_query(query, [analyzer])
        ensure
          state[ACTIVE] = false
        end
        private_class_method :ask

        # A limit that cannot be asked for does not exempt anyone.
        def self.exempt?(limiter, query)
          limiter.exempt?(query)
        rescue GraphQL::ExecutionError, GraphQL::UnauthorizedError
          false
        end
        private_class_method :exempt?

        def analyze_query(query:)
          super
        rescue GraphQL::ExecutionError, GraphQL::UnauthorizedError => error
          raise if query.context.namespace(Points::NAMESPACE)[ACTIVE]

          refusals = AnalysisGuard.decide(query, error)
          raise error if refusals.empty?

          refusals
        end
      end
    end
  end
end
