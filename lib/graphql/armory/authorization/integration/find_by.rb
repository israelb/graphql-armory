# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      module Integration
        # Field extension behind `field :invoice, Types::Invoice, find_by: :id`.
        # It never calls the field's own resolver: the object is looked up inside the user's scope,
        # so one the user may not see comes back exactly like one that does not exist.
        class FindBy < GraphQL::Schema::FieldExtension
          # The interpreter resolves one object at a time, Execution::Next a batch of them.
          def resolve(arguments:, context:, object: nil, objects: nil)
            key = options[:key]
            found = Integration.find(field.type.unwrap, key, arguments[key], context)

            objects ? Array.new(objects.size, found) : found
          end
        end
      end
    end
  end
end
