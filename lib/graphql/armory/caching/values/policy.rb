# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # What the walk concluded about an operation: cacheable for `ttl` seconds under `scope`, purgeable by `tags`
      # (custom tags and `type:<Name>` tags, in clear: they are digested before they reach a store), or refused with
      # a `reason` Symbol (`:undeclared_field`, `:directive`, ...).
      Policy = Data.define(:cacheable, :ttl, :scope, :tags, :reason) do
        def self.cacheable(ttl:, scope:, tags: [])
          new(cacheable: true, ttl: ttl, scope: scope, tags: tags, reason: nil)
        end

        def self.refused(reason)
          new(cacheable: false, ttl: nil, scope: nil, tags: [], reason: reason)
        end

        def initialize(cacheable:, ttl:, scope:, tags:, reason:)
          if cacheable == true
            raise ArgumentError, "a cacheable Policy needs a positive Integer ttl, got #{ttl.inspect}" unless ttl.is_a?(Integer) && ttl.positive?
            raise ArgumentError, "a cacheable Policy needs scope :viewer or :public, got #{scope.inspect}" unless Declaration::SCOPES.include?(scope)
            raise ArgumentError, "a cacheable Policy has no reason" unless reason.nil?
          elsif cacheable == false
            raise ArgumentError, "a refused Policy needs a reason Symbol, got #{reason.inspect}" unless reason.is_a?(Symbol)
          else
            raise ArgumentError, "cacheable: must be true or false"
          end
          raise ArgumentError, "Policy tags: must be an Array of Strings" unless tags.is_a?(Array) && tags.all?(String)

          super(cacheable: cacheable, ttl: ttl, scope: scope, tags: tags.map { |tag| tag.dup.freeze }.uniq.sort.freeze, reason: reason)
        end

        def cacheable?
          cacheable
        end

        def public?
          scope == :public
        end
      end
    end
  end
end
