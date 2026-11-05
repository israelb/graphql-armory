# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      class Core < GraphQL::Subscriptions
        # Pusher's socket id shape: what the core accepts before a channel transport signs anything.
        SOCKET_ID = /\A\d+\.\d+\z/
        JSON_HEADERS = { "content-type" => "application/json" }.freeze

        # For a `:channel` transport (Pusher private channels): the transport's signed answer for `channel`, or nil.
        # Nil unless the channel names a live subscription whose stored viewer digest equals the digest of the viewer
        # `context` holds (compared in constant time) and the channel name is the one the transport makes for that
        # subscription and digest. A deleted or expired subscription answers nil: the client re-subscribes. Build
        # `context` the way the GraphQL endpoint does: the channel is only as safe as that.
        def authorize_channel(channel:, socket_id: nil, context:)
          return nil unless @transport.authorization == :channel
          return nil unless socket_id.nil? || (socket_id.is_a?(String) && SOCKET_ID.match?(socket_id))

          record = live_record(channel)
          return nil unless record && same_viewer?(record.viewer_digest, requester_digest(context))

          @transport.authorize_channel(channel: channel, socket_id: socket_id)
        end

        # For a `:viewer` transport (Ably capability tokens): credentials reaching the channels of the viewer `context`
        # holds, and no one else's, or nil when it names no viewer.
        def authorize_viewer(context:)
          return nil unless @transport.authorization == :viewer

          digest = requester_digest(context)
          digest ? @transport.authorize_viewer(digest) : nil
        end

        # The provider's webhook, as a Rack triple: the transport verifies the signature, and each channel it reports
        # gone has its subscription deleted (200). A refused or failing webhook answers 401, deletes nothing and is
        # recorded. A forged "gone" can only end a subscription, never deliver one.
        def webhook(env)
          status, reported = begin
            @transport.webhook(env)
          rescue StandardError
            [:refused, :error]
          end
          unless status == :ok && reported.is_a?(Array)
            record_signal(:subscription_webhook_refused, reason: status == :refused && reported.is_a?(Symbol) ? reported : :invalid)
            return [401, JSON_HEADERS.dup, ["{}"]]
          end

          reported.each do |channel|
            id = @transport.id_from(channel)
            next unless id && @store.delete(id)

            record_signal(:subscription_ended, reason: :webhook, subscription: id_digest(id))
          end
          [200, JSON_HEADERS.dup, ["{}"]]
        end

        private

        # The live record `channel` names, when the transport would make exactly that channel for it.
        def live_record(channel)
          return nil unless channel.is_a?(String)

          id = @transport.id_from(channel)
          return nil unless id

          sealed = @store.read(id)
          record = sealed && open_record(id, sealed)
          return nil unless record && !record.expired?(now_ms)
          return nil unless @transport.channel_for(id, record.viewer_digest) == channel

          record
        end

        # The digest of the viewer `context` holds (the anonymous marker in anonymous mode), or nil.
        def requester_digest(context)
          viewer = @settings.viewer
          return Record::ANONYMOUS if viewer.anonymous?

          hex_mac(viewer.id(context), VIEWER_PURPOSE)
        rescue RefusedError
          nil
        end

        def same_viewer?(stored, requested)
          return false unless stored.is_a?(String) && requested.is_a?(String) && stored.bytesize == requested.bytesize

          OpenSSL.fixed_length_secure_compare(stored, requested)
        end
      end
    end
  end
end
