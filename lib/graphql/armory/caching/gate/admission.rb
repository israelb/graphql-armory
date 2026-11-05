# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      class Gate
        # The rows of "Never cached" that are known before a query runs (docs/response-caching.md "What is cached and when"). A query that
        # matches one is never looked up: it runs uncached, with the row's reason.
        module Admission
          # Per-request options that make a query uncacheable. `max_depth:` and `max_complexity:` are key components.
          REQUEST_OPTIONS = %i[static_validator validate warden use_visibility_profile root_value].freeze

          # Context keys whose presence alone makes a request uncacheable: a full-schema request sees members hidden
          # from everyone else, and an ability object is something the key cannot identify. Their absence is checked
          # here, so a later read of either is covered.
          ABSENT_KEYS = { armory_full_schema: :full_schema, current_ability: :current_ability }.freeze

          module_function

          def mutation?(query)
            query.respond_to?(:mutation?) && query.mutation? == true
          end

          # The reason `query` must run uncached, or nil when it may be looked up. `mutation_in_call` is whether any
          # query of the same call is a mutation: its writes may be meant for the others.
          def refusal(query, mutation_in_call:)
            return :built_query unless guard_built?(query)
            return :mutation if mutation?(query)
            return :multiplex_mutation if mutation_in_call
            return :subscription if query.subscription?
            # PersistedQueries and Versioning refuse through static_validator; an app-supplied one is refused too.
            return :refused if query.static_validator
            return :options if options?(query)
            return :not_persisted unless RecordKeys.persisted?(query.context)

            present_key(query.context)
          end

          # Only queries the guard built from the request's options are cached: never one the app built itself, nor a
          # `Query::Partial`, whose context the guard did not wrap.
          def guard_built?(query)
            query.is_a?(GraphQL::Query) && RecordKeys.guard_built?(query.context)
          end

          # What graphql-ruby keeps of the per-request options, read through its public readers.
          def options?(query)
            return true unless query.root_value.nil?
            return true if query.validate == false

            profiles = query.schema.respond_to?(:use_visibility_profile?) && query.schema.use_visibility_profile?
            profiled = query.respond_to?(:visibility_profile) && !query.visibility_profile.nil?
            # `warden:` or `use_visibility_profile:` changed how this query sees the schema.
            profiles != profiled
          end

          # Checked inside `Caching.neutral`: the check itself is not one of the run's reads.
          def present_key(context)
            Caching.neutral(context) do
              ABSENT_KEYS.each { |key, reason| return reason if context.key?(key) }
              nil
            end
          end
        end
      end
    end
  end
end
