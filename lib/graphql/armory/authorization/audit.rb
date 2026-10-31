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
          @definitions = Definitions.(schema)
          @foreign_policies = Set.new
          if schema.respond_to?(:armory_configuration) && schema.armory_configuration
            audit_denial_hooks(schema, findings)
            audit_own_checks(schema, findings)
            audit_overrides(schema, findings)
          else
            findings.problem(:plugin, "Schema", "never installed the plugin: add `use GraphQL::Armory::Authorization, adapter: ...`")
          end

          audited_types(schema).each { |type| audit_type(type, findings) }
          @definitions.each { |type| audit_edge_rule(type, schema, findings) if type.kind.object? && type <= GraphQL::Types::Relay::BaseEdge }
          @definitions.each { |type| audit_interface(type, schema, findings) if type.kind.interface? && !type.introspection? }
          @definitions.each { |type| audit_input_loads(type, findings) if type.kind.input_object? && !type.introspection? }
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
          @definitions.each do |type|
            next unless type.kind.object? && !type.introspection? && type.respond_to?(:armory_rule)

            %i[authorized? authorizes? authorized_new wrap].each { |name| note_class_check(found, type, name) }
            note_class_check(found, type, :visible?) if type.armory_rule&.visible_when
            Definitions.fields_at_every_level(type).each { |field| note_field_checks(found, field) }
          end
          @definitions.each do |type|
            next if type.introspection? || !type.respond_to?(:scope_items) || !(type.kind.object? || type.kind.interface? || type.kind.union?)

            note_class_check(found, type, :scope_items)
            note_reauthorization(found, type)
          end
          @definitions.each do |type|
            next unless type.kind.input_object? && !type.introspection?

            %i[authorized? unauthorized_object].each { |name| note_class_check(found, type, name) }
            note_argument_checks(found, type.all_argument_definitions)
          end
          report_own_checks(found, schema.armory_configuration.own_checks, findings)
        end

        def note_field_checks(found, field)
          %i[authorized? authorizes? unauthorized_object].each { |name| note_instance_check(found, field.class, name) }
          note_visibility_check(found, field)
          note_argument_checks(found, field.all_argument_definitions)
          resolver = field.resolver
          return unless resolver

          note_instance_check(found, resolver, :unauthorized_object)
          note_class_check(found, resolver, :authorizes?)
          note_instance_check(found, resolver, :authorized?) if resolver.respond_to?(:armory_rule)
        end

        def note_argument_checks(found, arguments)
          arguments.each do |argument|
            note_instance_check(found, argument.class, :authorized?)
            note_visibility_check(found, argument)
          end
        end

        # With no Schema::Visibility, a field hidden from a user falls back to another definition of its name, losing its
        # rule, arguments, return type and extensions. Many things can hide it (the field, its resolver, its return type,
        # the schema) and only a request knows, so every redefinition is reported until it declares `override_reason:`.
        def audit_overrides(schema, findings)
          @override_paths = {}.compare_by_identity
          @falling_back = {}.compare_by_identity
          @duplicates = Set.new.compare_by_identity
          @definitions.each do |type|
            next if type.introspection?

            note_redefinitions(type.graphql_name, type.ancestors, :own_fields, :original_name)
            note_redefinitions(type.graphql_name, type.ancestors, :own_arguments, :graphql_name) if type.kind.input_object?
            Definitions.fields_at_every_level(type).each do |field|
              levels = [field] + (field.resolver ? field.resolver.ancestors : [])
              note_redefinitions("#{type.graphql_name}.#{field.original_name}", levels, :own_arguments, :graphql_name)
            end
          end
          no_fallback = visibility_without_fallback?(schema)
          @override_paths.each do |member, path|
            falls_back = @falling_back.key?(member) && (!no_fallback || @duplicates.include?(member))
            note_override(findings, falls_back ? @falling_back[member] : path, member, falls_back)
          end
        end

        # Nearest level first; only a lone definition on the farthest level has nothing to fall back to. Duplicates on
        # one level are noted apart: a visibility profile skips the levels below, but still picks one of those.
        def note_redefinitions(prefix, ancestors, reader, name_reader)
          levels = ancestors.select { |ancestor| ancestor.respond_to?(reader) }
          levels.flat_map { |level| level.public_send(reader).keys }.uniq.each do |name|
            definitions = levels.filter_map { |level| [level.public_send(reader)[name]].flatten if level.public_send(reader).key?(name) }
            definitions.flatten.each { |member| @override_paths[member] ||= "#{prefix}.#{member.public_send(name_reader)}" }
            falling = definitions.last.size == 1 ? definitions.flatten[0...-1] : definitions.flatten
            falling.each { |member| @falling_back[member] ||= "#{prefix}.#{member.public_send(name_reader)}" }
            definitions.select { |level| level.size > 1 }.flatten.each { |member| @duplicates << member }
          end
        end

        # graphql-ruby skips the fallback to a lower level only when the request carries a visibility profile. A static
        # profile runs with a plain Hash, so only `Schema::Visibility` with no profiles, not turned off below, rules it out.
        def visibility_without_fallback?(schema)
          visibility = schema.visibility
          return false unless visibility
          return false if schema.respond_to?(:use_visibility_profile?) && !schema.use_visibility_profile?

          visibility.instance_variable_get(:@profiles).to_h.empty?
        end

        def note_override(findings, path, member, falls_back)
          reason = member.armory_override_reason if member.respond_to?(:armory_override_reason)
          if falls_back && reason
            findings.bypass(path, reason)
          elsif falls_back
            findings.problem(:ignored_rule, path, "is defined more than once: hidden from a user, it falls back to the other definition, and its own rule, arguments, type and extensions do not apply. " \
                                                  "Remove one or declare override_reason:; for a definition on an ancestor, Schema::Visibility with dynamic: true and no profiles also stops the fallback")
          elsif reason
            findings.problem(:ignored_rule, path, "declares override_reason: but nothing falls back from it: remove it")
          end
        end

        # Off, records that came through the scope skip `authorized?`: harmless only if the scope is as strict as the rule.
        # The interpreter asks the field's return type, Execution::Next the resolved object, and each path differs, so it
        # is reported wherever it is off, without judging whether it skips anything: declaring it takes one line.
        def note_reauthorization(found, type)
          readers = type.is_a?(Class) ? [type] : type.ancestors.select { |ancestor| ancestor.respond_to?(:reauthorize_scoped_objects, true) }
          readers.each { |reader| note_class_check(found, reader, :reauthorize_scoped_objects) }

          setter = reauthorization_setter(type)
          found[[setter, :reauthorize_scoped_objects]] = "#{setter.name || setter.inspect}.reauthorize_scoped_objects" if setter&.instance_variable_get(:@reauthorize_scoped_objects) == false
        end

        def relay_connection?(type)
          Definitions.connection?(type)
        end

        # The nearest that set the value, read from the classes so no method of the app runs: graphql-ruby's reader follows
        # superclasses, not the interfaces a class implements. A connection reads only its own, then its node's, which
        # `Definitions` reaches and the audit reads as a type of its own.
        def reauthorization_setter(type)
          return type if relay_connection?(type)

          chain = type.is_a?(Class) ? type.ancestors.grep(Class) : type.ancestors
          chain.find { |ancestor| !ancestor.instance_variable_get(:@reauthorize_scoped_objects).nil? }
        end

        # Apps define `visible?` for their own reasons: it only matters where a `visible_when:` depends on it.
        def note_visibility_check(found, member)
          note_instance_check(found, member.class, :visible?) if member.respond_to?(:armory_visible_when) && member.armory_visible_when
        end

        def note_instance_check(found, klass, name)
          return unless klass.method_defined?(name) || klass.private_method_defined?(name)

          note_own_check(found, klass, klass.instance_method(name), name, "#")
        end

        def note_class_check(found, klass, name)
          return unless klass.respond_to?(name, true)

          note_own_check(found, klass, klass.method(name), name, ".")
        end

        # Follows the whole chain: a method that only calls super must not hide one below it that answers true.
        def note_own_check(found, klass, method, name, separator)
          while method
            holder = holder_of(klass, method)
            found[[holder, name]] = "#{holder.name || holder.inspect}#{separator}#{name}" unless library_method?(method, holder, GRAPHQL_RUBY_PATH, ARMORY_PATH)
            method = method.super_method
          end
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
          when :authorized_new, :wrap then "defined by the app: it decides whether authorized? runs, so on the interpreter it can skip the rule"
          when :scope_items then "defined by the app: it replaces the user's scope, so a list can hold records the policy's scope excludes, and connections count them"
          when :reauthorize_scoped_objects then "set to false: records that come through the scope skip the rule, so a user the rule refuses gets them"
          when :visible? then "defined by the app: if it does not call super, visible_when: does not hide this from a user it should"
          else "defined by the app, it wins over the plugin's: if it does not call super it can skip the rule"
          end
        end

        def audited_types(schema)
          @definitions.select do |type|
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
          elsif rule.visible_when && (answer = graphql_ruby_answer(type, :visible?))
            findings.problem(:ignored_rule, path, "graphql-ruby's #{answer} answers visible? here, so visible_when: never runs: remove it")
          elsif rule.none?
            findings.bypass(path, rule.reason)
            audit_fields(type, findings, model: nil, bypassed: !rule.covers_fields?, reported: Set.new)
            audit_foreign_policies(type, rule.policy, findings) if rule.policy
          elsif (answer = graphql_ruby_answer(type, :authorized?))
            findings.problem(:ignored_rule, path, "graphql-ruby's #{answer} answers authorized? here, so this rule never runs: " \
                                                  "put the rule on the field that returns it (on a root field, on a resolver: a field rule asks " \
                                                  "the parent's policy), and declare `authorize :none, reason: \"...\", covers_fields: true` on this class")
          else
            model = model_of(type, path, findings)
            reported = Set.new
            check(path, model, rule, findings, reported) if model
            check(path, model, Rule.new(rule.visible_when, policy: rule.policy), findings, reported) if model && rule.visible_when
            audit_foreign_policies(type, rule.policy, findings) if rule.policy
            audit_fields(type, findings, model: model, bypassed: false, reported: reported)
          end
        end

        # ConnectionBehaviors and EdgeBehaviors, included after Base, bring an `authorized?` and a `visible?` that win
        # over the plugin's. An app's method may call super, so this follows the chain to the first library that answers.
        def graphql_ruby_answer(type, name)
          method = type.method(name)
          until method.nil? || method.owner == Integration::Object
            return method.owner if library_method?(method, holder_of(type, method), GRAPHQL_RUBY_PATH)

            method = method.super_method
          end
        end

        def holder_of(klass, method)
          owner = method.owner
          klass.ancestors.find { |ancestor| ancestor.singleton_class == owner } || owner
        end

        def library_method?(method, holder, *paths)
          file = method.source_location&.first
          !file.nil? && file.start_with?(*paths) && holder.name&.start_with?("GraphQL::") == true
        end

        # A direct edge subclass runs the plugin's check, but only where an edge is built: `nodes` never builds one.
        def audit_edge_rule(type, schema, findings)
          rule = type.armory_rule if type.respond_to?(:armory_rule)
          return if rule.nil? || rule.none? || !nodes_field_beside?(type, schema)

          findings.problem(:ignored_rule, type.graphql_name, "the connection's nodes field returns the nodes without building an edge, so this rule does not " \
                                                             "cover it: put the rule on the field that returns the connection (on a root field, on a resolver: " \
                                                             "a field rule asks the parent's policy), or remove the nodes field with has_nodes_field(false)")
        end

        def nodes_field_beside?(edge, schema)
          @definitions.any? do |type|
            next false unless type.kind.object? && !type.introspection?

            fields = type.all_field_definitions
            fields.any? { |field| field.graphql_name == "nodes" } &&
              fields.any? { |field| field.graphql_name == "edges" && field.type.unwrap == edge }
          end
        end

        # Interface fields are reported once, on the interface that declares them, not on every implementer.
        # Undeclared ones are denied when an implementer is a bypass; ones whose field class lacks Base are
        # never checked, so on a bypassed implementer they are open; `authorize: true` names no action.
        def audit_interface(interface, schema, findings)
          bypassed = Integration.any_bypass?(@definitions.select { |type| type.kind.object? && type <= interface })
          interface.own_fields.values.flatten.each do |field|
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

        # Every definition, the shadowed ones included: a hidden override falls back to them, so they serve requests too.
        # Nothing here loads a field's type, so a shadowed field whose type cannot load raises nothing.
        def audit_fields(type, findings, model:, bypassed:, reported:)
          Definitions.fields_at_every_level(type).each do |field|
            audit_field(type, field, "#{type.graphql_name}.#{field.original_name}", findings, model: model, bypassed: bypassed, reported: reported)
          end
        end

        def audit_field(type, field, path, findings, model:, bypassed:, reported:)
          # An inherited interface field is reported as uncovered on its interface; every other check still runs here.
          inherited = bypassed && interface_field?(field)
          if bypassed && !inherited && !field.respond_to?(:armory_declared)
            return findings.problem(:field_without_rule, path, "its field class does not include Base, so no rule runs on it: its type is bypassed and graphql-ruby's own " \
                                                               "authorized? answers true, so the field is served with no check. Use a field class that includes Base")
          end
          return unless field.respond_to?(:armory_declared)
          return audit_resolver(field, path, findings) if field.resolver.respond_to?(:armory_rule)

          audit_declaration(type, field, path, findings, model: model, bypassed: bypassed && !inherited, reported: reported)
          audit_visibility(field, path, findings, model: model, reported: reported)
          audit_loads(field, path, findings)
          audit_arguments(field, path, findings, reported: reported)
        end

        # A resolver or mutation carries its own rule: no rule is denied, `:none` is listed, an action is checked.
        def audit_resolver(field, path, findings)
          resolver = field.resolver
          rule = resolver.armory_rule
          audit_foreign_arguments(field.all_argument_definitions, path, rule.policy, findings, Set.new) if rule&.policy
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

          check(path.split(".").first, model, Rule.new(field.armory_visible_when, policy: field.armory_policy, attribute: field.original_name), findings, reported)
        end

        def audit_declaration(type, field, path, findings, model:, bypassed:, reported:)
          case (declared = field.armory_declared)
          when :none
            findings.bypass(path, field.armory_reason)
          when nil, true
            if bypassed && declared.nil? && served_by_owner?(type, field)
              findings.problem(:field_without_rule, path, "declares no rule and its type is bypassed, but it is inherited from #{field.owner.name || field.owner.inspect}: a field runs " \
                                                          "under the class that defines it, and no rule ran on this type, so the field is served with no check. Give it authorize: where it is defined, or remove it")
            elsif bypassed
              findings.problem(:field_without_rule, path, "declares no rule and its type is bypassed, so it is denied")
            end
          else
            check(path.split(".").first, model, Rule.new(declared, policy: field.armory_policy), findings, reported) if model
          end
        end

        # A rule asks the policy of the class that defines it, and a field never sees its resolved type: a rule on an
        # interface, a parent, an input object or a plain resolver does not ask the `policy:` of the type that uses it.
        def audit_foreign_policies(type, policy, findings)
          Definitions.fields_at_every_level(type).each do |field|
            path = "#{type.graphql_name}.#{field.original_name}"
            note_foreign_policy(field, path, policy, findings, model_or_nil(type)) if field.respond_to?(:armory_declared)
            audit_foreign_arguments(field.all_argument_definitions, path, policy, findings, Set.new)
          end
        end

        # A class without Base has no rule of its own, but what it leads to still runs its rules. A Base resolver's own
        # arguments ask the resolver's policy, on purpose; the input objects they take do not.
        def audit_foreign_arguments(arguments, path, policy, findings, seen)
          arguments.each do |argument|
            if argument.respond_to?(:armory_declared) && !argument.owner.respond_to?(:armory_rule)
              note_foreign_policy(argument, "#{path}(#{argument.keyword})", policy, findings, model_or_nil(argument))
            end
            input = argument.type.unwrap
            next unless input.respond_to?(:kind) && input.kind.input_object? && seen.add?(input)

            audit_foreign_arguments(input.all_argument_definitions, path, policy, findings, seen)
          end
        end

        def note_foreign_policy(member, path, policy, findings, model)
          ruled = member.armory_visible_when || ![nil, :none].include?(member.armory_declared)
          return if !ruled || asks_policy?(member, policy, model) || !@foreign_policies.add?([member, path, policy])

          asked = member.armory_policy || "the policy found from the record"
          findings.problem(:foreign_policy, path, "its rule asks #{asked}, not #{policy}, the `policy:` of this type: it is defined on a class that does not name that policy. " \
                                                  "Move the rule to the class that names it and remove the original, or name the `policy:` on the class that defines the rule, if it can hold one")
        end

        # With no `policy:` of its own, a rule asks what the adapter finds from the model, which may be the same policy.
        def asks_policy?(member, policy, model)
          asked = member.armory_policy
          return asked.equal?(policy) if asked

          !model.nil? && adapter.respond_to?(:found_policy) && adapter.found_policy(model).equal?(policy)
        end

        def model_or_nil(owner)
          owner.armory_model
        rescue ConfigurationError
          nil
        end

        # A field runs under its owner's rule, not the resolved type's. Inherited by a bypassed type from a parent whose
        # rule covers it, or that knows no rule at all, graphql-ruby serves it after a type check that checked nothing.
        def served_by_owner?(type, field)
          owner = field.owner
          return false if owner.equal?(type) || !owner.is_a?(Class)
          return true unless owner.respond_to?(:armory_rule)

          rule = owner.armory_rule
          !rule.nil? && (!rule.none? || rule.covers_fields?)
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
          check(path.split(".").first, argument.armory_model, Rule.new(action, policy: argument.armory_policy, attribute: argument.keyword), findings, reported)
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
