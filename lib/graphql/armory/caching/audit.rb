# frozen_string_literal: true

require "graphql/armory/authorization/audit"
require "graphql/armory/caching/audit/report"
require "graphql/armory/caching/audit/declarations"
require "graphql/armory/caching/audit/public_rules"
require "graphql/armory/caching/audit/own_checks"
require "graphql/armory/caching/audit/context_class"
require "graphql/armory/caching/audit/command"

module GraphQL
  module Armory
    module Caching
      # Walks a schema's declarations, without running a query, and reports every place a cached answer could reach a
      # viewer it was not computed for, or could never be used. Every declaration someone made is listed apart, with its
      # reason, so a reviewer can read them.
      #
      #   report = GraphQL::Armory::Caching::Audit.(AppSchema)
      #   report.ok?   # false when a :public declaration stands over a rule, a check it cannot read, ...
      #   puts report
      #   GraphQL::Armory::Caching::Audit.(AppSchema, own_checks: { Types::Product => { authorized?: "reads the class only" } })
      #   GraphQL::Armory::Caching::Audit.(AppSchema, strict: true)   # information (:directive) fails it too
      #
      # It walks every type the roots, the orphan types and `schema.types` reach, hidden or not, so every version of a
      # Versioning schema is read at once. It never runs at boot or during a request. Its `ok?` covers only what
      # Authorization's chokepoints decide: an answer that depends on something they do not see (`Current.user`, a
      # thread-local tenant) passes it (docs/response-caching.md "Guarantees and limits").
      class Audit
        OWN_CHECKS = %i[visible? authorized? scope_items authorized_new wrap].freeze

        attr_reader :configuration, :own_checks

        # `new` is inert: with no configuration, caching counts as not installed, so a schema that declares anything is
        # reported as `:plugin`. `configuration` is what `use GraphQL::Armory::Caching` installed (the schema's
        # `armory_caching`); see `Settings` for the attributes read.
        def initialize(configuration: nil, own_checks: {}, strict: false)
          check_own_checks(own_checks)
          @configuration = configuration
          @own_checks = own_checks.to_h { |holder, methods| [holder, methods.to_h { |name, reason| [name, reason.dup.freeze] }.freeze] }.freeze
          @strict = strict == true
          freeze
        end

        def self.build(schema, own_checks: {}, strict: false)
          configuration = schema.respond_to?(:armory_caching) ? schema.armory_caching : nil
          new(configuration: configuration, own_checks: own_checks, strict: strict)
        end

        def self.call(schema, own_checks: {}, strict: false)
          build(schema, own_checks: own_checks, strict: strict).(schema)
        end

        def call(schema)
          findings = Findings.new
          settings = Settings.new(@configuration)
          plugin(schema, settings, findings)
          definitions = Audit.definitions(schema)
          declarations = Declarations.new(schema, definitions, settings, findings)
          declarations.()
          pairs = declarations.public_pairs
          PublicRules.new(definitions, findings).(pairs)
          OwnChecks.new(definitions, findings).(pairs, own_checks_of(settings))
          ContextClass.(schema, settings, findings) if settings.installed?
          findings.report(strict: @strict)
        end

        # Every definition the schema holds, hidden or not: what the roots and the orphan types reach, what `schema.types`
        # lists, and Versioning's extra types. Introspection types are left out: they hold nothing an app declares.
        def self.definitions(schema)
          extra = schema.respond_to?(:extra_types) ? Array(schema.extra_types) : []
          Armory::Definitions.(schema, Authorization::Definitions.(schema) + extra).reject { |type| Armory::Definitions.introspection?(type) }
        end

        private

        def plugin(schema, settings, findings)
          if !settings.installed?
            return unless Declarations.uses_base?(schema)

            findings.problem(:plugin, "Schema", "includes GraphQL::Armory::Caching::Base but never installed the plugin: its declarations cache nothing. " \
                                                "Add `use GraphQL::Armory::Caching, store: ..., release: ...`", at: schema)
          elsif !persisted_queries?(schema)
            findings.problem(:plugin, "Schema", "installs caching without PersistedQueries, so its first request raises: only persisted operations are cached. " \
                                                "Add `use GraphQL::Armory::PersistedQueries, store: ...`", at: schema)
          end
        end

        def persisted_queries?(schema)
          schema.respond_to?(:armory_persisted_queries) && !schema.armory_persisted_queries.nil?
        rescue NoMethodError
          false
        end

        # The audit's own `own_checks:`, plus the installed configuration's when it carries any.
        def own_checks_of(settings)
          settings.own_checks.merge(@own_checks) { |_holder, installed, given| installed.merge(given) }
        end

        def check_own_checks(checks)
          valid = checks.is_a?(Hash) && checks.all? do |holder, methods|
            holder.is_a?(Module) && methods.is_a?(Hash) && methods.all? do |name, reason|
              OWN_CHECKS.include?(name) && reason.is_a?(String) && !reason.strip.empty?
            end
          end
          return if valid

          raise ArgumentError, "own_checks must map a class to #{OWN_CHECKS.inspect} and the reason you keep each, got #{checks.inspect}"
        end

        # What the audit reads from the installed configuration, duck-typed: an attribute it does not answer takes the
        # `use` default. With no configuration, caching is not installed.
        class Settings
          DEFAULTS = { viewer: nil, anonymous: :uncacheable, anonymous_reason: nil, neutral_keys: {}, context_methods: {},
                       max_ttl: 3600, max_viewer_ttl: 300, own_checks: {} }.freeze

          DEFAULTS.each_key do |name|
            define_method(name) { @values.fetch(name) }
          end

          def initialize(configuration)
            @installed = !configuration.nil?
            @values = DEFAULTS.to_h do |name, default|
              value = configuration.respond_to?(name) ? configuration.public_send(name) : nil
              [name, value.nil? ? default : value]
            end
            freeze
          end

          def installed?
            @installed
          end
        end
      end
    end
  end
end
