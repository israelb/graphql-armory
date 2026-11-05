# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # Goes in your base classes: fields, objects, interfaces (after `include GraphQL::Schema::Interface`) and
      # directives.
      #
      #   class Types::BaseField < GraphQL::Schema::Field
      #     include GraphQL::Armory::Caching::Base
      #   end
      #   class Types::BaseObject < GraphQL::Schema::Object
      #     include GraphQL::Armory::Caching::Base
      #     field_class Types::BaseField
      #   end
      #
      #   class Types::Product < Types::BaseObject
      #     cache_fields ttl: 300, scope: :public, tags: ["catalog"], reason: "the same for every viewer and tenant"
      #     field :price, Money, null: false, cache: { ttl: 60, tags: ["pricing"] }   # narrower
      #     field :stock_level, Integer, null: false, cache: false                    # never cached
      #   end
      #
      # `cache_fields` is the default for the fields the type declares itself, never for fields it inherits: a field
      # keeps the declaration of the class or interface that declared it. A field may only narrow that default.
      module Base
        def self.included(base)
          if !base.is_a?(Class) && base.include?(GraphQL::Schema::Interface)
            base.definition_methods { include Base::Type }
          elsif base.is_a?(Class) && base <= GraphQL::Schema::Field
            base.include(Base::Field)
          elsif base.is_a?(Class) && base <= GraphQL::Schema::Object
            base.extend(Base::Type)
          elsif base.is_a?(Class) && base <= GraphQL::Schema::Directive
            base.extend(Base::Directive)
          else
            raise ArgumentError, "GraphQL::Armory::Caching::Base goes in a field, object, interface or directive class, not #{base}. " \
                                 "In an interface, include GraphQL::Schema::Interface first"
          end
        end

        # Included in field classes: `cache: { ttl:, scope:, tags:, reason: }` or `cache: false`.
        module Field
          def initialize(*args, cache: nil, **kwargs, &block)
            @armory_cache_own = Declaration.from_option(cache)
            super(*args, **kwargs, &block)
            # Widening is refused at definition when the owner already declared its default; `cache_fields` declared
            # later checks the fields already defined.
            armory_cache if @armory_cache_own && (armory_owner_default || @armory_cache_own.complete?)
          rescue ConfigurationError => error
            raise error.class, "#{armory_cache_label(args, kwargs)}: #{error.message}"
          end

          # What the field itself declared (partial, `Declaration::FORBIDDEN`, or nil).
          attr_reader :armory_cache_own

          # The declaration that applies: the field's own, completed from its declaring owner's `cache_fields`.
          # nil when neither declares anything (the walk refuses the field).
          def armory_cache
            default = armory_owner_default
            memo = @armory_cache_memo
            return memo.last if memo && memo.first.equal?(default)

            declaration = Declaration.narrow(default, @armory_cache_own)
            @armory_cache_memo = [default, declaration] unless frozen?
            declaration
          end

          private

          def armory_owner_default
            owner = self.owner
            owner.respond_to?(:armory_cache_fields) ? owner.armory_cache_fields : nil
          end

          def armory_cache_label(args, kwargs)
            owner_name = kwargs[:owner].respond_to?(:graphql_name) ? kwargs[:owner].graphql_name : nil
            [owner_name, kwargs[:name] || args.first].compact.join(".")
          end
        end

        # Extended into object types and included into interfaces' definition methods.
        module Type
          def cache_fields(ttl:, scope: :viewer, tags: [], reason: nil)
            @armory_cache_fields = Declaration.build(ttl: ttl, scope: scope, tags: tags, reason: reason)
            own_fields.each_value { |defined| Array(defined).each { |field| field.armory_cache if field.respond_to?(:armory_cache) } }
            @armory_cache_fields
          rescue ConfigurationError => error
            raise error.class, "#{graphql_name}: #{error.message}"
          end

          # This type's own default, never a superclass's: fields keep their declaring owner's default.
          def armory_cache_fields
            instance_variable_defined?(:@armory_cache_fields) ? @armory_cache_fields : nil
          end
        end

        # Extended into directive classes. A directive that does not change the data (a client hint, a trace label)
        # declares `cache_safe`; any other directive anywhere in an operation makes it uncacheable.
        module Directive
          def cache_safe(reason:)
            raise ConfigurationError, "#{graphql_name}: cache_safe reason: must be a non-empty String" unless reason.is_a?(String) && !reason.strip.empty?

            @armory_cache_safe = reason.dup.freeze
          end

          # Own only: a subclass declares it again.
          def armory_cache_safe?
            instance_variable_defined?(:@armory_cache_safe)
          end

          def armory_cache_safe_reason
            instance_variable_defined?(:@armory_cache_safe) ? @armory_cache_safe : nil
          end
        end
      end
    end
  end
end
