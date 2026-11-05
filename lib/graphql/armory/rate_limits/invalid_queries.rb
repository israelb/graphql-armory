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

            # Who pays does not change any answer: the response cache does not count these reads (Caching.neutral).
            limits = Caching.neutral(query.context) { Settings.limits_for(limit, Array(Settings.key_for(reader, query)), query) }
            (groups[limits] ||= []) << query unless limits.empty?
          rescue StandardError => error
            report(handler, error, query)
          end
          groups
        end

        # Takes `cost` from each key in order, as if the queries had come one at a time. A key that cannot pay all of it pays
        # what it holds, and the keys after it pay only that much: sending invalid queries together never costs a client less
        # than sending them apart, and a client with nothing left cannot keep draining a bucket it shares. Never with `force`,
        # never below zero. A key whose store fails is left out. Answers `[budgets, every key paid in full]`.
        def self.charge(store, limits, cost, window, handler, query, bucket: ->(key) { key })
          budgets = []
          paid = true
          limits.each do |key, limit|
            break if cost.zero?

            stored = bucket.call(key)
            taken, remaining = take(store, stored, cost, limit, window)
            unless taken
              paid = false
              # A refused take changes nothing and answers what the key holds. Taking that can still fail when another request
              # got there first; then the keys after it pay nothing.
              held = remaining
              cost = 0
              if held.positive?
                again, remaining = take(store, stored, held, limit, window)
                cost = held if again
              end
            end
            budgets << { key: key, limit: limit, remaining: remaining }
          rescue StandardError => error
            report(handler, error, query)
          end
          [budgets, paid]
        end

        def self.take(store, key, cost, limit, window)
          Settings.checked(store.take(key, cost: cost, limit: limit, window: window, force: false), :take, "the Integer left")
        end
        private_class_method :take

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
