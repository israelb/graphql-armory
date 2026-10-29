# frozen_string_literal: true

require "set"
require "graphql/armory/authorization/audit/report"
require "graphql/armory/authorization/audit/command"

module GraphQL
  module Armory
    module Authorization
      # Walks a schema, without running a query, and reports everything that is not covered:
      # types nobody protected, types without a rule or a policy, fields with no rule on a bypassed
      # type, and `loads:` that skip the scope. Every declared bypass is listed with its reason.
      class Audit
        RELAY_TYPES = [GraphQL::Types::Relay::BaseConnection, GraphQL::Types::Relay::BaseEdge,
                       GraphQL::Types::Relay::PageInfo].freeze

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
          unless schema.respond_to?(:armory_configuration) && schema.armory_configuration
            findings.problem(:plugin, "Schema", "never installed the plugin: add `use GraphQL::Armory::Authorization, adapter: ...`")
          end

          audited_types(schema).each { |type| audit_type(type, findings) }
          findings.report
        end

        private

        # Walks `schema.types`, which a schema that hides types with `visible?` would filter.
        def audited_types(schema)
          schema.types.values.select do |type|
            type.kind.object? && !type.introspection? && RELAY_TYPES.none? { |relay| type <= relay }
          end
        end

        def audit_type(type, findings)
          path = type.graphql_name
          unless type.respond_to?(:armory_rule)
            findings.problem(:unprotected, path, "its base class does not include GraphQL::Armory::Authorization::Base, so it is open")
            return
          end

          rule = type.armory_rule
          if rule.nil?
            findings.problem(:no_rule, path, "has no rule and no default_action, so it is denied")
          elsif rule.none?
            findings.bypass(path, rule.reason)
            audit_fields(type, findings, model: nil, bypassed: true, reported: Set.new)
          else
            model = model_of(type, path, findings)
            reported = Set.new
            check(path, model, rule, findings, reported) if model
            audit_fields(type, findings, model: model, bypassed: false, reported: reported)
          end
        end

        def model_of(type, path, findings)
          type.armory_model
        rescue ConfigurationError => error
          findings.problem(:model, path, error.message)
          nil
        end

        # An adapter problem shows once per type, however many fields declare an action of their own.
        def check(path, model, rule, findings, reported)
          adapter.check(model, rule).each do |message|
            findings.problem(:adapter, path, message) if reported.add?(message)
          end
        end

        def audit_fields(type, findings, model:, bypassed:, reported:)
          type.all_field_definitions.each do |field|
            path = "#{type.graphql_name}.#{field.original_name}"
            next findings.problem(:field_without_rule, path, "its field class does not include Base, so it is denied") if bypassed && !field.respond_to?(:armory_declared)
            next unless field.respond_to?(:armory_declared)

            audit_declaration(field, path, findings, model: model, bypassed: bypassed, reported: reported)
            audit_loads(field, path, findings)
          end
        end

        def audit_declaration(field, path, findings, model:, bypassed:, reported:)
          case (declared = field.armory_declared)
          when :none
            findings.bypass(path, field.armory_reason)
          when nil, true
            if bypassed
              findings.problem(:field_without_rule, path, "declares no rule and its type is bypassed, so it is denied")
            end
          else
            check(path.split(".").first, model, Rule.new(declared), findings, reported) if model
          end
        end

        def audit_loads(field, path, findings)
          return if field.armory_load_through_scope?

          field.all_argument_definitions.select(&:loads).each do |argument|
            name = GraphQL::Schema::Member::BuildType.underscore(argument.graphql_name)
            findings.problem(:unscoped_load, "#{path}(#{name})", "loads through the app's object_from_id, not through the user's scope")
          end
        end

        # Collects what one audit finds.
        class Findings
          def initialize
            @problems = []
            @bypasses = []
          end

          def problem(kind, path, message)
            @problems << Report::Problem.new(kind, path, message)
          end

          def bypass(path, reason)
            @bypasses << Report::Bypass.new(path, reason)
          end

          def report
            Report.new(problems: @problems.sort_by { |problem| [problem.path, problem.kind.to_s] },
                       bypasses: @bypasses.sort_by(&:path))
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
