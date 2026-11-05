# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # Builds a request's `Key` (design 4.3): a keyed digest over the canonical JSON of every input the answer may depend
      # on that graphql-ruby can see, so no component is ever in clear and none can forge a separator:
      #
      #   ["armory-cache/2", release, schema name, schema digest, engine, document digest, selected operation name,
      #    declared variables, version label, visibility profile, max_depth, max_complexity, scope, viewer, vary]
      #
      #   keyer = Keyer.build(release: ENV.fetch("GIT_SHA"), digester: Digester.build(encoder: AppEncoder),
      #                       viewer: :current_user, vary: { locale: :locale, tenant: -> { Current.tenant&.id } })
      #   keyer.(query, policy, engine: :interpreter)  # => Key, or Policy.refused(reason)
      #   keyer.covered_keys(policy)                   # => [:current_user, :locale]: the context reads the key holds
      #   keyer.viewer_tag_for(user)                   # => the digest of the viewer's purge tag (`:anonymous` too)
      #
      # Refusals: the policy's own (a refused policy is answered as it is), `:unconfigured` (an inert keyer), `:operation`
      # (no operation selected), `:variables` (a declared variable's value is not JSON), `:viewer_unconfigured` and
      # `:anonymous` (a `:viewer` policy with no `viewer:` key, or an anonymous request under `anonymous: :uncacheable`),
      # `:vary_value` (a `vary:` value of a type the key cannot hold), `:version` (a refused version). A principal the key
      # cannot name (an anonymous class, a bad id) raises `ConfigurationError`: that is the app's setup, not the client's.
      #
      # The engine comes from the caller (the gate is told it per `multiplex` call): a query does not know it before it runs.
      # `new` is inert: it refuses every key, like `Keyer::Null`.
      class Keyer
        FORMAT = "armory-cache/2"
        ENGINES = %i[interpreter next].freeze

        # Validates `use`'s `release:`, `viewer:`, `viewer_id:`, `anonymous:`, `anonymous_reason:` and `vary:`; the
        # `digester:` is the one the gate digests tags and purges with, so a viewer tag here matches a purge.
        def self.build(release:, digester:, viewer: nil, viewer_id: Viewer::DEFAULT_ID, anonymous: :uncacheable, anonymous_reason: nil, vary: {})
          raise ConfigurationError, "release: must be a non-empty String (the deploy's identity, such as the git SHA)" unless release.is_a?(String) && !release.strip.empty?
          raise ConfigurationError, "digester: must answer call(string) with a keyed hex digest (a Caching::Digester)" unless digester.respond_to?(:call)

          new(release: release.dup.freeze,
              digester: digester,
              viewer: Viewer.build(key: viewer, id: viewer_id, anonymous: anonymous, anonymous_reason: anonymous_reason),
              vary: Vary.build(vary))
        end

        attr_reader :schema_identity

        def initialize(release: nil, digester: nil, viewer: Viewer.new, vary: Vary.new, schema_identity: SchemaIdentity.new)
          @release = release
          @digester = digester
          @viewer = viewer
          @vary = vary
          @schema_identity = schema_identity
        end

        def call(query, policy, engine:)
          raise ArgumentError, "engine: must be one of #{ENGINES.inspect}, got #{engine.inspect}" unless ENGINES.include?(engine)
          return policy unless policy.cacheable?
          return Policy.refused(:unconfigured) unless configured?

          operation = query.selected_operation
          return Policy.refused(:operation) if operation.nil?

          variables = refusing(:variables) { Canonical.variables(operation, query.provided_variables) }
          return variables if variables.is_a?(Policy)

          viewer = nil
          if policy.scope == :viewer
            viewer = @viewer.(query.context)
            return viewer if viewer.is_a?(Policy)
          end

          vary = refusing(:vary_value) { @vary.(query.context) }
          return vary if vary.is_a?(Policy)

          label = version_label(query)
          return label if label.is_a?(Policy)

          profile = profile_name(query)
          schema = query.schema
          components = [
            FORMAT, @release, schema.name, @schema_identity.schema_digest(schema, label, profile), engine.to_s,
            @schema_identity.document_digest(query.document), operation.name, variables, label,
            profile.nil? ? nil : Canonical.typed(profile), limit(query.max_depth, :max_depth), limit(query.max_complexity, :max_complexity),
            policy.scope.to_s, viewer&.component, vary
          ]

          Key.new(digest: @digester.(Canonical.json(components)), scope: policy.scope, viewer_tag: viewer && @digester.(viewer.tag))
        end

        # The context keys a `:viewer` or `:public` run may read because the key holds their whole value: the `viewer:` key
        # for a `:viewer` policy only, and each `vary:` entry given as a context key. A `vary:` callable covers nothing.
        def covered_keys(policy)
          keys = @vary.context_keys
          keys = [@viewer.key, *keys] if policy.scope == :viewer && !@viewer.key.nil?
          keys.uniq.freeze
        end

        # The keyed digest of a principal's purge tag (or of every anonymous request, `:anonymous`): what `Key#viewer_tag`
        # holds for that principal, so a purge finds its entries.
        def viewer_tag_for(principal)
          raise ConfigurationError, "this keyer is not built: Keyer.build(release:, digester:, ...)" unless configured?

          @digester.(@viewer.tag(principal))
        end

        def inspect = "#<#{self.class.name} viewer=#{@viewer.key.inspect} vary=#{@vary.names.inspect}>"

        private

        def configured?
          !@release.nil? && !@digester.nil?
        end

        def refusing(reason)
          yield
        rescue Canonical::Unsupported
          Policy.refused(reason)
        end

        # The resolved label (`Versioning.version`), not the client's raw value; nil on a schema without Versioning.
        def version_label(query)
          return nil unless query.schema.respond_to?(:armory_versioning)

          Versioning.version(query.context).label
        rescue Versioning::RefusedVersionError
          Policy.refused(:version)
        end

        # The named `Schema::Visibility` profile the query runs under, or nil (a dynamic profile, or the Warden).
        def profile_name(query)
          profile = query.respond_to?(:visibility_profile) ? query.visibility_profile : nil
          profile.respond_to?(:name) ? profile.name : nil
        end

        def limit(value, name)
          return value if value.nil? || value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)

          raise ConfigurationError, "#{name} is a #{value.class}: the key holds an Integer, a finite Float or nil"
        end

        # `vary:`: name => context key (its whole value enters the key and covers that key) or name => callable taking no
        # arguments (for inputs graphql-ruby cannot see, such as `Current` or `I18n.locale`; it covers nothing). Values
        # enter the key with their type, sorted by name; an absent context key is not a nil one.
        class Vary
          Entry = Struct.new(:name, :source, keyword_init: true) do
            def context_key? = source.is_a?(Symbol) || source.is_a?(String)
          end

          def self.build(vary)
            raise ConfigurationError, "vary: must be a Hash of name => context key or callable" unless vary.is_a?(Hash)

            entries = vary.map do |name, source|
              unless (name.is_a?(Symbol) || name.is_a?(String)) && !name.to_s.empty?
                raise ConfigurationError, "vary: names must be non-empty Symbols or Strings, got #{name.inspect}"
              end

              Entry.new(name: name.to_s.freeze, source: source(name, source))
            end
            duplicate = entries.map(&:name).tally.find { |_, count| count > 1 }
            raise ConfigurationError, "vary: names #{duplicate.first.inspect} twice (as a Symbol and a String)" if duplicate

            new(entries.sort_by(&:name))
          end

          def self.source(name, source)
            return source if (source.is_a?(Symbol) || source.is_a?(String)) && !source.to_s.empty?

            arity = if source.respond_to?(:arity) then source.arity
                    elsif source.respond_to?(:call) then source.method(:call).arity
                    end
            return source if [0, -1].include?(arity)

            raise ConfigurationError, "vary: #{name.inspect} must be a context key (Symbol or String) or a callable taking no arguments"
          end
          private_class_method :source

          def initialize(entries = [])
            @entries = entries.freeze
          end

          def names = @entries.map(&:name)

          def context_keys = @entries.select(&:context_key?).map(&:source)

          # `[[name, typed value], ...]`; raises `Canonical::Unsupported` for a value of another type.
          def call(context)
            @entries.map do |entry|
              value = if !entry.context_key? then Canonical.typed(entry.source.call)
                      elsif context.key?(entry.source) then Canonical.typed(context[entry.source])
                      else ["absent"]
                      end
              [entry.name, value]
            end
          end
        end
      end
    end
  end
end
