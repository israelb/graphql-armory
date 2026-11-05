# frozen_string_literal: true

require "json"

module GraphQL
  module Armory
    module Subscriptions
      class Ably
        # A signed Ably TokenRequest (https://ably.com/docs/api/token-request-spec): the app hands it to the client's
        # `authCallback`/`authUrl`, and the client trades it with Ably for a token. Fields: `keyName`, `ttl` (ms),
        # `capability` (the JSON text), `clientId`, `timestamp` (ms), `nonce`, `mac`. The clientId is the viewer digest
        # (or "anonymous"): Ably's presence, and so the leave webhook, needs one.
        #
        # The signing text is keyName, ttl, capability, clientId, timestamp and nonce, each followed by a newline;
        # mac = base64(HMAC-SHA256(keySecret, text)).
        class TokenRequest
          OPERATIONS = %w[presence subscribe].freeze

          def initialize(key:, prefix:, ttl_seconds:, clock:, nonce:)
            @key = key
            @prefix = prefix
            @ttl_seconds = ttl_seconds
            @clock = clock
            @nonce = nonce
          end

          # Credentials for the channels `<prefix>:<viewer_digest>:*` and no others (operations sorted, no whitespace,
          # as the spec's canonical form asks), as the client `viewer_digest`.
          def call(viewer_digest)
            capability = JSON.generate("#{@prefix}:#{viewer_digest}:*" => OPERATIONS)
            ttl = @ttl_seconds * 1000
            timestamp = (@clock.call.to_f * 1000).to_i
            nonce = @nonce.call.to_s
            text = [@key.name, ttl, capability, viewer_digest, timestamp, nonce].map { |field| "#{field}\n" }.join
            { "keyName" => @key.name, "ttl" => ttl, "capability" => capability, "clientId" => viewer_digest, "timestamp" => timestamp, "nonce" => nonce,
              "mac" => @key.sign(text) }
          end
        end
      end
    end
  end
end
