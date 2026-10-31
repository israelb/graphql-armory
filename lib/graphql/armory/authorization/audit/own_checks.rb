# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # A method an app defines wins over what the plugin and graphql-ruby decide: `authorized?` and `authorizes?`
        # can skip a rule, and graphql-ruby calls `unauthorized_object` on whatever loads a record, so returning the
        # object runs the code on a refused record. The audit cannot read them: each is reported once, where it is
        # defined, until it is declared. Methods that come from graphql-ruby or from this gem are not the app's.
        class OwnChecks
          def self.call(schema, definitions, findings)
            new(definitions, findings).(schema.armory_configuration.own_checks)
          end

          def initialize(definitions = [], findings = Findings.new)
            @definitions = definitions
            @findings = findings
            @found = {}
          end

          def call(declared)
            @definitions.each do |type|
              next unless type.kind.object? && !type.introspection? && type.respond_to?(:armory_rule)

              %i[authorized? authorizes? authorized_new wrap].each { |name| note_class_check(type, name) }
              note_class_check(type, :visible?) if type.armory_rule&.visible_when
              Definitions.fields_at_every_level(type).each { |field| note_field_checks(field) }
            end
            @definitions.each do |type|
              next if type.introspection? || !type.respond_to?(:scope_items) || !(type.kind.object? || type.kind.interface? || type.kind.union?)

              note_class_check(type, :scope_items)
              note_reauthorization(type)
            end
            @definitions.each do |type|
              next unless type.kind.input_object? && !type.introspection?

              %i[authorized? unauthorized_object].each { |name| note_class_check(type, name) }
              note_argument_checks(type.all_argument_definitions)
            end
            report(declared)
          end

          private

          def note_field_checks(field)
            %i[authorized? authorizes? unauthorized_object].each { |name| note_instance_check(field.class, name) }
            note_visibility_check(field)
            note_argument_checks(field.all_argument_definitions)
            resolver = field.resolver
            return unless resolver

            note_instance_check(resolver, :unauthorized_object)
            note_class_check(resolver, :authorizes?)
            note_instance_check(resolver, :authorized?) if resolver.respond_to?(:armory_rule)
          end

          def note_argument_checks(arguments)
            arguments.each do |argument|
              note_instance_check(argument.class, :authorized?)
              note_visibility_check(argument)
            end
          end

          # Off, records that came through the scope skip `authorized?`: harmless only if the scope is as strict as the rule.
          # The interpreter asks the field's return type, Execution::Next the resolved object, and each path differs, so it
          # is reported wherever it is off, without judging whether it skips anything: declaring it takes one line.
          def note_reauthorization(type)
            readers = type.is_a?(Class) ? [type] : type.ancestors.select { |ancestor| ancestor.respond_to?(:reauthorize_scoped_objects, true) }
            readers.each { |reader| note_class_check(reader, :reauthorize_scoped_objects) }

            setter = reauthorization_setter(type)
            @found[[setter, :reauthorize_scoped_objects]] = "#{setter.name || setter.inspect}.reauthorize_scoped_objects" if setter&.instance_variable_get(:@reauthorize_scoped_objects) == false
          end

          # The nearest that set the value, read from the classes so no method of the app runs: graphql-ruby's reader follows
          # superclasses, not the interfaces a class implements. A connection reads only its own, then its node's, which
          # `Definitions` reaches and the audit reads as a type of its own.
          def reauthorization_setter(type)
            return type if Definitions.connection?(type)

            chain = type.is_a?(Class) ? type.ancestors.grep(Class) : type.ancestors
            chain.find { |ancestor| !ancestor.instance_variable_get(:@reauthorize_scoped_objects).nil? }
          end

          # Apps define `visible?` for their own reasons: it only matters where a `visible_when:` depends on it.
          def note_visibility_check(member)
            note_instance_check(member.class, :visible?) if member.respond_to?(:armory_visible_when) && member.armory_visible_when
          end

          def note_instance_check(klass, name)
            return unless klass.method_defined?(name) || klass.private_method_defined?(name)

            note_own_check(klass, klass.instance_method(name), name, "#")
          end

          def note_class_check(klass, name)
            return unless klass.respond_to?(name, true)

            note_own_check(klass, klass.method(name), name, ".")
          end

          # Follows the whole chain: a method that only calls super must not hide one below it that answers true.
          def note_own_check(klass, method, name, separator)
            while method
              holder = LibraryMethods.holder_of(klass, method)
              @found[[holder, name]] = "#{holder.name || holder.inspect}#{separator}#{name}" unless LibraryMethods.library_method?(method, holder, GRAPHQL_RUBY_PATH, ARMORY_PATH)
              method = method.super_method
            end
          end

          def report(declared)
            @found.each do |(holder, name), path|
              reason = declared.fetch(holder, {})[name]
              next @findings.bypass(path, reason) if reason

              @findings.problem(:own_check, path, "#{risk(name)}. Remove it, or declare it in own_checks: with a reason")
            end
            declared.each do |holder, methods|
              methods.each_key do |name|
                next if @found.key?([holder, name])

                @findings.problem(:own_check, "#{holder.name || holder.inspect} #{name}", "named in own_checks: but no check of the schema is defined there: remove it from the option")
              end
            end
          end

          def risk(name)
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
        end
      end
    end
  end
end
