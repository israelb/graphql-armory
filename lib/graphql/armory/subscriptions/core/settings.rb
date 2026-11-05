# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      class Core < GraphQL::Subscriptions
        # The values `use` was given, checked: the viewer, the context keys a delivery restores, the lifetime and the
        # caps. `new` is inert (the Null viewer refuses every subscription); `build` checks each option. The class
        # methods check the options, the dependencies and the schema for `Core.build`.
        class Settings
          VALUES = %i[context_keys max_lifetime max_per_viewer max_per_topic max_executions_per_trigger on_delivery_error].freeze
          DEPENDENCIES = %i[store transport encoder].freeze
          OTHERS = %i[viewer anonymous cap_key sinks on_sink_error].freeze
          KNOWN = (VALUES + DEPENDENCIES + OTHERS).freeze
          REQUIRED = %i[store transport encoder max_lifetime].freeze
          ON_DELIVERY_ERROR = %i[record raise].freeze
          DEFAULTS = { context_keys: {}, max_per_viewer: 100, max_per_topic: 10_000, max_executions_per_trigger: 10_000, on_delivery_error: :record }.freeze

          # graphql-ruby's own options, which this backend never honours.
          REFUSED = {
            broadcast: "broadcast: is refused: one execution would be sent to every viewer of a topic; every subscriber runs with its own context",
            default_broadcastable: "default_broadcastable: is refused: no subscription is broadcast",
            validate_update: "validate_update: is refused: every delivery is validated like a request (PersistedQueries and Versioning refuse through validation)"
          }.freeze

          STORE_METHODS = %i[write read ids delete count cleanup].freeze
          TRANSPORT_METHODS = %i[capabilities authorization channel_for id_from publish authorize_channel authorize_viewer webhook].freeze
          ENCODER_METHODS = %i[seal open mac].freeze

          attr_reader :viewer, :context_keys, :max_lifetime, :max_per_viewer, :max_per_topic, :max_executions_per_trigger, :on_delivery_error

          # Milliseconds for `max_lifetime`: everything else as given.
          def initialize(viewer: Viewer::Null.new, context_keys: {}, max_lifetime: 1_000, max_per_viewer: 1, max_per_topic: 1, max_executions_per_trigger: 1,
                         on_delivery_error: :record)
            @viewer = viewer
            @context_keys = context_keys
            @max_lifetime = max_lifetime
            @max_per_viewer = max_per_viewer
            @max_per_topic = max_per_topic
            @max_executions_per_trigger = max_executions_per_trigger
            @on_delivery_error = on_delivery_error
            freeze
          end

          def self.build(viewer:, max_lifetime:, **options)
            values = DEFAULTS.merge(options)
            new(viewer: viewer, context_keys: context_keys(values[:context_keys]), max_lifetime: lifetime(max_lifetime),
                max_per_viewer: positive(:max_per_viewer, values[:max_per_viewer]), max_per_topic: positive(:max_per_topic, values[:max_per_topic]),
                max_executions_per_trigger: positive(:max_executions_per_trigger, values[:max_executions_per_trigger]),
                on_delivery_error: on_delivery_error(values[:on_delivery_error]))
          end

          def self.check_options(options)
            options.each_key do |name|
              raise ConfigurationError, REFUSED.fetch(name) if REFUSED.key?(name)
              raise ConfigurationError, "unknown option #{name.inspect}: GraphQL::Armory::Subscriptions takes #{KNOWN.inspect}" unless KNOWN.include?(name)
            end
            missing = REQUIRED.reject { |name| options.key?(name) }
            raise ConfigurationError, "missing #{missing.map { |name| "#{name}:" }.join(", ")} (#{REQUIRED.map { |name| "#{name}:" }.join(", ")} are required)" unless missing.empty?
          end

          # `{ key: "why every delivery needs it" }`: the only context values stored with a subscription.
          def self.context_keys(keys)
            valid = keys.is_a?(Hash) && keys.all? { |key, reason| key.is_a?(Symbol) && reason.is_a?(String) && !reason.strip.empty? }
            raise ConfigurationError, "context_keys: must map Symbol keys to the reason each one is stored, like { tenant_id: \"scopes every query\" }" unless valid

            reserved = keys.keys & RESERVED_KEYS
            raise ConfigurationError, "context_keys: #{reserved.inspect} are set by the core on every delivery, from the subscription itself" unless reserved.empty?

            keys.to_h { |key, reason| [key, reason.dup.freeze] }.freeze
          end

          # Context keys a delivery takes from the stored record, never from `context_keys:`.
          RESERVED_KEYS = %i[armory_version operation_id armory_allow_raw_query visibility_profile subscription_id].freeze

          # Seconds in, milliseconds out.
          def self.lifetime(value)
            unless value.is_a?(Numeric) && value.real? && value.finite? && value.positive? && (value * 1000).round >= 1
              raise ConfigurationError, "max_lifetime: must be a positive number of seconds (every subscription expires: no provider reports a gone client reliably), got #{value.inspect}"
            end

            (value * 1000).round
          end

          def self.positive(name, value)
            raise ConfigurationError, "#{name}: must be a positive Integer, got #{value.inspect}" unless value.is_a?(Integer) && value.positive?

            value
          end

          def self.on_delivery_error(value)
            raise ConfigurationError, "on_delivery_error: must be :record or :raise, got #{value.inspect}" unless ON_DELIVERY_ERROR.include?(value)

            value
          end

          def self.store(store)
            raise ConfigurationError, "store: Store::Null keeps no subscription: give a MemoryStore (one process) or a RedisStore" if store.is_a?(Store::Null)
            raise ConfigurationError, "store: must answer #{STORE_METHODS.inspect} (a MemoryStore, a RedisStore), got #{store.class}" unless STORE_METHODS.all? { |name| store.respond_to?(name) }

            store
          end

          def self.transport(transport)
            raise ConfigurationError, "transport: Transport::Null delivers nothing: give a transport such as Pusher or Ably" if transport.is_a?(Transport::Null)
            raise ConfigurationError, "transport: must answer #{TRANSPORT_METHODS.inspect}, got #{transport.class}" unless TRANSPORT_METHODS.all? { |name| transport.respond_to?(name) }
            raise ConfigurationError, "transport: #{transport.class} must declare its capabilities (a Capabilities)" unless transport.capabilities.is_a?(Capabilities)
            raise ConfigurationError, "transport: #{transport.class} authorization must be one of #{Transport::AUTHORIZATIONS.inspect}" unless Transport::AUTHORIZATIONS.include?(transport.authorization)

            transport
          end

          def self.encoder(encoder)
            if encoder.nil? || encoder.equal?(Encoder::Null)
              raise ConfigurationError, "encoder: is required (an Encoder subclass with a key): it seals stored subscriptions and digests topics and viewers"
            end
            raise ConfigurationError, "encoder: must answer #{ENCODER_METHODS.inspect} (an Encoder subclass), got #{encoder.class}" unless ENCODER_METHODS.all? { |name| encoder.respond_to?(name) }

            encoder
          end

          # With a viewer, a client must not be able to read another viewer's channel.
          def self.check_transport(transport, viewer)
            return if viewer.anonymous? || transport.capabilities.viewer_bound?

            raise ConfigurationError, "transport: #{transport.class} is not viewer_bound (it cannot refuse a client a channel), so with viewer: " \
                                      "one viewer could read another's subscriptions: use a transport with private channels or capability tokens"
          end

          # Each subscription field (every definition, so every version of a Versioning schema): no `topic_for`
          # override (its topics would never meet the core's digest), no `loads:`/`prepare:` argument and no input object
          # with its own `prepare` (the write side and the trigger side would hold different values), and a
          # `subscription_scope` key a delivery can restore.
          def self.check_schema(schema, settings)
            root = schema.subscription
            raise ConfigurationError, "#{schema} has no subscription root: declare `subscription(Types::Subscription)` before `use GraphQL::Armory::Subscriptions`" unless root

            restorable = settings.context_keys.keys + settings.viewer.sets
            root.all_field_definitions.each do |field|
              check_topic_for(field)
              unsafe = unsafe_argument(field, [])
              raise ConfigurationError, "#{field.path}: #{unsafe} cannot meet its trigger (the subscription and the trigger would digest different values): remove it from the subscription field" if unsafe

              scope = field.subscription_scope
              next if scope.nil? || restorable.include?(scope.to_sym)

              raise ConfigurationError, "#{field.path} is scoped by context[#{scope.inspect}], which a delivery cannot restore: add it to context_keys: or to viewer: { sets: [...] }"
            end
          end

          def self.check_topic_for(field)
            resolver = field.resolver
            return unless resolver.respond_to?(:topic_for)
            return if resolver.method(:topic_for).owner == GraphQL::Schema::Subscription.singleton_class

            raise ConfigurationError, "#{field.path}: #{resolver} overrides topic_for: its topics would never meet the core's topic digest; remove the override"
          end
          private_class_method :check_topic_for

          # The first argument (by path) with `loads:` or `prepare:`, or an input object with its own `prepare`.
          def self.unsafe_argument(owner, seen)
            owner.all_argument_definitions.each do |argument|
              return "the loads: argument #{argument.path}" if argument.loads
              return "the prepare: argument #{argument.path}" if argument.prepare

              type = argument.type.unwrap
              next unless type.kind.input_object? && !seen.include?(type)

              seen << type
              return "the input object #{type.graphql_name} with its own prepare" if type.instance_method(:prepare).owner != GraphQL::Schema::InputObject

              found = unsafe_argument(type, seen)
              return found if found
            end
            nil
          end
          private_class_method :unsafe_argument
        end
      end
    end
  end
end
