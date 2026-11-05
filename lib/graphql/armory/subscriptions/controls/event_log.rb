# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      module Controls
        # A bare graphql-ruby subscriptions backend that keeps the events graphql-ruby hands `write_subscription` and
        # does nothing else: for tests that need a subscription operation to run (graphql-ruby refuses one without a
        # backend) or the exact `Event` objects the write side sees, without our own backend.
        #
        #   schema = Controls::Schema.example(subscriptions: {}, plugin: Controls::EventLog)
        #   schema.execute("subscription { roomUpdated(roomId: 5) { id } }", context: ...)
        #   schema.subscriptions.events.first.topic      # graphql-ruby's own topic String
        #   schema.subscriptions.events.first.arguments  # the coerced keyword arguments
        class EventLog < GraphQL::Subscriptions
          attr_reader :events

          def initialize(**options)
            super
            @events = []
          end

          def write_subscription(_query, events)
            @events.concat(events)
          end
        end
      end
    end
  end
end
