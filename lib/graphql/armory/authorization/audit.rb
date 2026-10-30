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

        # Where a method is defined tells a library's from an app's: a name can be placed under `GraphQL::` by anyone.
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
          if schema.respond_to?(:armory_configuration) && schema.armory_configuration
            audit_denial_hooks(schema, findings)
            audit_own_checks(schema, findings)
          else
            findings.problem(:plugin, "Schema", "never installed the plugin: add `use GraphQL::Armory::Authorization, adapter: ...`")
          end

          audited_types(schema).each { |type| audit_type(type, findings) }
          schema.types.each_value { |type| audit_edge_rule(type, findings) if type.kind.object? && type <= GraphQL::Types::Relay::BaseEdge }
          schema.types.each_value { |type| audit_interface(type, schema, findings) if type.kind.interface? && !type.introspection? }
          schema.types.each_value { |type| audit_input_loads(type, findings) if type.kind.input_object? && !type.introspection? }
          findings.report
        end

        private

        # A method the schema defines on itself wins over the plugin's, so `on_unauthorized:` no longer decides
        # what that denial looks like. The check runs here because `use` usually comes before those methods.
        def audit_denial_hooks(schema, findings)
          declared = schema.armory_configuration.own_denial_hooks
          Configuration::DENIAL_HOOKS.each do |hook|
            path = "Schema.#{hook}"
            own = schema.method(hook).owner != Integration::Schema
            if own && declared.key?(hook)
              findings.bypass(path, declared[hook])
            elsif own
              findings.problem(:hook, path, "the schema's own method runs instead of the plugin's, so on_unauthorized: does not apply and a denial " \
                                            "may reveal what it hides: remove it, or declare it in own_denial_hooks: with a reason")
            elsif declared.key?(hook)
              findings.problem(:hook, path, "named in own_denial_hooks: but the plugin's hook is the one that runs: remove it from the option")
            end
          end
        end

        # A method an app defines wins over what the plugin and graphql-ruby decide: `authorized?` and `authorizes?`
        # can skip a rule, and graphql-ruby calls `unauthorized_object` on whatever loads a record, so returning the
        # object runs the code on a refused record. The audit cannot read them: each is reported once, where it is
        # defined, until it is declared. Methods that come from graphql-ruby or from this gem are not the app's.
        def audit_own_checks(schema, findings)
          found = {}
          schema.types.each_value do |type|
            next unless type.kind.object? && !type.introspection? && type.respond_to?(:armory_rule)

            %i[authorized? authorizes?].each { |name| note_class_check(found, type, name) }
            type.all_field_definitions.each { |field| note_field_checks(found, field) }
          end
          schema.types.each_value do |type|
            next unless type.kind.input_object? && !type.introspection?

            %i[authorized? unauthorized_object].each { |name| note_class_check(found, type, name) }
            note_argument_checks(found, type.all_argument_definitions)
          end
          report_own_checks(found, schema.armory_configuration.own_checks, findings)
        end

        def note_field_checks(found, field)
          %i[authorized? authorizes? unauthorized_object].each { |name| note_instance_check(found, field.class, name) }
          note_argument_checks(found, field.all_argument_definitions)
          resolver = field.resolver
          return unless resolver

          note_instance_check(found, resolver, :unauthorized_object)
          note_class_check(found, resolver, :authorizes?)
          note_instance_check(found, resolver, :authorized?) if resolver.respond_to?(:armory_rule)
        end

        def note_argument_checks(found, arguments)
          arguments.each { |argument| note_instance_check(found, argument.class, :authorized?) }
        end

        def note_instance_check(found, klass, name)
          return unless klass.method_defined?(name) || klass.private_method_defined?(name)

          note_own_check(found, klass, klass.instance_method(name), name, "#")
        end

        def note_class_check(found, klass, name)
          return unless klass.respond_to?(name, true)

          note_own_check(found, klass, klass.method(name), name, ".")
        end

        def note_own_check(found, klass, method, name, separator)
          return if defined_in?(method, GRAPHQL_RUBY_PATH, ARMORY_PATH)

          owner = method.owner
          holder = klass.ancestors.find { |ancestor| ancestor.singleton_class == owner } || owner
          found[[holder, name]] = "#{holder.name || holder.inspect}#{separator}#{name}"
        end

        def report_own_checks(found, declared, findings)
          found.each do |(holder, name), path|
            reason = declared.fetch(holder, {})[name]
            next findings.bypass(path, reason) if reason

            findings.problem(:own_check, path, "#{own_check_risk(name)}. Remove it, or declare it in own_checks: with a reason")
          end
          declared.each do |holder, methods|
            methods.each_key do |name|
              next if found.key?([holder, name])

              findings.problem(:own_check, "#{holder.name || holder.inspect} #{name}", "named in own_checks: but no check of the schema is defined there: remove it from the option")
            end
          end
        end

        def own_check_risk(name)
          case name
          when :unauthorized_object then "defined by the app: if it returns the object, the code runs on the refused record, and a message it raises reaches the client"
          when :authorizes? then "defined by the app: if it answers false, Execution::Next does not run authorized?, so the rule is skipped"
          else "defined by the app, it wins over the plugin's: if it does not call super it can skip the rule"
          end
        end

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
          elsif rule.visible_when && answered_by_graphql_ruby?(type, :visible?)
            findings.problem(:ignored_rule, path, "graphql-ruby's #{type.method(:visible?).owner} answers visible? here, so visible_when: never runs: remove it")
          elsif rule.none?
            findings.bypass(path, rule.reason)
            audit_fields(type, findings, model: nil, bypassed: !rule.covers_fields?, reported: Set.new)
          elsif answered_by_graphql_ruby?(type, :authorized?)
            findings.problem(:ignored_rule, path, "graphql-ruby's #{type.method(:authorized?).owner} answers authorized? here, so this rule never runs: " \
                                                  "put the rule on the field or resolver that returns it, and declare " \
                                                  "`authorize :none, reason: \"...\", covers_fields: true` on this class")
          else
            model = model_of(type, path, findings)
            reported = Set.new
            check(path, model, rule, findings, reported) if model
            check(path, model, Rule.new(rule.visible_when, policy: rule.policy), findings, reported) if model && rule.visible_when
            audit_fields(type, findings, model: model, bypassed: false, reported: reported)
          end
        end

        # ConnectionBehaviors and EdgeBehaviors, included after Base, bring an `authorized?` and a `visible?` that win
        # over the plugin's.
        def answered_by_graphql_ruby?(type, name)
          defined_in?(type.method(name), GRAPHQL_RUBY_PATH)
        end

        def defined_in?(method, *paths)
          file = method.source_location&.first
          !file.nil? && file.start_with?(*paths)
        end

        # A direct edge subclass runs the plugin's check, but only where an edge is built: `nodes` never builds one.
        def audit_edge_rule(type, findings)
          rule = type.armory_rule if type.respond_to?(:armory_rule)
          return if rule.nil? || rule.none?

          findings.problem(:ignored_rule, type.graphql_name, "the connection's nodes field returns the nodes without building an edge, so this rule " \
                                                             "does not cover it: put the rule on the field or resolver that returns the connection")
        end

        # Interface fields are reported once, on the interface that declares them, not on every implementer.
        # Undeclared ones are denied when an implementer is a bypass; ones whose field class lacks Base are
        # never checked, so on a bypassed implementer they are open; `authorize: true` names no action.
        def audit_interface(interface, schema, findings)
          bypassed = Integration.bypassed_implementer?(interface, schema)
          interface.own_fields.each_value do |field|
            path = "#{interface.graphql_name}.#{field.original_name}"
            unless field.respond_to?(:armory_declared)
              findings.problem(:unprotected, path, "its field class does not include Base, so it is not checked on a bypassed implementer") if bypassed
              next
            end

            case field.armory_declared
            when true
              findings.problem(:field_without_rule, path, "uses authorize: true, but an interface has no action of its own, so it is always denied")
            when nil
              findings.problem(:field_without_rule, path, "declares no rule and an implementing type is bypassed, so it is denied") if bypassed
            end
          end
        end

        # A field an implementer inherits from an interface is reported on the interface.
        def interface_field?(field)
          field.owner.respond_to?(:kind) && field.owner.kind.interface?
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
            # An inherited interface field is reported as uncovered on its interface; every other check still runs here.
            inherited = bypassed && interface_field?(field)
            next findings.problem(:field_without_rule, path, "its field class does not include Base, so it is denied") if bypassed && !inherited && !field.respond_to?(:armory_declared)
            next unless field.respond_to?(:armory_declared)
            next audit_resolver(field, path, findings) if field.resolver.respond_to?(:armory_rule)

            audit_declaration(field, path, findings, model: model, bypassed: bypassed && !inherited, reported: reported)
            audit_visibility(field, path, findings, model: model, reported: reported)
            audit_loads(field, path, findings)
            audit_arguments(field, path, findings, reported: reported)
          end
        end

        # A resolver or mutation carries its own rule: no rule is denied, `:none` is listed, an action is checked.
        def audit_resolver(field, path, findings)
          resolver = field.resolver
          rule = resolver.armory_rule
          return findings.problem(:no_rule, path, "its mutation or resolver declares no `authorize`, so it is denied") if rule.nil?
          return findings.bypass(path, rule.reason) if rule.none?

          model = begin
            resolver.armory_model
          rescue ConfigurationError => error
            return findings.problem(:model, path, error.message)
          end
          check(path, model, rule, findings, Set.new)
        end

        # The action a field is hidden with is asked of the policy like any other, so it must exist.
        def audit_visibility(field, path, findings, model:, reported:)
          return unless model && field.armory_visible_when

          check(path.split(".").first, model, Rule.new(field.armory_visible_when, attribute: field.original_name), findings, reported)
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

        # An argument that declares a rule is listed (a bypass with its reason) or checked like a field's action.
        def audit_arguments(field, path, findings, reported:)
          field.all_argument_definitions.each do |argument|
            next unless argument.respond_to?(:armory_declared)

            apath = "#{path}(#{argument.keyword})"
            declared = argument.armory_declared
            findings.bypass(apath, argument.armory_reason) if declared == :none
            [declared, argument.armory_visible_when].compact.reject { |action| action == :none }.each do |action|
              audit_argument_action(argument, apath, action, findings, reported)
            end
          end
        end

        def audit_argument_action(argument, path, action, findings, reported)
          check(path.split(".").first, argument.armory_model, Rule.new(action, attribute: argument.keyword), findings, reported)
        rescue ConfigurationError => error
          findings.problem(:model, path, error.message)
        end

        def audit_loads(field, path, findings)
          return if field.armory_load_through_scope?

          opted_out_loads(field.all_argument_definitions, Set.new).each do |name|
            findings.problem(:unscoped_load, "#{path}(#{name})", "loads through the app's object_from_id, not through the user's scope")
          end
        end

        # Execution::Next loads `loads:` nested in input objects with the field's loader, so a field's opt-out
        # reaches them too: list them as `filter.invoice_id`. `seen` stops recursive input types.
        def opted_out_loads(arguments, seen, prefix = nil)
          arguments.flat_map do |argument|
            name = [prefix, GraphQL::Schema::Member::BuildType.underscore(argument.graphql_name)].compact.join(".")
            next [name] if argument.loads

            input = argument.type.unwrap
            next [] unless input.kind.input_object? && seen.add?(input)

            opted_out_loads(input.all_argument_definitions, seen, name)
          end
        end

        # An input object loads its own `loads:` arguments; without Base they skip the user's scope.
        def audit_input_loads(input, findings)
          return if input.respond_to?(:armory_scoped_loads?)

          # A mutation's generated input (`from_resolver`) is loaded, scoped, by the mutation itself.
          input.all_argument_definitions.select(&:loads).reject(&:from_resolver?).each do |argument|
            name = GraphQL::Schema::Member::BuildType.underscore(argument.graphql_name)
            findings.problem(:unscoped_load, "#{input.graphql_name}(#{name})",
                             "its input object class does not include Base, so it loads through the app's object_from_id, not the user's scope")
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
