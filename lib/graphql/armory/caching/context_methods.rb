# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # The public methods an app adds to its query contexts. The recorder sees reads through the context's own methods
      # only; an added method such as `def current_user = @provided_values[:current_user]` reads the provided Hash
      # without being recorded (docs/response-caching.md "Inputs you must declare"). So a query whose context class
      # answers such a method the app did not declare in `context_methods:` with a reason runs uncached.
      #
      #   ContextMethods.added(AppContext)                                   # => [:current_user, :tenant]
      #   ContextMethods.undeclared(AppContext, { tenant: "reads Current" }) # => [:current_user]
      #
      # Counted: every public method the class answers, from the class itself, its ancestors up to
      # `GraphQL::Query::Context`, that class itself and every module prepended to or included in it, plus
      # `method_missing` whatever its visibility, since it answers any name. Not counted: a method whose code is
      # graphql-ruby's or this gem's (by its source file), and a name graphql-ruby's context answers when this gem
      # loads: the wrapper records those it reads through when they call `super`, and the audit reports those that do
      # not. A method reopened onto `GraphQL::Query::Context` itself, or added by a module prepended to it, counts
      # like one in the app's own class.
      module ContextMethods
        BASE = GraphQL::Query::Context
        DYNAMIC = :method_missing
        GRAPHQL_ROOT = File.dirname(BASE.instance_method(:query).source_location.first, 2).freeze
        ARMORY_ROOT = File.dirname(__FILE__, 2).freeze
        # graphql-ruby's own public context methods, taken when this gem loads, before any app code: some are defined
        # through Forwardable, whose source file is not graphql-ruby's. Object's methods are never the context's.
        GRAPHQL_NAMES = (BASE.public_instance_methods - Object.public_instance_methods).to_h { |name| [name, true] }.freeze

        module_function

        def added(klass)
          check(klass)
          names = owners(klass).flat_map do |owner|
            dynamic = owner.private_instance_methods(false).include?(DYNAMIC) ? [DYNAMIC] : []
            owner.public_instance_methods(false) + dynamic
          end
          names.uniq.reject { |name| recorded_name?(name) || graphql_name?(name) || trusted?(klass.instance_method(name)) }.sort
        end

        # The added methods not named in `declared` (a Hash of name => reason, or a list of names).
        def undeclared(klass, declared)
          names = (declared.respond_to?(:keys) ? declared.keys : Array(declared)).map(&:to_sym)
          added(klass) - names
        end

        # Changes when a method is added to the class or to any module it answers through, so a memo of `added`
        # keyed by it sees methods defined after the class's first query.
        def signature(klass)
          check(klass)
          owners(klass).map { |owner| [owner, owner.public_instance_methods(false).size, owner.private_method_defined?(DYNAMIC, false)] }
        end

        def owners(klass)
          (klass.ancestors - Object.ancestors).reject { |owner| own?(owner) }
        end

        # A name the recording wrapper overrides: it records the read before any app code under it runs.
        def recorded_name?(name)
          Recorder::Context.wrap(BASE).public_method_defined?(name, false)
        end

        # A name graphql-ruby itself defines publicly on the context (an override of it is the wrapper's to record, or
        # the audit's to report).
        def graphql_name?(name)
          GRAPHQL_NAMES.key?(name)
        end

        def trusted?(method)
          own?(method.owner) || from?(method, GRAPHQL_ROOT) || from?(method, ARMORY_ROOT)
        end

        def from?(method, root)
          file = method.source_location&.first
          !file.nil? && file.start_with?(root + File::SEPARATOR, root + "/")
        end

        def own?(owner)
          Recorder::Context.wrapper?(owner) || owner.equal?(Recorder::Context::Wrapped)
        end

        def check(klass)
          raise ArgumentError, "expected a GraphQL::Query::Context subclass, got #{klass.inspect}" unless klass.is_a?(Class) && klass <= BASE
        end
      end
    end
  end
end
