# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # The context and namespace keys the modules share. Every unit reads and writes them through here, never by
      # spelling the key itself.
      #
      # - `namespace(:armory)[:persisted]`: set by PersistedQueries on the persisted branch only.
      # - `namespace(:armory)[:viewer_dependent]`: set by Authorization where a policy or ability is consulted.
      # - `namespace(:armory_cache)`: the query's recorder, the hit's Result and the rescued flag.
      # - `namespace(:graphql_armory)[:response_cache]` and `context[:response_cache]`: the record for the controller.
      #
      # Namespaces other than nil are read without being recorded: they are the gem's own state, not request input.
      module RecordKeys
        ARMORY = :armory
        PERSISTED = :persisted
        VIEWER_DEPENDENT = :viewer_dependent

        CACHE = :armory_cache
        RECORDER = :recorder
        RESULT = :result
        RESCUED = :rescued
        GUARD_BUILT = :guard_built

        RECORD_NAMESPACE = :graphql_armory
        RECORD = :response_cache
        CONTEXT_RECORD = :response_cache

        module_function

        def persisted!(context)
          context.namespace(ARMORY)[PERSISTED] = true
        end

        def persisted?(context)
          namespaced?(context) && context.namespace(ARMORY)[PERSISTED] == true
        end

        def viewer_dependent!(context)
          context.namespace(ARMORY)[VIEWER_DEPENDENT] = true if namespaced?(context)
        end

        def viewer_dependent?(context)
          namespaced?(context) && context.namespace(ARMORY)[VIEWER_DEPENDENT] == true
        end

        # The query's recorder, or nil when the context has none (caching not installed, a plain Hash, nil).
        def recorder(context)
          namespaced?(context) ? context.namespace(CACHE)[RECORDER] : nil
        end

        def recorder!(context, recorder)
          context.namespace(CACHE)[RECORDER] = recorder
        end

        # The guard built this query from the request's options (through `query_class`). The gate refuses any query
        # without the mark as `:built_query`: one the app built itself, or a `Query::Partial`.
        def guard_built!(context)
          context.namespace(CACHE)[GUARD_BUILT] = true
        end

        def guard_built?(context)
          namespaced?(context) && context.namespace(CACHE)[GUARD_BUILT] == true
        end

        def rescued!(context)
          context.namespace(CACHE)[RESCUED] = true
        end

        def rescued?(context)
          namespaced?(context) && context.namespace(CACHE)[RESCUED] == true
        end

        # The Result the gate answered a hit with, so `query.result` answers it instead of running. The gate sets it for
        # every `Decision.hit`: the cached answer, or the Points limiter's refusal when the client is over budget.
        def hit_result!(context, result)
          context.namespace(CACHE)[RESULT] = result
        end

        def hit_result(context)
          namespaced?(context) ? context.namespace(CACHE)[RESULT] : nil
        end

        # Writes the controller's record to the query's own namespace and copies it to the context, like Points.
        def record!(context, record)
          record = record.dup.freeze
          context.namespace(RECORD_NAMESPACE)[RECORD] = record
          context[CONTEXT_RECORD] = record
        end

        def record(context)
          namespaced?(context) ? context.namespace(RECORD_NAMESPACE)[RECORD] : nil
        end

        def namespaced?(context)
          context.is_a?(GraphQL::Query::Context)
        end
      end
    end
  end
end
