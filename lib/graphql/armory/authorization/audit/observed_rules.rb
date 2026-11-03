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
              report(findings, type.graphql_name, rule.observe, unobservable(type), at: type) if rule&.observed?
              next unless type.respond_to?(:fields)

              Definitions.fields_at_every_level(type).each do |field|
                reason = Integration.observed_reason(field)
                report(findings, "#{type.graphql_name}.#{field.graphql_name}", reason, field.resolver ? field : nil, at: field) if reason
              end
            end
            custom_introspection(schema).each { |field| report(findings, "#{field.owner.graphql_name}.#{field.graphql_name}", field.armory_observe, at: field) }
          end

          def self.report(findings, path, reason, resolver_field = nil, at: nil)
            effect = if resolver_field
                       "raises on every query, because #{resolver_field.graphql_name} has a resolver or a mutation, which can write (#{reason}): remove observe:"
                     else
                       "serves what this rule would refuse (#{reason}): remove it to enforce the rule"
                     end
            findings.problem(:observed, path, "observe: #{effect}", at: at)
          end

          def self.unobservable(type)
            type.all_field_definitions.find(&:resolver)
          end
          private_class_method :unobservable

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
