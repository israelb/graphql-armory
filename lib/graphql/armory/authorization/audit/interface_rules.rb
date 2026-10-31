# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # Interface fields are reported once, on the interface that declares them, not on every implementer.
        # Undeclared ones are denied when an implementer is a bypass; ones whose field class lacks Base are
        # never checked, so on a bypassed implementer they are open; `authorize: true` names no action.
        module InterfaceRules
          def self.call(definitions, findings)
            definitions.each do |type|
              audit(type, definitions, findings) if type.kind.interface? && !type.introspection?
            end
          end

          def self.audit(interface, definitions, findings)
            bypassed = Integration.any_bypass?(definitions.select { |type| type.kind.object? && type <= interface })
            interface.own_fields.values.flatten.each do |field|
              path = "#{interface.graphql_name}.#{field.original_name}"
              unless field.respond_to?(:armory_declared)
                findings.problem(:unprotected, path, "its field class does not include Base, so it is not checked on a bypassed implementer") if bypassed
                next
              end

              case field.armory_declared
              when true
                findings.problem(:field_without_rule, path, "uses authorize: true, but an interface has no action of its own, so it is always denied")
              when nil
                findings.problem(:field_without_rule, path, "declares no rule and an implementing type is bypassed, so it is denied") if bypassed
              end
            end
          end
          private_class_method :audit
        end
      end
    end
  end
end
