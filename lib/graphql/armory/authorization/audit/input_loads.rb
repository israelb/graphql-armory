# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # An input object loads its own `loads:` arguments; without Base they skip the user's scope.
        module InputLoads
          def self.call(definitions, findings)
            definitions.each do |input|
              next unless input.kind.input_object? && !input.introspection?
              next if input.respond_to?(:armory_scoped_loads?)

              # A mutation's generated input (`from_resolver`) is loaded, scoped, by the mutation itself.
              input.all_argument_definitions.select(&:loads).reject(&:from_resolver?).each do |argument|
                name = GraphQL::Schema::Member::BuildType.underscore(argument.graphql_name)
                findings.problem(:unscoped_load, "#{input.graphql_name}(#{name})",
                                 "its input object class does not include Base, so it loads through the app's object_from_id, not the user's scope")
              end
            end
          end
        end
      end
    end
  end
end
