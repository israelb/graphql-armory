# frozen_string_literal: true

module GraphQL
  module Armory
    # API versioning: a client names the version of the schema it was built against, and gets exactly that version's
    # schema, or a refusal. Members say when they arrived and when they left.
    #
    #   class AppSchema < GraphQL::Schema
    #     use GraphQL::Schema::Visibility
    #     use GraphQL::Armory::Versioning, versions: %w[2024-01-15 2024-06-01 2025-01-01], retired: %w[2024-01-15], default: :latest
    #   end
    #
    #   class Types::BaseField < GraphQL::Schema::Field
    #     include GraphQL::Armory::Versioning::Base
    #   end
    #
    #   field :total, Integer, null: false, added: "2024-06-01"
    #   field :amount, Integer, null: false, removed: "2025-01-01"
    #
    #   AppSchema.execute(params[:query], context: { armory_version: request.headers["X-API-Version"] })
    #
    # Hooks only `Schema.query_class` (to decide the version once per query) and `visible?` on the classes that include
    # `Base`, so every lookup graphql-ruby makes for the query (validation, both engines, introspection, SDL) sees one version.
    module Versioning
      class Error < Armory::Error; end

      # The schema or a member was not set up the way versioning needs. Server-side, never a client's doing.
      class ConfigurationError < Error; end

      # A label the version list does not hold.
      class UnknownVersionError < ConfigurationError; end

      # A versioned member was asked about in a query whose version is refused: only callers that skip validation reach it,
      # such as `to_definition`, `Schema.validate` or a query the app built itself. The message never quotes the client's value.
      class RefusedVersionError < Error
        attr_reader :code

        def initialize(message, code)
          @code = code
          super(message)
        end
      end

      # The request named no version and the schema says `default: :refuse`.
      class MissingVersionError < RefusedVersionError; end

      # Answers the Version a query sees, from a resolver, `resolve_type` or anything else that holds its context, so data
      # can be mapped to the schema that client sees. Raises for anything that is not a query's context.
      def self.version(context)
        if context.is_a?(GraphQL::Query::NullContext) || !context.respond_to?(:namespace)
          raise ConfigurationError, "Versioning.version needs a query's context (a resolver's, resolve_type's or a trigger's), not a #{context.class}"
        end

        Integration.version(context)
      end

      # One version's schema for tooling (a `View`): what a query naming `label` sees, decided the way a request is, with
      # `context:` merged in (a user, for `visible_when:`). Records no signal. Raises the refusal for a version that is not
      # served, and `ConfigurationError` for a schema versioning cannot serve.
      def self.types(schema, label, context: {})
        decision = Integration.gate(schema).resolve(label)
        raise decision.error if decision.refused?

        Integration.refuse_always_visible(schema)
        Integration.check_schema(schema)
        query = GraphQL::Query.new(schema, "{ __typename }", validate: false, context: context.merge(armory_version: label))
        View.new(query.types)
      end

      # Whether no served version of `schema` sees more than one of `definitions` (twins of one name), for Authorization's
      # audit. False for a schema without versioning.
      def self.disjoint?(schema, definitions)
        return false unless schema.respond_to?(:armory_versioning)

        schema.armory_versioning.versions.each_served.all? do |version|
          definitions.count { |definition| Integration.covers?(definition, version) } <= 1
        end
      end

      # `versions:` the labels, oldest first; `retired:` the oldest ones, no longer served; `default:` what a request with no
      # version gets: `:latest`, a served label or `:refuse`. `sinks:` and `on_sink_error:` as in Telemetry.
      def self.use(schema, versions:, default: Gate::UNSET, retired: [], sinks: [], on_sink_error: nil)
        gate = Gate.build(versions: versions, default: default, retired: retired, sinks: sinks, on_sink_error: on_sink_error)

        if schema.singleton_class.include?(Integration::Guard)
          raise ConfigurationError, "#{schema} already uses Versioning (here or in a parent schema): use it once"
        end

        schema.instance_variable_set(:@armory_versioning, gate)
        schema.singleton_class.prepend(Integration::Guard)
        schema.query_class(schema.query_class)
      end
    end
  end
end

require "graphql/armory/definitions"
require "graphql/armory/versioning/versions"
require "graphql/armory/versioning/lifecycle"
require "graphql/armory/versioning/decision"
require "graphql/armory/versioning/gate"
require "graphql/armory/versioning/integration"
require "graphql/armory/versioning/view"
require "graphql/armory/versioning/controls"
