# frozen_string_literal: true

module GraphQL
  module Armory
    module Versioning
      # Translates graphql-ruby's hooks: `query_class` to decide each query's version, `visible?` to answer from it.
      module Integration
        PARTIAL = defined?(GraphQL::Query::Partial) ? GraphQL::Query::Partial : nil

        # The Version a context sees, for `visible?`:
        #
        # - `NullContext` (graphql-ruby asking with no query): the latest version.
        # - A query's context: the version `Lookup` stored for it. A second context graphql-ruby builds for a query
        #   (`Visibility::Migration`'s) and a `Query::Partial`'s see that query's version. A `GraphQL::Query` the app built
        #   itself is decided once from its own `armory_version`, recording nothing.
        # - Anything else, such as the frozen Hash of a named `Schema::Visibility` profile: refused, fail closed.
        def self.version(context)
          return Version::LATEST if context.is_a?(GraphQL::Query::NullContext)

          unless context.respond_to?(:namespace)
            raise ConfigurationError, "versioned members need a query's context, got a #{context.class}: named Schema::Visibility profiles " \
                                      "(profiles:) are not supported by Versioning yet, use dynamic: true or no profiles"
          end

          store = context.namespace(:armory)
          store.fetch(:version) do
            refusal = store[:version_refusal]
            raise refusal.error if refusal

            store[:version] = undecided(context)
          end
        end

        def self.undecided(context)
          query = context.query
          # `Visibility::Migration` builds a second context for the same query; a Partial reads its parent's schema.
          return version(query.context) if query.respond_to?(:context) && !query.context.equal?(context)
          return version(query.query.context) if PARTIAL && query.is_a?(PARTIAL)

          decision = gate(context.schema).resolve(context[:armory_version])
          raise decision.error if decision.refused?

          decision.version
        end
        private_class_method :undecided

        def self.gate(schema)
          return schema.armory_versioning if schema.respond_to?(:armory_versioning)

          raise ConfigurationError, "#{schema} has versioned members but never installed the plugin: add `use GraphQL::Armory::Versioning, versions: ..., default: ...`"
        end

        # `Schema::AlwaysVisible` answers every `visible?` with true, so nothing would be versioned.
        def self.refuse_always_visible(schema)
          return unless schema.is_a?(GraphQL::Schema::AlwaysVisible)

          raise ConfigurationError, "#{schema} uses GraphQL::Schema::AlwaysVisible, which never asks visible?: nothing would be versioned. Remove it"
        end

        # Included in a field class by `include GraphQL::Armory::Versioning::Base`.
        #
        #   field :total, Integer, null: false, added: "2024-06-01"     # from 2024-06-01 on
        #   field :amount, Integer, null: false, removed: "2025-01-01"  # up to 2024-06-01
        module Field
          def initialize(*args, added: nil, removed: nil, **kwargs, &block)
            begin
              @armory_lifecycle = Lifecycle.build(added: added, removed: removed)
            rescue ConfigurationError => error
              raise ConfigurationError, "#{kwargs[:name]}: #{error.message}"
            end
            super(*args, **kwargs, &block)
          end

          # When the field lives, for the audit and for tooling.
          attr_reader :armory_lifecycle

          def visible?(context)
            super && @armory_lifecycle.covers?(Integration.version(context))
          rescue ConfigurationError => error
            raise ConfigurationError, "#{owner.graphql_name}.#{graphql_name}: #{error.message}"
          end
        end

        # Keeps the lookup in every query class the schema uses, including one set after `use` or by a child schema.
        module Guard
          UNSET = Object.new.freeze

          def query_class(new_query_class = UNSET)
            return super() if UNSET.equal?(new_query_class)
            return super(new_query_class) if new_query_class.include?(Lookup)

            super(Class.new(new_query_class) { include Lookup })
          end

          def armory_versioning
            @armory_versioning || superclass.armory_versioning
          end
        end

        # Decides the query's version after the query is built, from its own context, so a version set by a custom
        # `context_class` is seen. A refused query fails validation with the refusal as its only error, through the
        # public `validate=` and `static_validator=` setters, so neither engine runs anything, even with `validate: false`.
        module Lookup
          def initialize(schema, query_string = nil, **options)
            Integration.refuse_always_visible(schema)
            super

            decision = schema.armory_versioning.(context)
            store = context.namespace(:armory)
            return store[:version] = decision.version unless decision.refused?

            store[:version_refusal] = decision
            # A PersistedQueries refusal already runs nothing: its code stands. Any other validator is replaced.
            @armory_refusal = static_validator.is_a?(PersistedQueries::Refusal) ? static_validator : Refusal.new(schema, decision)
            self.validate = true
            self.static_validator = @armory_refusal
          end

          # A refused query keeps refusing: code that sets these after the query is built cannot turn the refusal off.
          # Execution::Next skips validation when `validate` is false.
          def validate=(value)
            super(@armory_refusal ? true : value)
          end

          def static_validator=(validator)
            super(@armory_refusal || validator)
          end
        end

        # A validation error with its code.
        class RefusalError < GraphQL::StaticValidation::Error
          def initialize(decision)
            super(decision.message)
            @code = decision.code
          end

          def to_h
            super.merge("extensions" => { "code" => @code })
          end
        end

        # Validates nothing and answers the refusal, through the query's public `static_validator`.
        class Refusal < GraphQL::StaticValidation::Validator
          def initialize(schema, decision)
            super(schema: schema)
            @decision = decision
          end

          def validate(_query, **)
            { errors: [RefusalError.new(@decision)], remaining_timeout: nil }
          end
        end
      end

      # Goes in your base field class. Arguments, enum values and types come in later versions of the gem.
      #
      #   class Types::BaseField < GraphQL::Schema::Field
      #     include GraphQL::Armory::Versioning::Base
      #   end
      module Base
        def self.included(base)
          unless base.is_a?(Class) && base <= GraphQL::Schema::Field
            raise ArgumentError, "GraphQL::Armory::Versioning::Base goes in a field class (a GraphQL::Schema::Field subclass) for now, not #{base}: " \
                                 "versioning arguments, enum values and types is not supported yet"
          end

          base.include(Integration::Field)
        end
      end
    end
  end
end
