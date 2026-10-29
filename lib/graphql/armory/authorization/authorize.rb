# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      # Can this actor perform this rule's action on this subject? Anything but a clear `true` is a denial.
      class Authorize
        attr_reader :adapter, :memo, :telemetry

        # `new` is inert: with no configuration it denies everything.
        def initialize(adapter: Adapters::Null.new, memo: Memo.new, telemetry: Telemetry.new)
          @adapter = adapter
          @memo = memo
          @telemetry = telemetry
        end

        def self.build(context, adapter:, sinks: [])
          new(adapter: adapter, memo: Memo.build(context), telemetry: Telemetry.build(sinks: sinks))
        end

        def self.call(subject, rule, context, adapter:, sinks: [])
          build(context, adapter: adapter, sinks: sinks).(subject, rule, context)
        end

        def call(subject, rule, context)
          return bypass(subject, rule) if rule.none?

          memo.fetch(subject, rule) { decide(subject, rule, context) }
        end

        private

        def bypass(subject, rule)
          telemetry.record(:bypassed, type: subject.class.name, reason: rule.reason)
          true
        end

        def decide(subject, rule, context)
          answer = adapter.authorized?(adapter.actor(context), subject, rule)

          case answer
          when true, false, nil
            allowed = answer == true
            telemetry.record(allowed ? :allowed : :denied, type: subject.class.name, action: rule.action)
            allowed
          else
            raise AdapterError, "#{adapter.class} answered #{answer.inspect}; it must answer true, false or nil"
          end
        end

        # Answers what it was told and keeps the calls, for tests.
        class Substitute
          attr_reader :calls

          def initialize(answer: true)
            @answer = answer
            @calls = []
          end

          def call(subject, rule, _context)
            @calls << [subject, rule]
            @answer
          end
        end
      end
    end
  end
end
