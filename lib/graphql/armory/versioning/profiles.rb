# frozen_string_literal: true

module GraphQL
  module Armory
    module Versioning
      # One named `Schema::Visibility` profile per served version (`use ..., profiles: true`): graphql-ruby computes each
      # version's visibility once, for the life of the schema, instead of once per query.
      #
      #   class AppSchema < GraphQL::Schema
      #     use GraphQL::Armory::Versioning, versions: %w[2024-06-01 2025-01-01], default: :latest, profiles: true
      #     use GraphQL::Schema::Visibility, profiles: GraphQL::Armory::Versioning.profiles(self), preload: true
      #   end
      #
      # Each profile's Hash holds the version's label and the gate's own `Versions`, and nothing else: a check that needs the
      # query's user (Authorization's `visible_when:`, an app's `visible?`) cannot run under it. A query runs only under its
      # own version's profile: `Lookup` names it before graphql-ruby builds the query, and refuses a query that ends up
      # under any other.
      class Profiles
        # Before 2.4.10, graphql-ruby built a named profile with the first query's context and kept it for every query.
        MINIMUM_GRAPHQL = Gem::Version.new("2.4.10")

        # Validates `use`'s `profiles:` and wires the gate's list; `use` goes through here.
        def self.build(versions, enabled:, graphql_version: GraphQL::VERSION)
          raise ConfigurationError, "profiles: must be true or false, got #{enabled.inspect}" unless [true, false].include?(enabled)
          return Off.new unless enabled

          if Gem::Version.new(graphql_version) < MINIMUM_GRAPHQL
            raise ArgumentError, "profiles: true needs graphql #{MINIMUM_GRAPHQL} or later, this is graphql #{graphql_version}: " \
                                 "earlier versions build a named profile from the first query's context and keep it for every query"
          end

          new(versions)
        end

        # `new` is inert: it knows no version, so it names no profile and refuses every query that asks for one.
        def initialize(versions = Versions::Null.new)
          @versions = versions
        end

        def enabled? = true

        # The profile name of a served version.
        def name(version) = :"armory_v_#{version.label}"

        # The Hash for `use GraphQL::Schema::Visibility, profiles:`, new each time: graphql-ruby adds the name to each
        # Hash it is given and freezes it.
        def to_h
          @versions.each_served.to_h { |version| [name(version), { armory_version: version.label, armory_versions: @versions }] }
        end

        # What a query built for tooling (`Versioning.types`) passes to run under its version's profile.
        def query_options(version) = { visibility_profile: name(version) }

        # Before graphql-ruby builds the query: name the profile of the version its context asks for. A refused version
        # gets none and runs under the Warden, whose `visible?` raises the refusal, so `to_definition` still raises it.
        def options(gate, options)
          values = options[:context]
          decision = gate.resolve(values.respond_to?(:[]) ? values[:armory_version] : nil)
          expected = decision.refused? ? nil : name(decision.version)
          [options[:visibility_profile], values.respond_to?(:[]) ? values[:visibility_profile] : nil].each do |named|
            raise ConfigurationError, foreign(named, expected) unless named.nil? || named == expected
          end
          return options.merge(use_visibility_profile: false) if decision.refused?

          options.merge(visibility_profile: expected)
        end

        # After the query is built and its version decided: it runs under that version's profile, or under the Warden.
        def check(query, decision)
          expected = decision.refused? ? nil : name(decision.version)
          named = query.context[:visibility_profile]
          raise ConfigurationError, foreign(named, expected) unless named.nil? || named == expected

          profile = query.visibility_profile
          if profile
            return if !expected.nil? && profile.name == expected

            raise ConfigurationError, "the query runs under #{profile.name ? "the visibility profile #{profile.name.inspect}" : 'a dynamic visibility profile'}, " \
                                      "not #{expected.inspect}: under profiles: true, pass `profiles: GraphQL::Armory::Versioning.profiles(#{query.schema})` " \
                                      "to `use GraphQL::Schema::Visibility`"
          end
          return if decision.refused? || query.schema.use_visibility_profile?

          raise ConfigurationError, "profiles: true needs `use GraphQL::Schema::Visibility, profiles: GraphQL::Armory::Versioning.profiles(#{query.schema})`: " \
                                    "the schema does not use Schema::Visibility"
        end

        private

        def foreign(named, expected)
          "the query names the visibility profile #{named.inspect}, " \
            "#{expected ? "not its version's #{expected.inspect}" : 'and its version is refused'}: under profiles: true a query runs " \
            "only under its version's profile, which the plugin names. Do not set visibility_profile"
        end

        # `profiles: false`, the default: no profile of its own, and no named profile at all, since one keeps the
        # visibility of every query that names it.
        class Off
          def enabled? = false

          def to_h
            raise ConfigurationError, "Versioning.profiles needs `use GraphQL::Armory::Versioning, ..., profiles: true`, " \
                                      "before `use GraphQL::Schema::Visibility, profiles: GraphQL::Armory::Versioning.profiles(self)`"
          end

          def query_options(_version) = {}

          def options(_gate, options) = options

          def check(query, _decision)
            name = query.visibility_profile.respond_to?(:name) ? query.visibility_profile.name : nil
            return if name.nil?

            raise ConfigurationError, "the query runs under the visibility profile #{name.inspect}: named Schema::Visibility profiles keep " \
                                      "one visibility for every query that names them, so they cannot follow each query's version. Use " \
                                      "`use GraphQL::Armory::Versioning, ..., profiles: true` with `GraphQL::Armory::Versioning.profiles`, or dynamic: true"
          end
        end
      end
    end
  end
end
