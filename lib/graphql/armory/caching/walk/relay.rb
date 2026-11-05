# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      class Walk
        # The fields graphql-ruby generates on Relay connection, edge and PageInfo types. They only page through the
        # connection object the field above them returned, so they take that field's declaration and need none of
        # their own. A field only counts as generated when graphql-ruby's own code resolves it: a field the app adds
        # (`totalCount`) or resolves itself (its own `def nodes`, `resolver_method:`, `method:`, a resolver class,
        # an extension) needs a declaration like any other.
        module Relay
          GENERATED = {
            GraphQL::Types::Relay::ConnectionBehaviors => %i[edges nodes page_info],
            GraphQL::Types::Relay::EdgeBehaviors => %i[node cursor],
            GraphQL::Types::Relay::PageInfoBehaviors => %i[has_next_page has_previous_page start_cursor end_cursor]
          }.freeze

          # How graphql-ruby resolves a field with no resolver of its own: a method on the type, else the object's.
          PLAIN_MODES = %i[direct_send resolve_legacy_instance_method].freeze

          module_function

          def generated?(field)
            owner = field.owner
            return false unless owner.is_a?(Class)

            behaviors, names = GENERATED.find { |mod, _| owner < mod }
            return false unless behaviors && names.include?(field.original_name)

            plain?(field) && graphql_ruby_resolves?(field, owner)
          end

          def plain?(field)
            name = field.original_name
            return false unless field.resolver.nil? && field.method_sym == name && field.resolver_method == name
            return false if field.respond_to?(:execution_mode) && !PLAIN_MODES.include?(field.execution_mode)

            field.extensions.empty?
          end

          # The type's own method of that name, if it has one, must be graphql-ruby's (`ConnectionBehaviors#nodes`,
          # `EdgeBehaviors#node`); otherwise the field resolves on the connection or edge object graphql-ruby built.
          def graphql_ruby_resolves?(field, owner)
            name = field.original_name
            return true unless owner.method_defined?(name) || owner.private_method_defined?(name)

            GENERATED.key?(owner.instance_method(name).owner)
          end
        end
      end
    end
  end
end
