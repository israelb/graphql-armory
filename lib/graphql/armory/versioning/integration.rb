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

        # What every versioned member keeps: its lifecycle, built from `added:` and `removed:`, which it strips before `super`.
        module Member
          def initialize(*args, added: nil, removed: nil, **kwargs, &block)
            begin
              @armory_lifecycle = Lifecycle.build(added: added, removed: removed)
            rescue ConfigurationError => error
              raise error.class, "#{kwargs[:name] || args.first}: #{error.message}"
            end
            super(*args, **kwargs, &block)
          end

          # When the member lives, for the audit and for tooling.
          attr_reader :armory_lifecycle

          private

          def armory_versioned? = !Lifecycle::EVERYWHERE.equal?(@armory_lifecycle)
        end

        # Included in a field class by `include GraphQL::Armory::Versioning::Base`.
        #
        #   field :total, Integer, null: false, added: "2024-06-01"     # from 2024-06-01 on
        #   field :amount, Integer, null: false, removed: "2025-01-01"  # up to 2024-06-01
        module Field
          include Member

          def visible?(context)
            super && @armory_lifecycle.covers?(Integration.version(context))
          rescue ConfigurationError => error
            raise error.class, "#{owner.graphql_name}.#{graphql_name}: #{error.message}"
          end
        end

        # Included in an argument class: arguments of fields, input-object fields and arguments of executable directives.
        #
        #   argument :first, Integer, required: false, added: "2025-01-01"
        #
        # When it is asked, it also refuses what graphql-ruby would serve outside the version anyway: a default value naming a
        # member the version does not have, a versioned argument shadowing a parent's of the same name, and, on a directive
        # used in the SDL, a lifecycle or a type with versioned members.
        module Argument
          include Member

          # Where graphql-ruby runs a directive while executing a query. Any other location is the schema's own (SDL), where
          # applied arguments are printed as the latest version sees them, without asking `visible?`.
          EXECUTABLE = %i[QUERY MUTATION SUBSCRIPTION FIELD FRAGMENT_DEFINITION FRAGMENT_SPREAD INLINE_FRAGMENT VARIABLE_DEFINITION].freeze

          def visible?(context)
            return false unless super

            armory_refuse_on_schema_directive if owner.is_a?(Class) && owner < GraphQL::Schema::Directive
            in_default = armory_default_members
            return true if !armory_versioned? && in_default.empty?

            version = Integration.version(context)
            return false unless @armory_lifecycle.covers?(version)

            # Each entry lists the definitions the default may mean (an enum value renamed across versions keeps its Ruby value).
            missing = in_default.reject { |choices| choices.any? { |member| member.armory_lifecycle.covers?(version) } }
            return true if missing.empty?

            raise ConfigurationError, "its default_value names #{missing.map { |choices| choices.first.path }.join(', ')}, not in " \
                                      "#{Integration.label(version)}: introspection would print it and the field would run without it. " \
                                      "Use a default every version of this argument has"
          rescue ConfigurationError => error
            raise error.class, "#{path}: #{error.message}"
          end

          private

          # The versioned members the default value names, found once, after the check that refuses a shadowing definition.
          def armory_default_members
            return @armory_default_members if defined?(@armory_default_members)

            Integration.refuse_shadowing(self, armory_inherited_arguments) if armory_versioned?
            @armory_default_members = default_value? ? Integration.members_in(type, default_value).freeze : [].freeze
          end

          def armory_inherited_arguments
            sources = []
            sources << owner.resolver if owner.is_a?(GraphQL::Schema::Field) && owner.resolver
            sources << owner.superclass if owner.is_a?(Class) && owner.superclass.respond_to?(:all_argument_definitions)
            sources.flat_map(&:all_argument_definitions)
          end

          # Asked every time, not remembered: a subclass defined later may add a location, and an argument's owner is the
          # class that declared it, so the subclasses' locations count too.
          def armory_refuse_on_schema_directive
            schema_locations = Integration.directive_locations(owner) - EXECUTABLE
            return if schema_locations.empty?

            where = "is on a directive used in the SDL (#{schema_locations.join(', ')}), which prints applied arguments as the latest version sees them"
            raise ConfigurationError, "#{where}: it cannot have a lifecycle" if armory_versioned?

            reached = Integration.versioned_members_of(type)
            return if reached.empty?

            raise ConfigurationError, "#{where}: its type cannot reach versioned members (#{reached.first(3).map(&:path).join(', ')})"
          end
        end

        # Included in an enum value class.
        #
        #   value "VOID", added: "2024-06-01"
        module EnumValue
          include Member

          def visible?(context)
            return false unless super
            return true unless armory_versioned?

            unless defined?(@armory_checked)
              parent = owner.superclass
              Integration.refuse_shadowing(self, parent.respond_to?(:all_enum_value_definitions) ? parent.all_enum_value_definitions : [])
              @armory_checked = true
            end
            @armory_lifecycle.covers?(Integration.version(context))
          rescue ConfigurationError => error
            raise error.class, "#{path}: #{error.message}"
          end
        end

        # graphql-ruby serves a parent's definition of a name when the local one is hidden (enum values on every path,
        # arguments under the legacy Warden), so a versioned member must not shadow one.
        def self.refuse_shadowing(member, inherited)
          shadowed = inherited.find { |other| !other.equal?(member) && other.graphql_name == member.graphql_name }
          return unless shadowed

          raise ConfigurationError, "shadows #{shadowed.path}, so graphql-ruby would serve that one in the versions where this " \
                                    "one is hidden. Version the parent's definition, or give this one another name"
        end

        # The members with a lifecycle that a Ruby default value names, through lists and nested input objects, as a list of
        # choices: the default is fine in a version where any definition of a choice lives. A choice with a definition that
        # lives everywhere is left out.
        def self.members_in(type, value, found = [])
          return found if value.nil?
          return members_in(type.of_type, value, found) if type.non_null?

          if type.list?
            (value.is_a?(Array) ? value : [value]).each { |item| members_in(type.of_type, item, found) }
          elsif type.kind.enum?
            choices = type.all_enum_value_definitions.select { |defn| defn.value == value || defn.graphql_name == value.to_s }
            found << choices if !choices.empty? && choices.all? { |defn| versioned?(defn) }
          elsif type.kind.input_object? && value.respond_to?(:each_pair)
            value.each_pair do |key, item|
              argument = input_field(type, key.to_s)
              next unless argument

              found << [argument] if versioned?(argument)
              members_in(argument.type, item, found)
            end
          end
          found
        end

        # graphql-ruby accepts a default's key as the field's GraphQL name, its keyword (`as:`) or its underscored name.
        def self.input_field(type, key)
          camelized = GraphQL::Schema::Member::BuildType.camelize(key)
          type.all_argument_definitions.find do |defn|
            defn.graphql_name == key || defn.graphql_name == camelized || defn.keyword.to_s == key
          end
        end

        # Every versioned enum value and input field a type can reach, through lists and nested input objects.
        def self.versioned_members_of(type, seen = {}.compare_by_identity)
          type = type.unwrap
          return [] if seen.key?(type)

          seen[type] = true
          if type.kind.enum?
            type.all_enum_value_definitions.select { |defn| versioned?(defn) }
          elsif type.kind.input_object?
            type.all_argument_definitions.flat_map { |defn| (versioned?(defn) ? [defn] : []) + versioned_members_of(defn.type, seen) }
          else
            []
          end
        end

        # A directive's locations and those of every subclass, since an inherited argument's owner is the parent.
        def self.directive_locations(directive)
          directive.subclasses.reduce(directive.locations) { |locations, subclass| locations | directive_locations(subclass) }
        end

        def self.versioned?(member)
          member.respond_to?(:armory_lifecycle) && !Lifecycle::EVERYWHERE.equal?(member.armory_lifecycle)
        end

        def self.label(version)
          Version::LATEST.equal?(version) ? "the latest version" : version.label
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

      # Goes in your base field, argument and enum value classes. Types and their memberships come in a later version.
      #
      #   class Types::BaseField < GraphQL::Schema::Field
      #     include GraphQL::Armory::Versioning::Base
      #     argument_class Types::BaseArgument
      #   end
      #   class Types::BaseArgument < GraphQL::Schema::Argument;  include GraphQL::Armory::Versioning::Base; end
      #   class Types::BaseEnumValue < GraphQL::Schema::EnumValue; include GraphQL::Armory::Versioning::Base; end
      module Base
        KINDS = { GraphQL::Schema::Field => :Field, GraphQL::Schema::Argument => :Argument, GraphQL::Schema::EnumValue => :EnumValue }.freeze

        def self.included(base)
          kind = base.is_a?(Class) && KINDS.find { |parent, _| base <= parent }&.last
          unless kind
            raise ArgumentError, "GraphQL::Armory::Versioning::Base goes in a field, argument or enum value class for now, not #{base}: " \
                                 "versioning types and their memberships is not supported yet"
          end

          base.include(Integration.const_get(kind))
        end
      end
    end
  end
end
