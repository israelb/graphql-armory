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
              report(findings, type.graphql_name, rule.observe, unobservable(type)) if rule&.observed?
              next unless type.respond_to?(:fields)

              Definitions.fields_at_every_level(type).each do |field|
                reason = observed_reason(field)
                report(findings, "#{type.graphql_name}.#{field.graphql_name}", reason, field.resolver ? field : nil) if reason
              end
            end
            custom_introspection(schema).each { |field| report(findings, "#{field.owner.graphql_name}.#{field.graphql_name}", field.armory_observe) }
          end

          def self.report(findings, path, reason, resolver_field = nil)
            effect = if resolver_field
                       "raises on every query, because #{resolver_field.graphql_name} has a resolver or a mutation, which can write (#{reason}): remove observe:"
                     else
                       "serves what this rule would refuse (#{reason}): remove it to enforce the rule"
                     end
            findings.problem(:observed, path, "observe: #{effect}")
          end

          # Its own observe:, or `authorize: true` on an owner whose rule is observed: if that owner is only a parent, no
          # type reports its rule.
          def self.observed_reason(field)
            return field.armory_observe if field.respond_to?(:armory_observe) && field.armory_observe
            return unless field.respond_to?(:armory_declared) && field.armory_declared == true

            rule = field.owner.armory_rule if field.owner.respond_to?(:armory_rule)
            rule.observe if rule&.observed?
          end

          def self.unobservable(type)
            Definitions.fields_at_every_level(type).find(&:resolver)
          end
          private_class_method :observed_reason, :unobservable

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
