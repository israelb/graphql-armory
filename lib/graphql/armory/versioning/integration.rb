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
        # - The frozen Hash of a named `Schema::Visibility` profile built by `Versioning.profiles`: its version.
        # - Anything else, such as an app's own profile Hash: refused, fail closed.
        def self.version(context)
          return Version::LATEST if context.is_a?(GraphQL::Query::NullContext)
          return profile_version(context) unless context.respond_to?(:namespace)

          store = context.namespace(:armory)
          store.fetch(:version) do
            refusal = store[:version_refusal]
            raise refusal.error if refusal

            store[:version] = undecided(context)
          end
        end

        # A profile's Hash carries no schema: it carries the gate's own list instead, and a served label of it.
        def self.profile_version(context)
          versions = context.is_a?(Hash) ? context[:armory_versions] : nil
          unless versions.is_a?(Versions)
            named = context.is_a?(Hash) && context[:visibility_profile] ? " (visibility profile #{context[:visibility_profile].inspect})" : ""
            raise ConfigurationError, "versioned members need a query's context or a profile from Versioning.profiles, got a #{context.class}#{named}: " \
                                      "pass `profiles: GraphQL::Armory::Versioning.profiles(Schema)` to Schema::Visibility, with " \
                                      "`use GraphQL::Armory::Versioning, ..., profiles: true`, or use dynamic: true and no named profiles"
          end

          version = versions.fetch(context[:armory_version])
          raise ConfigurationError, "the visibility profile #{context[:visibility_profile].inspect} names #{version.label}, which is retired" if version.retired?

          version
        end
        private_class_method :profile_version

        def self.undecided(context)
          query = context.query
          # `Visibility::Migration` builds a second context for the same query; a Partial reads its parent's schema.
          return version(query.context) if query.respond_to?(:context) && !query.context.equal?(context)
          return version(query.query.context) if PARTIAL && query.is_a?(PARTIAL)

          # A query built without the schema's query class skipped `Lookup`, and with it the schema check.
          check_schema(context.schema)
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
          def initialize(*args, added: nil, removed: nil, deprecated: nil, **kwargs, &block)
            unless deprecated.nil?
              raise ConfigurationError, "#{kwargs[:name] || args.first}: deprecated: needs the class that defines it to include "                                         "GraphQL::Armory::Versioning::Base, which makes its two definitions"
            end
            begin
              @armory_lifecycle = Lifecycle.build(added: added, removed: removed)
            rescue ConfigurationError => error
              raise error.class, "#{kwargs[:name] || args.first}: #{error.message}"
            end
            late_bound = Integration.late_bound_name(kwargs.key?(:type) ? kwargs[:type] : args[1])
            super(*args, **kwargs, &block)
            Integration.mark_late_bound(self, late_bound) if late_bound
          end

          # When the member lives, for the audit and for tooling.
          attr_reader :armory_lifecycle

          # The definition before `deprecated:`'s version, when `deprecated:` wrote this one: the two are one member.
          def armory_deprecated_of = @armory_deprecated_of

          # The GraphQL names its type was given by, when it was a `LateBoundType`: the schema check refuses one that has
          # twins.
          def armory_late_bound = @armory_late_bound || []

          private

          def armory_versioned? = !Lifecycle::EVERYWHERE.equal?(@armory_lifecycle)

          # The other definitions of this name on the same owner, found once.
          def armory_twins
            @armory_twins ||= Integration.twins_of(self).freeze
          end
        end

        # Included in a field class by `include GraphQL::Armory::Versioning::Base`.
        #
        #   field :total, Integer, null: false, added: "2024-06-01"     # from 2024-06-01 on
        #   field :amount, Integer, null: false, removed: "2025-01-01"  # up to 2024-06-01
        module Field
          include Member
          include Deprecation::Arguments

          # A field also leaves with the type that declared it: an interface that includes a versioned interface would
          # otherwise keep that interface's fields where it does not live.
          # `type` given inside the field's block is recorded like the positional one.
          def type(*args)
            name = Integration.late_bound_name(args.first) unless args.empty?
            Integration.mark_late_bound(self, name) if name
            super
          end

          def visible?(context)
            Integration.refuse_twin_overlap(self, armory_twins, context, field: true)
            return false unless super

            version = Integration.version(context)
            @armory_lifecycle.covers?(version) && Integration.lifecycle_of(owner).covers?(version)
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
            Integration.refuse_twin_overlap(self, armory_twins, context)
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

            # graphql-ruby checks an object loaded as an interface or union against members asked with no context.
            if loads && loads.kind.abstract? && Integration.versioned_memberships?(loads)
              raise ConfigurationError, "it loads #{loads.graphql_name}, which has a membership with a lifecycle: graphql-ruby would load " \
                                        "an object that is not a member in the query's version. Load the object types instead"
            end

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
            Integration.refuse_twin_overlap(self, armory_twins, context)
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
            if added.nil? && removed.nil?
              raise ConfigurationError, "lifecycle needs added:, removed: or both; a type with neither lives in every version"
            end

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

            Integration.refuse_membership_conflicts(self)
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

        # Extended into object types. An argument that `loads:` an abstract type checks the loaded object's type against the
        # abstract type's members with no context, so an object of a type outside the version would load: it is not
        # authorized there, and the resolver never runs with it.
        module Authorized
          def authorized?(object, context)
            lifecycle = armory_lifecycle
            return super if Lifecycle::EVERYWHERE.equal?(lifecycle)

            lifecycle.covers?(Integration.version(context)) && super
          rescue ConfigurationError => error
            raise error.class, "#{graphql_name}: #{error.message}"
          end
        end

        # Included in a type membership class, which the app sets as `type_membership_class` on its base interface and
        # base union, so `implements X, added:` and `possible_types Y, added:` carry a lifecycle.
        module Membership
          def initialize(abstract_type, object_type, added: nil, removed: nil, **options)
            @armory_lifecycle = Lifecycle.build(added: added, removed: removed)
            unless Lifecycle::EVERYWHERE.equal?(@armory_lifecycle)
              Integration.refuse_unguarded_membership(abstract_type, object_type)
              Integration.mark_versioned_membership(abstract_type)
            end
            super(abstract_type, object_type, **options)
          end

          # When the membership lives, for the audit and for tooling.
          attr_reader :armory_lifecycle

          def visible?(context)
            return false unless super
            return true if Lifecycle::EVERYWHERE.equal?(@armory_lifecycle)

            @armory_lifecycle.covers?(Integration.version(context))
          rescue ConfigurationError => error
            raise error.class, "#{path}: #{error.message}"
          end
        end

        # `implements` with `added:` or `removed:` checks every interface before graphql-ruby adds any, since graphql-ruby
        # would ignore the keywords, apply them partly or fail halfway.
        module Implements
          def implements(*interfaces, added: nil, removed: nil, **options)
            Integration.refuse_deprecated_membership(options, "implements")
            interfaces.each do |interface|
              name = Integration.late_bound_name(interface)
              Integration.mark_late_bound(self, name) if name
            end
            return super(*interfaces, **options) if added.nil? && removed.nil?

            Integration.check_implements(self, interfaces, added, removed)
            super(*interfaces, added: added, removed: removed, **options)
          end
        end

        # GraphQL cannot deprecate a membership, and graphql-ruby would keep the keyword without a word.
        def self.refuse_deprecated_membership(options, method)
          return unless options.key?(:deprecated) || options.key?(:deprecation_reason)

          raise ConfigurationError, "#{method} cannot take deprecated: or deprecation_reason:: GraphQL has no deprecated " \
                                    "membership. Use removed: instead"
        end

        # The same for a union's `possible_types`. Called with no types, it is graphql-ruby's reader.
        module Members
          def possible_types(*types, added: nil, removed: nil, **options)
            Integration.refuse_deprecated_membership(options, "possible_types")
            return super(*types, **options) if added.nil? && removed.nil?

            Integration.check_possible_types(self, types, added, removed)
            super(*types, added: added, removed: removed, **options)
          end
        end

        def self.check_implements(type, interfaces, added, removed)
          name = type.graphql_name
          raise ConfigurationError, "#{name}: an interface cannot implement another with added: or removed:" unless type.is_a?(Class)

          build_lifecycle(name, added, removed)
          interfaces.each do |interface|
            unless interface.is_a?(Module)
              raise ConfigurationError, "#{name}: implements #{interface.inspect} with added: or removed: needs the interface's module, not a name"
            end

            check_membership_class(name, "implements #{interface.graphql_name}", interface)
            next if interface.interfaces.empty?

            raise ConfigurationError, "#{name}: implements #{interface.graphql_name} with added: or removed:, but #{interface.graphql_name} " \
                                      "implements other interfaces, which graphql-ruby would add without the lifecycle. Implement each one directly"
          end
        end

        def self.check_possible_types(union, types, added, removed)
          name = union.graphql_name
          build_lifecycle(name, added, removed)
          types.each do |type|
            next if type.is_a?(Class)

            raise ConfigurationError, "#{name}: possible_types #{type.inspect} with added: or removed: needs the object's class, not a name"
          end
          check_membership_class(name, "possible_types", union)
        end

        def self.build_lifecycle(name, added, removed)
          Lifecycle.build(added: added, removed: removed)
        rescue ConfigurationError => error
          raise error.class, "#{name}: #{error.message}"
        end

        def self.check_membership_class(name, what, abstract_type)
          return if abstract_type.type_membership_class.include?(Membership)

          raise ConfigurationError, "#{name}: #{what} with added: or removed: needs #{abstract_type.graphql_name}'s type_membership_class " \
                                    "to include GraphQL::Armory::Versioning::Base"
        end

        # The checks of a versioned membership run from the types that include `Base`, so a membership between types
        # without it is refused: graphql-ruby would pass it the keywords and serve it unchecked.
        def self.refuse_unguarded_membership(abstract_type, object_type)
          guarded = object_type.is_a?(Class) && object_type.singleton_class.include?(Type) &&
                    abstract_type.is_a?(Module) && abstract_type.singleton_class.include?(Type)
          return if guarded

          names = [abstract_type, object_type].map { |type| type.respond_to?(:graphql_name) ? display_name(type) : type.inspect }
          raise ConfigurationError, "#{names.last} and #{names.first}: a membership with added: or removed: needs an object class and " \
                                    "an interface or union that include GraphQL::Armory::Versioning::Base"
        end

        def self.mark_versioned_membership(abstract_type)
          abstract_type.instance_variable_set(:@armory_versioned_memberships, true) if abstract_type.is_a?(Module)
          @versioned_memberships = (@versioned_memberships || 0) + 1
        end

        def self.versioned_membership_count = @versioned_memberships || 0

        # The GraphQL name a type expression binds late: a `LateBoundType`, bare, wrapped or in a list (`[T, null: true]`
        # included). A String is a Ruby constant, bound to one class at once.
        def self.late_bound_name(expression)
          case expression
          when GraphQL::Schema::LateBoundType then expression.graphql_name
          when GraphQL::Schema::Wrapper then late_bound_name(expression.of_type)
          when Array then late_bound_name(expression.first)
          end
        end

        def self.mark_late_bound(member, name)
          member.instance_variable_set(:@armory_late_bound, [*member.instance_variable_get(:@armory_late_bound), name])
          @late_bound = (@late_bound || 0) + 1
        end

        def self.late_bound_count = @late_bound || 0

        # Every type the schema holds, twins included: Warden's `schema.types` keeps one per name, the one the latest
        # version sees, and nil where none does.
        def self.definitions(schema)
          Armory::Definitions.(schema, schema.extra_types).reject { |type| Armory::Definitions.introspection?(type) }
        end

        # Every argument a type holds, at every level of its fields, twins included.
        def self.arguments_in(type)
          return type.all_argument_definitions if type.kind.input_object?

          Armory::Definitions.fields_at_every_level(type).flat_map(&:all_argument_definitions)
        end

        # graphql-ruby binds a late-bound name to the first type registered with it, whatever the version: one that has
        # twins would serve the wrong one. Only members that include `Base` are known.
        def self.refuse_late_bound_twins(types, directives)
          # A base interface module brought in with `include` has no name of its own.
          named = types.group_by do |type|
            type.graphql_name
          rescue GraphQL::RequiredImplementationMissingError
            nil
          end
          twins = named.select { |name, list| name && list.size > 1 }
          return if twins.empty?

          members = types.flat_map { |type| [type, *Armory::Definitions.fields_at_every_level(type), *arguments_in(type)] }
          members.concat(directives.flat_map(&:all_argument_definitions))
          members.each do |member|
            names = member.instance_variable_get(:@armory_late_bound)
            twin = names&.find { |name| twins.key?(name) }
            next unless twin

            at = member.respond_to?(:path) ? member.path : display_name(member)
            raise ConfigurationError, "#{at}: names #{twin} by name, and #{twin} has more than one definition: graphql-ruby binds the " \
                                      "name to the first one registered, in every version. Reference the class instead"
          end
        end

        # Every argument of the schema that loads an interface or union with a versioned membership, whatever its class:
        # an argument class without `Base` never asks. Walked only when a versioned membership exists.
        def self.refuse_abstract_loads(types)
          types.each do |type|
            arguments_in(type).each do |argument|
              loads = argument.loads
              next unless loads && loads.kind.abstract? && versioned_memberships?(loads)

              raise ConfigurationError, "#{argument.path}: it loads #{loads.graphql_name}, which has a membership with a lifecycle: " \
                                        "graphql-ruby would load an object that is not a member in the query's version. Load the object types instead"
            end
          end
        end

        def self.versioned_memberships?(abstract_type)
          abstract_type.instance_variable_defined?(:@armory_versioned_memberships)
        end

        # graphql-ruby serves a membership when any membership to the same abstract type is visible, and `get_field` answers
        # a hidden interface's definition of a name another source also declares, so both are refused. Checked when the
        # object or union is asked, again when its memberships change.
        def self.refuse_membership_conflicts(type)
          memberships = type.is_a?(Class) && type < GraphQL::Schema::Union ? type.type_memberships : object_memberships(type)
          return if memberships.nil? || type.instance_variable_get(:@armory_memberships_checked) == memberships.size

          versioned = memberships.select { |membership| membership.respond_to?(:armory_lifecycle) && !Lifecycle::EVERYWHERE.equal?(membership.armory_lifecycle) }
          versioned.each do |membership|
            target = type < GraphQL::Schema::Union ? membership.object_type : membership.abstract_type
            others = memberships.reject { |other| other.equal?(membership) || !other.respond_to?(:abstract_type) }
            union = type < GraphQL::Schema::Union
            # Another membership to the same type, or, for an object, to an interface that includes it.
            overridden = others.any? do |other|
              reached = union ? other.object_type : other.abstract_type
              reached.equal?(target) || (!union && reached.is_a?(Module) && reached.include?(target))
            end
            if overridden
              raise ConfigurationError, "#{union ? 'lists' : 'implements'} #{target.graphql_name} with a lifecycle, but another membership " \
                                        "to #{target.graphql_name}, or to an interface that includes it, makes it a member in every version. Keep one"
            end
            refuse_shared_fields(type, target, others) unless type < GraphQL::Schema::Union
          end
          type.instance_variable_set(:@armory_memberships_checked, memberships.size)
        end

        # Every definition of each field name a type declares or inherits, twins included, read without a query.
        def self.field_definitions(type, own_only: false)
          levels = own_only ? [type] : type.ancestors.select { |ancestor| ancestor.respond_to?(:own_fields) }
          levels.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |level, found|
            level.own_fields.each { |name, definitions| found[name].concat(Array(definitions)) }
          end
        end

        def self.display_name(type)
          type.graphql_name
        rescue GraphQL::RequiredImplementationMissingError
          type.name || type.inspect
        end

        def self.object_memberships(type)
          type.interface_type_memberships if type.is_a?(Class) && type < GraphQL::Schema::Object
        end

        def self.refuse_shared_fields(object, interface, others)
          own = object.own_fields
          sources = others.map(&:abstract_type).select { |other| other.is_a?(Module) }.map { |other| [other, field_definitions(other)] }
          object.ancestors.each do |ancestor|
            next unless ancestor.is_a?(Class) && ancestor < GraphQL::Schema::Object && !ancestor.equal?(object)

            sources << [ancestor, field_definitions(ancestor, own_only: true)]
          end
          field_definitions(interface).each do |name, definitions|
            next if own.key?(name)

            source = sources.find { |_, fields| fields.key?(name) && !(fields[name] - definitions).empty? }
            next unless source

            raise ConfigurationError, "implements #{interface.graphql_name} with a lifecycle, but " \
                                      "#{interface.graphql_name}.#{name} is also declared by #{display_name(source.first)}, so graphql-ruby could serve " \
                                      "#{interface.graphql_name}'s definition where the membership does not live. Declare #{name} on " \
                                      "#{object.graphql_name}, or rename one"
          end
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

        # A type must not live where any versioned ancestor does not: the legacy Warden checks the parents' visibility for the
        # memberships a subclass inherits. Every ancestor counts, since an intermediate one may never be asked.
        def self.refuse_wider_than_parent(type, version)
          return unless type.is_a?(Class)

          parent = type.superclass
          while parent.respond_to?(:armory_lifecycle)
            unless parent.armory_lifecycle.covers?(version)
              raise ConfigurationError, "lives in #{label(version)} but its parent #{parent.graphql_name} does not: a subclass's lifecycle " \
                                        "must fit inside its parent's"
            end
            parent = parent.superclass
          end
        end

        # Checked when a query of a schema is built, and by `Versioning.types`: graphql-ruby answers these without asking
        # `visible?` with the query's context. Checked again when the roots or `extra_types` change.
        def self.check_schema(schema)
          checked = [schema.query, schema.mutation, schema.subscription, versioned_membership_count, late_bound_count, *schema.extra_types]
          return if schema.instance_variable_get(:@armory_schema_checked) == checked

          schema_checks(schema).each(&:call)
          schema.instance_variable_set(:@armory_schema_checked, checked)
        end

        # Each schema-level check on its own, in the order `check_schema` runs them: the audit runs every one and reports
        # each refusal.
        def self.schema_checks(schema)
          # Under `Schema::Visibility` such a type counts as referenced and its members are filtered.
          visibility = schema.respond_to?(:use_visibility_profile?) && schema.use_visibility_profile?
          abstract_loads = versioned_membership_count.positive? && !visibility
          types = nil
          walked = -> { types ||= definitions(schema) }
          checks = []
          checks << -> { refuse_late_base(walked.(), schema.directives.values) }
          checks << -> { refuse_abstract_loads(walked.()) } if abstract_loads
          checks << -> { refuse_late_bound_twins(walked.(), schema.directives.values) } if late_bound_count.positive?
          checks << -> { refuse_subscription_twins(schema) }
          [schema.query, schema.mutation, schema.subscription].compact.each do |root|
            checks << lambda do
              next unless versioned_type?(root)

              raise ConfigurationError, "#{root.graphql_name}: a root type cannot have a lifecycle: a version without it would have no " \
                                        "#{root.graphql_name} root. Version its fields instead"
            end
          end
          schema.extra_types.each do |type|
            checks << lambda do
              next unless versioned_type?(type)

              raise ConfigurationError, "#{type.graphql_name}: a type with a lifecycle cannot be in extra_types: `__type` and the SDL " \
                                        "read extra_types without asking visible?"
            end
          end
          checks
        end

        # Twins: other definitions of a member's name on its own owner.
        def self.twins_of(member)
          holder = member.owner
          definitions = case member
                        when GraphQL::Schema::Field then holder.own_fields[member.graphql_name] if holder.respond_to?(:own_fields)
                        when GraphQL::Schema::Argument then holder.own_arguments[member.graphql_name] if holder.respond_to?(:own_arguments)
                        when GraphQL::Schema::EnumValue
                          holder.all_enum_value_definitions.select { |value| value.owner.equal?(holder) && value.graphql_name == member.graphql_name }
                        end
          Array(definitions).reject { |definition| definition.equal?(member) }
        end

        # graphql-ruby 2.4.0 to 2.4.8 fail with NoMethodError under Schema::Visibility when no twin of a field is visible.
        FIELD_TWINS = Gem::Version.new(GraphQL::VERSION) >= Gem::Version.new("2.4.9")

        # Two definitions of one name that a version would both see: graphql-ruby would raise DuplicateNamesError on every
        # query that asks for it. Checked before any other `visible?`, so the answer never depends on the user.
        def self.refuse_twin_overlap(member, twins, context, field: false)
          return if twins.empty?
          raise ConfigurationError, "has two definitions, which needs graphql 2.4.9 or later" if field && !FIELD_TWINS

          version = version(context)
          return unless covers?(member, version) && twins.any? { |twin| covers?(twin, version) }

          raise ConfigurationError, "is defined more than once for #{label(version)}: graphql-ruby would refuse every query that asks " \
                                    "for it. Give the definitions lifecycles that do not overlap"
        end

        # graphql-ruby's subscription trigger reads the arguments of a subscription field with no query, where twins raise.
        def self.refuse_subscription_twins(schema)
          root = schema.subscription
          return unless root

          seen = {}.compare_by_identity
          root.all_field_definitions.each do |field|
            refuse_argument_twins(field.path, field.path, field.all_argument_definitions, seen)
          end
        end

        def self.refuse_argument_twins(at, holder, arguments, seen)
          arguments.group_by(&:graphql_name).each do |name, definitions|
            if definitions.size > 1
              raise ConfigurationError, "#{at}: #{holder}.#{name} has two definitions, and graphql-ruby's subscription trigger reads " \
                                        "arguments with no version, where they raise. Keep one definition (deprecated: makes two)"
            end

            input = definitions.first.type.unwrap
            refuse_enum_twins(definitions.first.path, input) if input.kind.enum?
            next unless input.kind.input_object? && !seen.key?(input)

            seen[input] = true
            refuse_argument_twins(definitions.first.path, input.graphql_name, input.all_argument_definitions, seen)
          end
        end

        # An enum value with two definitions coerces, with no version, to the latest one's Ruby value.
        def self.refuse_enum_twins(at, enum)
          name, = enum.all_enum_value_definitions.group_by(&:graphql_name).find { |_, values| values.size > 1 }
          return unless name

          raise ConfigurationError, "#{at}: #{enum.graphql_name}.#{name} has two definitions, and graphql-ruby's subscription trigger reads "                                     "arguments with no version, where they raise or coerce to the latest. Keep one definition"
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
              arguments = input_fields(type, key.to_s)
              next if arguments.empty?

              found << arguments if arguments.all? { |argument| versioned?(argument) }
              members_in(arguments.first.type, item, found)
            end
          end
          found
        end

        # graphql-ruby accepts a default's key as the field's GraphQL name, its keyword (`as:`) or its underscored name.
        def self.input_fields(type, key)
          camelized = GraphQL::Schema::Member::BuildType.camelize(key)
          type.all_argument_definitions.select do |defn|
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

        # A member built before its class included `Base` has none (`refuse_late_base` refuses the schema); the audit reads it
        # as living everywhere, which is what it could declare, so it reports that refusal instead of failing.
        def self.lifecycle_of(member)
          (member.armory_lifecycle if member.respond_to?(:armory_lifecycle)) || Lifecycle::EVERYWHERE
        end

        # A type and everything versioned under it: its fields at every level, their arguments (or an input object's),
        # an enum's values and its type memberships.
        def self.members_of(type)
          members = [type, *Armory::Definitions.fields_at_every_level(type), *arguments_in(type)]
          members.concat(type.all_enum_value_definitions) if type.kind.enum?
          members.concat(type.type_memberships) if type.kind.union?
          members.concat(type.interface_type_memberships.select { |membership| membership.respond_to?(:visible?) }) if type.respond_to?(:interface_type_memberships)
          members
        end

        LATE_BASE_LISTED = 5

        # A field, argument, enum value or membership built before its class included `Base` has no lifecycle: its
        # `visible?` would fail on every query. Refused with the members and what to do.
        def self.refuse_late_base(types, directives)
          members = types.flat_map { |type| members_of(type) } + directives.flat_map(&:all_argument_definitions)
          late = members.uniq.select do |member|
            (member.is_a?(Member) || member.is_a?(Membership)) && !member.instance_variable_defined?(:@armory_lifecycle)
          end
          return if late.empty?

          names = late.first(LATE_BASE_LISTED).map { |member| late_base_name(member) }
          names << "and #{late.size - LATE_BASE_LISTED} more" if late.size > LATE_BASE_LISTED
          first = late_base_name(late.first, located: false)
          raise ConfigurationError, "#{names.join(", ")}: the class of #{first} included GraphQL::Armory::Versioning::Base after #{first} " \
                                    "was defined, so it has no lifecycle and every query would fail. include Base in the class before " \
                                    "defining any field, argument or enum value with it (your base field, argument and enum value classes)"
        end

        def self.late_base_name(member, located: true)
          name = if member.is_a?(Membership)
                   "#{member.abstract_type.graphql_name} membership of #{member.object_type.graphql_name}"
                 else
                   member.path
                 end
          location = located && Location.of(member)
          location ? "#{name} (#{location})" : name
        end
        private_class_method :late_base_name

        def self.versioned_type?(type) = !Lifecycle::EVERYWHERE.equal?(lifecycle_of(type))

        # A member is versioned by its own lifecycle, or, for an argument or input field, by its type's.
        def self.versioned?(member)
          versioned_type?(member) || (member.is_a?(GraphQL::Schema::Argument) && versioned_type?(member.type.unwrap))
        end

        def self.covers?(member, version)
          return false unless lifecycle_of(member).covers?(version)

          typed = member.is_a?(GraphQL::Schema::Argument) || member.is_a?(GraphQL::Schema::Field)
          !typed || lifecycle_of(member.type.unwrap).covers?(version)
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

          # The named profiles `use ..., profiles: true` runs queries under, or `Profiles::Off`.
          def armory_versioning_profiles
            @armory_versioning_profiles || superclass.armory_versioning_profiles
          end
        end

        # Decides the query's version after the query is built, from its own context, so a version set by a custom
        # `context_class` is seen. A refused query fails validation with the refusal as its only error, through the
        # public `validate=` and `static_validator=` setters, so neither engine runs anything, even with `validate: false`.
        module Lookup
          def initialize(schema, query_string = nil, **options)
            Integration.refuse_always_visible(schema)
            Integration.check_schema(schema)
            profiles = schema.armory_versioning_profiles
            super(schema, query_string, **profiles.options(schema.armory_versioning, options))

            # Neutral for response caching: the resolved label is in its key. An app's own read of the raw value is not.
            decision = Caching.neutral(context) { schema.armory_versioning.(context) }
            profiles.check(self, decision)
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
        MEMBERS = {
          GraphQL::Schema::Field => :Field, GraphQL::Schema::Argument => :Argument, GraphQL::Schema::EnumValue => :EnumValue,
          GraphQL::Schema::TypeMembership => :Membership
        }.freeze
        TYPES = {
          GraphQL::Schema::Object => %i[Type Implements Authorized Fields], GraphQL::Schema::Union => %i[Type Members],
          GraphQL::Schema::InputObject => %i[Type Arguments], GraphQL::Schema::Enum => %i[Type Values], GraphQL::Schema::Scalar => %i[Type],
          GraphQL::Schema::Resolver => %i[Type Arguments Fields]
        }.freeze

        def self.included(base)
          if !base.is_a?(Class) && base.include?(GraphQL::Schema::Interface)
            modules = [Integration::Type, Integration::Implements, Deprecation::Fields]
            base.definition_methods { modules.each { |mod| include mod } }
          elsif base.is_a?(Class) && (member = MEMBERS.find { |parent, _| base <= parent })
            base.include(Integration.const_get(member.last))
          elsif base.is_a?(Class) && (type = TYPES.find { |parent, _| base <= parent })
            type.last.each { |name| base.extend(Integration.const_defined?(name, false) ? Integration.const_get(name) : Deprecation.const_get(name)) }
          else
            raise ArgumentError, "GraphQL::Armory::Versioning::Base goes in a field, argument, enum value, type membership, object, interface, union, enum, " \
                                 "scalar, input object, resolver or mutation class, not #{base}. In an interface, include GraphQL::Schema::Interface first"
          end
        end
      end
    end
  end
end
