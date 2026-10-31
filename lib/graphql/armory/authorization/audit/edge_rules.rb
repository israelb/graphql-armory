# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # A direct edge subclass runs the plugin's check, but only where an edge is built: `nodes` never builds one.
        module EdgeRules
          def self.call(definitions, findings)
            definitions.each do |type|
              next unless type.kind.object? && type <= GraphQL::Types::Relay::BaseEdge

              rule = type.armory_rule if type.respond_to?(:armory_rule)
              next if rule.nil? || rule.none? || !nodes_field_beside?(type, definitions)

              findings.problem(:ignored_rule, type.graphql_name, "the connection's nodes field returns the nodes without building an edge, so this rule does not " \
                                                                 "cover it: put the rule on the field that returns the connection (on a root field, on a resolver: " \
                                                                 "a field rule asks the parent's policy), or remove the nodes field with has_nodes_field(false)")
            end
          end

          def self.nodes_field_beside?(edge, definitions)
            definitions.any? do |type|
              next false unless type.kind.object? && !type.introspection?

              fields = type.all_field_definitions
              fields.any? { |field| field.graphql_name == "nodes" } &&
                fields.any? { |field| field.graphql_name == "edges" && field.type.unwrap == edge }
            end
          end
          private_class_method :nodes_field_beside?
        end
      end
    end
  end
end
