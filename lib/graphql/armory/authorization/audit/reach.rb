# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # What a problem reaches beyond its own name: every definition that is, inherits from or implements what its path
        # names, with their fields and `loads:`. A problem on a type or a base class says nothing about what is added to it
        # later, so a baseline compares this to tell the problem someone accepted from a larger one.
        class Reach
          def initialize(definitions)
            @definitions = definitions
          end

          def call(path)
            head, member = path.delete_suffix(")").split(/[.(]/)
            @definitions.select { |type| holds?(type, head) }.flat_map { |type| of(type, member) }.sort
          end

          private

          def holds?(type, head)
            type.graphql_name == head || type.ancestors.any? { |ancestor| ancestor.name == head || named?(ancestor, head) }
          end

          # graphql-ruby's own classes answer `graphql_name` too (`Member`, `Object`): a type named like one must not reach everything.
          def named?(ancestor, head)
            return false if ancestor.name&.start_with?("GraphQL::")

            ancestor.respond_to?(:graphql_name) && ancestor.graphql_name == head
          rescue GraphQL::Error
            false # an anonymous class with no name of its own
          end

          # A problem on one field reaches that field: the others of its type have their own problems.
          def of(type, member)
            label = type.name || type.graphql_name
            return ["type:#{label}", *input_loads(label, type)] if type.kind.input_object?
            return ["type:#{label}"] unless type.respond_to?(:fields)

            fields = Definitions.fields_at_every_level(type)
            fields = fields.select { |field| field.graphql_name == member || field.original_name.to_s == member } if member
            ["type:#{label}", *fields.flat_map { |field| of_field(label, field) }]
          end

          def input_loads(label, type)
            type.all_argument_definitions.filter_map { |argument| argument.loads && "loads:#{label}.#{argument.graphql_name}:#{argument.loads.graphql_name}" }
          end

          def of_field(label, field)
            ["field:#{label}.#{field.graphql_name}:#{signature(field)}",
             *field.all_argument_definitions.filter_map { |argument| loads_of(label, field, argument) }]
          end

          # A field whose type cannot be read is what some problems are about: it must not stop the audit.
          def signature(field)
            field.type.to_type_signature
          rescue StandardError, LoadError
            "unreadable"
          end

          def loads_of(label, field, argument)
            loads = argument.loads
            "loads:#{label}.#{field.graphql_name}.#{argument.graphql_name}:#{loads.graphql_name}" if loads
          end
        end
      end
    end
  end
end
