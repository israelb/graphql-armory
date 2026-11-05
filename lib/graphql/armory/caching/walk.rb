# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # The operation's policy from its declarations: `walk.(query) -> Policy`.
      #
      #   policy = Walk.(query)
      #   policy.cacheable?   # every selected field is declared, and nothing refuses the operation
      #   policy.ttl          # the smallest TTL over every selected field
      #   policy.scope        # :public only if every selected field is :public
      #   policy.tags         # each declared tag ("tag:catalog") and each type the selection can return ("type:Product")
      #   policy.reason       # when refused: :undeclared_field, :forbidden_field, :directive, :introspection, ...
      #
      # The walk reads the selected operation's AST and `query.types` (the version- and visibility-aware view, on
      # both engines). It needs no validation and no variables, and every rule fails closed: an invalid document is
      # refused, and graphql-ruby answers its error when it runs. `new` needs nothing: the walk has no dependencies.
      #
      # The policy is memoized per query object only. Visibility is per viewer, so a memo across requests (by
      # document) could judge one viewer's query with another's schema.
      class Walk
        def self.build = new

        def self.call(query) = new.(query)

        def initialize
          @memo = ObjectSpace::WeakMap.new
        end

        def call(query)
          policy = @memo[query]
          return policy if policy

          policy = Run.new(query).policy
          @memo[query] = policy
          policy
        end
      end
    end
  end
end

require "graphql/armory/caching/walk/tally"
require "graphql/armory/caching/walk/relay"
require "graphql/armory/caching/walk/directives"
require "graphql/armory/caching/walk/run"
