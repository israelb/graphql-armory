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

      # What a sink reads the context through: it decides nothing, so it cannot change who the query runs as. An object in
      # the context is the app's own, and stays as it is. `inspect` stays out of it, so a sink that logs its arguments logs no token.
      class ContextView
        def initialize(context)
          @context = context
        end

        def [](key) = @context[key]
        def fetch(key, *default, &block) = @context.fetch(key, *default, &block)
        def dig(key, *rest) = @context.dig(key, *rest)
        def key?(key) = @context.key?(key)
        def inspect = "#<#{self.class.name}>"
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

      # Whether anything hears what is recorded.
      def listening?
        !@sinks.empty?
      end

      # Every sink gets the same frozen data, so one sink (or a subscriber) cannot change what the next one sees.
      def record(signal, context: nil, **data)
        return nil if @sinks.empty?

        data = data.to_h { |key, value| [key, value.is_a?(String) ? value.dup.freeze : value] }.freeze
        view = ContextView.new(context || {}) if @sinks.any? { |_sink, takes_context| takes_context }
        @sinks.each do |sink, takes_context|
          takes_context ? sink.call(signal, data, view) : sink.call(signal, data)
        rescue StandardError => error
          @on_sink_error.call(error, signal)
        end
        nil
      end

      private

      # Only a sink that requires it: one taking `*arguments` or a defaulted third may log whatever it gets. A sink whose
      # `call` cannot be read (a BasicObject, one behind method_missing) takes two.
      def takes_context?(sink)
        callable = Proc === sink || Method === sink ? sink : ::Kernel.instance_method(:method).bind_call(sink, :call)
        return callable.arity == 3 if Proc === callable && !callable.lambda?

        parameters = callable.parameters
        refuse_uncallable(sink, parameters)
        parameters.count { |type, _| type == :req } == 3
      rescue NameError, TypeError
        false
      end

      # It would raise on every signal, and with sinks that no longer fail the request nobody would notice.
      def refuse_uncallable(sink, parameters)
        required = parameters.count { |type, _| type == :req }
        optional = parameters.count { |type, _| type == :opt }
        rest = parameters.any? { |type, _| type == :rest }
        return unless required > 3 || parameters.any? { |type, _| type == :keyreq } || (required + optional < 2 && !rest)

        raise ConfigurationError, "sink #{sink.is_a?(Module) ? sink.name : sink.class} must take (signal, data) or (signal, data, context)"
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

        def listening?
          true
        end

        def recorded?(signal)
          @recorded.any? { |recorded_signal, _| recorded_signal == signal }
        end
      end
    end
  end
end
