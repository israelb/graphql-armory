# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # A rule under `observe:` serves what it would refuse, so it is a problem until someone enforces it.
        class ObservedRules
          def self.call(schema, definitions, findings)
            definitions.each do |type|
              rule = type.armory_rule if type.respond_to?(:armory_rule)
              report(findings, type.graphql_name, rule.observe) if rule&.observed?
              next unless type.respond_to?(:fields)

              Definitions.fields_at_every_level(type).each do |field|
                next unless field.respond_to?(:armory_observe) && field.armory_observe

                report(findings, "#{type.graphql_name}.#{field.graphql_name}", field.armory_observe)
              end
            end
            custom_introspection(schema).each { |field| report(findings, "#{field.owner.graphql_name}.#{field.graphql_name}", field.armory_observe) }
          end

          def self.report(findings, path, reason)
            findings.problem(:observed, path, "observe: serves what this rule would refuse (#{reason}): remove it to enforce the rule")
          end
          # Definitions holds what these fields return, not the classes that own them.
          def self.custom_introspection(schema)
            system = schema.introspection_system
            (system.entry_points + system.dynamic_fields).select { |field| field.respond_to?(:armory_observe) && field.armory_observe }
          end
          private_class_method :custom_introspection
          private_class_method :report
        end
      end
    end
  end
end
