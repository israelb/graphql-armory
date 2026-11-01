# frozen_string_literal: true

require "set"
require "graphql/armory/authorization/audit/report"
require "graphql/armory/authorization/audit/baseline"
require "graphql/armory/authorization/audit/reach"
require "graphql/armory/authorization/audit/command"
require "graphql/armory/authorization/audit/findings"
require "graphql/armory/authorization/audit/library_methods"
require "graphql/armory/authorization/audit/denial_hooks"
require "graphql/armory/authorization/audit/own_checks"
require "graphql/armory/authorization/audit/overrides"
require "graphql/armory/authorization/audit/foreign_policies"
require "graphql/armory/authorization/audit/type_rules"
require "graphql/armory/authorization/audit/observed_rules"
require "graphql/armory/authorization/audit/edge_rules"
require "graphql/armory/authorization/audit/interface_rules"
require "graphql/armory/authorization/audit/input_loads"
require "graphql/armory/authorization/audit/visibility_models"
require "graphql/armory/authorization/audit/introspection_fields"

module GraphQL
  module Armory
    module Authorization
      # Walks a schema, without running a query, and reports everything that is not covered:
      # types nobody protected, types without a rule or a policy, fields with no rule on a bypassed
      # type, and `loads:` that skip the scope. Every declared bypass is listed with its reason.
      #
      # Each check is an object of its own, built for one run, so one Audit can serve several threads.
      class Audit
        RELAY_TYPES = [GraphQL::Types::Relay::BaseConnection, GraphQL::Types::Relay::BaseEdge,
                       GraphQL::Types::Relay::PageInfo].freeze
        GENERATED_RELAY_FIELDS = { GraphQL::Types::Relay::BaseConnection => %i[edges nodes page_info],
                                   GraphQL::Types::Relay::BaseEdge => %i[node cursor] }.freeze

        # A library's method is defined in its files and held by a class it names. Either alone misleads: anyone can name
        # a module under `GraphQL::`, and an alias keeps graphql-ruby's location on an app's class.
        GRAPHQL_RUBY_PATH = "#{File.dirname(GraphQL::Schema.method(:from_definition).source_location.first)}/"
        ARMORY_PATH = "#{File.expand_path('..', __dir__)}/"

        attr_reader :adapter

        # `new` is inert: with no adapter nothing can be verified, so nothing is covered.
        def initialize(adapter: Adapters::Null.new)
          @adapter = adapter
        end

        def self.build(schema)
          configuration = schema.armory_configuration if schema.respond_to?(:armory_configuration)
          configuration ? new(adapter: configuration.adapter) : new
        end

        def self.call(schema)
          build(schema).(schema)
        end

        def call(schema)
          findings = Findings.new
          listing_error = nil
          definitions = Definitions.(schema) { |error| listing_error = error }
          if schema.respond_to?(:armory_configuration) && schema.armory_configuration
            DenialHooks.(schema, findings)
            OwnChecks.(schema, definitions, findings)
            Overrides.(schema, definitions, findings)
          else
            findings.problem(:plugin, "Schema", "never installed the plugin: add `use GraphQL::Armory::Authorization, adapter: ...`")
          end

          foreign_policies = ForeignPolicies.new(adapter, findings)
          type_rules = TypeRules.new(adapter, findings, foreign_policies)
          audited_types(definitions).each { |type| type_rules.(type) }
          definitions.each { |type| foreign_policies.relay(type) if type.kind.object? && RELAY_TYPES.any? { |relay| type <= relay } }
          EdgeRules.(definitions, findings)
          InterfaceRules.(definitions, findings)
          InputLoads.(definitions, findings)
          ObservedRules.(schema, definitions, findings)
          VisibilityModels.(schema, definitions, findings)
          IntrospectionFields.(schema, findings)
          findings.problem(:model, "Schema", listing_error.message) if listing_error && !findings.problem?(:model)
          findings.report(Reach.new(definitions))
        end

        private

        # PageInfo holds no data of the app, until a subclass, its parent or an interface adds a field.
        def extended_page_info?(type)
          type < GraphQL::Types::Relay::PageInfo &&
            Definitions.fields_at_every_level(type).any? { |field| !field.owner.equal?(GraphQL::Types::Relay::PageInfo) }
        end

        # A connection or an edge holds only what graphql-ruby generates, until a subclass, its parent or an interface adds a field.
        def extended_relay?(type)
          GENERATED_RELAY_FIELDS.any? do |relay, names|
            type < relay && Definitions.fields_at_every_level(type).any? { |field| !names.include?(field.original_name) }
          end
        end

        def audited_types(definitions)
          definitions.select do |type|
            type.kind.object? && !Definitions.introspection?(type) &&
              (extended_page_info?(type) || extended_relay?(type) || RELAY_TYPES.none? { |relay| type <= relay })
          end
        end

        # Answers the report it was given, for tests.
        class Substitute
          def initialize(report)
            @report = report
          end

          def call(_schema)
            @report
          end
        end
      end
    end
  end
end
