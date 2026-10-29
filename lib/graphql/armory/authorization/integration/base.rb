# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      # One module for every base class. It detects what it was included in.
      #
      #   class Types::BaseObject < GraphQL::Schema::Object
      #     include GraphQL::Armory::Authorization::Base
      #     default_action :read
      #   end
      #   class Types::BaseField < GraphQL::Schema::Field
      #     include GraphQL::Armory::Authorization::Base
      #   end
      module Base
        def self.included(base)
          if base <= GraphQL::Schema::Object
            base.extend(Integration::Object)
          elsif base <= GraphQL::Schema::Field
            base.include(Integration::Field)
          elsif base <= GraphQL::Schema::Argument
            base.include(Integration::Argument)
          else
            raise ArgumentError,
                  "GraphQL::Armory::Authorization::Base can only be included in a GraphQL object, field or argument class, not #{base}"
          end
        end
      end
    end
  end
end
