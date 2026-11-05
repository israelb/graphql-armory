# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # Charges a hit the Points its run cost (design 4.6). A hit runs no analyzer, so the gate calls this instead: it
      # calls `Points#charge_cached` on every Points limiter of the query's schema, found through `query_analyzers` and
      # the `armory_limiter` reader Points defines on its analyzer. Time does not bound hits, and Concurrency takes no
      # slot for one.
      #
      #   charge = Charge.build(schema)
      #   charge.limited?(query)             # is any Points limiter installed? (a run must record its cost to be stored)
      #   Charge.recorded_cost(query)        # after a run: the Integer cost it was charged, or nil
      #   refusal = charge.(query, cost)     # on a hit: nil (charged, serve it) or a GraphQL::Query::Result to answer
      #   Charge.result(query, "data" => data)  # the hit's Result, with the extensions the charge added
      #
      # `Charge.new` is inert: it finds no limiter and charges nothing, like `Charge::Null`.
      class Charge
        # graphql-ruby keeps a query's response extensions in this context namespace (`Context#response_extensions`) and
        # copies it into the result when it exists.
        EXTENSIONS = :__query_result_extensions__

        def self.build(schema)
          unless schema.is_a?(Class) && schema <= GraphQL::Schema
            raise ConfigurationError, "Charge.build needs a GraphQL::Schema class, got #{schema.inspect}"
          end

          new(schema: schema)
        end

        # The Points cost the query's own run was charged, from its own record (`namespace(:graphql_armory)[:points]`),
        # never from `context[:rate_limit_points]`: queries of a multiplex may share one context Hash, where the last
        # query's record wins. Nil when the run recorded no cost (no Points limiter, a store that failed, a limiter that
        # could not charge) or was charged as an invalid query.
        def self.recorded_cost(query)
          info = query.context.namespace(RateLimits::Points::NAMESPACE)[:points]
          return nil if info.nil? || info[:invalid]

          cost = info[:cost]
          cost if cost.is_a?(Integer) && !cost.negative?
        end

        # The Result graphql-ruby would build for `query` with these `values` ("data", or "errors"): the response
        # extensions are added under "extensions" when the query has any, as both engines do. A charge with
        # `extensions: true` puts `rateLimit` there.
        def self.result(query, values)
          values = values.dup
          values["extensions"] = query.context.namespace(EXTENSIONS) if query.context.namespace?(EXTENSIONS)
          GraphQL::Query::Result.new(query: query, values: values)
        end

        def initialize(schema: nil)
          @schema = schema
        end

        # Charges `cost` to every Points limiter, in the order the schema has them, as a run's analysis does: each
        # limiter is charged even when an earlier one refused. Answers nil when every limiter let the hit through, or the
        # Result a run refused by its limiters answers: `{ "errors" => [each refusal's to_h], "extensions" => ... }`.
        # Raises ArgumentError when a limiter is installed and `cost` is not a non-negative Integer.
        def call(query, cost)
          refusals = limiters(query).filter_map { |points| points.charge_cached(query, cost: cost) }
          return nil if refusals.empty?

          self.class.result(query, "errors" => refusals.map(&:to_h))
        end

        # Whether a Points limiter is installed on the query's schema (or, without a query, on the schema built with).
        def limited?(query = nil)
          !limiters(query).empty?
        end

        # Looked up on every call, not at build: the response cache is built at `use`, and Points may be `use`d after it.
        # A query of a subclass is charged by the subclass's limiters, as its run would be.
        def limiters(query = nil)
          return [] if @schema.nil?

          schema = query && query.schema.is_a?(Class) && query.schema <= @schema ? query.schema : @schema
          schema.query_analyzers.filter_map do |analyzer|
            limiter = analyzer.armory_limiter if analyzer.respond_to?(:armory_limiter)
            limiter if limiter.is_a?(RateLimits::Points)
          end
        end
      end
    end
  end
end
