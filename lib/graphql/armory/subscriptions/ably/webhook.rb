# frozen_string_literal: true

require "json"
require "openssl"

module GraphQL
  module Armory
    module Subscriptions
      class Ably
        # Verifies and reads an Ably presence webhook (https://ably.com/docs/platform/integrations/webhooks). Order
        # matters: the key header, the declared length and the signature are decided before the body is parsed.
        #
        #   X-Ably-Key        our key name (or its key id part)
        #   X-Ably-Signature  base64(HMAC-SHA256(keySecret, raw body)), compared in constant time
        #
        # A body over 1 MB, or with a presence event more than 5 minutes from now, is refused. The answer is
        # `[:ok, channels]`: the subscription channels with a presence `leave` (action 3, or "leave") from any client.
        class Webhook
          MAX_BODY_BYTES = 1_048_576
          MAX_AGE_MS = 300_000
          PRESENCE = "channel.presence"
          LEAVE = [3, "leave"].freeze

          def initialize(key:, clock:, id_from:)
            @key = key
            @clock = clock
            @id_from = id_from
          end

          def call(env)
            return [:refused, :bad_signature] unless env.respond_to?(:[]) && env.respond_to?(:key?)
            return [:refused, :unknown_key] unless known_key?(env["HTTP_X_ABLY_KEY"])

            input = env["rack.input"]
            length = env["CONTENT_LENGTH"].to_s
            return [:refused, :too_large] if /\A\d+\z/.match?(length) && length.to_i > MAX_BODY_BYTES
            return [:refused, :bad_signature] unless input.respond_to?(:read)

            raw = input.read(MAX_BODY_BYTES + 1).to_s
            return [:refused, :too_large] if raw.bytesize > MAX_BODY_BYTES
            return [:refused, :bad_signature] unless signed?(raw, env["HTTP_X_ABLY_SIGNATURE"])

            events = events_in(parse(raw))
            return [:refused, :bad_body] unless events

            read(events)
          end

          private

          def known_key?(header)
            header.is_a?(String) && (header == @key.name || header == @key.id)
          end

          def signed?(raw, signature)
            return false unless signature.is_a?(String) && !signature.empty?

            OpenSSL.fixed_length_secure_compare(OpenSSL::Digest::SHA256.digest(@key.sign(raw)), OpenSSL::Digest::SHA256.digest(signature))
          end

          def parse(raw)
            JSON.parse(raw)
          rescue JSON::ParserError
            nil
          end

          # The presence events of a batched (`items`) or single enveloped body, as [{channel:, presence: [...]}], or nil.
          def events_in(body)
            return nil unless body.is_a?(Hash)

            items = body["items"].is_a?(Array) ? body["items"] : [body]
            items.select { |item| item.is_a?(Hash) && item["source"] == PRESENCE }.map do |item|
              data = item["data"].is_a?(Hash) ? item["data"] : item
              { channel: data["channelId"] || data["channel"], presence: Array(data["presence"]).grep(Hash), timestamp: item["timestamp"] }
            end
          end

          def read(events)
            now = (@clock.call.to_f * 1000).to_i
            channels = []
            events.each do |event|
              event[:presence].each do |message|
                timestamp = message["timestamp"] || event[:timestamp]
                return [:refused, :missing_timestamp] unless timestamp.is_a?(Integer)
                return [:refused, :stale] if (now - timestamp).abs > MAX_AGE_MS

                channels << event[:channel] if LEAVE.include?(message["action"]) && event[:channel].is_a?(String) && @id_from.call(event[:channel])
              end
            end
            [:ok, channels.uniq]
          end
        end
      end
    end
  end
end
