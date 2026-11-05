# frozen_string_literal: true

require "set"

module GraphQL
  module Armory
    module Caching
      class Walk
        # Folds the declarations of every selected field into one Policy: the smallest TTL, `:public` only while
        # every declaration is, and the union of their tags plus the type tags of what the selection returns.
        class Tally
          def initialize
            @ttl = nil
            @public = true
            @tags = Set.new
          end

          def declare(declaration)
            @ttl = @ttl.nil? ? declaration.ttl : [@ttl, declaration.ttl].min
            @public &&= declaration.public?
            declaration.tags.each { |tag| @tags << Tags.custom(tag) }
          end

          def type(graphql_name)
            @tags << Tags.type(graphql_name)
          end

          # Nothing declared a TTL (only `__typename` was selected): there is nothing to cache for.
          def policy
            return Policy.refused(:undeclared_field) if @ttl.nil?

            Policy.cacheable(ttl: @ttl, scope: @public ? :public : :viewer, tags: @tags.to_a)
          end
        end
      end
    end
  end
end
