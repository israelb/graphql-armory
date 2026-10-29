# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      module Integration
        # Class-level DSL of a resolver or mutation that includes `GraphQL::Armory::Authorization::Base`.
        #
        #   class ApproveInvoice < BaseMutation
        #     authorize :approve, model: Invoice                  # InvoicePolicy#approve? on the loaded record
        #     authorize :approve, model: Invoice, on_denied: :errors
        #     authorize :none, reason: "anyone may call it"
        #   end
        #
        # A mutation is an action, not a read: `default_action` does not apply, and one with no rule is denied.
        module ResolverClass
          ON_DENIED = %i[default errors].freeze

          # `on_denied: :default` follows the schema's `on_unauthorized` mode, like a field. `:errors` answers
          # `{ errors: [{ message: "Not allowed", code: "FORBIDDEN" }] }` as data: the payload needs an `errors` field.
          def authorize(action, reason: nil, on_denied: :default, **options)
            raise ArgumentError, "on_denied must be one of #{ON_DENIED.inspect}, got #{on_denied.inspect}" unless ON_DENIED.include?(on_denied)

            @armory_on_denied = on_denied
            @armory_rule = Rule.new(action, reason: reason, **options)
          end

          def armory_rule
            @armory_rule || (superclass.armory_rule if superclass.respond_to?(:armory_rule))
          end

          def armory_on_denied
            @armory_on_denied || (superclass.armory_on_denied if superclass.respond_to?(:armory_on_denied)) || :default
          end

          # The model the rule is asked about, which a mutation cannot be named after.
          def armory_model
            model = armory_rule&.model
            return model if model.is_a?(Class)

            raise ConfigurationError, "#{graphql_name}: declare the model with `authorize :action, model: YourModel`"
          end
        end

        # Instance side: runs after the `loads:` arguments are loaded, so the policy sees the loaded record.
        module Resolver
          # Every loaded record of the model is asked about; with none loaded, the model's class is.
          def authorized?(**inputs)
            rule = self.class.armory_rule
            return armory_denied if rule.nil?

            allowed = armory_subjects(rule, inputs).all? { |subject| Integration.allowed?(subject, rule, context) }
            allowed ? super : armory_denied
          end

          # `loads:` arguments are looked up inside the user's scope, so a foreign id answers like a missing one.
          def object_from_id(type, id, context)
            Integration.load(type, id, context)
          end

          def load_application_object_failed(error)
            raise GraphQL::UnauthorizedError.new(object: nil, type: error.argument.loads, context: error.context)
          end

          private

          def armory_subjects(rule, inputs)
            return [nil] if rule.none?

            model = self.class.armory_model
            loaded = inputs.values.flatten.select { |value| value.is_a?(model) }
            loaded.empty? ? [model] : loaded
          end

          def armory_denied
            return false unless self.class.armory_on_denied == :errors

            [false, { errors: [{ message: "Not allowed", code: "FORBIDDEN" }] }]
          end
        end
      end
    end
  end
end
