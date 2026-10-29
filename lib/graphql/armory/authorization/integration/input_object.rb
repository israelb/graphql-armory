# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      module Integration
        # Extended into an input object class by `include GraphQL::Armory::Authorization::Base`.
        # graphql-ruby loads an input object's `loads:` arguments with the class's own loader, not the
        # field's, so the scoped lookup has to live here too.
        #
        #   class Types::BaseInputObject < GraphQL::Schema::InputObject
        #     include GraphQL::Armory::Authorization::Base
        #   end
        module InputObject
          def armory_scoped_loads?
            true
          end

          def object_from_id(type, id, context)
            Integration.load(type, id, context)
          end

          # A `loads:` id that is not found is answered like a denial, so the client cannot tell the two apart.
          def load_application_object_failed(error)
            raise GraphQL::UnauthorizedError.new(object: nil, type: error.argument.loads, context: error.context)
          end
        end
      end
    end
  end
end
