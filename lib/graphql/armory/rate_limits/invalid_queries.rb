# frozen_string_literal: true

module GraphQL
  module Armory
    module RateLimits
      # Finds what a limiter owes for a multiplex's invalid queries, which no analyzer ever sees. It runs after the answers are
      # made, so a failure here is reported and never replaces them.
      module InvalidQueries
        # The invalid queries this limiter did not handle, grouped by what they draw from: `{ { key => limit } => [query] }`.
        def self.grouped(multiplex, limiter, reader, limit, handler)
          groups = {}
          multiplex.queries.each do |query|
            next unless invalid?(query, limiter)

            key = Settings.key_for(reader, query)
            limits = Settings.limits_for(limit, Array(key), query)
            (groups[limits] ||= []) << query unless limits.empty?
          rescue StandardError => error
            report(handler, error, query)
          end
          groups
        end

        # Takes `cost` from each key in order. A key that cannot pay all of it is drained to zero and the charge stops there, so
        # sending more invalid queries than a client has left never costs it less, and a client with nothing left cannot keep
        # draining a bucket it shares. A key whose store fails is left out. Answers `[budgets, every key paid]`.
        def self.charge(store, limits, cost, window, handler, query, bucket: ->(key) { key })
          budgets = []
          limits.each do |key, limit|
            taken, remaining = Settings.checked(store.take(bucket.call(key), cost: cost, limit: limit, window: window, force: true), :take, "the Integer left")
            budgets << { key: key, limit: limit, remaining: remaining }
            return [budgets, false] unless taken
          rescue StandardError => error
            report(handler, error, query)
          end
          [budgets, true]
        end

        def self.report(handler, error, query)
          handler.call(error, query)
        rescue StandardError => raised
          warn("graphql-armory: on_store_error raised while charging an invalid query: #{raised.class}: #{raised.message}")
        end

        # Only validation decides: `valid?` is also false for a query an analyzer refused, and graphql-ruby copies a multiplex
        # analyzer's errors into every query, invalid ones included. A query that was analyzed is not invalid: what the
        # limiter decided on it stands.
        def self.invalid?(query, limiter)
          !query.validation_pipeline.valid? && !query.context.namespace(Points::NAMESPACE)[AnalysisGuard::ASKED]&.key?(limiter)
        end
        private_class_method :invalid?
      end
    end
  end
end
