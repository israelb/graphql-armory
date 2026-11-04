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
            loaded = armory_loaded_lifecycle
            return true if !armory_versioned? && in_default.empty? && loaded.nil?

            version = Integration.version(context)
            return false unless @armory_lifecycle.covers?(version)
            # A `loads:` argument takes an ID, so graphql-ruby never hides it with the loaded type: it is hidden here.
            return false if loaded && !loaded.covers?(version)

            # Each entry lists the definitions the default may mean (an enum value renamed across versions keeps its Ruby value).
            missing = in_default.reject { |choices| choices.any? { |member| Integration.covers?(member, version) } }
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

          def armory_loaded_lifecycle
            return @armory_loaded_lifecycle if defined?(@armory_loaded_lifecycle)

            lifecycle = loads && Integration.lifecycle_of(loads)
            @armory_loaded_lifecycle = lifecycle && !Lifecycle::EVERYWHERE.equal?(lifecycle) ? lifecycle : nil
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

        # Extended into a type class (object, input object, enum, scalar, union, resolver or mutation) and included into an
        # interface's definition methods by `include GraphQL::Armory::Versioning::Base`.
        #
        #   class Types::Contract < Types::BaseObject
        #     lifecycle added: "2025-01-01"
        #   end
        #
        # A class without its own lifecycle takes its mutation's (a generated payload or input type) or its superclass's.
        # An interface takes nothing from the interfaces it includes, and objects take nothing from their interfaces.
        module Type
          def lifecycle(added: nil, removed: nil)
            @armory_lifecycle = Lifecycle.build(added: added, removed: removed)
          rescue ConfigurationError => error
            raise error.class, "#{graphql_name}: #{error.message}"
          end

          # When the type lives, for the audit and for tooling.
          def armory_lifecycle
            return @armory_lifecycle if defined?(@armory_lifecycle)

            source = Integration.lifecycle_source(self)
            source ? source.armory_lifecycle : Lifecycle::EVERYWHERE
          end

          def visible?(context)
            return false unless super

            lifecycle = armory_lifecycle
            return true if Lifecycle::EVERYWHERE.equal?(lifecycle)

            version = Integration.version(context)
            return false unless lifecycle.covers?(version)

            Integration.refuse_wider_than_parent(self, version)
            true
          rescue ConfigurationError => error
            raise error.class, "#{graphql_name}: #{error.message}"
          end
        end

        # `implements` with `added:` or `removed:` is refused until memberships can carry a lifecycle: graphql-ruby would
        # accept the keywords and ignore them.
        module Implements
          def implements(*interfaces, added: nil, removed: nil, **options)
            Integration.refuse_membership_lifecycle(self, :implements, added, removed)
            super(*interfaces, **options)
          end
        end

        # The same for a union's `possible_types`.
        module Members
          def possible_types(*types, added: nil, removed: nil, **options)
            Integration.refuse_membership_lifecycle(self, :possible_types, added, removed)
            super(*types, **options)
          end
        end

        def self.refuse_membership_lifecycle(type, method, added, removed)
          return if added.nil? && removed.nil?

          raise ConfigurationError, "#{type.graphql_name}: `#{method}` with added: or removed: is not supported yet, and graphql-ruby would " \
                                    "ignore it. Give the member type its own `lifecycle` instead"
        end

        # The class a type without its own lifecycle takes it from: its mutation (a generated payload or input type), else its
        # superclass. Modules (interfaces) take it from nothing.
        def self.lifecycle_source(type)
          return unless type.is_a?(Class)

          mutation = type.mutation if type.respond_to?(:mutation)
          return mutation if mutation.is_a?(Class) && !mutation.equal?(type) && mutation.respond_to?(:armory_lifecycle)

          parent = type.superclass
          parent if parent.respond_to?(:armory_lifecycle)
        end

        # A subclass with its own lifecycle must not live where its versioned parent does not: the legacy Warden checks the
        # parent's visibility for the memberships the subclass inherits.
        def self.refuse_wider_than_parent(type, version)
          return unless type.is_a?(Class) && type.instance_variable_defined?(:@armory_lifecycle)

          parent = type.superclass
          return unless parent.respond_to?(:armory_lifecycle) && !parent.armory_lifecycle.covers?(version)

          raise ConfigurationError, "lives in #{label(version)} but its parent #{parent.graphql_name} does not: a subclass's lifecycle must " \
                                    "fit inside its parent's"
        end

        # Checked when the first query of a schema is built, and by `Versioning.types`: graphql-ruby answers these without
        # asking `visible?` with the query's context.
        def self.check_schema(schema)
          return if schema.instance_variable_defined?(:@armory_schema_checked)

          [schema.query, schema.mutation, schema.subscription].compact.each do |root|
            next unless versioned_type?(root)

            raise ConfigurationError, "#{root.graphql_name}: a root type cannot have a lifecycle: a version without it would have no " \
                                      "#{root.graphql_name} root. Version its fields instead"
          end
          schema.extra_types.each do |type|
            next unless versioned_type?(type)

            raise ConfigurationError, "#{type.graphql_name}: a type with a lifecycle cannot be in extra_types: `__type` and the SDL " \
                                      "read extra_types without asking visible?"
          end
          schema.instance_variable_set(:@armory_schema_checked, true)
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

        # Every versioned type, enum value and input field a type can reach, through lists and nested input objects.
        def self.versioned_members_of(type, seen = {}.compare_by_identity)
          type = type.unwrap
          return [] if seen.key?(type)

          seen[type] = true
          own = versioned_type?(type) ? [type] : []
          if type.kind.enum?
            own + type.all_enum_value_definitions.select { |defn| versioned?(defn) }
          elsif type.kind.input_object?
            own + type.all_argument_definitions.flat_map { |defn| (versioned?(defn) ? [defn] : []) + versioned_members_of(defn.type, seen) }
          else
            own
          end
        end

        # A directive's locations and those of every subclass, since an inherited argument's owner is the parent.
        def self.directive_locations(directive)
          directive.subclasses.reduce(directive.locations) { |locations, subclass| locations | directive_locations(subclass) }
        end

        def self.lifecycle_of(member)
          member.respond_to?(:armory_lifecycle) ? member.armory_lifecycle : Lifecycle::EVERYWHERE
        end

        def self.versioned_type?(type) = !Lifecycle::EVERYWHERE.equal?(lifecycle_of(type))

        # A member is versioned by its own lifecycle, or, for an argument or input field, by its type's.
        def self.versioned?(member)
          versioned_type?(member) || (member.is_a?(GraphQL::Schema::Argument) && versioned_type?(member.type.unwrap))
        end

        def self.covers?(member, version)
          return false unless lifecycle_of(member).covers?(version)

          !member.is_a?(GraphQL::Schema::Argument) || lifecycle_of(member.type.unwrap).covers?(version)
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
            Integration.check_schema(schema)
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

      # Goes in your base classes: fields, arguments, enum values, objects, interfaces (after `include
      # GraphQL::Schema::Interface`), unions, enums, scalars, input objects, resolvers and mutations.
      #
      #   class Types::BaseField < GraphQL::Schema::Field
      #     include GraphQL::Armory::Versioning::Base
      #     argument_class Types::BaseArgument
      #   end
      #   class Types::BaseObject < GraphQL::Schema::Object
      #     include GraphQL::Armory::Versioning::Base
      #     field_class Types::BaseField
      #   end
      #   module Types::BaseInterface
      #     include GraphQL::Schema::Interface
      #     include GraphQL::Armory::Versioning::Base
      #   end
      module Base
        # Instances (members) get `added:`/`removed:`; classes (types) get `lifecycle`.
        MEMBERS = { GraphQL::Schema::Field => :Field, GraphQL::Schema::Argument => :Argument, GraphQL::Schema::EnumValue => :EnumValue }.freeze
        TYPES = {
          GraphQL::Schema::Object => %i[Type Implements], GraphQL::Schema::Union => %i[Type Members],
          GraphQL::Schema::InputObject => %i[Type], GraphQL::Schema::Enum => %i[Type], GraphQL::Schema::Scalar => %i[Type],
          GraphQL::Schema::Resolver => %i[Type]
        }.freeze

        def self.included(base)
          if !base.is_a?(Class) && base.include?(GraphQL::Schema::Interface)
            modules = [Integration::Type, Integration::Implements]
            base.definition_methods { modules.each { |mod| include mod } }
          elsif base.is_a?(Class) && (member = MEMBERS.find { |parent, _| base <= parent })
            base.include(Integration.const_get(member.last))
          elsif base.is_a?(Class) && (type = TYPES.find { |parent, _| base <= parent })
            type.last.each { |name| base.extend(Integration.const_get(name)) }
          else
            raise ArgumentError, "GraphQL::Armory::Versioning::Base goes in a field, argument, enum value, object, interface, union, enum, " \
                                 "scalar, input object, resolver or mutation class, not #{base}. In an interface, include GraphQL::Schema::Interface first"
          end
        end
      end
    end
  end
end
