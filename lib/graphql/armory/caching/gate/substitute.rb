# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # Decides, per `multiplex` call, which queries are answered from the store, which run and may be stored, and
      # which run uncached (unit U8):
      #
      #   gate.(queries, engine:) -> [Decision]               # one per query, in order
      #   gate.store(query, decision, result) -> :stored | reason
      class Gate
        # Answers the decisions it is told and records what it saw, for the integration's specs:
        #
        #   gate = Gate::Substitute.new
        #   gate.decide(Decision.hit(entry), Decision.pass(:mutation))   # consumed in order; then pass(:unconfigured)
        #   gate.store_answer(:errors)                                   # what `store` answers (default :stored)
        #   gate.seen                                                    # => [[queries, engine], ...]
        #   gate.stored                                                  # => [[query, decision, result], ...]
        class Substitute
          attr_reader :seen, :stored

          def initialize
            @decisions = []
            @store_answer = :stored
            @seen = []
            @stored = []
          end

          def decide(*decisions)
            raise ArgumentError, "decide takes Decisions" unless decisions.all?(Decision)

            @decisions.concat(decisions)
          end

          def store_answer(answer)
            raise ArgumentError, "store answers :stored or a reason Symbol" unless answer.is_a?(Symbol)

            @store_answer = answer
          end

          def call(queries, engine:)
            @seen << [queries, engine]
            queries.map do |query|
              decision = @decisions.shift || Decision.pass(:unconfigured)
              # Like the real gate: every hit's Result is set, so `query.result` answers it without running.
              if decision.hit?
                RecordKeys.hit_result!(query.context, GraphQL::Query::Result.new(query: query, values: { "data" => decision.entry.data }))
              end
              decision
            end
          end

          def store(query, decision, result)
            @stored << [query, decision, result]
            @store_answer
          end
        end
      end
    end
  end
end
