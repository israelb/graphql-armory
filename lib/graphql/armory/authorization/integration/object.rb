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

          # The model the type wraps: `authorize :read, model: Invoice`, else the constant named like the type.
          def armory_model
            declared = armory_rule&.model
            return declared if declared.is_a?(Class)

            Object.const_get(declared || name&.split("::")&.last || graphql_name)
          rescue NameError
            raise ConfigurationError,
                  "cannot tell which model #{graphql_name} wraps: declare it with `authorize :read, model: YourModel`"
          end

          # Runs before pagination, so connections page and count the scoped list.
          def scope_items(items, context)
            super(Integration.scoped(items, armory_rule, context), context)
          end


          # `authorize :read, visible_when: :export` hides the type from users the policy answers `false`
          # for, in introspection and in error suggestions. Asked of the model's class, with no record.
          def visible?(context)
            rule = armory_rule
            return super unless rule&.visible_when

            super && Integration.visible?(armory_model, Rule.new(rule.visible_when, policy: rule.policy), context)
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
