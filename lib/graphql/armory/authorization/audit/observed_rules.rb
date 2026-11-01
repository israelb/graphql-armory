# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # A rule under `observe:` serves what it would refuse, so it is a problem until someone enforces it.
        class ObservedRules
          def self.call(definitions, findings)
            definitions.each do |type|
              rule = type.armory_rule if type.respond_to?(:armory_rule)
              report(findings, type.graphql_name, rule.observe) if rule&.observed?
              next unless type.respond_to?(:fields)

              Definitions.fields_at_every_level(type).each do |field|
                next unless field.respond_to?(:armory_observe) && field.armory_observe

                report(findings, "#{type.graphql_name}.#{field.graphql_name}", field.armory_observe)
              end
            end
          end

          def self.report(findings, path, reason)
            findings.problem(:observed, path, "observe: serves what this rule would refuse (#{reason}): remove it to enforce the rule")
          end
          private_class_method :report
        end
      end
    end
  end
end
