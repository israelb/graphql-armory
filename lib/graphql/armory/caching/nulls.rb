# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # The operation's policy from its declarations (unit U3). `Null` refuses everything.
      class Walk
        class Null
          def call(_query) = Policy.refused(:unconfigured)
        end
      end

      # The request's Key (unit U7). `Null` refuses everything.
      class Keyer
        class Null
          def call(_query, _policy) = Policy.refused(:unconfigured)
        end
      end

      # Charges a hit the Points its run cost (unit U6): `charge.(query, cost)` answers nil (charged) or the
      # limiter's refusal.
      class Charge
        # Charges nothing: for schemas without a Points limiter.
        class Null
          def call(_query, _cost) = nil
        end

        # Answers what it is told (`refuse_with(refusal)`, `recover`) and records `calls` as `[query, cost]`.
        class Substitute
          attr_reader :calls

          def initialize
            @calls = []
            @refusal = nil
          end

          def refuse_with(refusal)
            @refusal = refusal
          end

          def recover
            @refusal = nil
          end

          def call(query, cost)
            @calls << [query, cost]
            @refusal
          end
        end
      end
    end
  end
end
