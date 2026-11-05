# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      class Core < GraphQL::Subscriptions
        # graphql-ruby's Event, with the core's topic digest of the triggered field, arguments and scope: the key of the
        # store's topic index.
        class Event < GraphQL::Subscriptions::Event
          attr_reader :digest

          def initialize(digest:, **options)
            super(**options)
            @digest = digest
          end
        end

        # Runs every live subscriber of `event_name` with `args` in `scope` against `object`, each as itself.
        #
        # - `context:` must be empty: a trigger never changes who a subscriber is or which version it runs (graphql-ruby
        #   merges it over each subscriber's context). It raises ArgumentError otherwise.
        # - `version:` is the API version used only to look the field and its arguments up (with Versioning's
        #   `default: :refuse`, a trigger without it finds nothing); a delivery always runs its subscriber's version.
        #
        # An unknown field or argument raises GraphQL::Subscriptions::InvalidTriggerError; a value its type cannot
        # coerce, or a scope the topic cannot hold, raises ArgumentError.
        def trigger(event_name, args, object, scope: nil, context: {}, version: nil)
          unless context.nil? || (context.respond_to?(:empty?) && context.empty?)
            raise ArgumentError, "trigger context: is refused: a delivery runs as its subscriber only (its stored context keys and reloaded viewer); " \
                                 "use version: to pick the version the field is looked up in"
          end
          raise ArgumentError, "trigger version: must be a non-empty String or nil" unless version.nil? || (version.is_a?(String) && !version.empty?)

          lookup = lookup_query(version)
          name, field = trigger_field(lookup, event_name.to_s)
          arguments = normalize_arguments(name, field, args, lookup.context)
          digest = Topic.digest(@encoder, field, arguments, scope, context: lookup.context)
          execute_all(Event.new(digest: digest, name: name, arguments: arguments, field: field, scope: scope, context: lookup.context), object)
        end

        private

        # A query built without the schema's query class, so PersistedQueries counts nothing (it is never run) and
        # Versioning decides it from `version:` alone.
        def lookup_query(version)
          GraphQL::Query.new(@schema, "{ __typename }", validate: false, context: version ? { armory_version: version } : {})
        end

        def trigger_field(lookup, name)
          root = @schema.subscription
          field = lookup.types.field(root, name)
          return [name, field] if field

          normalized = normalize_name(name)
          field = lookup.types.field(root, normalized)
          raise InvalidTriggerError, "No subscription matching trigger: #{name} (looked for #{root.graphql_name}.#{normalized})" unless field

          [normalized, field]
        end
      end
    end
  end
end
