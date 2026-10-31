# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # `Schema.introspection` can add or redefine entry points and dynamic fields. A client reaches them from any type,
        # with no type of the app around them, so no type's rule runs. The built-in ones hold no data of the app.
        class IntrospectionFields
          BUILT_IN = { EntryPoints: :entry_points, DynamicFields: :dynamic_fields }.freeze

          def self.call(schema, findings)
            new(findings).(schema)
          end

          def initialize(findings = Findings.new)
            @findings = findings
          end

          def call(schema)
            system = schema.introspection_system
            BUILT_IN.each do |holder, reader|
              system.public_send(reader).each { |field| note(field, GraphQL::Introspection.const_get(holder)) }
            end
          end

          private

          # graphql-ruby serves a copy of the holder's fields, on a copy of the holder.
          def note(field, built_in)
            name = field.graphql_name
            return if field.owner.superclass.fields[name].equal?(built_in.fields[name])

            @findings.problem(:unprotected, "#{field.owner.graphql_name}.#{name}", "is a custom introspection field, so no type's rule runs on it: move it to a type with a rule")
          end
        end
      end
    end
  end
end
