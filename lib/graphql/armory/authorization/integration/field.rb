# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      module Integration
        # Included in a field class by `include GraphQL::Armory::Authorization::Base`.
        #
        #   field :notes, String, authorize: :manage                      # another action on the parent
        #   field :id, ID, authorize: :none, reason: "ids are public"     # declared bypass
        #   field :owner_id, ID, authorize: true                          # the parent type's own action
        #
        # A field with no rule is covered by its type's rule, unless the type is bypassed:
        # coverage does not propagate from a bypass, so that field is denied.
        #
        # graphql-ruby hands `authorized?` the application object, not the type instance, so the type
        # whose rule applies is the one that owns the field.
        module Field
          def initialize(*args, authorize: nil, reason: nil, **kwargs, &block)
            @armory_declared = authorize
            @armory_reason = reason
            Rule.none(reason: reason) if authorize == :none
            super(*args, **kwargs, &block)
          end

          def authorized?(object, args, context)
            rule = armory_rule_for(owner)
            return false if rule.nil?

            (rule == :covered || Integration.allowed?(object, rule, context)) && super
          end

          private

          # A Rule to check on the parent object, :covered when the type's own check already did it,
          # or nil to deny.
          def armory_rule_for(type)
            type_rule = type.armory_rule if type.respond_to?(:armory_rule)

            case @armory_declared
            when nil
              return :covered if !type.respond_to?(:armory_rule)

              type_rule && !type_rule.none? ? :covered : nil
            when true
              type_rule unless type_rule&.none?
            when :none
              Rule.none(reason: @armory_reason)
            else
              Rule.new(@armory_declared, attribute: original_name)
            end
          end
        end
      end
    end
  end
end
