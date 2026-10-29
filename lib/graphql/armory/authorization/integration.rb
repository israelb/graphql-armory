# frozen_string_literal: true

require "graphql/armory/authorization/integration/schema"
require "graphql/armory/authorization/integration/object"
require "graphql/armory/authorization/integration/field"
require "graphql/armory/authorization/integration/base"

module GraphQL
  module Armory
    module Authorization
      # Translates graphql-ruby's hooks into questions for the core. No permission logic lives here.
      module Integration
        # In graphql 2.5.26 to 2.6.1 Execution::Next resolves a denied field against a nil object and crashes.
        NEXT_MINIMUM = Gem::Version.new("2.6.2")
        NEXT_SUPPORTED = Gem::Version.new(GraphQL::VERSION) >= NEXT_MINIMUM

        def self.configuration(context)
          check_engine!(context)

          schema = context.schema
          return schema.armory_configuration if schema.respond_to?(:armory_configuration)

          raise ConfigurationError,
                "this schema never installed the plugin: add `use GraphQL::Armory::Authorization, adapter: ...` to #{schema}"
        end

        def self.check_engine!(context, supported: NEXT_SUPPORTED)
          return if supported || !context[:__graphql_execute_next]

          raise ConfigurationError,
                "Execution::Next needs graphql >= #{NEXT_MINIMUM} (running #{GraphQL::VERSION}): " \
                "a denied field crashes it in earlier versions"
        end

        def self.allowed?(subject, rule, context)
          configuration = configuration(context)
          Authorize.(subject, rule, context, adapter: configuration.adapter, sinks: configuration.sinks)
        end
      end
    end
  end
end
