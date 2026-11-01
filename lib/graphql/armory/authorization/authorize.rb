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

        def self.build(context, adapter:, sinks: [], on_sink_error: nil)
          new(adapter: adapter, memo: Memo.build(context), telemetry: Telemetry.build(sinks: sinks, on_sink_error: on_sink_error))
        end

        def self.call(subject, rule, context, adapter:, sinks: [], on_sink_error: nil)
          build(context, adapter: adapter, sinks: sinks, on_sink_error: on_sink_error).(subject, rule, context)
        end

        def call(subject, rule, context)
          return bypass(subject, rule, context) if rule.none?

          memo.fetch(subject, rule) { decide(subject, rule, context) }
        end

        private

        def bypass(subject, rule, context)
          telemetry.record(:bypassed, context: context, type: class_name(subject), reason: rule.reason)
          true
        end

        # Observing opens one thing only: a clear "no" to a read, with someone listening, from an adapter someone configured.
        # A mutation or a subscription keeps refusing, even on a read inside its response: only a query runs nothing it cannot undo.
        def observes?(rule, context)
          rule.observed? && telemetry.listening? && !adapter.is_a?(Adapters::Null) && read_only?(context)
        end

        # A partial always answers `query?`, whatever the operation that ran it: only the query it came from can tell.
        def read_only?(context)
          query = context.query if context.respond_to?(:query)
          query = query.query while defined?(GraphQL::Query::Partial) && query.is_a?(GraphQL::Query::Partial)
          query.respond_to?(:query?) && query.query? == true
        end

        def observe(subject, rule, context)
          # A type's rule, not a field's: a field with a resolver on this object must not run for this user. See Integration.observed?
          (context.namespace(:armory)[:observed] ||= {}.compare_by_identity)[subject] = true if rule.attribute.nil?
          telemetry.record(:observed, context: context, type: class_name(subject), action: rule.action, reason: rule.observe)
          true
        end

        # The record's own `class` can be a data member, and the error for it quotes the record.
        def class_name(subject)
          ::Kernel.instance_method(:class).bind_call(subject).name
        end

        def decide(subject, rule, context)
          answer = adapter.authorized?(adapter.actor(context), subject, rule)

          case answer
          when true, false, nil
            return observe(subject, rule, context) if answer != true && observes?(rule, context)

            allowed = answer == true
            telemetry.record(allowed ? :allowed : :denied, context: context, type: class_name(subject), action: rule.action)
            allowed
          else
            # The class alone: the answer may be the record, and on a relation `inspect` runs the query.
            raise AdapterError, "#{adapter.class} answered a #{::Kernel.instance_method(:class).bind_call(answer)}; it must answer true, false or nil"
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
