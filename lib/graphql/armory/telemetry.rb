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
        unless sinks.is_a?(Array) && sinks.all? { |sink| sink.respond_to?(:call) }
          raise ConfigurationError, "sinks: must be an Array of callables taking (signal, data), got #{sinks.inspect}"
        end

        sinks.each do |sink|
          if sink.respond_to?(:available?) && !sink.available?
            raise ConfigurationError, "sink #{sink} is not available: the library it reports to is not loaded"
          end
        end

        @sinks = sinks.dup.freeze
      end

      def record(signal, **data)
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
          ::ActiveSupport::Notifications.instrument("#{signal}.graphql_armory", data)
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
