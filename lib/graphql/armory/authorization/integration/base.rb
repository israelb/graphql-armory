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
          elsif base <= GraphQL::Schema::Resolver
            base.extend(Integration::ResolverClass)
            base.include(Integration::Resolver)
          elsif base <= GraphQL::Schema::Argument
            base.include(Integration::Argument)
          else
            raise ArgumentError,
                  "GraphQL::Armory::Authorization::Base can only be included in a GraphQL object, field, argument, resolver or mutation class, not #{base}. Interfaces and unions are not authorized themselves: declare the rule on their possible types"
          end
        end
      end
    end
  end
end
