# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      module Controls
        # A transport's capabilities: viewer bound, Pusher-sized (10 KB, batches of 10), existence webhooks.
        module Capabilities
          def self.example(**overrides)
            Subscriptions::Capabilities.new(**{ viewer_bound: true, max_payload_bytes: 10_240, max_batch: 10, webhooks: :existence, compress: false }, **overrides)
          end
        end

        # A `Store::Substitute` on a fixed clock.
        module Store
          def self.example(now: 1_000_000)
            Subscriptions::Store::Substitute.new(now: now)
          end
        end

        # A `Transport::Substitute`: viewer bound, channel authorization unless told otherwise.
        module Transport
          def self.example(capabilities: Capabilities.example, authorization: :channel)
            Subscriptions::Transport::Substitute.new(capabilities: capabilities, authorization: authorization)
          end
        end

        # A message as the core publishes it: one result, more to come.
        module Message
          def self.example(channel: "substitute:#{Digest.example("viewer")}:#{Id.example}")
            Subscriptions::Message.new(channel: channel, payload: { result: { "data" => { "messagePosted" => { "id" => "m1" } } }, more: true })
          end
        end
      end
    end
  end
end
