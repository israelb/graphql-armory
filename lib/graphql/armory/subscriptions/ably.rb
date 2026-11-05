# frozen_string_literal: true

require "securerandom"
require "graphql/armory/subscriptions/ably/key"
require "graphql/armory/subscriptions/ably/publisher"
require "graphql/armory/subscriptions/ably/token_request"
require "graphql/armory/subscriptions/ably/webhook"

module GraphQL
  module Armory
    module Subscriptions
      # The Ably transport, over Ably's REST API and `Http` (no SDK).
      #
      #   schema.use GraphQL::Armory::Subscriptions, transport: Ably.build(key: ENV["ABLY_KEY"])
      #
      # Ably authorises per connection, not per channel: the app's token endpoint answers
      # `schema.subscriptions.authorize_viewer(context:)`, a signed TokenRequest whose capability names the viewer's
      # channels (`<prefix>:<viewer digest>:*`) and no others. Channels are `<prefix>:<viewer digest>:<id>`. The
      # presence webhook reports the clients that left.
      #
      # `Ably.new` is inert (no key, `Http::Null`): it publishes, authorizes and accepts nothing. `Ably.build` checks
      # the settings and wires the real HTTP client.
      class Ably
        DIGEST = /\A(?:[0-9a-f]{64}|#{Record::ANONYMOUS})\z/
        SEGMENT = /\A[A-Za-z0-9_-]+\z/
        HOST = /\A[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\z/
        MAX_PAYLOAD_BYTES = 262_144
        MAX_TOKEN_TTL = 3600
        # https://ably.com/docs/api/rest-api : a request body is under 2 MiB (and a spec holds up to 100 channels).
        MAX_REQUEST_BYTES = 2 * 1024 * 1024
        MAX_SPECS = 100
        # A payload is sent as a JSON string inside a JSON body: worst case every byte is escaped, plus the spec's own text.
        SPEC_OVERHEAD_BYTES = 512
        DEFAULT_CLOCK = -> { Time.now }
        DEFAULT_NONCE = -> { SecureRandom.alphanumeric(24) }

        def self.build(key:, prefix: "graphql", max_payload_bytes: 65_536, host: "rest.ably.io", http: Http.build, token_ttl: 3600, clock: DEFAULT_CLOCK, nonce: DEFAULT_NONCE, compress: false)
          parsed = Key.parse(key)
          check(SEGMENT.match?(prefix.to_s) && prefix.is_a?(String), "prefix:", "must be letters, digits, _ or - (no \":\"), got #{prefix.inspect}")
          check(max_payload_bytes.is_a?(Integer) && max_payload_bytes.between?(1, MAX_PAYLOAD_BYTES), "max_payload_bytes:", "must be an Integer up to #{MAX_PAYLOAD_BYTES} (65_536; more only on plans that allow it), got #{max_payload_bytes.inspect}")
          check(host.is_a?(String) && HOST.match?(host), "host:", "must be a host name such as \"rest.ably.io\", got #{host.inspect}")
          check(http.respond_to?(:post), "http:", "must answer post(url, body, headers)")
          check(token_ttl.is_a?(Integer) && token_ttl.between?(1, MAX_TOKEN_TTL), "token_ttl:", "must be 1 to #{MAX_TOKEN_TTL} seconds, got #{token_ttl.inspect}")
          check(clock.respond_to?(:call), "clock:", "must answer call (returning a Time)")
          check(nonce.respond_to?(:call), "nonce:", "must answer call (returning a String)")
          check(compress == true || compress == false, "compress:", "must be true or false, got #{compress.inspect}")

          new(key: parsed, prefix: prefix, max_payload_bytes: max_payload_bytes, host: host, http: http, token_ttl: token_ttl, clock: clock, nonce: nonce, compress: compress)
        end

        def self.check(condition, option, problem)
          raise ConfigurationError, "#{option} #{problem}" unless condition
        end
        private_class_method :check

        attr_reader :capabilities

        def initialize(key: nil, prefix: "graphql", max_payload_bytes: 65_536, host: "rest.ably.io", http: Http::Null.new, token_ttl: 3600, clock: DEFAULT_CLOCK, nonce: DEFAULT_NONCE, compress: false)
          @key = key
          @prefix = prefix
          @clock = clock
          @capabilities = Capabilities.new(
            viewer_bound: true, max_payload_bytes: max_payload_bytes, max_batch: max_batch_for(max_payload_bytes), webhooks: :presence, compress: compress
          )
          return unless key

          @publisher = Publisher.new(key: key, url: "https://#{host}/messages", http: http, max_payload_bytes: max_payload_bytes, max_batch: @capabilities.max_batch)
          @tokens = TokenRequest.new(key: key, prefix: prefix, ttl_seconds: token_ttl, clock: clock, nonce: nonce)
          @webhook = Webhook.new(key: key, clock: clock, id_from: method(:id_from))
        end

        def authorization = :viewer

        def channel_for(id, viewer_digest)
          raise ArgumentError, "viewer_digest: must be 64 hex characters or #{Record::ANONYMOUS.inspect}" unless viewer_digest.is_a?(String) && DIGEST.match?(viewer_digest)
          raise ArgumentError, "id: must be a subscription id" unless id.is_a?(String) && Record::ID.match?(id)

          "#{@prefix}:#{viewer_digest}:#{id}"
        end

        def id_from(channel)
          return nil unless channel.is_a?(String)

          prefix, digest, id, *rest = channel.split(":", -1)
          return nil unless prefix == @prefix && rest.empty? && digest && id && DIGEST.match?(digest)

          Record::ID.match?(id) ? id : nil
        end

        def publish(messages)
          raise ArgumentError, "publish takes an Array of Messages" unless messages.is_a?(Array) && messages.all?(Message)
          return messages.each_index.map { |index| Outcome.new(status: :refused, index: index, reason: :not_configured) } unless @publisher

          @publisher.call(messages)
        end

        # A signed TokenRequest for the channels of `viewer_digest` only. The core matched the viewer first.
        def authorize_viewer(viewer_digest)
          return nil unless @tokens && viewer_digest.is_a?(String) && DIGEST.match?(viewer_digest)

          @tokens.call(viewer_digest)
        end

        def authorize_channel(channel:, socket_id: nil) = nil

        def webhook(env)
          return [:refused, :not_configured] unless @webhook

          @webhook.call(env)
        end

        def inspect = "#<#{self.class.name} prefix=#{@prefix.inspect}>"
        alias_method :to_s, :inspect

        private

        # One spec per message; each payload may be escaped twice (a JSON string inside the JSON body), and the whole
        # request must stay under 2 MiB.
        def max_batch_for(max_payload_bytes)
          (MAX_REQUEST_BYTES / (2 * max_payload_bytes + SPEC_OVERHEAD_BYTES)).clamp(1, MAX_SPECS)
        end
      end
    end
  end
end
