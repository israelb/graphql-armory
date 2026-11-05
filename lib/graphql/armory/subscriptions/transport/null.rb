# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      module Transport
        # The transport of subscriptions nobody wired: not viewer bound, nothing fits, no channel is named, every
        # publish, authorization and webhook is refused. `Subscriptions.new` therefore delivers nothing to anyone.
        class Null
          CAPABILITIES = Capabilities.new(viewer_bound: false, max_payload_bytes: 0, max_batch: 1, webhooks: nil, compress: false)

          def capabilities = CAPABILITIES
          def authorization = :channel
          def channel_for(_id, _viewer_digest) = nil
          def id_from(_channel) = nil

          def publish(messages)
            messages.each_index.map { |index| Outcome.new(status: :refused, index: index, reason: :null_transport) }
          end

          def authorize_channel(channel:, socket_id: nil) = nil
          def authorize_viewer(_viewer_digest) = nil
          def webhook(_env) = [:refused, :null_transport]
        end
      end
    end
  end
end
