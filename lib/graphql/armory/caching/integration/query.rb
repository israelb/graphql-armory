# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      module Integration
        # Included in the schema's query class (`Guard#query_class`).
        #
        # - `current_trace`: the guard builds queries before the multiplex exists, and graphql-ruby memoizes a standalone
        #   trace for a query traced then (`query.rb` `current_trace`). Before the multiplex is bound this answers the
        #   context's `:trace` or a throwaway trace, unmemoized, so the run traces with the multiplex.
        # - `result`: a hit's query never ran; `query.result` answers the hit's Result instead of running it.
        module Query
          WRAPPERS = {}.compare_by_identity
          LOCK = Mutex.new

          # A subclass of `klass` that includes this module, the same one for the same `klass` every time, and `klass`
          # itself when it already includes it.
          def self.wrap(klass)
            return klass if klass.include?(self)

            hooks = self
            LOCK.synchronize do
              WRAPPERS[klass] ||= Class.new(klass) { include hooks }
            end
          end

          def current_trace
            return super if multiplex

            context[:trace] || schema.new_trace(multiplex: nil, query: self)
          end

          def result
            hit = executed? ? nil : Integration.hit_result(self)
            hit || super
          end
        end
      end
    end
  end
end
