# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # A payload's fields are covered by the mutation's rule, so they check nothing themselves. A field that returns the
        # payload without being a mutation with a rule serves them with none run: a user the mutation refuses gets the data.
        # It reads the definitions and not the schema's lookups, which filter by visibility and may need a profile.
        class PayloadReuse
          def self.call(definitions, findings)
            new(findings).(definitions)
          end

          def initialize(findings = Findings.new)
            @findings = findings
          end

          def call(definitions)
            objects = definitions.select { |type| type.kind.object? }
            fields = objects.flat_map { |type| Definitions.fields_at_every_level(type).map { |field| [type, field] } }
            guarded = fields.filter_map { |_type, field| field.resolver.payload_type if ruled_resolver?(field.resolver) }.uniq
            payloads = objects.select do |type|
              next false if own_rule?(type)

              guarded.any? { |payload| type <= payload } || generated_by_ruled_mutation?(type) || holds_field_of_ruled_mutation?(type)
            end
            return if payloads.empty?

            named = definitions.to_h { |type| [type.graphql_name, type] }
            fields.each { |type, field| note(type, field, objects, payloads, named) }
          end

          private

          # graphql-ruby marks the payload it generates with its mutation, which the schema may not hold at all.
          def generated_by_ruled_mutation?(type)
            type.ancestors.any? { |ancestor| ancestor.respond_to?(:mutation) && ruled_resolver?(ancestor.mutation) }
          end

          # A field keeps the mutation that defined it as its owner, wherever it ends up.
          def holds_field_of_ruled_mutation?(type)
            Definitions.fields_at_every_level(type).any? do |field|
              field.respond_to?(:armory_declared) && field.armory_declared.nil? && ruled_resolver?(field.owner)
            end
          end

          def ruled_resolver?(resolver)
            return false unless resolver.respond_to?(:payload_type) && resolver.respond_to?(:armory_rule)

            rule = resolver.armory_rule
            !rule.nil? && !rule.none?
          end

          # A type with a rule of its own checks itself wherever it is returned: `payload_type Types::Invoice`.
          def own_rule?(type)
            return false unless type.respond_to?(:armory_rule)

            rule = type.armory_rule
            !rule.nil? && !rule.none?
          end

          def note(type, field, objects, payloads, named)
            target = returned_type(field, named) or return
            reused = members(target, objects) & payloads
            return if reused.empty? || own_payload?(field, target)

            @findings.problem(:payload_outside_mutation, "#{type.graphql_name}.#{field.original_name}",
                              "returns #{reused.map(&:graphql_name).sort.join(", ")}, a mutation's payload, whose fields are covered by that mutation's rule: " \
                              "here no such rule runs, so they are served with no check. Return a type of its own")
          end

          # A shadowed definition may name a type that never resolved; it cannot serve anything.
          def returned_type(field, named)
            type = field.type.unwrap
            type.is_a?(GraphQL::Schema::LateBoundType) ? named[type.graphql_name] : type
          rescue NameError, GraphQL::Error
            nil
          end

          def members(target, objects)
            return target.all_possible_types if target.kind.union?
            return objects.select { |type| type <= target } if target.kind.interface?

            [target]
          end

          def own_payload?(field, target)
            ruled_resolver?(field.resolver) && field.resolver.payload_type == target
          end
        end
      end
    end
  end
end
