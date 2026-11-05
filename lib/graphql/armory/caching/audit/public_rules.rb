# frozen_string_literal: true

require "set"

module GraphQL
  module Armory
    module Caching
      class Audit
        # A `:public` answer is stored once and served to everyone, so nothing on its path may decide per user. Wherever
        # Authorization consults a policy for it, the answer is not public: the type that serves the field or defines it,
        # the field's own rule, `visible_when:` and `observe:`, its resolver's rule, an argument's rule, `loads:` and
        # `find_by:`, and every type it returns (an interface's or a union's possible types, a connection's nodes and
        # edges, so a scoped list too). Each is read with the same readers Authorization's audit uses: `armory_rule` and
        # `Rule#none?`, `armory_declared`, `armory_visible_when`, `Integration.observed_reason`, `Argument#loads`.
        class PublicRules
          NO_RULE = [nil, :none].freeze

          # Every type a field answers with: its unwrapped type, an interface's or a union's possible types among the
          # definitions (hidden and orphan ones included), and a connection's nodes and edges.
          def self.data_types(field, definitions)
            pending = [element_of(field)].compact
            seen = Set.new.compare_by_identity
            found = []
            until pending.empty?
              type = pending.pop
              next unless type.respond_to?(:kind) && seen.add?(type)

              found << type
              pending.concat(related(type, definitions))
            end
            found
          end

          def self.element_of(field)
            field.type.unwrap
          rescue GraphQL::Error, NameError
            nil
          end
          private_class_method :element_of

          def self.related(type, definitions)
            related = []
            if Armory::Definitions.connection?(type)
              related << type.node_type
              related.concat(Armory::Definitions.fields_at_every_level(type).select { |field| field.original_name == :edges }.filter_map { |field| element_of(field) })
            end
            related.concat(definitions.select { |member| member.is_a?(Class) && member.kind.object? && member <= type }) if type.kind.interface?
            related.concat(type.type_memberships.map(&:object_type)) if type.kind.union?
            related.concat(Armory::Definitions.fields_at_every_level(type).select { |field| field.original_name == :node }.filter_map { |field| element_of(field) }) if edge?(type)
            related.compact
          end
          private_class_method :related

          def self.edge?(type)
            type.is_a?(Class) && type <= GraphQL::Types::Relay::BaseEdge
          end
          private_class_method :edge?

          # The arguments a field takes: its own and its resolver's.
          def self.arguments_of(field)
            resolver = field.resolver
            (field.all_argument_definitions + (resolver ? resolver.all_argument_definitions : [])).uniq
          end

          def initialize(definitions, findings)
            @definitions = definitions
            @findings = findings
          end

          def call(pairs)
            pairs.each do |type, field, _declaration|
              reasons = reasons_for(type, field).uniq
              next if reasons.empty?

              @findings.problem(:public_over_rule, "#{type.graphql_name}.#{field.graphql_name}",
                                "declared :public, but the policy decides per user here: #{reasons.join('; ')}. Make it :viewer, " \
                                "or bypass the rule (`authorize :none`) if the data really is the same for everyone", at: field)
            end
          end

          private

          def reasons_for(type, field)
            reasons = rule_reasons(type, "its type #{type.graphql_name}")
            reasons.concat(rule_reasons(field.owner, "#{name_of(field.owner)}, which defines it,")) unless field.owner.equal?(type)
            reasons.concat(field_reasons(field))
            reasons.concat(argument_reasons(PublicRules.arguments_of(field), Set.new.compare_by_identity))
            reasons << "find_by:, which looks the record up through the user's scope" if find_by?(field)
            PublicRules.data_types(field, @definitions).each do |returned|
              reasons.concat(rule_reasons(returned, "#{name_of(returned)}, which it returns#{' (a scoped list)' if list?(field)},"))
            end
            reasons
          end

          # A type's or a resolver's rule: an action is a policy, and `visible_when:` asks one even on a bypass.
          def rule_reasons(holder, who)
            rule = holder.armory_rule if holder.respond_to?(:armory_rule)
            return [] if rule.nil?

            reasons = []
            reasons << "#{who} has the rule #{rule.action.inspect}#{" under observe: (#{rule.observe})" if rule.observed?}" unless rule.none?
            reasons << "#{who} has visible_when: #{rule.visible_when.inspect}" if rule.visible_when
            reasons
          end

          def field_reasons(field)
            reasons = []
            declared = field.armory_declared if field.respond_to?(:armory_declared)
            reasons << "a field rule (authorize: #{declared.inspect})" unless NO_RULE.include?(declared)
            reasons << "visible_when: #{field.armory_visible_when.inspect}" if field.respond_to?(:armory_visible_when) && field.armory_visible_when
            observed = Authorization::Integration.observed_reason(field)
            reasons << "observe: (#{observed})" if observed
            reasons.concat(rule_reasons(field.resolver, "its resolver #{name_of(field.resolver)}")) if field.resolver
            reasons
          end

          # An input object's arguments are loaded and checked too, nested to any depth.
          def argument_reasons(arguments, seen, prefix = nil)
            arguments.flat_map do |argument|
              name = [prefix, argument.keyword].compact.join(".")
              reasons = []
              reasons << "loads: #{name_of(argument.loads)} through argument #{name}" if argument.loads
              declared = argument.armory_declared if argument.respond_to?(:armory_declared)
              reasons << "argument #{name} has the rule #{declared.inspect}" unless NO_RULE.include?(declared)
              reasons << "argument #{name} has visible_when: #{argument.armory_visible_when.inspect}" if argument.respond_to?(:armory_visible_when) && argument.armory_visible_when
              input = input_of(argument)
              reasons.concat(argument_reasons(input.all_argument_definitions, seen, name)) if input && seen.add?(input)
              reasons
            end
          end

          def input_of(argument)
            type = argument.type.unwrap
            type if type.respond_to?(:kind) && type.kind.input_object?
          rescue GraphQL::Error, NameError
            nil
          end

          def find_by?(field)
            field.extensions.any? { |extension| extension.is_a?(Authorization::Integration::FindBy) }
          end

          def list?(field)
            field.type.list?
          rescue GraphQL::Error, NameError
            false
          end

          def name_of(member)
            member.respond_to?(:graphql_name) ? member.graphql_name : member.inspect
          rescue GraphQL::Error
            member.inspect
          end
        end
      end
    end
  end
end
