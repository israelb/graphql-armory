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
        NOT_CHECKED = "members hidden in a version because their type is, fields served by a parent or an interface " \
                      "under the Warden, interfaces and unions left with no member, types with no visible field, your own " \
                      "visible? methods, defaults of arguments without Base, and subscription triggers"

        # `location` is "path:line" where the app wrote what the problem is about, or nil.
        Problem = Struct.new(:kind, :path, :message, :location) do
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
            problems.empty?
          end

          def to_s
            lines = if ok?
                      ["No problems."]
                    else
                      ["#{problems.size} #{problems.size == 1 ? 'problem' : 'problems'}:",
                       *problems.map { |problem| "  #{problem.location ? "#{problem} (at #{problem.location})" : problem}" }]
                    end
            [*lines, "", "Not checked yet: #{NOT_CHECKED}."].join("\n") << "\n"
          end
        end

        # Collects what one audit finds: one problem per kind and path (per message for the schema's own), the first kept.
        class Findings
          def initialize
            @problems = {}
          end

          def problem(kind, path, message, at: nil)
            key = path == "Schema" ? [kind, path, message] : [kind, path]
            @problems[key] ||= Problem.new(kind, path, message, Location.of(at))
          end

          def path?(path) = @problems.each_key.any? { |key| key[1] == path }

          def any? = !@problems.empty?

          # Whether a refusal is one already reported: graphql-ruby's lookups ask a member again inside its owner's.
          def explained?(message) = @problems.each_value.any? { |problem| message.start_with?("#{problem.path}: ") || message == problem.message }

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
