# frozen_string_literal: true

require "graphql/armory/authorization/integration/schema"
require "graphql/armory/authorization/integration/object"
require "graphql/armory/authorization/integration/find_by"
require "graphql/armory/authorization/integration/field"
require "graphql/armory/authorization/integration/argument"
require "graphql/armory/authorization/integration/resolver"
require "graphql/armory/authorization/integration/input_object"
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
          Scope.(items, rule, context, adapter: configuration.adapter, sinks: configuration.sinks, on_sink_error: configuration.on_sink_error)
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

        # Loads a `loads:` argument inside the user's scope. When the schema defines `object_from_id` (global
        # IDs), it decodes the id; the record must be of the type's model, and is then looked up again
        # through the scope, so a foreign id still looks like a missing one. Otherwise the id is the primary key.
        def self.load(type, id, context)
          schema = context.schema
          return find(type, nil, id, context) unless decodes_ids?(schema) && type.respond_to?(:armory_model)

          model = type.armory_model
          record = decode(schema, id, context)
          return nil unless record.is_a?(model)

          find(type, nil, record.public_send(model.primary_key), context)
        end

        # `GlobalID.find`, graphql-ruby's documented `object_from_id`, raises for a missing record, and a
        # decoder may raise for a malformed id (ArgumentError, or the Encoder's InvalidError). All must answer like a
        # record out of scope: nil.
        def self.decode(schema, id, context)
          schema.object_from_id(id, context)
        rescue StandardError => error
          raise unless error.is_a?(ArgumentError) || error.is_a?(Encoder::InvalidError) || error.class.name == "ActiveRecord::RecordNotFound"

          nil
        end
        private_class_method :decode

        # graphql-ruby's default `object_from_id` only raises, so an override is the app decoding its IDs.
        def self.decodes_ids?(schema)
          schema.method(:object_from_id).owner != GraphQL::Schema.singleton_class
        end

        # An interface field with no rule of its own cannot name the type it is resolved on, so it is only
        # covered when no implementer is a bypass: a field on a bypassed type is denied, and so is this one.
        # `possible_types` is read with no request, so it drops an implementer hidden there.
        def self.bypassed_implementer?(interface, schema)
          hidden = schema.respond_to?(:armory_implementers) ? schema.armory_implementers(interface) : []
          any_bypass?(schema.possible_types(interface) + hidden)
        end

        def self.any_bypass?(types)
          types.any? do |type|
            rule = type.armory_rule if type.respond_to?(:armory_rule)
            rule && rule.none? && !rule.covers_fields?
          end
        end

        # The rule with the model its owner wraps, the one the audit reads: named by the rule, or named like the type.
        def self.with_owner_model(rule, owner)
          return rule if rule.none? || rule.policy || rule.model || !owner.respond_to?(:armory_model)

          rule.with_model(declared_model(owner) || owner.armory_model)
        rescue ConfigurationError, GraphQL::RequiredImplementationMissingError
          rule
        end

        # A Symbol or a String stays as written: only that spelling can name a policy for a Symbol the type wraps.
        def self.declared_model(owner)
          owner.armory_rule&.model if owner.respond_to?(:armory_rule)
        end
        private_class_method :declared_model

        # One Authorize per query: building it (and its memo and telemetry) once per object is pure overhead.
        def self.allowed?(subject, rule, context)
          store = context.namespace(:armory)
          authorize = store[:authorize] ||= begin
            configuration = configuration(context)
            Authorize.build(context, adapter: configuration.adapter, sinks: configuration.sinks, on_sink_error: configuration.on_sink_error)
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
