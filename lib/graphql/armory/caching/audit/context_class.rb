# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      class Audit
        # The recorder sees the context's reads through the methods it overrides. An app's context class that overrides
        # one of them without calling `super` hides its reads; a public method it adds can read the provided Hash directly.
        # Each added public method must be declared in `context_methods:` with a reason (the app's word), and is listed.
        #
        # Whether an override calls `super` is read from its compiled instructions (CRuby's
        # `RubyVM::InstructionSequence`). Where they cannot be read, the override is reported as one the audit cannot
        # clear.
        module ContextClass
          RECORDED = %i[[] fetch dig key? to_h to_hash namespace scoped_context []= delete scoped_merge! scoped_set!].freeze
          LIBRARY_PATHS = OwnChecks::LIBRARY_PATHS

          def self.call(schema, settings, findings)
            klass = schema.context_class
            app = klass.is_a?(Class) && klass < GraphQL::Query::Context ? app_ancestors(klass) : []
            RECORDED.each { |name| overrides(klass, name, findings) } unless app.empty?
            added(klass, app, settings, findings)
          end

          # The classes and modules between graphql-ruby's context and the schema's context class that are the app's: the
          # recording wrapper and this gem's own classes are not.
          def self.app_ancestors(klass)
            klass.ancestors.take_while { |ancestor| !ancestor.equal?(GraphQL::Query::Context) }.reject { |ancestor| library?(ancestor) }
          end

          def self.library?(mod)
            return true if mod.equal?(Recorder::Context::Wrapped)

            methods = mod.instance_methods(false) + mod.private_instance_methods(false)
            gem_named = mod.name&.start_with?("GraphQL::") == true || wrapper?(mod)
            gem_named && methods.all? { |name| library_method?(mod.instance_method(name), mod) }
          end

          # `Recorder::Context.wrap` answers an unnamed subclass that includes `Wrapped`.
          def self.wrapper?(mod)
            mod.is_a?(Class) && mod.name.nil? && mod.include?(Recorder::Context::Wrapped)
          end

          def self.library_method?(method, holder)
            file = method.source_location&.first
            return true if file.nil?

            Authorization::Audit::LibraryMethods.library_method?(method, holder, *LIBRARY_PATHS) ||
              (wrapper?(holder) && file.start_with?(Authorization::Audit::ARMORY_PATH))
          end

          def self.overrides(klass, name, findings)
            return unless klass.method_defined?(name) || klass.private_method_defined?(name)

            method = klass.instance_method(name)
            while method && !GraphQL::Query::Context.ancestors.include?(method.owner)
              unless library_method?(method, method.owner)
                case calls_super?(method)
                when false
                  findings.problem(:context_class, "#{label(method.owner)}##{name}", "overrides #{name} without calling super, so the recorder never sees " \
                                                                                     "its reads and a run that read an input the key does not hold is stored. Call super", at: method)
                when nil
                  findings.problem(:context_class, "#{label(method.owner)}##{name}", "overrides #{name}, and this Ruby cannot tell whether it calls super: " \
                                                                                     "if it does not, the recorder never sees its reads. Call super, or remove it", at: method)
                end
              end
              method = method.super_method
            end
          end

          # true or false, or nil when the instructions cannot be read.
          def self.calls_super?(method)
            return nil unless defined?(RubyVM::InstructionSequence)

            iseq = RubyVM::InstructionSequence.of(method)
            iseq && super_in?(iseq.to_a)
          rescue StandardError
            nil
          end

          def self.super_in?(node)
            case node
            when Array then node.any? { |each| super_in?(each) }
            when Symbol then node.start_with?("invokesuper")
            else false
            end
          end

          def self.added(klass, app, settings, findings)
            declared = settings.context_methods.to_h { |name, reason| [name.to_sym, reason] }
            # The gate's own rule, so the audit and the runtime never disagree on what counts.
            names = ContextMethods.added(klass)
            names.each do |name|
              method = klass.instance_method(name)
              if declared.key?(name)
                findings.declared(:context_method, "context_methods: #{name.inspect}", declared[name].to_s, at: method)
              else
                findings.problem(:context_class, "#{label(method.owner)}##{name}", "a public method of the app's context class, which can read the provided " \
                                                                                   "Hash without the recorder seeing it, so nothing is cached. Declare it in " \
                                                                                   "context_methods: with a reason, or make it private", at: method)
              end
            end
            (declared.keys - names).each do |name|
              findings.problem(:context_class, "context_methods: #{name.inspect}", "names no public method the app's context class adds: remove it from the option")
            end
          end

          def self.label(mod)
            mod.name || mod.inspect
          end

          private_class_method :app_ancestors, :library?, :wrapper?, :library_method?, :overrides, :calls_super?, :super_in?, :added, :label
        end
      end
    end
  end
end
