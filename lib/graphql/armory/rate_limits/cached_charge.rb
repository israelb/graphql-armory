# frozen_string_literal: true

module GraphQL
  module Armory
    module RateLimits
      # Charges a response the cache answers instead of running it. A hit runs no analyzer, so without this it would be
      # free, and a budget that does not move tells the client that someone else asked the same question first. Mixed
      # into `Points`; the response cache reaches it through `Caching::Charge`.
      module CachedCharge
        # Charges `cost`, the points the query's run was charged, exactly as a run is charged: the same keys, limits,
        # soft mode and store, the same records (`context[:rate_limit_points]` and the query's own namespace), the same
        # `rateLimit` extension and so the same `Points.headers`. Answers nil when the hit may be served, or the
        # limiter's own `RATE_LIMITED` refusal, the `GraphQL::AnalysisError` a run would answer. A store that fails lets
        # the hit through and is reported to `on_store_error`, as for a run.
        #
        # A `key:` or `limit:` callable that raises a GraphQL::ExecutionError is handled as `AnalysisGuard` handles it
        # for a run: in hard mode the refusal is that error when it is an AnalysisError, else RATE_LIMIT_NOT_CHARGED; in
        # soft mode the hit is served and recorded `charged: false`.
        def charge_cached(query, cost:)
          unless cost.is_a?(Integer) && !cost.negative?
            raise ArgumentError, "cost: must be the non-negative Integer of points the run was charged, got #{cost.inspect}"
          end

          call(query, cost)
        rescue GraphQL::ExecutionError, GraphQL::UnauthorizedError => error
          uncharged(query, error)
        end

        private

        def uncharged(query, error)
          Caching.neutral(query.context) do
            query.context[self.class::CONTEXT_KEY] = { limit: nil, soft: soft?, limited: !soft?, charged: false }
          end
          return nil if soft?
          return error if error.is_a?(GraphQL::AnalysisError)

          GraphQL::AnalysisError.new(AnalysisGuard::NOT_CHARGED, extensions: { "code" => "RATE_LIMIT_NOT_CHARGED" })
        end
      end
    end
  end
end
