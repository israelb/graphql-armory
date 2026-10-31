# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      # Narrows a list to what the actor may see. A declared bypass leaves the list alone.
      class Scope
        attr_reader :adapter, :telemetry

        # `new` is inert: with no configuration every list is scoped down to nothing.
        def initialize(adapter: Adapters::Null.new, telemetry: Telemetry.new)
          @adapter = adapter
          @telemetry = telemetry
        end

        def self.build(adapter:, sinks: [], on_sink_error: nil)
          new(adapter: adapter, telemetry: Telemetry.build(sinks: sinks, on_sink_error: on_sink_error))
        end

        def self.call(items, rule, context, adapter:, sinks: [], on_sink_error: nil)
          build(adapter: adapter, sinks: sinks, on_sink_error: on_sink_error).(items, rule, context)
        end

        def call(items, rule, context)
          if rule.none?
            telemetry.record(:bypassed, context: context, reason: rule.reason)
            return items
          end

          scoped = adapter.scope(adapter.actor(context), items, rule)
          telemetry.record(:scoped, context: context, action: rule.action)
          scoped
        end
      end
    end
  end
end
