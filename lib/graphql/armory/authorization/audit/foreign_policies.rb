# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # A rule asks the policy of the class that defines it, and a field never sees its resolved type: a rule on an
        # interface, a parent, an input object or a plain resolver does not ask the `policy:` of the type that uses it.
        class ForeignPolicies
          def initialize(adapter = Adapters::Null.new, findings = Findings.new)
            @adapter = adapter
            @findings = findings
            @seen = Set.new
          end

          def call(type, policy)
            Definitions.fields_at_every_level(type).each do |field|
              path = "#{type.graphql_name}.#{field.original_name}"
              note(field, path, policy, model_or_nil(type)) if field.respond_to?(:armory_declared)
              arguments(field.all_argument_definitions, path, policy, Set.new)
            end
          end

          # A connection or edge is not audited as a type, but a field rule on it runs under the same terms.
          def relay(type)
            policy = type.armory_rule&.policy if type.respond_to?(:armory_rule)
            call(type, policy) if policy
          end

          # A class without Base has no rule of its own, but what it leads to still runs its rules. An argument, a Base
          # resolver's included, asks the policy of the class that defines it, not of the type that uses it.
          def arguments(arguments, path, policy, seen)
            arguments.each do |argument|
              if argument.respond_to?(:armory_declared)
                note(argument, "#{path}(#{argument.keyword})", policy, model_or_nil(argument))
              end
              input = argument.type.unwrap
              next unless input.respond_to?(:kind) && input.kind.input_object? && seen.add?(input)

              arguments(input.all_argument_definitions, path, policy, seen)
            end
          end

          private

          def note(member, path, policy, model)
            ruled = member.armory_visible_when || ![nil, :none].include?(member.armory_declared)
            return if !ruled || asks_policy?(member, policy, model) || !@seen.add?([member, path, policy])

            asked = member.armory_policy || "the policy found from the record"
            @findings.problem(:foreign_policy, path, "its rule asks #{asked}, not #{policy}, the `policy:` of this type: it is defined on a class that does not name that policy. " \
                                                     "Move the rule to the class that names it and remove the original, or name the `policy:` on the class that defines the rule, if it can hold one")
          end

          # With no `policy:` of its own, a rule asks what the adapter finds from the model, which may be the same policy.
          def asks_policy?(member, policy, model)
            asked = member.armory_policy
            return asked.equal?(policy) if asked

            !model.nil? && @adapter.respond_to?(:found_policy) && @adapter.found_policy(model).equal?(policy)
          end

          def model_or_nil(owner)
            owner.armory_model
          rescue ConfigurationError
            nil
          end
        end
      end
    end
  end
end
