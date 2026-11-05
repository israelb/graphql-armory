# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      class Gate
        # What a miss's run must show before its answer is stored (docs/response-caching.md "What is cached and when"). Each check
        # answers nil (it holds) or a reason; the gate stores only when every one holds.
        module StoreCheck
          # The only response extension a stored run may carry: the limiters' own, which is never stored.
          EXTENSIONS = %w[rateLimit].freeze

          module_function

          # The response itself: no errors, a Hash of data, nothing but JSON-native values in it (a hit must equal the
          # miss: a Symbol or a Time would come back as text), and no extension but the limiters'.
          def response(values)
            return :errors if values.key?("errors")

            data = values["data"]
            return :no_data unless data.is_a?(Hash)
            return :non_json_data unless json_native?(data)

            extensions = values["extensions"]
            return :extensions unless extensions.nil? || (extensions.is_a?(Hash) && (extensions.keys - EXTENSIONS).empty?)

            nil
          end

          def json_native?(value)
            case value
            when String, Integer, true, false, nil then true
            when Float then value.finite?
            when Array then value.all? { |inner| json_native?(inner) }
            when Hash then value.all? { |key, inner| key.is_a?(String) && json_native?(inner) }
            else false
            end
          end

          # The context reads and writes the recorder saw, against the keys the cache key covers. Answers
          # `[reason, key name]`, or nil. Only a Symbol key is named: the app's own key, never one a client chose.
          # `write_guarded` is the covered set a write must not touch (graphql-ruby's own writes left out).
          def recorder(recorder, covered, write_guarded: covered)
            uncovered = recorder.uncovered(covered)
            return [:context_read, nameable(uncovered.first)] unless uncovered.empty?

            written = recorder.forbidden_writes(write_guarded)
            return [:context_written, nameable(written.first)] unless written.empty?

            nil
          end

          def nameable(key)
            key.is_a?(Symbol) && key != Recorder::ALL ? key : nil
          end
        end
      end
    end
  end
end
