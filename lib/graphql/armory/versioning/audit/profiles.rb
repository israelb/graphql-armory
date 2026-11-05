# frozen_string_literal: true

module GraphQL
  module Armory
    module Versioning
      class Audit
        # `:profiles`: under `use ..., profiles: true`, graphql-ruby asks `visible?` once per version with the profile's
        # frozen Hash, never with a query's context. A check that needs the query's user cannot run there: Authorization's
        # `visible_when:` raises on every query that reaches it, and the app's own `visible?` would decide once for every
        # user. Each is reported where it is declared. The audit cannot read whether an app's `visible?` reads the user.
        module Profiles
          def self.call(schema, findings)
            return findings unless schema.respond_to?(:armory_versioning_profiles) && schema.armory_versioning_profiles.enabled?

            found = {}
            Members.of(schema).each do |member|
              visible_when(member, findings)
              klass = member.is_a?(Module) ? member : member.class
              separator = member.is_a?(Module) ? "." : "#"
              method = member.is_a?(Module) ? member.method(:visible?) : klass.instance_method(:visible?)
              own_methods(klass, method, separator, found)
            end
            own_methods(schema, schema.method(:visible?), ".", found)
            found.each_value do |path, method|
              findings.problem(:profiles, path, "defined by the app: under profiles: true graphql-ruby asks it once per version, with the " \
                                                "profile's Hash instead of a query's context, so it decides for every user at once. Drop " \
                                                "profiles: true, or make sure it reads nothing but the version", at: method)
            end
            findings
          end

          def self.visible_when(member, findings)
            declared = if member.is_a?(Module)
                         member.respond_to?(:armory_rule) && member.armory_rule&.visible_when
                       else
                         member.respond_to?(:armory_visible_when) && member.armory_visible_when
                       end
            return unless declared

            findings.problem(:profiles, Members.path_of(member), "uses visible_when: #{declared.inspect}, which needs the query's user, but " \
                                                                 "under profiles: true visible? is asked with the version's profile Hash, so " \
                                                                 "every query that reaches it raises. Drop visible_when: here, or profiles: true", at: member)
          end
          private_class_method :visible_when

          # Follows the whole chain: a method that only calls super must not hide one below it.
          def self.own_methods(klass, method, separator, found)
            while method
              file = method.source_location&.first
              if file && !file.start_with?(Location::GRAPHQL_RUBY_PATH, Location::ARMORY_PATH)
                holder = klass.ancestors.find { |ancestor| ancestor.singleton_class == method.owner } || method.owner
                found[[holder, separator]] ||= ["#{holder.name || holder.inspect}#{separator}visible?", method]
              end
              method = method.super_method
            end
          end
          private_class_method :own_methods
        end

        # `:retired_only`: a member, or one of two twins, whose lifecycle covers only retired versions. No client can reach
        # it any more, so it is dead code: information, which `ok?` ignores, unless `strict: true` makes it a problem.
        module RetiredOnly
          def self.call(schema, findings, strict: false)
            return findings unless schema.respond_to?(:armory_versioning)

            versions = schema.armory_versioning.versions.to_a
            return findings if versions.none?(&:retired?)

            Members.of(schema).each do |member|
              lifecycle = Integration.lifecycle_of(member)
              next if Lifecycle::EVERYWHERE.equal?(lifecycle)

              covered = covered(lifecycle, versions)
              next if covered.empty? || !covered.all?(&:retired?)

              message = "lives only in retired versions (#{covered.map(&:label).join(', ')}), by its lifecycle #{lifecycle.to_h.inspect}: " \
                        "no client can reach it. Delete it"
              if strict
                findings.problem(:retired_only, Members.path_of(member), message, at: member)
              else
                findings.information(:retired_only, Members.path_of(member), message, at: member)
              end
            end
            findings
          end

          # A label versions: does not hold is reported as :undeclared_version.
          def self.covered(lifecycle, versions)
            versions.select { |version| lifecycle.covers?(version) }
          rescue ConfigurationError
            []
          end
          private_class_method :covered
        end

        # Every type and member a schema holds, twins included, as the audit walks them.
        module Members
          def self.of(schema)
            members = Integration.definitions(schema).flat_map do |type|
              found = [type, *Armory::Definitions.fields_at_every_level(type), *Integration.arguments_in(type)]
              found.concat(type.all_enum_value_definitions) if type.kind.enum?
              found.concat(type.type_memberships) if type.kind.union?
              found.concat(type.interface_type_memberships.select { |membership| membership.respond_to?(:visible?) }) if type.respond_to?(:interface_type_memberships)
              found
            end
            members.concat(schema.directives.values.flat_map(&:all_argument_definitions))
            members.uniq
          end

          def self.path_of(member)
            return member.path if member.respond_to?(:path) && !member.is_a?(Module)

            Integration.display_name(member)
          end
        end
      end
    end
  end
end
