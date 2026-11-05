# frozen_string_literal: true

module GraphQL
  module Armory
    module Versioning
      # Checks a schema's versioning before production: every refusal a query of a served version would hit, and every
      # member a served version lists outside its lifecycle. It never runs at boot or during a request.
      #
      #   report = GraphQL::Armory::Versioning::Audit.(AppSchema)
      #   report.ok?    # false when a query of some served version would be refused, or would see a member it should not
      #   puts report
      #
      # Each member is asked with a context that names the version and `armory_full_schema: true`, so a check that hides it
      # from a user (Authorization's `visible_when:`) never hides a refusal. Nothing it does records a signal.
      class Audit
        # What the report does not check yet: it says so, so `ok?` never claims more than was checked.
        NOT_CHECKED = "your own visible? methods, defaults of arguments without Base, and subscription triggers"

        # `location` is "path:line" where the app wrote what the problem is about, or nil. `severity` is nil for a problem,
        # or :information for something listed that changes nothing a client relies on: `ok?` ignores it.
        Problem = Struct.new(:kind, :path, :message, :location, :severity) do
          def information? = severity == :information

          def to_s
            "#{path} (#{kind}): #{message}"
          end
        end

        class Report
          attr_reader :problems

          def initialize(problems = [])
            @problems = problems.freeze
            freeze
          end

          def ok?
            problems.all?(&:information?)
          end

          def to_s
            failing, information = problems.partition { |problem| !problem.information? }
            lines = if failing.empty?
                      ["No problems."]
                    else
                      ["#{failing.size} #{failing.size == 1 ? 'problem' : 'problems'}:", *failing.map { |problem| line(problem) }]
                    end
            lines.push("", "Information:", *information.map { |problem| line(problem) }) unless information.empty?
            [*lines, "", "Not checked yet: #{NOT_CHECKED}."].join("\n") << "\n"
          end

          private

          def line(problem) = "  #{problem.location ? "#{problem} (at #{problem.location})" : problem}"
        end

        # Collects what one audit finds: one problem per kind and path (per message for the schema's own), the first kept.
        class Findings
          def initialize
            @problems = {}
          end

          # A problem replaces information of the same kind and path found in another version.
          def problem(kind, path, message, at: nil, severity: nil)
            key = path == "Schema" ? [kind, path, message] : [kind, path]
            kept = @problems[key]
            return kept if kept && (severity || !kept.information?)

            @problems[key] = Problem.new(kind, path, message, Location.of(at), severity)
          end

          def information(kind, path, message, at: nil) = problem(kind, path, message, at: at, severity: :information)

          # Information never stands for a problem: a member listed as information is still asked in every version.
          def path?(path) = failing.any? { |problem| problem.path == path }

          def any? = failing.any?

          # Whether a refusal is one already reported: graphql-ruby's lookups ask a member again inside its owner's.
          def explained?(message) = failing.any? { |problem| message.start_with?("#{problem.path}: ") || message == problem.message }

          def failing = @problems.each_value.reject(&:information?)

          def report
            Report.new(@problems.values.sort_by { |problem| [problem.path, problem.kind.to_s] })
          end
        end

        def self.call(schema)
          new.(schema)
        end

        def call(schema)
          findings = Findings.new
          return findings.report unless installed?(schema, findings) && visibility?(schema, findings)

          refused = schema_refusals(schema, findings)
          definitions = Integration.definitions(schema)
          members = definitions.flat_map { |type| members_of(type) }.uniq
          members.concat(schema.directives.values.flat_map(&:all_argument_definitions))
          undeclared(schema, members, findings)
          # A schema-level refusal fails every query, before any member is asked.
          schema.armory_versioning.versions.each_served { |version| walk(schema, version, definitions, members, findings) } unless refused
          findings.report
        end

        private

        def installed?(schema, findings)
          return true if schema.respond_to?(:armory_versioning)

          findings.problem(:plugin, "Schema", "#{schema} never installed the plugin: `visible?` of members with Base raises on " \
                                              "every query. Add `use GraphQL::Armory::Versioning, versions: ..., default: ...`")
          false
        end

        # Without Visibility or the Warden, graphql-ruby warns on every query that hides something, and may stop asking.
        def visibility?(schema, findings)
          visibility = schema.respond_to?(:use_visibility_profile?) && schema.use_visibility_profile?
          return true if visibility || schema.plugins.any? { |plugin, _| plugin == GraphQL::Schema::Warden }

          findings.problem(:visibility, "Schema", "neither GraphQL::Schema::Visibility nor GraphQL::Schema::Warden is used: graphql-ruby " \
                                                  "warns on every query that hides a member. Add `use GraphQL::Schema::Visibility`")
          false
        end

        def schema_refusals(schema, findings)
          checks = [-> { Integration.refuse_always_visible(schema) }, *Integration.schema_checks(schema)]
          checks.count do |check|
            check.()
            false
          rescue ConfigurationError => error
            findings.problem(:refused, "Schema", error.message)
            true
          end.positive?
        end

        def members_of(type)
          members = [type, *Armory::Definitions.fields_at_every_level(type), *Integration.arguments_in(type)]
          members.concat(type.all_enum_value_definitions) if type.kind.enum?
          members.concat(type.type_memberships) if type.kind.union?
          members.concat(type.interface_type_memberships.select { |membership| membership.respond_to?(:visible?) }) if type.respond_to?(:interface_type_memberships)
          members
        end

        # A label no version has fails the member's check whenever it is asked: reported even for a member no query asks.
        def undeclared(schema, members, findings)
          labels = schema.armory_versioning.versions.map(&:label)
          members.each do |member|
            lifecycle = Integration.lifecycle_of(member)
            next if Lifecycle::EVERYWHERE.equal?(lifecycle)

            lifecycle.to_h.each do |keyword, label|
              next if labels.include?(label)

              findings.problem(:undeclared_version, path_of(member), "#{keyword}: #{label.inspect} is not in versions: #{labels.inspect}", at: member)
            end
          end
        end

        def walk(schema, version, definitions, members, findings)
          query = GraphQL::Query.new(schema, "{ __typename }", validate: false, context: { armory_full_schema: true, armory_version: version.label })
          context = query.context
          members.each do |member|
            # graphql-ruby never asks a member whose owner the version does not have.
            next if findings.path?(path_of(member)) || !owners_live?(member, version)

            guarded(findings, member) { member.visible?(context) }
          end
          types = query.types
          view = View.new(types)
          # As `__type(name:)` asks it: graphql-ruby checks that the name is reachable in V first.
          definitions.filter_map { |type| named(type) }.uniq.each do |name|
            guarded(findings, name) { view.type(name) }
          end
          outside_lifecycle(view, version, findings)
          directive_arguments(types, view, version, findings)
          missing_members(schema, types, view, version, definitions, findings)
        end

        # What a version leaves out without refusing anything: members hidden because their type is, and types left with
        # no field, no member or no implementer.
        def missing_members(schema, types, view, version, definitions, findings)
          listed = begin
            view.all_types.reject { |type| Armory::Definitions.introspection?(type) }
          rescue StandardError
            return # reported by outside_lifecycle
          end
          listed.each do |type|
            guarded(findings, type) do
              hidden_by_type(view, type, version, findings)
              empty(schema, view, type, version, definitions, findings)
            end
          end
          (guarded(findings, "Schema") { types.directives } || []).each do |directive|
            guarded(findings, directive) { hidden_arguments(view, directive, version, findings) }
          end
          guarded(findings, "Schema") { unlisted_abstract(view, version, definitions, listed, findings) }
          listed.each do |type|
            next unless type.kind.fields?

            guarded(findings, type) { fallbacks(view, type, version, findings) }
            guarded(findings, type) { contract_arguments(view, type, version, findings) } if type.kind.object?
          end
        end

        # A field whose nearest definition V hides while a farther one (a parent's or an interface's) lives in V: the Warden
        # serves the farther one, `Schema::Visibility` drops the name. graphql-ruby walks the ancestors in order, interfaces
        # before the superclass, skipping an interface whose membership V hides.
        def fallbacks(view, type, version, findings)
          levels = type.ancestors.select { |ancestor| ancestor.respond_to?(:own_fields) && member_in?(type, ancestor, version) }
          levels.flat_map { |level| level.own_fields.keys }.uniq.each do |name|
            defining = levels.select { |level| level.own_fields.key?(name) }
            next if defining.size < 2

            nearest = Array(defining.first.own_fields[name])
            served = view.field(type, name)
            next if nearest.any? { |field| field.equal?(served) } || nearest.any? { |field| live?(field, version) }

            farther = defining.drop(1).flat_map { |level| Array(level.own_fields[name]) }.select { |field| live?(field, version) }
            next if farther.empty?

            path = "#{type.graphql_name}.#{name}"
            hidden = Integration.display_name(defining.first)
            if served
              findings.problem(:fallback, path, "#{label(version)} hides #{hidden}'s definition, so the Warden serves " \
                                                "#{Integration.display_name(served.owner)}'s definition instead, with its type, " \
                                                "arguments and resolver", at: nearest.first)
            else
              interface = farther.map(&:owner).find { |owner| owner.respond_to?(:kind) && owner.kind.interface? && view.visible?(owner) }
              why = if interface
                      "which #{interface.graphql_name} declares: a schema with it is invalid"
                    else
                      "though #{Integration.display_name(farther.first.owner)}'s definition lives there: the Warden would serve that one"
                    end
              findings.problem(:fallback, path, "#{type.graphql_name} no longer has #{name} in #{label(version)}, #{why}", at: nearest.first)
            end
          end
        end

        # An argument of an interface's field that the object's own field hides in V: the object no longer takes what the
        # interface declares. Only an argument the object defines and V hides is versioning's doing.
        def contract_arguments(view, type, version, findings)
          view.interfaces(type).each do |interface|
            view.fields(interface).each do |declared|
              field = view.field(type, declared.graphql_name)
              next if field.nil? || field.equal?(declared)

              taken = view.arguments(field).map(&:graphql_name)
              view.arguments(declared).each do |argument|
                name = argument.graphql_name
                next if taken.include?(name)

                hidden = field.all_argument_definitions.select { |own| own.graphql_name == name && !Integration.covers?(own, version) }
                next if hidden.empty?

                findings.problem(:fallback, "#{type.graphql_name}.#{field.graphql_name}.#{name}",
                                 "#{label(version)} hides it on #{type.graphql_name}.#{field.graphql_name}, though " \
                                 "#{interface.graphql_name}.#{declared.graphql_name} takes it: a schema with it is invalid", at: hidden.first)
              end
            end
          end
        end

        # A field's own lifecycle, its owner's and its resolver's cover V.
        def live?(field, version)
          [field, field.owner, field.resolver].compact.all? { |member| Integration.lifecycle_of(member).covers?(version) }
        end

        def hidden_by_type(view, type, version, findings)
          hidden_arguments(view, type, version, findings) if type.kind.input_object?
          return unless type.kind.fields?

          live_fields(type, version).each do |field|
            # A twin of the same name served in its place is versioning, not a hidden field.
            next if view.field(type, field.graphql_name)

            hidden = hidden_type(view, field.type.unwrap, version)
            findings.information(:implicit, field.path, "#{label(version)} hides it because its type #{hidden.graphql_name} is not in that version", at: field) if hidden
          end
          view.fields(type).each { |field| hidden_arguments(view, field, version, findings) }
        end

        # A required argument hidden this way lets a client of the version call its owner without it.
        def hidden_arguments(view, owner, version, findings)
          served = view.arguments(owner)
          owner.all_argument_definitions.each do |argument|
            next if served.any? { |member| member.graphql_name == argument.graphql_name } || !Integration.lifecycle_of(argument).covers?(version)

            hidden = if argument.loads
                       argument.loads unless Integration.lifecycle_of(argument.loads).covers?(version)
                     else
                       hidden_type(view, argument.type.unwrap, version)
                     end
            next unless hidden

            why = "#{label(version)} hides it because its type #{hidden.graphql_name} is not in that version"
            if argument.type.non_null? && !argument.default_value?
              findings.problem(:implicit, argument.path, "required, but #{why}: a client of #{label(version)} can use " \
                                                         "#{path_of(owner)} without it", at: argument)
            else
              findings.information(:implicit, argument.path, why, at: argument)
            end
          end
        end

        # The type a version leaves out because of a lifecycle: its own, or, for an interface or a union, its members'.
        def hidden_type(view, type, version)
          return if view.visible?(type)

          type if !Integration.lifecycle_of(type).covers?(version) || type.kind.abstract?
        end

        # The nearest definitions of each field name whose own lifecycle, owner and resolver live in the version, and, for an
        # interface's field, whose membership does.
        def live_fields(type, version)
          Armory::Definitions.fields_at_every_level(type).select do |field|
            !Armory::Definitions.shadowed?(type, field) && member_in?(type, field.owner, version) &&
              [field, field.owner, field.resolver].compact.all? { |member| Integration.lifecycle_of(member).covers?(version) }
          end
        end

        # An interface the type names with `implements` only counts where one of those memberships lives.
        def member_in?(type, owner, version)
          return true if owner.equal?(type) || !owner.respond_to?(:kind) || !owner.kind.interface? || !type.respond_to?(:interface_type_memberships)

          named = type.ancestors.select { |ancestor| ancestor.respond_to?(:interface_type_memberships) }.flat_map(&:interface_type_memberships)
                      .select { |membership| membership.respond_to?(:abstract_type) && membership.abstract_type.equal?(owner) }
          named.empty? || named.any? { |membership| Integration.lifecycle_of(membership).covers?(version) }
        end

        def empty(schema, view, type, version, definitions, findings)
          if type.kind.input_object?
            if type.all_argument_definitions.any? && view.arguments(type).empty?
              findings.problem(:empty, path_of(type), "#{label(version)} serves it with no input field: a schema with it is invalid", at: type)
            end
          elsif type.kind.fields? && !type.has_no_fields? && Armory::Definitions.fields_at_every_level(type).any? && view.fields(type).empty?
            findings.problem(:empty, path_of(type), "#{label(version)} serves it with no field: a client can select only " \
                                                    "__typename, and a schema with it is invalid", at: type)
          end
          # graphql 2.4's Schema::Visibility lists interfaces among an interface's possible types: only objects count.
          return unless type.kind.abstract? && members?(type, definitions) && view.possible_types(type).none? { |member| member.kind.object? }

          # Only Schema::Visibility serves an interface or a union with no member.
          kind = type.kind.interface? ? :orphan_interface : :empty
          findings.problem(kind, path_of(type), "#{label(version)} serves it with no #{type.kind.interface? ? 'implementer' : 'member'}: " \
                                                "possibleTypes is empty, a fragment on any object fails, and data returned " \
                                                "for it raises#{schema.use_visibility_profile? ? '' : ' (Warden)'}", at: type)
        end

        # The Warden hides an interface or a union with no member in the version, and every field that returns it.
        def unlisted_abstract(view, version, definitions, listed, findings)
          returned = listed.select { |type| type.kind.fields? }.flat_map { |type| live_fields(type, version) }.map { |field| field.type.unwrap }
          returned.uniq.each do |type|
            next unless type.kind.abstract? && !view.visible?(type) && Integration.lifecycle_of(type).covers?(version) && members?(type, definitions)

            kind = type.kind.interface? ? :orphan_interface : :empty
            findings.problem(kind, path_of(type), "#{label(version)} has no #{type.kind.interface? ? 'implementer' : 'member'} of it, " \
                                                  "so graphql-ruby hides it and every field that returns it", at: type)
          end
        end

        # An interface or a union with no member in any version is not versioning's doing.
        def members?(type, definitions)
          return type.type_memberships.any? if type.kind.union?

          definitions.any? { |definition| definition.is_a?(Class) && definition.kind.object? && definition.ancestors.include?(type) }
        end

        # A base interface module brought in with `include` has no name of its own.
        def named(type)
          type.graphql_name
        rescue GraphQL::RequiredImplementationMissingError
          nil
        end

        # The field, input object or directive that holds a member, and the type that holds that field, all live in V.
        def owners_live?(member, version)
          owner = member.respond_to?(:owner) ? member.owner : nil
          while owner
            return false unless owner.is_a?(Module) ? Integration.lifecycle_of(owner).covers?(version) : Integration.covers?(owner, version)

            owner = owner.respond_to?(:owner) && !owner.is_a?(Module) ? owner.owner : nil
          end
          true
        rescue ConfigurationError
          false # an owner's label not in versions: is reported as :undeclared_version
        end

        # Directives are not types: their arguments are listed apart.
        def directive_arguments(types, view, version, findings)
          directives = guarded(findings, "Schema") { types.directives } || []
          directives.each do |directive|
            guarded(findings, directive) { view.arguments(directive) }&.each do |member|
              outside(findings, member, version) unless covered?(member, version)
            end
          end
        end

        # A member that a version lists must live there: an app `visible?` that answers before the plugin's, or a check
        # graphql-ruby leaves out, would otherwise serve it with nothing refused.
        def outside_lifecycle(view, version, findings)
          listed = begin
            view.all_types
          rescue StandardError => error
            # What raised is reported above; otherwise nothing could be listed, so nothing was checked.
            findings.problem(:unchecked, "Schema", "listing #{label(version)}'s types raised #{error.class}: #{error.message}") unless findings.any?
            return
          end
          listed.each do |type|
            next if Armory::Definitions.introspection?(type)

            outside(findings, type, version) unless Integration.lifecycle_of(type).covers?(version)
            served_members(view, type, findings).each do |member|
              outside(findings, member, version) unless covered?(member, version)
            end
            memberships(view, type, findings).each do |abstract, object|
              next if membership_covers?(abstract, object, version)

              findings.problem(:outside_lifecycle, "#{object.graphql_name}.#{abstract.graphql_name}",
                               "#{label(version)} lists #{object.graphql_name} as a member of #{abstract.graphql_name}, outside the membership's lifecycle", at: object)
            end
          end
        end

        def served_members(view, type, findings)
          guarded(findings, type) do
            members = []
            view.fields(type).each { |field| members << field << view.arguments(field) } if type.kind.fields?
            members << view.arguments(type) if type.kind.input_object?
            members << view.enum_values(type) if type.kind.enum?
            members.flatten
          end || []
        end

        def memberships(view, type, findings)
          guarded(findings, type) do
            if type.kind.abstract?
              view.possible_types(type).map { |object| [type, object] }
            elsif type.kind.object?
              view.interfaces(type).map { |interface| [interface, type] }
            else
              []
            end
          end || []
        end

        def covered?(member, version)
          return false unless Integration.covers?(member, version)

          !member.is_a?(GraphQL::Schema::Field) || Integration.lifecycle_of(member.owner).covers?(version)
        end

        def membership_covers?(abstract, object, version)
          found = abstract.kind.union? ? abstract.type_memberships : object.interface_type_memberships
          found.any? do |membership|
            # An inherited membership names the class that declared it.
            membership.respond_to?(:abstract_type) && membership.abstract_type.equal?(abstract) && object <= membership.object_type &&
              Integration.lifecycle_of(membership).covers?(version)
          end
        end

        def outside(findings, member, version)
          findings.problem(:outside_lifecycle, path_of(member), "#{label(version)} lists it outside its lifecycle " \
                                                                "(#{Integration.lifecycle_of(member).to_h.inspect})", at: member)
        end

        # Runs one check; whatever it raises becomes the member's problem, so one failure never hides another.
        def guarded(findings, member)
          yield
        rescue ConfigurationError => error
          findings.problem(:refused, path_of(member), without_path(error.message, member), at: member) unless findings.explained?(error.message)
          nil
        rescue GraphQL::Schema::DuplicateNamesError => error
          findings.problem(:duplicate, path_of(member), error.message, at: member)
          nil
        rescue GraphQL::Schema::Enum::MissingValuesError => error
          findings.problem(:empty, path_of(member), error.message, at: member)
          nil
        rescue StandardError => error
          findings.problem(:unchecked, path_of(member), "raised #{error.class} when asked with no user: #{error.message}", at: member)
          nil
        end

        def path_of(member)
          return member if member.is_a?(String)
          return member.path if member.respond_to?(:path) && !member.is_a?(Module)

          Integration.display_name(member)
        end

        def without_path(message, member)
          message.delete_prefix("#{path_of(member)}: ")
        end

        def label(version) = Integration.label(version)
      end
    end
  end
end
