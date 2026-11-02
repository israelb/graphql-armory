# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # A type's covers_fields says a rule runs elsewhere, and on a resolver or mutation with no Base none does: it runs
        # with no check. A plain method under the same type is the declaration's own meaning, and it is listed by the type.
        module PlainResolvers
          PROBLEM = "its resolver or mutation does not include GraphQL::Armory::Authorization::Base, so no rule runs on it and the type's covers_fields serves it to anyone. " \
                    "Include Base and declare `authorize`, or declare `authorize: :none, reason: \"...\"` on the field"
          PLAIN_FIELD_PROBLEM = "its resolver or mutation does not include GraphQL::Armory::Authorization::Base and neither does its field class, so no rule runs on it and the type's covers_fields " \
                                "serves it to anyone. Include Base in the resolver and declare `authorize`, or use a field class that includes Base and declare `authorize: :none, reason: \"...\"`"

          def self.report(findings, path, field)
            findings.problem(:unprotected, path, field.respond_to?(:armory_declared) ? PROBLEM : PLAIN_FIELD_PROBLEM)
          end

          def self.covering?(rule)
            !rule.nil? && rule.none? && rule.covers_fields?
          end

          # A field that names its own rule, or that its parent mutation's rule already answered, does not depend on covers_fields.
          def self.open?(field)
            resolver = field.resolver
            return false if resolver.nil? || resolver.respond_to?(:armory_rule)
            return false if field.respond_to?(:armory_declared) && !field.armory_declared.nil?
            return false if ruled_owner?(field.owner)

            !refused_by_its_type?(field, resolver)
          end

          def self.ruled_owner?(owner)
            return false unless owner.is_a?(Class) && owner <= GraphQL::Schema::Resolver && owner.respond_to?(:armory_rule)

            rule = owner.armory_rule
            !rule.nil? && !rule.none?
          end
          private_class_method :ruled_owner?

          # What a plain read answers with is refused by the rule of that type. A mutation has already written by then, and
          # an interface, a union or a connection may hold a type with no rule. A type that does not load yet counts as neither.
          def self.refused_by_its_type?(field, resolver)
            return false if resolver <= GraphQL::Schema::Mutation || resolver <= GraphQL::Schema::Subscription

            element = field.type.unwrap
            return false unless element.is_a?(Class) && element.respond_to?(:armory_rule) && !Definitions.connection?(element)

            rule = element.armory_rule
            !rule.nil? && !rule.none?
          rescue GraphQL::Error, NameError
            false
          end
          private_class_method :refused_by_its_type?
        end
      end
    end
  end
end
