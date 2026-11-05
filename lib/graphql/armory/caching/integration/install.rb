# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      module Integration
        # The installer behind `use GraphQL::Armory::Caching` (docs/response-caching.md "Installing"): checks every option at boot,
        # refuses a second `use` in one hierarchy and a `rescue_from` registered before it, builds the gate, and prepends
        # the guard. PersistedQueries is checked at the first request, not here: the two `use` lines may come in either
        # order.
        module Install
          # `gate:` is internal: specs inject a `Gate::Substitute`. Without it the real gate is built from the settings.
          def self.call(schema, gate: nil, **options)
            if schema.singleton_class.include?(Guard)
              raise ConfigurationError, "#{schema} already uses GraphQL::Armory::Caching (here or in a parent schema): use it once"
            end
            if Handlers.registered?(schema)
              raise ConfigurationError, "#{schema} registered a rescue_from handler before `use GraphQL::Armory::Caching`, which cannot wrap it: " \
                                        "a run that handler answered could be stored. Move `use GraphQL::Armory::Caching` above `rescue_from`"
            end

            settings = Settings.build(**options)
            gate ||= build_gate(schema, settings)
            unless gate.respond_to?(:call) && gate.respond_to?(:store)
              raise ConfigurationError, "gate: must answer call(queries, engine:) and store(query, decision, result), found a #{gate.class}"
            end

            schema.instance_variable_set(:@armory_caching, settings.bind(gate))
            schema.singleton_class.prepend(Guard)
            schema.context_class(schema.context_class)
            schema.query_class(schema.query_class)
          end

          # The seam the integration wires to the real gate: `Gate.build(schema, **settings.to_h)`, which
          # receives the checked options plus the one `digester:` and `telemetry:` every part shares.
          def self.build_gate(schema, settings)
            raise NotImplementedError, "#{schema}: Caching::Gate.build is not defined" unless Gate.respond_to?(:build)

            Gate.build(schema, **settings.to_h)
          end
          private_class_method :build_gate
        end

        # The checked `use` options, frozen, read through `schema.armory_caching` by the gate, the keyer, `Purge` and
        # the audit. `digester` is the one keyed digester for keys and tags (from `encoder:`, or a per-process key), so
        # what `purge` digests matches what the gate stored; `telemetry` is built from `sinks:` and `on_sink_error:`.
        class Settings
          DEFAULT_VIEWER_ID = ->(principal) { principal.id }
          ANONYMOUS = %i[uncacheable shared].freeze
          MAX_VIEWER_TTL = 300
          REDIS_STORE = "GraphQL::Armory::Caching::RedisStore"
          STORE_METHODS = %i[lookup write purge purge_all].freeze
          SEALING = %i[seal open mac].freeze

          FIELDS = %i[store encoder release viewer viewer_id anonymous anonymous_reason vary max_ttl max_viewer_ttl max_entry_bytes
                      neutral_keys context_methods own_checks extensions sinks on_sink_error on_store_error digester telemetry].freeze

          attr_reader(*FIELDS, :gate)

          def self.build(store: nil, encoder: nil, release: nil, viewer: nil, viewer_id: nil, anonymous: :uncacheable, anonymous_reason: nil,
                         vary: {}, max_ttl: 3600, max_viewer_ttl: MAX_VIEWER_TTL, max_entry_bytes: 262_144, neutral_keys: {}, context_methods: {},
                         own_checks: {}, extensions: false, sinks: [], on_sink_error: nil, on_store_error: nil)
            check_store(store)
            check_encoder(encoder, store)
            raise ConfigurationError, "release: must be a non-empty String (the deploy, e.g. ENV.fetch(\"GIT_SHA\"))" unless text?(release)

            check_viewer(viewer, viewer_id)
            check_anonymous(anonymous, anonymous_reason, viewer)
            new(store: store, encoder: encoder, release: release.dup.freeze, viewer: viewer, viewer_id: viewer_id || DEFAULT_VIEWER_ID,
                anonymous: anonymous, anonymous_reason: anonymous_reason&.dup&.freeze, vary: check_vary(vary),
                max_ttl: positive(:max_ttl, max_ttl), max_viewer_ttl: viewer_ttl(max_viewer_ttl), max_entry_bytes: positive(:max_entry_bytes, max_entry_bytes),
                neutral_keys: reasons(:neutral_keys, neutral_keys, viewer), context_methods: reasons(:context_methods, context_methods, nil).transform_keys(&:to_sym).freeze,
                own_checks: check_own_checks(own_checks), extensions: boolean(:extensions, extensions), sinks: sinks, on_sink_error: on_sink_error, on_store_error: callable(:on_store_error, on_store_error),
                digester: encoder ? Digester.build(encoder: encoder) : Digester.new, telemetry: telemetry(sinks, on_sink_error))
          end

          def initialize(store: Store::Null.new, encoder: nil, release: nil, viewer: nil, viewer_id: DEFAULT_VIEWER_ID, anonymous: :uncacheable,
                         anonymous_reason: nil, vary: {}, max_ttl: 3600, max_viewer_ttl: MAX_VIEWER_TTL, max_entry_bytes: 262_144, neutral_keys: {},
                         context_methods: {}, own_checks: {}, extensions: false, sinks: [], on_sink_error: nil, on_store_error: nil, digester: Digester.new,
                         telemetry: Telemetry.new, gate: nil)
            @store = store
            @encoder = encoder
            @release = release
            @viewer = viewer
            @viewer_id = viewer_id
            @anonymous = anonymous
            @anonymous_reason = anonymous_reason
            @vary = vary
            @max_ttl = max_ttl
            @max_viewer_ttl = max_viewer_ttl
            @max_entry_bytes = max_entry_bytes
            @neutral_keys = neutral_keys
            @context_methods = context_methods
            @own_checks = own_checks
            @extensions = extensions
            @sinks = sinks
            @on_sink_error = on_sink_error
            @on_store_error = on_store_error
            @digester = digester
            @telemetry = telemetry
            @gate = gate
            freeze
          end

          # The same settings with the gate that decides for them.
          def bind(gate)
            self.class.new(**to_h, gate: gate)
          end

          # Every field but the gate, as keywords: what `Gate.build(schema, **settings.to_h)` receives.
          def to_h
            FIELDS.to_h { |field| [field, public_send(field)] }
          end

          def inspect = "#<#{self.class.name} release=#{release.inspect}>"

          def self.check_store(store)
            raise ConfigurationError, "store: is required (a MemoryStore, or a RedisStore with encoder:)" if store.nil?
            raise ConfigurationError, "store: Store::Null is a cache that stores nothing: pass a MemoryStore or a RedisStore" if store.is_a?(Store::Null)
            return if STORE_METHODS.all? { |name| store.respond_to?(name) }

            raise ConfigurationError, "store: must answer lookup, write, purge and purge_all, like a MemoryStore; found a #{store.class}"
          end

          # Named, never loaded: RedisStore is its own unit, and a subclass counts too.
          def self.check_encoder(encoder, store)
            if encoder.nil?
              return unless store.class.ancestors.any? { |ancestor| ancestor.name == REDIS_STORE }

              raise ConfigurationError, "encoder: is required with RedisStore: entries in Redis are sealed and their keys digested with it (an Encoder subclass)"
            end

            if [Encoder::Null, Encoder::Legacy].any? { |plain| encoder.is_a?(Module) && encoder <= plain }
              raise ConfigurationError, "encoder: #{encoder.name} does not encrypt: pass an Encoder subclass with a key"
            end
            return if SEALING.all? { |name| encoder.respond_to?(name) }

            raise ConfigurationError, "encoder: must seal entries (seal, open and mac), like an Encoder subclass with a key; found a #{encoder.class}"
          end

          def self.check_viewer(viewer, viewer_id)
            unless viewer.nil? || ((viewer.is_a?(Symbol) || viewer.is_a?(String)) && !viewer.empty?)
              raise ConfigurationError, "viewer: must be the context key that holds the principal (a Symbol or a String), or nil"
            end
            return if viewer_id.nil?
            raise ConfigurationError, "viewer_id: needs viewer:, the context key it reads the principal from" if viewer.nil?

            callable(:viewer_id, viewer_id)
          end

          def self.check_anonymous(anonymous, reason, viewer)
            raise ConfigurationError, "anonymous: must be one of #{ANONYMOUS.map(&:inspect).join(", ")}, got #{anonymous.inspect}" unless ANONYMOUS.include?(anonymous)

            if anonymous == :shared
              raise ConfigurationError, "anonymous: :shared needs viewer:, the key whose absence makes a request anonymous" if viewer.nil?
              raise ConfigurationError, "anonymous: :shared needs anonymous_reason:, a non-empty String the audit lists" unless text?(reason)
            elsif !reason.nil?
              raise ConfigurationError, "anonymous_reason: goes with anonymous: :shared only"
            end
          end

          # name => context key (its value enters the key whole) or a callable taking no arguments.
          def self.check_vary(vary)
            raise ConfigurationError, "vary: must be a Hash of name => context key or callable taking no arguments" unless vary.is_a?(Hash)

            vary.each do |name, source|
              raise ConfigurationError, "vary: names must be non-empty Symbols or Strings" unless key?(name)
              next if key?(source)
              raise ConfigurationError, "vary: #{name} must be a context key (Symbol or String) or a callable" unless source.respond_to?(:call)
              raise ConfigurationError, "vary: #{name} must be a callable that takes no arguments (read Current or I18n, not the context)" unless no_arguments?(source)
            end
            names = vary.keys.map(&:to_s)
            raise ConfigurationError, "vary: names a value twice (#{names.find { |name| names.count(name) > 1 }})" unless names.uniq.size == names.size

            vary.dup.freeze
          end

          # key => reason, each reason a non-empty String the audit lists.
          def self.reasons(option, declared, viewer)
            raise ConfigurationError, "#{option}: must be a Hash of name => reason" unless declared.is_a?(Hash)

            declared.each do |name, reason|
              raise ConfigurationError, "#{option}: names must be non-empty Symbols or Strings" unless key?(name)
              raise ConfigurationError, "#{option}: #{name} needs a reason, a non-empty String" unless text?(reason)
            end
            if !viewer.nil? && declared.key?(viewer)
              raise ConfigurationError, "neutral_keys: cannot hold the viewer key #{viewer.inspect}: a shared answer that reads it depends on the viewer"
            end

            declared.transform_values { |reason| reason.dup.freeze }.freeze
          end

          # For the audit only, Authorization's shape: `{ Types::Invoice => { visible?: "reason" } }`. Changes nothing at runtime.
          def self.check_own_checks(own_checks)
            raise ConfigurationError, "own_checks: must be a Hash of class => { method name => reason }" unless own_checks.is_a?(Hash)

            own_checks.each do |owner, methods|
              raise ConfigurationError, "own_checks: keys must be classes or modules, found a #{owner.class}" unless owner.is_a?(Module)
              raise ConfigurationError, "own_checks: #{owner} must map method names to reasons" unless methods.is_a?(Hash)

              reasons("own_checks: #{owner}", methods, nil)
            end
            own_checks.dup.freeze
          end

          def self.positive(option, value)
            raise ConfigurationError, "#{option}: must be a positive Integer, got #{value.inspect}" unless value.is_a?(Integer) && value.positive?

            value
          end

          def self.viewer_ttl(value)
            positive(:max_viewer_ttl, value)
            raise ConfigurationError, "max_viewer_ttl: is at most #{MAX_VIEWER_TTL} seconds, got #{value}" if value > MAX_VIEWER_TTL

            value
          end

          def self.boolean(option, value)
            raise ConfigurationError, "#{option}: must be true or false, got #{value.inspect}" unless [true, false].include?(value)

            value
          end

          def self.callable(option, value)
            raise ConfigurationError, "#{option}: must be a callable, found a #{value.class}" unless value.nil? || value.respond_to?(:call)

            value
          end

          def self.telemetry(sinks, on_sink_error)
            Telemetry.build(sinks: sinks, on_sink_error: on_sink_error)
          rescue Telemetry::ConfigurationError => error
            raise ConfigurationError, error.message
          end

          def self.text?(value)
            value.is_a?(String) && !value.strip.empty?
          end

          def self.key?(value)
            (value.is_a?(Symbol) || value.is_a?(String)) && !value.empty?
          end

          # A lambda or method with no required parameter, or a block proc that names none.
          def self.no_arguments?(callable)
            target = callable.is_a?(Proc) || callable.is_a?(Method) ? callable : callable.method(:call)
            parameters = target.parameters
            return false if parameters.any? { |type, _| %i[req keyreq].include?(type) }

            !(target.is_a?(Proc) && !target.lambda? && parameters.any?)
          rescue NameError
            false
          end

          private_class_method :check_store, :check_encoder, :check_viewer, :check_anonymous, :check_vary, :check_own_checks, :reasons, :positive, :viewer_ttl,
                               :boolean, :callable, :telemetry, :text?, :key?, :no_arguments?
        end
      end
    end
  end
end
