# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # What a schema author declared about caching a field or a type's fields: for how long (`ttl`, seconds), for
      # whom (`scope`, `:viewer` or `:public`), what to purge it by (`tags`) and why (`reason`, required by `:public`).
      # `FORBIDDEN` is `cache: false`.
      #
      # A field's own declaration may leave out `ttl` or `scope` (`cache: { ttl: 60 }`): it is partial, and `narrow`
      # completes it from its declaring owner's `cache_fields`. A declaration may only narrow its owner's default.
      class Declaration
        SCOPES = %i[viewer public].freeze
        OPTIONS = %i[ttl scope tags reason].freeze

        attr_reader :ttl, :scope, :tags, :reason

        # A complete declaration: `cache_fields ttl:, scope: :viewer, tags: [], reason: nil`.
        def self.build(ttl:, scope: :viewer, tags: [], reason: nil)
          new(ttl: ttl, scope: scope, tags: tags, reason: reason).completed
        end

        # A field's own declaration from its `cache:` value: nil (none), false (forbidden) or a Hash of OPTIONS.
        def self.from_option(value)
          case value
          when nil then nil
          when false then FORBIDDEN
          when Hash
            unknown = value.keys - OPTIONS
            raise ConfigurationError, "cache: takes #{OPTIONS.join(', ')}; unknown: #{unknown.join(', ')}" unless unknown.empty?

            new(**value)
          else
            raise ConfigurationError, "cache: must be false or a Hash of #{OPTIONS.join(', ')}, got #{value.class}"
          end
        end

        # The declaration that applies to a field: its own, completed from `owner_default` (the declaring owner's
        # `cache_fields`, or nil). Raises when `own` would widen the default: a longer TTL or `:public` over `:viewer`.
        # Answers nil when neither declares anything.
        def self.narrow(owner_default, own)
          return own if own&.forbidden?
          return owner_default if own.nil?

          return own.completed if owner_default.nil?

          if own.ttl && own.ttl > owner_default.ttl
            raise ConfigurationError, "cache: ttl: #{own.ttl} is longer than its type's cache_fields ttl: #{owner_default.ttl}: a field may only narrow it"
          end
          if own.scope == :public && owner_default.scope == :viewer
            raise ConfigurationError, "cache: scope: :public is wider than its type's cache_fields scope: :viewer: a field may only narrow it"
          end

          build(ttl: own.ttl || owner_default.ttl, scope: own.scope || owner_default.scope,
                tags: (owner_default.tags + own.tags).uniq, reason: own.reason || owner_default.reason)
        end

        def initialize(ttl: nil, scope: nil, tags: [], reason: nil, forbidden: false)
          @forbidden = forbidden == true
          unless @forbidden
            raise ConfigurationError, "cache ttl: must be a positive Integer of seconds, got #{ttl.inspect}" unless ttl.nil? || (ttl.is_a?(Integer) && ttl.positive?)
            raise ConfigurationError, "cache scope: must be #{SCOPES.map(&:inspect).join(' or ')}, got #{scope.inspect}" unless scope.nil? || SCOPES.include?(scope)
            unless tags.is_a?(Array) && tags.all? { |tag| tag.is_a?(String) && !tag.strip.empty? }
              raise ConfigurationError, "cache tags: must be an Array of non-empty Strings"
            end
            raise ConfigurationError, "cache reason: must be a non-empty String" unless reason.nil? || (reason.is_a?(String) && !reason.strip.empty?)
          end

          @ttl = ttl
          @scope = scope
          @tags = tags.map { |tag| tag.dup.freeze }.freeze
          @reason = reason&.dup&.freeze
          freeze
        end

        def forbidden?
          @forbidden
        end

        def public?
          @scope == :public
        end

        def complete?
          forbidden? || !(@ttl.nil? || @scope.nil?)
        end

        # This declaration standing alone: a scope left out is `:viewer`. Raises without a TTL, or for `:public`
        # without a reason.
        def completed
          return self if forbidden?

          raise ConfigurationError, "cache needs ttl: (a field declares it, or its type's cache_fields does)" if @ttl.nil?

          declaration = @scope.nil? ? Declaration.new(ttl: @ttl, scope: :viewer, tags: @tags, reason: @reason) : self
          if declaration.public? && declaration.reason.nil?
            raise ConfigurationError, "cache scope: :public needs reason: (why the answer is the same for every viewer and tenant)"
          end

          declaration
        end

        def ==(other)
          other.is_a?(Declaration) && other.forbidden? == forbidden? && other.ttl == ttl && other.scope == scope && other.tags == tags && other.reason == reason
        end
        alias eql? ==

        def hash = [self.class, forbidden?, ttl, scope, tags, reason].hash

        FORBIDDEN = new(forbidden: true)
      end
    end
  end
end
