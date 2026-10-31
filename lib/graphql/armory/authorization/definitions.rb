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
          pending = [schema.query, schema.mutation, schema.subscription, *schema.orphan_types, *listed_types(schema)]
          until pending.empty?
            type = pending.pop
            next if !type.respond_to?(:kind) || !found.add?(type)

            pending.concat(referenced_types(type))
          end
          found.to_a
        end

        # With only static profiles, graphql-ruby refuses to list types without naming one: the roots still lead everywhere.
        def self.listed_types(schema)
          schema.types.values
        rescue ArgumentError
          raise unless schema.visibility

          []
        end
        private_class_method :listed_types

        def self.connection?(type)
          type.is_a?(Class) && type.include?(GraphQL::Types::Relay::ConnectionBehaviors)
        end

        def self.referenced_types(type)
          references = []
          references << fields_of(type)
          references << arguments_of(type) if type.kind.input_object?
          references.concat(type.interface_type_memberships.map(&:abstract_type)) if type.respond_to?(:interface_type_memberships)
          references.concat(type.orphan_types) if type.kind.interface?
          references.concat(type.type_memberships.map(&:object_type)) if type.kind.union?
          references << type.node_type if connection?(type)
          references.flatten.compact
        end
        private_class_method :referenced_types

        # Every definition of every field, nearest first: a hidden one falls back to the next of its name, and
        # `all_field_definitions` merges them by name. `field ... do ... end` blocks are loaded here, because only
        # `schema.types` or a request loads them, and the audit reads arguments from them.
        def self.fields_at_every_level(type)
          return [] unless type.respond_to?(:all_field_definitions)

          fields = type.ancestors.select { |ancestor| ancestor.respond_to?(:own_fields) }.flat_map { |ancestor| ancestor.own_fields.values.flatten }
          fields.each { |field| field.ensure_loaded if field.respond_to?(:ensure_loaded) }
          fields.uniq
        end

        # A shadowed definition is only served by a fallback, so one whose type cannot load fails nothing that runs today.
        def self.shadowed?(type, field)
          !type.all_field_definitions.include?(field)
        end

        def self.fields_of(type)
          fields_at_every_level(type).map do |field|
            references_of(field)
          rescue GraphQL::Error
            raise unless shadowed?(type, field)

            nil
          end
        end
        private_class_method :fields_of

        def self.references_of(field)
          [field.type.unwrap, arguments_of(field)]
        end
        private_class_method :references_of

        def self.arguments_of(member)
          member.all_argument_definitions.flat_map { |argument| [argument.type.unwrap, argument.loads] }
        end
        private_class_method :arguments_of
      end
    end
  end
end
