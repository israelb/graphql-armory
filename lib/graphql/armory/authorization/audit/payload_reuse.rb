# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # A payload's fields are covered by the mutation's rule, so they check nothing themselves. A field that returns the
        # payload without being that mutation serves them with no rule run: a user the mutation refuses gets the data.
        class PayloadReuse
          def self.call(schema, definitions, findings)
            new(findings).(schema, definitions)
          end

          def initialize(findings = Findings.new)
            @findings = findings
          end

          def call(schema, definitions)
            objects = definitions.select { |type| type.kind.object? }
            payloads = objects.select { |type| Definitions.fields_at_every_level(type).any? { |field| covered_by_mutation?(field) } }
            return if payloads.empty?

            objects.each do |type|
              Definitions.fields_at_every_level(type).each { |field| note(schema, type, field, payloads) }
            end
          end

          private

          def covered_by_mutation?(field)
            return false unless field.respond_to?(:armory_declared) && field.armory_declared.nil?

            owner = field.owner
            return false unless owner.is_a?(Class) && owner <= GraphQL::Schema::Resolver && owner.respond_to?(:armory_rule)

            rule = owner.armory_rule
            !rule.nil? && !rule.none?
          end

          def note(schema, type, field, payloads)
            target = returned_type(schema, field) or return
            reused = (target.kind.union? || target.kind.interface? ? schema.possible_types(target) : [target]) & payloads
            return if reused.empty? || own_payload?(field, target)

            @findings.problem(:payload_outside_mutation, "#{type.graphql_name}.#{field.original_name}",
                              "returns #{reused.map(&:graphql_name).join(", ")}, a mutation's payload, whose fields are covered by that mutation's rule: " \
                              "here no such rule runs, so they are served with no check. Return a type of its own")
          end

          # A shadowed definition may name a type that never resolved; it cannot serve anything.
          def returned_type(schema, field)
            type = field.type.unwrap
            type.is_a?(GraphQL::Schema::LateBoundType) ? schema.get_type(type.graphql_name) : type
          rescue NameError, GraphQL::RequiredImplementationMissingError
            nil
          end

          def own_payload?(field, target)
            field.resolver.respond_to?(:payload_type) && field.resolver.payload_type == target
          end
        end
      end
    end
  end
end
