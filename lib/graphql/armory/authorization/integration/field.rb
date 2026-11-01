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
        #   field :notes, String, authorize: :manage, visible_when: :export  # hidden from users who cannot export
        #   field :notes, String, authorize: :manage, observe: "rollout"  # served and recorded, see Authorize
        #
        # A field with no rule is covered by its type's rule, unless the type is bypassed:
        # coverage does not propagate from a bypass, so that field is denied.
        #
        # graphql-ruby hands `authorized?` the application object, not the type instance, so the type
        # whose rule applies is the one that owns the field.
        module Field
          # `find_by: :id` looks the object up inside the user's scope instead of calling the resolver.
          # `loads:` arguments also load through the scope unless `load_through_scope: false`.
          def initialize(*args, authorize: nil, reason: nil, observe: nil, find_by: nil, load_through_scope: true, visible_when: nil, override_reason: nil, **kwargs, &block)
            raise ConfigurationError, "override_reason: must say why the override is safe" if !override_reason.nil? && override_reason.to_s.strip.empty?

            if !observe.nil? && (!authorize.is_a?(Symbol) || authorize == :none)
              raise ArgumentError, "observe: needs an action of the field's own: `authorize: :manage, observe: \"...\"`"
            end
            Rule.new(authorize, observe: observe) unless observe.nil?

            @armory_observe = observe
            @armory_override_reason = override_reason
            @armory_declared = authorize
            @armory_reason = reason
            @armory_visible_when = visible_when&.to_sym
            @armory_load_through_scope = load_through_scope
            Rule.none(reason: reason) if authorize == :none
            super(*args, **kwargs, &block)
            extension(Integration::FindBy, key: find_by) if find_by
          end

          attr_reader :armory_declared, :armory_reason, :armory_observe, :armory_visible_when, :armory_override_reason

          def armory_load_through_scope?
            @armory_load_through_scope
          end

          def object_from_id(type, id, context)
            return super unless @armory_load_through_scope

            Integration.load(type, id, context)
          end

          # A `loads:` id that is not found is answered like a denial, so the client cannot tell the two apart.
          def load_application_object_failed(error)
            return super unless @armory_load_through_scope

            raise GraphQL::UnauthorizedError.new(object: nil, type: error.argument.loads, context: error.context)
          end


          # `visible_when: :export` hides the field from users the owner's policy answers `false` for.
          def visible?(context)
            return super unless @armory_visible_when

            unless owner.respond_to?(:armory_model)
              raise ConfigurationError, "#{owner.graphql_name}.#{original_name} uses visible_when:, so its type must include Base"
            end

            rule = Rule.new(@armory_visible_when, policy: armory_policy, attribute: original_name)
            super && Integration.visible?(owner.armory_model, rule, context)
          end

          # The `policy:` of the type that defines the field: a rule on the field asks it another question.
          def armory_policy
            owner.armory_rule&.policy if owner.respond_to?(:armory_rule)
          end

          def authorized?(object, args, context)
            rule = armory_rule_for(owner, context)
            return false if rule.nil?

            (rule == :covered || Integration.allowed?(object, Integration.with_owner_model(rule, owner), context)) && super
          end

          private

          # A resolver or mutation that includes Base enforces its own rule, so the field is covered by it.
          def armory_resolver?
            resolver.respond_to?(:armory_rule)
          end

          # A Rule to check on the parent object, :covered when the type's own check already did it,
          # or nil to deny.
          def armory_rule_for(type, context)
            type_rule = type.armory_rule if type.respond_to?(:armory_rule)

            case @armory_declared
            when nil
              return :covered if armory_resolver?
              return Integration.bypassed_implementer?(type, context.schema) ? nil : :covered if type.respond_to?(:kind) && type.kind.interface?
              return :covered unless type.respond_to?(:armory_rule)

              type_rule && (!type_rule.none? || type_rule.covers_fields?) ? :covered : nil
            when true
              type_rule unless type_rule&.none?
            when :none
              Rule.none(reason: @armory_reason)
            else
              Rule.new(@armory_declared, policy: armory_policy, attribute: original_name, observe: @armory_observe)
            end
          end
        end
      end
    end
  end
end
