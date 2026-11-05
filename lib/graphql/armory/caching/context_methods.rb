# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # The public methods an app's context class adds to `GraphQL::Query::Context`. The recorder sees reads through the
      # context's own methods only; an added method such as `def current_user = @provided_values[:current_user]` reads
      # the provided Hash without being recorded (docs/response-caching.md, limit 2). So the installer refuses every
      # added method the app did not declare in `context_methods:` with a reason.
      #
      #   ContextMethods.added(AppContext)                                   # => [:current_user, :tenant]
      #   ContextMethods.undeclared(AppContext, { tenant: "reads Current" }) # => [:current_user]
      #
      # Counted: public instance methods defined by the classes and modules between `GraphQL::Query::Context` and the
      # given class (wrappers built by `Recorder::Context.wrap` excluded) that `GraphQL::Query::Context` does not
      # define publicly, plus `method_missing` whatever its visibility, since it answers any name. Overrides of
      # graphql-ruby's own methods are not counted: the wrapper records them when they call `super`, and the audit
      # reports those that do not.
      module ContextMethods
        BASE = GraphQL::Query::Context
        DYNAMIC = :method_missing

        module_function

        def added(klass)
          raise ArgumentError, "expected a GraphQL::Query::Context subclass, got #{klass.inspect}" unless klass.is_a?(Class) && klass <= BASE

          owners = klass.ancestors.take_while { |owner| !owner.equal?(BASE) }.reject { |owner| own?(owner) }
          names = owners.flat_map do |owner|
            dynamic = owner.private_instance_methods(false).include?(DYNAMIC) ? [DYNAMIC] : []
            owner.public_instance_methods(false) + dynamic
          end
          names.uniq.reject { |name| name != DYNAMIC && BASE.public_method_defined?(name) }.sort
        end

        # The added methods not named in `declared` (a Hash of name => reason, or a list of names).
        def undeclared(klass, declared)
          names = (declared.respond_to?(:keys) ? declared.keys : Array(declared)).map(&:to_sym)
          added(klass) - names
        end

        def own?(owner)
          Recorder::Context.wrapper?(owner) || owner.equal?(Recorder::Context::Wrapped)
        end
        private_class_method :own?
      end
    end
  end
end
