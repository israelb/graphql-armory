# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      module Integration
        # Extended onto an object type class by `include GraphQL::Armory::Authorization::Base`.
        module Object
          # `default_action :read` makes every type below be checked with `read` unless it declares its own.
          def default_action(action = nil)
            return @armory_default_action = action if action

            @armory_default_action || (superclass.default_action if superclass.respond_to?(:default_action))
          end

          def authorize(action, reason: nil, **options)
            @armory_rule = Rule.new(action, reason: reason, **options)
          end

          # Own rule, then an inherited one, then the default action. Nil means: nothing covers this type.
          def armory_rule
            return @armory_rule if @armory_rule

            inherited = superclass.armory_rule if superclass.respond_to?(:armory_rule)
            return inherited if inherited

            action = default_action
            Rule.new(action) if action
          end

          def authorized?(object, context)
            rule = armory_rule
            return false if rule.nil?

            Integration.allowed?(object, rule, context) && super
          end
        end
      end
    end
  end
end
