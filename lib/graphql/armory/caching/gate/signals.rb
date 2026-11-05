# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      class Gate
        # What the gate reports for each query: one signal through Telemetry, and the controller's record
        # `{ status:, reason:, scope:, ttl:, age: }` in `context[:response_cache]` (docs/response-caching.md "Signals").
        #
        # No signal and no record holds a key, a viewer, a variable, a document, an operation id or name, or a tag:
        # only reasons, scopes, TTLs, ages, the store operation and an error's class name.
        class Signals
          def initialize(telemetry)
            @telemetry = telemetry
          end

          def hit(query, entry, now, limited:)
            @telemetry.record(:cache_hit, context: query.context, scope: entry.scope)
            write(query, status: :hit, reason: limited ? :rate_limited : nil, scope: entry.scope, ttl: entry.ttl, age: entry.age(now))
          end

          def stored(query, scope, ttl)
            @telemetry.record(:cache_stored, context: query.context, scope: scope, ttl: ttl)
            write(query, status: :stored, scope: scope, ttl: ttl)
          end

          # `key` only for `:context_read` and `:context_written`, and only when it has a name.
          def skipped(query, reason, scope: nil, key: nil)
            data = key.nil? ? { reason: reason } : { reason: reason, key: key }
            @telemetry.record(:cache_skipped, context: context_of(query), **data)
            write(query, status: :skipped, reason: reason, scope: scope)
          end

          def rejected(query, reason)
            @telemetry.record(:cache_entry_rejected, context: query.context, reason: reason)
          end

          # The error's class only: its message may quote the store's URL and credentials.
          def store_failed(query, operation, error, scope: nil)
            @telemetry.record(:cache_store_failed, context: query.context, operation: operation, error: error.class.name.to_s)
            write(query, status: :skipped, reason: :store_failed, scope: scope)
          end

          private

          def context_of(query)
            query.respond_to?(:context) ? query.context : nil
          end

          # Written without recording it: the record is the gate's, not a value the run's answer depends on. A query
          # the app built itself is passed through untouched: no record goes into its context.
          def write(query, status:, reason: nil, scope: nil, ttl: nil, age: nil)
            return unless Admission.guard_built?(query)

            context = query.context

            Caching.neutral(context) do
              RecordKeys.record!(context, { status: status, reason: reason, scope: scope, ttl: ttl, age: age })
            end
          end
        end
      end
    end
  end
end
