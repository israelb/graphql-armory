# frozen_string_literal: true

require "graphql/armory/definitions"

module GraphQL
  module Armory
    module Authorization
      # Every definition a schema holds, hidden or not (`Armory::Definitions`), plus what `schema.types` lists, which the
      # audit must not miss either.
      module Definitions
        def self.call(schema, &on_listing_error)
          Armory::Definitions.(schema, listed_types(schema, &on_listing_error))
        end

        # With only static profiles, graphql-ruby refuses to list types without naming one: the roots still lead everywhere.
        # A `visible_when:` that cannot name its model raises here, on the first listing only. The roots still lead to the
        # rest, and the audit passes a block because it must not say ok after that.
        def self.listed_types(schema)
          schema.types.values
        rescue ConfigurationError => error
          yield error if block_given?
          []
        rescue ArgumentError
          raise unless schema.visibility

          []
        end
        private_class_method :listed_types

        def self.introspection?(type) = Armory::Definitions.introspection?(type)
        def self.connection?(type) = Armory::Definitions.connection?(type)
        def self.fields_at_every_level(type) = Armory::Definitions.fields_at_every_level(type)
        def self.shadowed?(type, field) = Armory::Definitions.shadowed?(type, field)
      end
    end
  end
end
