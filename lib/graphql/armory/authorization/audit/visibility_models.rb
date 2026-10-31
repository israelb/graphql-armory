# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # A `visible_when:` is asked of a model at request time, so one that cannot name it raises there. Listing the
        # schema hits it only once, so every location is read here, with no request and no policy.
        class VisibilityModels
          def self.call(schema, definitions, findings)
            new(findings).(schema, definitions)
          end

          def initialize(findings = Findings.new)
            @findings = findings
            @seen = Set.new.compare_by_identity
          end

          def call(schema, definitions)
            definitions.each do |type|
              next if type.introspection?

              note_type(type)
              note_arguments(type.graphql_name, type.all_argument_definitions) if type.kind.input_object?
              Definitions.fields_at_every_level(type).each do |field|
                path = "#{type.graphql_name}.#{field.original_name}"
                note_field(field, path)
                note_arguments(path, field.all_argument_definitions)
              end
            end
            schema.directives.each_value { |directive| note_arguments("@#{directive.graphql_name}", directive.all_argument_definitions) }
          end

          private

          def note_type(type)
            return unless type.respond_to?(:armory_rule) && type.armory_rule&.visible_when && @seen.add?(type)

            problem = model_problem { type.armory_model }
            @findings.problem(:model, type.graphql_name, problem) if problem && !@findings.problem?(:model, type.graphql_name)
          end

          def note_field(field, path)
            return unless field.respond_to?(:armory_visible_when) && field.armory_visible_when && @seen.add?(field)

            problem = if field.owner.respond_to?(:armory_model)
                        model_problem { field.owner.armory_model }
                      else
                        "uses visible_when:, but what defines it cannot name a model, so a request that reads it raises: put it on an object type that includes Base"
                      end
            @findings.problem(:model, path, problem) if problem
          end

          def note_arguments(path, arguments)
            arguments.each do |argument|
              next unless argument.respond_to?(:armory_visible_when) && argument.armory_visible_when && @seen.add?(argument)

              problem = model_problem { argument.armory_model }
              @findings.problem(:model, "#{path}(#{argument.keyword})", problem) if problem
            end
          end

          def model_problem
            yield
            nil
          rescue ConfigurationError, GraphQL::RequiredImplementationMissingError => error
            error.message
          end
        end
      end
    end
  end
end
