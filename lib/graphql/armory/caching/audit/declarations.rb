# frozen_string_literal: true

require "set"

module GraphQL
  module Armory
    module Caching
      class Audit
        # Reads every declaration once: what it is (a type's `cache_fields`, a field's `cache:`, a directive's `cache_safe`),
        # whether it can be used at all, whether the installed limits allow its TTL, and lists the public ones and the
        # installed configuration's own declarations with their reasons. Answers the (serving type, field) pairs a
        # `:public` declaration covers, for the checks of what stands on their path.
        class Declarations
          # graphql-ruby's names for the places a directive can stand in an operation.
          EXECUTABLE_LOCATIONS = %i[QUERY MUTATION SUBSCRIPTION FIELD FRAGMENT_DEFINITION FRAGMENT_SPREAD INLINE_FRAGMENT VARIABLE_DEFINITION].freeze

          # Whether anything of the schema includes `Caching::Base`: a type, a field or a directive.
          def self.uses_base?(schema)
            Audit.definitions(schema).any? do |type|
              type.respond_to?(:armory_cache_fields) || Armory::Definitions.fields_at_every_level(type).any? { |field| field.respond_to?(:armory_cache_own) }
            end || schema.directives.each_value.any? { |directive| directive.respond_to?(:armory_cache_safe?) }
          end

          # [[serving type, field, declaration]] for every field whose declaration is `:public`, on every type that serves it.
          attr_reader :public_pairs

          def initialize(schema, definitions, settings, findings)
            @schema = schema
            @definitions = definitions
            @settings = settings
            @findings = findings
            @public_pairs = []
            @seen = Set.new.compare_by_identity
            @declarations = {}.compare_by_identity
          end

          def call
            ignored_roots = [@schema.mutation, @schema.subscription].compact
            @definitions.each do |type|
              next ignored_input(type) if type.kind.input_object?
              next unless type.respond_to?(:fields)
              next ignored_root(type) if ignored_roots.include?(type)

              type_default(type)
              Armory::Definitions.fields_at_every_level(type).each { |field| field_declaration(type, field) }
            end
            directives
            installed
          end

          private

          def type_default(type)
            declaration = type.armory_cache_fields if type.respond_to?(:armory_cache_fields)
            return if declaration.nil?

            check(declaration, type.graphql_name, type)
          end

          def field_declaration(type, field)
            declaration = declaration_of(field)
            return if declaration.nil? || declaration.forbidden?

            @public_pairs << [type, field, declaration] if declaration.public?
            return unless @seen.add?(field) && !field.armory_cache_own.nil?
            # A field that keeps its type's TTL and scope is that type's declaration: it is checked and listed there.
            return if inherits?(field, declaration) && !declaration.public?

            check(declaration, path_of(field), field, limits: !inherits?(field, declaration))
          end

          # The declaration that applies to a field, worked out once. One its type cannot complete raises
          # (`armory_cache`): it is reported, and the field counts as declaring nothing, as the walk refuses it.
          def declaration_of(field)
            return unless field.respond_to?(:armory_cache)
            return @declarations[field] if @declarations.key?(field)

            @declarations[field] = field.armory_cache
          rescue ConfigurationError => error
            @findings.problem(:incomplete, path_of(field), "#{error.message}: its type declares no cache_fields to complete it, so it is never cached. " \
                                                           "Give it ttl:, or give its type cache_fields", at: field)
            @declarations[field] = nil
          end

          def inherits?(field, declaration)
            default = field.owner.armory_cache_fields if field.owner.respond_to?(:armory_cache_fields)
            !default.nil? && default.ttl == declaration.ttl && default.scope == declaration.scope
          end

          def check(declaration, path, at, limits: true)
            @findings.declared(:public, path, declaration.reason, at: at) if declaration.public?
            return unless limits

            ttl(declaration, path, at)
            viewer(declaration, path, at)
          end

          def ttl(declaration, path, at)
            if declaration.ttl > @settings.max_ttl
              @findings.problem(:ttl, path, "ttl: #{declaration.ttl} is longer than max_ttl: #{@settings.max_ttl} allows. Lower it", at: at)
            elsif !declaration.public? && declaration.ttl > @settings.max_viewer_ttl
              @findings.problem(:ttl, path, "a :viewer ttl: #{declaration.ttl} is longer than max_viewer_ttl: #{@settings.max_viewer_ttl} allows: " \
                                            "a viewer keeps a revoked permission's answer that long. Lower it", at: at)
            end
          end

          def viewer(declaration, path, at)
            return if declaration.public? || !@settings.installed? || !@settings.viewer.nil?

            @findings.problem(:viewer_unconfigured, path, "declared :viewer, but `use GraphQL::Armory::Caching` sets no viewer:, so operations that " \
                                                          "select it never cache. Set viewer:, or declare it :public if it really is the same for everyone", at: at)
          end

          # A mutation and a subscription are never cached: what their root declares is never read.
          def ignored_root(type)
            label = type.equal?(@schema.mutation) ? "mutation" : "subscription"
            if type.respond_to?(:armory_cache_fields) && type.armory_cache_fields
              @findings.problem(:ignored, type.graphql_name, "cache_fields on the #{label} root type is never used: a #{label} is never cached. Remove it", at: type)
            end
            Armory::Definitions.fields_at_every_level(type).each do |field|
              next unless field.respond_to?(:armory_cache_own) && !field.armory_cache_own.nil?

              @findings.problem(:ignored, "#{type.graphql_name}.#{field.graphql_name}", "cache: on a #{label} field is never used: a #{label} is never cached. Remove it", at: field)
            end
          end

          def ignored_input(type)
            return unless type.respond_to?(:armory_cache_fields) && type.armory_cache_fields

            @findings.problem(:ignored, type.graphql_name, "cache_fields on an input type is never used: only output fields are cached. Remove it", at: type)
          end

          # A directive in an operation makes it uncacheable unless it declares `cache_safe`: that never serves a wrong
          # answer, so it is information.
          def directives
            defaults = GraphQL::Schema.default_directives
            @schema.directives.each do |name, directive|
              next if defaults[name].equal?(directive)

              path = "@#{name}"
              if directive.respond_to?(:armory_cache_safe?) && directive.armory_cache_safe?
                @findings.declared(:cache_safe, path, directive.armory_cache_safe_reason, at: directive)
              elsif (Array(directive.locations).map(&:to_sym) & EXECUTABLE_LOCATIONS).any?
                @findings.information(:directive, path, "an operation that uses it is never cached: declare `cache_safe reason: \"...\"` on it if it does not change the data", at: directive)
              end
            end
          end

          # What the installed configuration declares, with its reasons. `context_methods:` is listed by ContextClass,
          # which knows which of them the context class defines.
          def installed
            return unless @settings.installed?

            @findings.declared(:anonymous, "anonymous: :shared", @settings.anonymous_reason.to_s) if @settings.anonymous == :shared
            @settings.neutral_keys.each { |key, reason| @findings.declared(:neutral_key, "neutral_keys: #{key.inspect}", reason.to_s) }
          end

          def path_of(field)
            owner = field.owner
            "#{owner.respond_to?(:graphql_name) ? owner.graphql_name : owner.inspect}.#{field.graphql_name}"
          end
        end
      end
    end
  end
end
