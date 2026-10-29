# frozen_string_literal: true

require "graphql/armory/authorization/integration/schema"
require "graphql/armory/authorization/integration/object"
require "graphql/armory/authorization/integration/find_by"
require "graphql/armory/authorization/integration/field"
require "graphql/armory/authorization/integration/argument"
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

        # Narrows a list to what the user may see. Without a rule nothing is visible.
        def self.scoped(items, rule, context)
          return Adapters::Null.new.scope(nil, items, rule) if rule.nil?

          configuration = configuration(context)
          Scope.(items, rule, context, adapter: configuration.adapter, sinks: configuration.sinks)
        end

        # Looks an object up inside the user's scope, by primary key unless a key is given.
        # What is out of scope and what does not exist look the same: nil.
        def self.find(type, key, value, context)
          unless type.respond_to?(:armory_model)
            raise ConfigurationError,
                  "#{type.graphql_name} cannot be looked up through a scope: " \
                  "include GraphQL::Armory::Authorization::Base in its base class"
          end

          model = type.armory_model
          rule = type.armory_rule
          conditions = { (key || model.primary_key) => value }
          return scoped(model.all, rule, context).find_by(conditions) unless rule&.scope == :in_memory

          # An in-memory scope yields an Array, which cannot look one record up: find it, then ask the rule.
          record = model.find_by(conditions)
          record if record && allowed?(record, rule, context)
        end

        # One Authorize per query: building it (and its memo and telemetry) once per object is pure overhead.
        def self.allowed?(subject, rule, context)
          store = context.namespace(:armory)
          authorize = store[:authorize] ||= begin
            configuration = configuration(context)
            Authorize.build(context, adapter: configuration.adapter, sinks: configuration.sinks)
          end

          authorize.(subject, rule, context)
        end

        # Whether a type or field may appear in the schema this user sees. The question is asked of the
        # model's class, with no record, so the rule's action must be one a policy can answer that way.
        # `Schema.types` with no context sees the whole schema. A schema dump asks for it explicitly with
        # `to_definition(context: { armory_full_schema: true })`: graphql 2.6 builds an ordinary context for it,
        # which cannot be told from an anonymous request, and an anonymous request must not see hidden members.
        def self.visible?(model, rule, context)
          unless context.respond_to?(:namespace)
            raise ConfigurationError,
                  "visible_when: needs a per-query context; static Schema::Visibility profiles are not supported, " \
                  "use `dynamic: true` or no profiles"
          end

          return true if context.is_a?(GraphQL::Query::NullContext) || context[:armory_full_schema] == true

          allowed?(model, rule, context)
        end
      end
    end
  end
end
