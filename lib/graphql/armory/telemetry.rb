# frozen_string_literal: true

module GraphQL
  module Armory
    # Records what a module decided (a request allowed, an ID refused, an operation run) and hands it to its sinks.
    # A sink is anything that responds to `call(signal, data)`: a lambda that logs, a metrics client, or
    # `Telemetry::Notifications`. Never put record attributes, IDs, keys or queries in `data`: a client chooses
    # those, and they would end up in the app's logs.
    class Telemetry
      class ConfigurationError < Armory::Error; end

      def self.build(sinks: [])
        new(sinks: sinks)
      end

      def initialize(sinks: [])
        # Messages name a class, never `inspect` a value: a metrics client holds its API key.
        raise ConfigurationError, "sinks: must be an Array of callables taking (signal, data), got #{sinks.class}" unless sinks.is_a?(Array)

        sinks.each do |sink|
          raise ConfigurationError, "sinks: must be an Array of callables taking (signal, data), found a #{sink.class}" unless sink.respond_to?(:call)
          next unless sink.respond_to?(:available?) && !sink.available?

          raise ConfigurationError, "sink #{sink.is_a?(Module) ? sink.name : sink.class} is not available: the library it reports to is not loaded"
        end

        @sinks = sinks.dup.freeze
      end

      # Every sink gets the same frozen data, so one sink (or a subscriber) cannot change what the next one sees.
      def record(signal, **data)
        return nil if @sinks.empty?

        data = data.to_h { |key, value| [key, value.is_a?(String) ? value.dup.freeze : value] }.freeze
        @sinks.each { |sink| sink.call(signal, data) }
        nil
      end

      # Reports every signal as an ActiveSupport::Notifications event named "<signal>.graphql_armory", with the
      # signal's data as payload: `sinks: [GraphQL::Armory::Telemetry::Notifications]`.
      module Notifications
        def self.available?
          defined?(::ActiveSupport::Notifications) ? true : false
        end

        def self.call(signal, data)
          ::ActiveSupport::Notifications.instrument("#{signal}.graphql_armory", data.dup) # ActiveSupport may add keys to its payload
        end
      end

      # Keeps what was recorded and fails when told, for tests.
      class Substitute
        attr_reader :recorded

        def initialize
          @recorded = []
          @failure = nil
        end

        # Raises `error` from every `record` until `recover`, like a sink that cannot reach its service.
        def fail_with(error)
          @failure = error
        end

        def recover
          @failure = nil
        end

        def record(signal, **data)
          raise @failure if @failure

          @recorded << [signal, data]
          nil
        end

        def recorded?(signal)
          @recorded.any? { |recorded_signal, _| recorded_signal == signal }
        end
      end
    end
  end
end
