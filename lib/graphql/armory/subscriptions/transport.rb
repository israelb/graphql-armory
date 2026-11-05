# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      # How messages reach clients: `Pusher`, `Ably`, or any object answering the same methods. Transports talk to
      # their provider over `Http` and never require an SDK.
      #
      #   transport.capabilities -> Capabilities              # checked by `build` (viewer_bound, limits, webhooks)
      #   transport.authorization -> :channel | :viewer        # how a client is let onto its channels
      #   transport.channel_for(id, viewer_digest) -> String   # the channel of one subscription (nil: none)
      #   transport.id_from(channel) -> id | nil               # the subscription id a channel name holds
      #   transport.publish([Message, ...]) -> [Outcome, ...]  # one Outcome per message, by index
      #   transport.authorize_channel(channel:, socket_id:) -> Hash | nil   # :channel transports
      #   transport.authorize_viewer(viewer_digest) -> Hash | nil           # :viewer transports
      #   transport.webhook(rack_env) -> [:ok, [channel, ...]] | [:refused, reason]
      #
      # The contract:
      #
      # - `channel_for` binds the channel to the viewer digest as well as the id (the id alone is a bearer token on a
      #   hosted service), and `id_from(channel_for(id, digest)) == id`. `id_from` answers nil for any other text.
      # - `publish` is called with at most `capabilities.max_batch` messages, each payload at most
      #   `capabilities.max_payload_bytes` once JSON-encoded. It answers `:gone` only when the provider says the channel
      #   is gone, and raises `TransportError` (never a provider's own error) when the whole call failed.
      # - `authorize_channel` is called only after the core matched the stored viewer digest with the requester's; it
      #   signs what the provider needs for that channel. `authorize_viewer` answers credentials (a token request) that
      #   reach that viewer's channels only. Each answers nil in the mode it does not implement.
      # - `webhook` verifies the provider's signature in constant time and refuses an old, oversized or unsigned body
      #   before reading what it reports; it answers the channels the provider reports gone, nothing else.
      module Transport
        AUTHORIZATIONS = %i[channel viewer].freeze

        # The transport's declared capabilities: the same value as `Subscriptions::Capabilities`.
        Capabilities = Subscriptions::Capabilities
      end
    end
  end
end

require "graphql/armory/subscriptions/transport/null"
require "graphql/armory/subscriptions/transport/substitute"
