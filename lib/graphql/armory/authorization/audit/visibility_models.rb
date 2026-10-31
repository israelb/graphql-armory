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
              next if Definitions.introspection?(type)

              note_type(type)
              note_arguments(type.graphql_name, type.all_argument_definitions) if type.kind.input_object?
              Definitions.fields_at_every_level(type).each do |field|
                # With Schema::Visibility a request never falls back to a shadowed definition, so it never asks it.
                next if schema.visibility && Definitions.shadowed?(type, field)

                path = "#{path_owner(type, field)}.#{field.original_name}"
                note_field(field, path)
                note_arguments(path, field.all_argument_definitions)
              end
            end
            schema.directives.each_value { |directive| note_arguments("@#{directive.graphql_name}", directive.all_argument_definitions) }
          end

          private

          def note_type(type)
            return unless type.respond_to?(:armory_rule) && type.armory_rule&.visible_when && @seen.add?(type)

            report(type.graphql_name, model_problem { type.armory_model })
          end

          def note_field(field, path)
            return unless field.respond_to?(:armory_visible_when) && field.armory_visible_when && @seen.add?(field)

            problem = if field.owner.respond_to?(:armory_model)
                        model_problem { field.owner.armory_model }
                      else
                        "uses visible_when:, but what defines it cannot name a model, so a request that reads it raises: put it on an object type that includes Base"
                      end
            report(path, problem)
          end

          def note_arguments(path, arguments)
            arguments.each do |argument|
              next unless argument.respond_to?(:armory_visible_when) && argument.armory_visible_when && @seen.add?(argument)

              report("#{path}(#{argument.keyword})", model_problem { argument.armory_model })
            end
          end

          # An interface's field is reported on the interface, whichever implementer the walk reaches first.
          def path_owner(type, field)
            field.owner.respond_to?(:kind) && field.owner.kind.interface? ? field.owner.graphql_name : type.graphql_name
          end

          def report(path, problem)
            @findings.problem(:model, path, problem) if problem && !@findings.problem?(:model, path)
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
