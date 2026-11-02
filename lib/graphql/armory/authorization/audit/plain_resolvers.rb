# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # A type's covers_fields says a rule runs elsewhere, and on a resolver or mutation with no Base none does: it runs
        # with no check. A plain method under the same type is the declaration's own meaning, and it is listed by the type.
        module PlainResolvers
          PROBLEM = "its resolver or mutation does not include GraphQL::Armory::Authorization::Base, so no rule of this gem runs on it and the type's covers_fields serves it, unless its own code refuses. " \
                    "Include Base and declare `authorize`, or declare `authorize: :none, reason: \"...\"` on the field"
          PLAIN_FIELD_PROBLEM = "its resolver or mutation does not include GraphQL::Armory::Authorization::Base and neither does its field class, so no rule of this gem runs on it and the type's covers_fields " \
                                "serves it, unless its own code refuses. Include Base in the resolver and declare `authorize`, or use a field class that includes Base and declare `authorize: :none, reason: \"...\"`"

          def self.report(findings, path, field)
            findings.problem(:unprotected, path, field.respond_to?(:armory_declared) ? PROBLEM : PLAIN_FIELD_PROBLEM)
          end

          def self.covering?(rule)
            !rule.nil? && rule.none? && rule.covers_fields?
          end

          # A field that names its own rule, or that its parent mutation's rule already answered, does not depend on covers_fields.
          # Under a write root, what it answers with comes after what it did, whichever class it is.
          def self.open?(field, write_root: false)
            resolver = field.resolver
            return false if resolver.nil? || resolver.respond_to?(:armory_rule)
            return false if field.respond_to?(:armory_declared) && !field.armory_declared.nil?
            return false if ruled_owner?(field.owner)

            write_root || !refused_by_its_type?(field, resolver)
          end

          def self.ruled_owner?(owner)
            return false unless owner.is_a?(Class) && owner <= GraphQL::Schema::Resolver && owner.respond_to?(:armory_rule)

            rule = owner.armory_rule
            # With on_denied: :errors a refusal answers a live payload, so its fields still run.
            !rule.nil? && !rule.none? && owner.armory_on_denied != :errors
          end
          private_class_method :ruled_owner?

          # What a plain read answers with is refused by the rule of that type. A mutation has already written by then, and an
          # interface may gain an implementer with no rule. A type that does not load yet counts as neither.
          def self.refused_by_its_type?(field, resolver)
            return false if resolver <= GraphQL::Schema::Mutation || resolver <= GraphQL::Schema::Subscription

            ruled?(field.type.unwrap)
          rescue GraphQL::Error, NameError
            false
          end
          private_class_method :refused_by_its_type?

          def self.ruled?(element)
            return generated_connection?(element) && ruled?(element.node_type) if Definitions.connection?(element)

            if element.respond_to?(:kind) && element.kind.union?
              members = element.type_memberships.map(&:object_type)
              return !members.empty? && members.all? { |member| ruled?(member) }
            end
            return false unless element.is_a?(Class) && element.respond_to?(:armory_rule)

            rule = element.armory_rule
            !rule.nil? && !rule.none?
          end
          private_class_method :ruled?

          # A field a connection or its edge adds is served by that class, whatever the rule on its nodes.
          def self.generated_connection?(connection)
            fields = Definitions.fields_at_every_level(connection)
            edges = fields.select { |field| field.original_name == :edges }.map { |field| field.type.unwrap }
            only_generated?(fields, GENERATED_RELAY_FIELDS.fetch(GraphQL::Types::Relay::BaseConnection)) &&
              edges.all? { |edge| only_generated?(Definitions.fields_at_every_level(edge), GENERATED_RELAY_FIELDS.fetch(GraphQL::Types::Relay::BaseEdge)) }
          end
          private_class_method :generated_connection?

          def self.only_generated?(fields, names)
            fields.all? { |field| names.include?(field.original_name) && field.resolver.nil? }
          end
          private_class_method :only_generated?
        end
      end
    end
  end
end
