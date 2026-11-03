# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      module Integration
        # Refuses an operation whose root type cannot be observed before anything runs. Inside the root type's own check,
        # graphql-ruby hands the error to the app's `rescue_from`, which can turn it into an empty answer, and on the
        # interpreter of graphql 2.6 its handling fails with a NoMethodError first. Raised here, it is the same
        # ConfigurationError on every engine. The check in `Object#authorized?` stays for a query that runs with its own
        # trace (`context[:trace]`).
        module RootCheck
          def execute_multiplex(multiplex:)
            multiplex.queries.each { |query| RootCheck.(query) }
            super
          end

          # A partial runs on its own type, not the operation's root, and is left to that type's check. An invalid query
          # keeps its validation errors (and what a rate limiter charges for them).
          def self.call(query)
            return if defined?(GraphQL::Query::Partial) && query.is_a?(GraphQL::Query::Partial)

            operation = query.selected_operation
            return unless operation && query.valid?

            # Query#root_type is graphql 2.5+; the schema answers the same on 2.4.
            type = query.schema.root_type_for_operation(operation.operation_type || "query")
            rule = type.armory_rule if type.respond_to?(:armory_rule)
            Integration.refuse_unobservable(type, rule, query.context) if rule
          end
        end
      end
    end
  end
end
