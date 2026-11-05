# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      # One message for a transport to publish: `payload` (`{ result: ... | compressed_result: ..., more: ... }`, the
      # graphql-ruby client's wire format) sent on `channel` under `event` ("update", the event its PusherLink and
      # AblyLink listen to). The payload is kept as given, not copied.
      class Message
        EVENT = "update"

        attr_reader :channel, :event, :payload

        def initialize(channel:, payload:, event: EVENT)
          raise ArgumentError, "Message channel: must be a non-empty String" unless channel.is_a?(String) && !channel.empty?
          raise ArgumentError, "Message payload: must be a Hash" unless payload.is_a?(Hash)
          raise ArgumentError, "Message event: must be a non-empty String" unless event.is_a?(String) && !event.empty?

          @channel = channel.dup.freeze
          @event = event.dup.freeze
          @payload = payload
          freeze
        end

        # The channel holds the subscription id: never in a log.
        def inspect = "#<#{self.class.name} event=#{event.inspect}>"
        alias_method :to_s, :inspect
      end
    end
  end
end
