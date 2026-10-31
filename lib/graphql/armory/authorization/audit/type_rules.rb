# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # An object type's rule, and what its fields, resolvers and arguments declare under it.
        class TypeRules
          def initialize(adapter = Adapters::Null.new, findings = Findings.new, foreign_policies = ForeignPolicies.new(adapter, findings))
            @adapter = adapter
            @findings = findings
            @foreign_policies = foreign_policies
          end

          def call(type)
            path = type.graphql_name
            unless type.respond_to?(:armory_rule)
              @findings.problem(:unprotected, path, "its base class does not include GraphQL::Armory::Authorization::Base, so it is open")
              return
            end

            rule = type.armory_rule
            if rule.nil?
              @findings.problem(:no_rule, path, "has no rule and no default_action, so it is denied")
            elsif rule.visible_when && (answer = graphql_ruby_answer(type, :visible?))
              @findings.problem(:ignored_rule, path, "graphql-ruby's #{answer} answers visible? here, so visible_when: never runs: remove it")
            elsif rule.none?
              @findings.bypass(path, rule.reason)
              audit_fields(type, model: nil, bypassed: !rule.covers_fields?, reported: Set.new)
              @foreign_policies.(type, rule.policy) if rule.policy
            elsif (answer = graphql_ruby_answer(type, :authorized?))
              @findings.problem(:ignored_rule, path, "graphql-ruby's #{answer} answers authorized? here, so this rule never runs: " \
                                                     "put the rule on the field that returns it (on a root field, on a resolver: a field rule asks " \
                                                     "the parent's policy), and declare `authorize :none, reason: \"...\", covers_fields: true` on this class")
            else
              model = model_of(type, path)
              reported = Set.new
              check(path, model, rule, reported) if model
              check(path, model, Rule.new(rule.visible_when, policy: rule.policy), reported) if model && rule.visible_when
              @foreign_policies.(type, rule.policy) if rule.policy
              audit_fields(type, model: model, bypassed: false, reported: reported)
            end
          end

          private

          # ConnectionBehaviors and EdgeBehaviors, included after Base, bring an `authorized?` and a `visible?` that win
          # over the plugin's. An app's method may call super, so this follows the chain to the first library that answers.
          def graphql_ruby_answer(type, name)
            method = type.method(name)
            until method.nil? || method.owner == Integration::Object
              return method.owner if LibraryMethods.library_method?(method, LibraryMethods.holder_of(type, method), GRAPHQL_RUBY_PATH)

              method = method.super_method
            end
          end

          # A field an implementer inherits from an interface is reported on the interface.
          def interface_field?(field)
            field.owner.respond_to?(:kind) && field.owner.kind.interface?
          end

          def model_of(type, path)
            type.armory_model
          rescue ConfigurationError => error
            @findings.problem(:model, path, error.message)
            nil
          end

          # An adapter problem shows once per type, however many fields declare an action of their own.
          def check(path, model, rule, reported)
            @adapter.check(model, rule).each do |message|
              @findings.problem(:adapter, path, message) if reported.add?(message)
            end
          end

          # Every definition, the shadowed ones included: a hidden override falls back to them, so they serve requests too.
          # Nothing here loads a field's type, so a shadowed field whose type cannot load raises nothing.
          def audit_fields(type, model:, bypassed:, reported:)
            Definitions.fields_at_every_level(type).each do |field|
              audit_field(type, field, "#{type.graphql_name}.#{field.original_name}", model: model, bypassed: bypassed, reported: reported)
            end
          end

          def audit_field(type, field, path, model:, bypassed:, reported:)
            # An inherited interface field is reported as uncovered on its interface; every other check still runs here.
            inherited = bypassed && interface_field?(field)
            if bypassed && !inherited && !field.respond_to?(:armory_declared)
              return @findings.problem(:field_without_rule, path, "its field class does not include Base, so no rule runs on it: its type is bypassed and graphql-ruby's own " \
                                                                  "authorized? answers true, so the field is served with no check. Use a field class that includes Base")
            end
            return unless field.respond_to?(:armory_declared)
            return audit_resolver(field, path) if field.resolver.respond_to?(:armory_rule)

            audit_declaration(type, field, path, model: model, bypassed: bypassed && !inherited, reported: reported)
            audit_visibility(field, path, model: model, reported: reported)
            audit_loads(field, path)
            audit_arguments(field, path, reported: reported)
          end

          # A resolver or mutation carries its own rule: no rule is denied, `:none` is listed, an action is checked.
          def audit_resolver(field, path)
            resolver = field.resolver
            rule = resolver.armory_rule
            @foreign_policies.arguments(field.all_argument_definitions, path, rule.policy, Set.new) if rule&.policy
            return @findings.problem(:no_rule, path, "its mutation or resolver declares no `authorize`, so it is denied") if rule.nil?
            return @findings.bypass(path, rule.reason) if rule.none?

            model = begin
              resolver.armory_model
            rescue ConfigurationError => error
              return @findings.problem(:model, path, error.message)
            end
            check(path, model, rule, Set.new)
          end

          # The action a field is hidden with is asked of the policy like any other, so it must exist.
          def audit_visibility(field, path, model:, reported:)
            return unless model && field.armory_visible_when

            check(path.split(".").first, model, Rule.new(field.armory_visible_when, policy: field.armory_policy, attribute: field.original_name), reported)
          end

          def audit_declaration(type, field, path, model:, bypassed:, reported:)
            case (declared = field.armory_declared)
            when :none
              @findings.bypass(path, field.armory_reason)
            when nil, true
              if bypassed && declared.nil? && served_by_owner?(type, field)
                @findings.problem(:field_without_rule, path, "declares no rule and its type is bypassed, but it is inherited from #{field.owner.name || field.owner.inspect}: a field runs " \
                                                             "under the class that defines it, and no rule ran on this type, so the field is served with no check. Give it authorize: where it is defined, or remove it")
              elsif bypassed
                @findings.problem(:field_without_rule, path, "declares no rule and its type is bypassed, so it is denied")
              end
            else
              check(path.split(".").first, model, Rule.new(declared, policy: field.armory_policy), reported) if model
            end
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
          def audit_arguments(field, path, reported:)
            field.all_argument_definitions.each do |argument|
              next unless argument.respond_to?(:armory_declared)

              apath = "#{path}(#{argument.keyword})"
              declared = argument.armory_declared
              @findings.bypass(apath, argument.armory_reason) if declared == :none
              [declared, argument.armory_visible_when].compact.reject { |action| action == :none }.each do |action|
                audit_argument_action(argument, apath, action, reported)
              end
            end
          end

          def audit_argument_action(argument, path, action, reported)
            check(path.split(".").first, argument.armory_model, Rule.new(action, policy: argument.armory_policy, attribute: argument.keyword), reported)
          rescue ConfigurationError => error
            @findings.problem(:model, path, error.message)
          end

          def audit_loads(field, path)
            return if field.armory_load_through_scope?

            opted_out_loads(field.all_argument_definitions, Set.new).each do |name|
              @findings.problem(:unscoped_load, "#{path}(#{name})", "loads through the app's object_from_id, not through the user's scope")
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
        end
      end
    end
  end
end
