# frozen_string_literal: true

require "set"

module GraphQL
  module Armory
    module Authorization
      # Every definition a schema holds, hidden or not. `schema.types` is read with no request, so it leaves out what is
      # hidden there and a request can still reach: a type or field hidden by `visible?`, or one of several definitions of
      # a name. This follows the definitions themselves from the roots and `orphan_types`.
      module Definitions
        def self.call(schema)
          found = Set.new.compare_by_identity
          pending = [schema.query, schema.mutation, schema.subscription, *schema.orphan_types, *schema.types.values]
          until pending.empty?
            type = pending.pop
            next if !type.respond_to?(:kind) || !found.add?(type)

            pending.concat(referenced_types(type))
          end
          found.to_a
        end

        def self.connection?(type)
          type.is_a?(Class) && type.include?(GraphQL::Types::Relay::ConnectionBehaviors)
        end

        def self.referenced_types(type)
          references = []
          type.all_field_definitions.each { |field| references << field.type.unwrap << arguments_of(field) } if type.respond_to?(:all_field_definitions)
          references << arguments_of(type) if type.kind.input_object?
          references.concat(type.interface_type_memberships.map(&:abstract_type)) if type.respond_to?(:interface_type_memberships)
          references.concat(type.orphan_types) if type.kind.interface?
          references.concat(type.type_memberships.map(&:object_type)) if type.kind.union?
          references << type.node_type if connection?(type)
          references.flatten.compact
        end
        private_class_method :referenced_types

        def self.arguments_of(member)
          member.all_argument_definitions.flat_map { |argument| [argument.type.unwrap, argument.loads] }
        end
        private_class_method :arguments_of
      end
    end
  end
end
