# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      # Records what happened (allowed, denied, bypassed, scoped) and hands it to its sinks.
      # A sink is anything that responds to `call(signal, data)`. Never put record attributes in `data`.
      class Telemetry
        def self.build(sinks: [])
          new(sinks: sinks)
        end

        def initialize(sinks: [])
          @sinks = sinks
        end

        def record(signal, **data)
          @sinks.each { |sink| sink.call(signal, data) }
          nil
        end

        # Keeps what was recorded, for tests.
        class Substitute
          attr_reader :recorded

          def initialize
            @recorded = []
          end

          def record(signal, **data)
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
end
