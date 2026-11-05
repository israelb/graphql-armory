# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      # What a transport can do, declared by the transport and checked by `build`:
      #
      #   viewer_bound       the transport can refuse a client a channel (Pusher private channels, Ably capability
      #                      tokens); required when a viewer is configured
      #   max_payload_bytes  the largest message the provider accepts, in bytes (0: nothing fits)
      #   max_batch          how many messages one `publish` may carry
      #   webhooks           :presence, :existence or nil: what the provider reports when a client goes away
      #   compress           whether the client accepts `compressed_result` (deflate + base64)
      class Capabilities
        WEBHOOKS = [nil, :presence, :existence].freeze

        attr_reader :max_payload_bytes, :max_batch, :webhooks

        def initialize(viewer_bound:, max_payload_bytes:, max_batch:, webhooks: nil, compress: false)
          raise ArgumentError, "Capabilities viewer_bound: must be true or false" unless viewer_bound == true || viewer_bound == false
          raise ArgumentError, "Capabilities max_payload_bytes: must be a non-negative Integer" unless max_payload_bytes.is_a?(Integer) && max_payload_bytes >= 0
          raise ArgumentError, "Capabilities max_batch: must be a positive Integer" unless max_batch.is_a?(Integer) && max_batch.positive?
          raise ArgumentError, "Capabilities webhooks: must be one of #{WEBHOOKS.inspect}" unless WEBHOOKS.include?(webhooks)
          raise ArgumentError, "Capabilities compress: must be true or false" unless compress == true || compress == false

          @viewer_bound = viewer_bound
          @max_payload_bytes = max_payload_bytes
          @max_batch = max_batch
          @webhooks = webhooks
          @compress = compress
          freeze
        end

        def viewer_bound? = @viewer_bound
        def compress? = @compress

        def to_h
          { viewer_bound: @viewer_bound, max_payload_bytes: max_payload_bytes, max_batch: max_batch, webhooks: webhooks, compress: @compress }
        end

        def ==(other)
          other.is_a?(Capabilities) && other.to_h == to_h
        end
        alias_method :eql?, :==

        def hash = to_h.hash
      end
    end
  end
end
