# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      module Integration
        # Extended onto a schema class by `use GraphQL::Armory::Authorization`.
        # Both engines route every denial through these hooks, so the client sees the same thing in each.
        module Schema
          def armory_configuration=(configuration)
            @armory_configuration = configuration
          end

          def armory_configuration
            @armory_configuration ||
              (superclass.armory_configuration if superclass.respond_to?(:armory_configuration))
          end

          # `loads:` asks the schema which type an object is. For an object type the answer is known:
          # the lookup went through that type's model. Abstract types and foreign objects are the app's call.
          def resolve_type(type, object, context)
            if !type.kind.abstract? && type.respond_to?(:armory_model) && object.is_a?(type.armory_model)
              type
            else
              super
            end
          end

          def unauthorized_object(error)
            raise_denial(error)
            nil
          end

          # A denied field that cannot be null must still fail: Execution::Next would otherwise leave
          # a null in a non-null position without an error or a null propagation.
          def unauthorized_field(error)
            raise_denial(error)
            raise_not_found if error.field&.type&.non_null?

            nil
          end

          private

          def raise_denial(error)
            case armory_configuration.on_unauthorized
            when :error then raise_not_found
            when :raise then raise NotAuthorizedError, error.type&.graphql_name
            end
          end

          # The same answer a missing object gets, so a denial does not reveal that it exists.
          def raise_not_found
            raise GraphQL::ExecutionError.new("Not found", extensions: { "code" => "NOT_FOUND" })
          end
        end
      end
    end
  end
end
