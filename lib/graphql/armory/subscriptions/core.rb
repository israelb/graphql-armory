# frozen_string_literal: true

require "securerandom"
require "json"
require "zlib"
require "base64"
require "openssl"

module GraphQL
  module Armory
    module Subscriptions
      # The schema plugin: `use GraphQL::Armory::Subscriptions, store:, transport:, encoder:, viewer:, max_lifetime:, ...`
      # installs a `Core` built and checked by `Core.build` (see docs/subscriptions.md).
      def self.use(schema, **options)
        Core.use(schema, **options)
      end

      # A checked, wired backend for `schema`, without installing it.
      def self.build(schema, **options)
        Core.build(schema, **options)
      end

      # An inert backend: it stores nothing, delivers nothing and authorizes no channel.
      def self.new(**dependencies)
        Core.new(**dependencies)
      end

      DELIVERY = :subscription_delivery

      # What the core puts in a delivery's `namespace(:armory)`: an object only this code makes, under a namespace no
      # request can write (graphql-ruby keeps namespaces apart from the context values the app provides).
      class DeliveryMark
        def initialize
          freeze
        end

        def inspect = "#<#{self.class.name}>"
      end
      private_constant :DeliveryMark

      # Marks `context` (a query's, after `Query.new`) as a subscription delivery: server work a trigger caused, which
      # no rate limiter charges to the subscriber. The id is not kept: a mark may end up in a log.
      def self.delivery!(context, _id)
        context.namespace(:armory)[DELIVERY] = DeliveryMark.new
        nil
      end

      # Whether `context` is a query context the core marked as a delivery. Anything else answers false: a Hash, nil,
      # NullContext, a context whose request put any value of its own anywhere.
      def self.delivery?(context)
        return false unless context.is_a?(GraphQL::Query::Context) && !context.is_a?(GraphQL::Query::NullContext) && context.namespace?(:armory)

        context.namespace(:armory)[DELIVERY].is_a?(DeliveryMark)
      end

      # The graphql-ruby subscriptions backend: subscribe (`write_subscription`), `trigger`, delivery, channel and
      # viewer authorization, webhooks and cleanup over a `Store` and a `Transport`. Each delivery runs as the
      # subscriber (stored allow-listed context keys and the reloaded viewer, never the trigger's context) through the
      # schema's own query class, so Authorization, Versioning and PersistedQueries decide it like a request; a
      # refused delivery ends the subscription.
      #
      # `new` is inert: a Null store (refuses every subscription), a Null transport (delivers nothing, authorizes no
      # channel) and the Null encoder (seals and digests nothing). `build` checks every option and wires the real ones;
      # `use` goes through `build`.
      class Core < GraphQL::Subscriptions
        SEAL_PURPOSE = "subscription"
        VIEWER_PURPOSE = "subscription-viewer"
        CAP_PURPOSE = "subscription-cap"
        ID_PURPOSE = "subscription-id"
        ID_BYTES = 32

        # Installs a built backend on `schema`. Refuses a schema (or a parent) that already has one.
        def self.use(schema, **options)
          if schema.subscriptions(inherited: false)
            raise ConfigurationError, "#{schema} already has subscriptions (#{schema.subscriptions.class}): install GraphQL::Armory::Subscriptions once"
          end
          if schema.subscriptions
            raise ConfigurationError, "#{schema} inherits subscriptions (#{schema.subscriptions.class}) from a parent schema: install GraphQL::Armory::Subscriptions on one schema only"
          end

          schema.subscriptions = build(schema, **options)
          schema.add_subscription_extension_if_necessary
          nil
        end

        # Checks every option (unknown ones raise) and the schema's subscription fields, then wires the dependencies.
        def self.build(schema, **options)
          Settings.check_options(options)
          store = Settings.store(options[:store])
          transport = Settings.transport(options[:transport])
          encoder = Settings.encoder(options[:encoder])
          viewer = Viewer.build(viewer: options[:viewer], anonymous: options[:anonymous], cap_key: options[:cap_key])
          settings = Settings.build(viewer: viewer, **options.slice(*Settings::VALUES))
          Settings.check_transport(transport, viewer)
          Settings.check_schema(schema, settings)
          telemetry = Telemetry.build(sinks: options.fetch(:sinks, []), on_sink_error: options[:on_sink_error])

          new(schema: schema, settings: settings, store: store, transport: transport, encoder: encoder, telemetry: telemetry)
        end

        attr_reader :schema, :settings, :store, :transport, :encoder
        # A callable answering Integer milliseconds: `Clock.system`, or a `Clock::Substitute` in tests.
        attr_accessor :clock
        # The Telemetry `build` made from `sinks:`, or a `Telemetry::Substitute` in tests.
        attr_accessor :telemetry

        def initialize(schema: nil, settings: Settings.new, store: Store::Null.new, transport: Transport::Null.new, encoder: Encoder::Null,
                       telemetry: Telemetry.new, clock: Clock.system)
          super(schema: schema)
          @settings = settings
          @store = store
          @transport = transport
          @encoder = encoder
          @telemetry = telemetry
          @clock = clock
        end

        # 32 random bytes, urlsafe base64: never taken from the context, where a client could choose a victim's id.
        def build_id
          SecureRandom.urlsafe_base64(ID_BYTES, false)
        end

        # Always false: every subscriber is executed with its own context, never grouped with another viewer's.
        def broadcastable?(_query_str, **_query_options)
          false
        end

        # Always true: a delivery is validated like a request (PersistedQueries and Versioning refuse through it).
        def validate_update?(**_options)
          true
        end

        # The channel of the subscription `query` created, for the `X-Subscription-ID` header, or nil.
        def channel_for(query)
          context = query.respond_to?(:context) ? query.context : query
          return nil unless context.respond_to?(:namespace?) && context.namespace?(:armory)

          context.namespace(:armory)[:subscription_channel]
        end

        def delete_subscription(subscription_id)
          @store.delete(subscription_id)
        end

        # Removes every record expired at `now` (a Time, or Integer milliseconds; the clock when nil). Answers how many.
        # Call it from a periodic job: an expired record is also dropped when a trigger reaches it.
        def cleanup(now: nil)
          @store.cleanup(now: milliseconds(now))
        end

        def inspect = "#<#{self.class.name}>"
        alias_method :to_s, :inspect

        private

        def now_ms
          value = @clock.call
          raise ConfigurationError, "clock: must answer Integer milliseconds, got #{value.class}" unless value.is_a?(Integer)

          value
        end

        def milliseconds(now)
          case now
          when nil then now_ms
          when Integer then now
          when Time then (now.to_r * 1000).to_i
          else raise ArgumentError, "now: must be a Time or Integer milliseconds, got #{now.class}"
          end
        end

        def hex_mac(text, purpose)
          @encoder.mac(text, purpose: purpose).unpack1("H*")
        end

        # What telemetry carries instead of an id: a keyed digest, shortened.
        def id_digest(id)
          hex_mac(id, ID_PURPOSE)[0, 16]
        rescue StandardError
          nil
        end

        def record_signal(signal, context: nil, **data)
          @telemetry.record(signal, context: context, **data)
        rescue StandardError => error
          warn("graphql-armory subscriptions telemetry failed on #{signal}: #{error.class}")
        end
      end
    end
  end
end

require "graphql/armory/subscriptions/core/clock"
require "graphql/armory/subscriptions/core/viewer"
require "graphql/armory/subscriptions/core/settings"
require "graphql/armory/subscriptions/core/write"
require "graphql/armory/subscriptions/core/trigger"
require "graphql/armory/subscriptions/core/delivery"
require "graphql/armory/subscriptions/core/channels"
require "graphql/armory/subscriptions/core/controls"
