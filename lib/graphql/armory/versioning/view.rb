# frozen_string_literal: true

module GraphQL
  module Armory
    module Versioning
      # One version's schema, for tooling: what a query of that version sees. Built by `Versioning.types(schema, label)`.
      #
      #   v = GraphQL::Armory::Versioning.types(AppSchema, "2024-06-01")
      #   v.type("Contract")                  # nil: not in that version
      #   v.fields(Types::Invoice).map(&:graphql_name)
      #
      # Everything goes through graphql-ruby's own visibility for that version (`query.types`), plus the checks graphql-ruby
      # leaves out: a type answers only when it is listed in that version, and a member only when its owner is. Objects it
      # answers are graphql-ruby's own: calling their methods (`type.fields`) without a context sees every version.
      # `View.new` with nothing answers nothing.
      class View
        def initialize(types = nil)
          @types = types
        end

        # The type of that name in this version, or nil.
        def type(name)
          return unless @types && @types.reachable_type?(name)

          @types.type(name)
        end

        def all_types = @types ? @types.all_types : []

        def fields(owner) = visible?(owner) ? @types.fields(owner) : []

        def field(owner, name) = visible?(owner) ? @types.field(owner, name) : nil

        # Of a field, an input object or a directive.
        def arguments(owner) = owner_visible?(owner) ? @types.arguments(owner) : []

        def possible_types(type) = visible?(type) ? @types.possible_types(type) : []

        def interfaces(type) = visible?(type) ? @types.interfaces(type) : []

        def enum_values(type) = visible?(type) ? @types.enum_values(type) : []

        # Whether this version lists the type.
        def visible?(type)
          !type.nil? && type.respond_to?(:graphql_name) && type(type.graphql_name).equal?(type)
        end

        private

        def owner_visible?(owner)
          case owner
          when GraphQL::Schema::Field then visible?(owner.owner) && field(owner.owner, owner.graphql_name).equal?(owner)
          when Class
            owner < GraphQL::Schema::Directive ? !@types.nil? && @types.directives.include?(owner) : visible?(owner)
          else false
          end
        end
      end
    end
  end
end
