# frozen_string_literal: true

module GraphQL
  module Armory
    # Records what a module decided (a request allowed, an ID refused, an operation run) and hands it to its sinks.
    # A sink is anything that responds to `call(signal, data)`: a lambda that logs, a metrics client, or
    # `Telemetry::Notifications`. A sink that requires a third argument also receives the query's context, to read who
    # asked from it; the context never goes in `data`. Never put record attributes, IDs, keys or queries in `data`: a client chooses
    # those, and they would end up in the app's logs.
    class Telemetry
      class ConfigurationError < Armory::Error; end

      # The class alone: an error's message may quote what the sink was sending, or its credentials.
      DEFAULT_ON_SINK_ERROR = ->(error, signal) { warn("graphql-armory sink failed on #{signal}, request continues: #{error.class}") }

      def self.build(sinks: [], on_sink_error: nil)
        new(sinks: sinks, on_sink_error: on_sink_error)
      end

      def initialize(sinks: [], on_sink_error: nil)
        # Messages name a class, never `inspect` a value: a metrics client holds its API key.
        raise ConfigurationError, "sinks: must be an Array of callables taking (signal, data), got #{sinks.class}" unless sinks.is_a?(Array)

        sinks.each do |sink|
          raise ConfigurationError, "sinks: must be an Array of callables taking (signal, data), found a #{sink.class}" unless sink.respond_to?(:call)
          next unless sink.respond_to?(:available?) && !sink.available?

          raise ConfigurationError, "sink #{sink.is_a?(Module) ? sink.name : sink.class} is not available: the library it reports to is not loaded"
        end

        raise ConfigurationError, "on_sink_error: must be a callable taking the error and the signal, found a #{on_sink_error.class}" unless on_sink_error.nil? || on_sink_error.respond_to?(:call)

        @sinks = sinks.map { |sink| [sink, takes_context?(sink)] }.freeze
        @on_sink_error = on_sink_error || DEFAULT_ON_SINK_ERROR
      end

      # Every sink gets the same frozen data, so one sink (or a subscriber) cannot change what the next one sees.
      def record(signal, context: nil, **data)
        return nil if @sinks.empty?

        data = data.to_h { |key, value| [key, value.is_a?(String) ? value.dup.freeze : value] }.freeze
        @sinks.each do |sink, takes_context|
          takes_context ? sink.call(signal, data, context) : sink.call(signal, data)
        rescue StandardError => error
          @on_sink_error.call(error, signal)
        end
        nil
      end

      private

      # Only a sink that asks for it by name: one taking `*arguments` may log whatever it gets.
      def takes_context?(sink)
        parameters = sink.is_a?(Proc) || sink.is_a?(Method) ? sink.parameters : sink.method(:call).parameters
        return parameters.size >= 3 && parameters.first(3).all? { |type, _| type == :opt } if sink.is_a?(Proc) && !sink.lambda?

        parameters.count { |type, _| type == :req } == 3
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
        attr_reader :recorded, :contexts

        def initialize
          @recorded = []
          @contexts = []
          @failure = nil
        end

        # Raises `error` from every `record` until `recover`, like a sink that cannot reach its service.
        def fail_with(error)
          @failure = error
        end

        def recover
          @failure = nil
        end

        def record(signal, context: nil, **data)
          @contexts << context
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
