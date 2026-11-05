# frozen_string_literal: true

require "json"
require "graphql/armory/subscriptions/pusher/signature"

module GraphQL
  module Armory
    module Subscriptions
      # The Transport for Pusher Channels (and Pusher-compatible servers such as Soketi), over plain HTTP and HMAC with
      # no SDK. Each subscription gets a private channel, `private-<prefix>-<id>`; the client is let onto it by the
      # app's auth endpoint calling `authorize_channel` once the core matched the viewer.
      #
      #   Pusher.build(app_id: "3", key: "...", secret: "...", cluster: "eu")
      #   Pusher.new   # inert: names no channel and refuses everything
      #
      # `publish` never raises for what the provider answers and never retries inline: 2xx is `:ok`, a payload or
      # request Pusher refuses for good is `:refused` (with a reason), a rate limit, a timeout or a 5xx is `:retry`.
      class Pusher
        MAX_PAYLOAD_BYTES = 10_240
        MAX_BATCH = 10
        MAX_WEBHOOK_BYTES = 1024 * 1024
        WEBHOOK_MAX_AGE_MS = 5 * 60 * 1000
        MAX_CHANNEL_LENGTH = 164
        SOCKET_ID = /\A\d+\.\d+\z/
        SEGMENT = /\A[A-Za-z0-9_-]+\z/
        HOST = /\A[A-Za-z0-9.-]+(:\d+)?\z/
        CLUSTER = /\A[a-z0-9-]+\z/
        SCHEMES = %w[https http].freeze
        DEFAULT_CLUSTER = "mt1"

        # HTTP status to [Outcome status, reason], for what Pusher answers a batch.
        REFUSED = { 400 => :bad_request, 401 => :unauthorized, 403 => :forbidden, 413 => :payload_rejected }.freeze
        RETRY = { 408 => :timeout, 429 => :rate_limited }.freeze

        def self.build(app_id:, key:, secret:, cluster: nil, host: nil, scheme: "https", prefix: "graphql", compress: false, http: Http.build, clock: Time)
          new(app_id: app_id, key: key, secret: secret, cluster: cluster, host: host, scheme: scheme, prefix: prefix, compress: compress, http: http, clock: clock).tap(&:validate!)
        end

        attr_reader :capabilities, :http

        def initialize(app_id: nil, key: nil, secret: nil, cluster: nil, host: nil, scheme: "https", prefix: "graphql", compress: false, http: Http::Null.new, clock: Time)
          @app_id = app_id
          @key = key
          @secret = secret
          @cluster = cluster
          @host = host
          @scheme = scheme
          @prefix = prefix
          @compress = compress
          @http = http
          @clock = clock
          @capabilities = Capabilities.new(viewer_bound: true, max_payload_bytes: MAX_PAYLOAD_BYTES, max_batch: MAX_BATCH, webhooks: :existence, compress: compress == true)
        end

        def authorization = :channel

        def configured? = !@secret.nil? && !@key.nil? && !@app_id.nil?

        def channel_for(id, _viewer_digest)
          return nil unless configured? && id.is_a?(String) && SEGMENT.match?(id)

          channel = "#{channel_prefix}#{id}"
          channel.length <= MAX_CHANNEL_LENGTH ? channel : nil
        end

        def id_from(channel)
          return nil unless configured? && channel.is_a?(String) && channel.length <= MAX_CHANNEL_LENGTH && channel.start_with?(channel_prefix)

          id = channel.delete_prefix(channel_prefix)
          SEGMENT.match?(id) ? id : nil
        end

        def publish(messages)
          check(messages)
          return refuse_all(messages, :not_configured) unless configured?

          body = JSON.generate(batch: messages.map { |message| { name: message.event, channel: message.channel, data: JSON.generate(message.payload) } })
          response = @http.post(url("/batch_events", body), body, { "Content-Type" => "application/json" })
          status, reason = classify(response.status)
          messages.each_index.map { |index| Outcome.new(status: status, index: index, reason: reason) }
        rescue TransportError
          messages.each_index.map { |index| Outcome.new(status: :retry, index: index, reason: :transport_error) }
        end

        def authorize_channel(channel:, socket_id: nil)
          return nil unless configured? && socket_id.is_a?(String) && SOCKET_ID.match?(socket_id) && id_from(channel)

          { "auth" => Signature.channel_auth(key: @key, secret: @secret, socket_id: socket_id, channel: channel) }
        end

        def authorize_viewer(_viewer_digest) = nil

        # Verifies a Pusher webhook (Rack env): size, X-Pusher-Key, X-Pusher-Signature (constant time), age. Answers
        # `[:ok, channels]` for the `channel_vacated` events on channels this transport named, `[:refused, reason]`
        # otherwise.
        def webhook(env)
          return [:refused, :not_configured] unless configured?

          body = read_body(env)
          return [:refused, :too_large] unless body
          return [:refused, :wrong_key] unless Signature.same?(env["HTTP_X_PUSHER_KEY"], @key)
          return [:refused, :bad_signature] unless Signature.same?(env["HTTP_X_PUSHER_SIGNATURE"], Signature.hmac(@secret, body))

          vacated(body)
        end

        def inspect = "#<#{self.class.name} app_id=#{@app_id.inspect} prefix=#{@prefix.inspect}>"
        alias_method :to_s, :inspect

        def validate!
          text = ->(name, value, pattern) { fail!("#{name}: must match #{pattern.inspect}") unless value.is_a?(String) && pattern.match?(value) }
          text.(:app_id, @app_id, SEGMENT)
          fail!("key: must be a non-empty String without ':' or whitespace") unless @key.is_a?(String) && @key.match?(/\A[^:\s]+\z/)
          fail!("secret: must be a non-empty String") unless @secret.is_a?(String) && !@secret.empty?
          text.(:prefix, @prefix, SEGMENT)
          fail!("scheme: must be one of #{SCHEMES.inspect}") unless SCHEMES.include?(@scheme)
          fail!("cluster: and host: are two ways to say where the API is; give one") if @cluster && @host
          text.(:cluster, @cluster, CLUSTER) if @cluster
          text.(:host, @host, HOST) if @host
          fail!("compress: must be true or false") unless @compress == true || @compress == false
          fail!("http: must answer post(url, body, headers)") unless @http.respond_to?(:post)
          fail!("clock: must answer now") unless @clock.respond_to?(:now) || @clock.respond_to?(:call)
          self
        end

        private

        def fail!(message) = raise(ConfigurationError, "Pusher #{message}")

        def channel_prefix = "private-#{@prefix}-"

        def check(messages)
          raise ArgumentError, "publish takes a non-empty Array of Messages" unless messages.is_a?(Array) && !messages.empty? && messages.all?(Message)
          raise ArgumentError, "publish got #{messages.size} messages, over max_batch #{MAX_BATCH}" if messages.size > MAX_BATCH

          messages.each do |message|
            bytes = JSON.generate(message.payload).bytesize
            raise ArgumentError, "a payload of #{bytes} bytes is over max_payload_bytes #{MAX_PAYLOAD_BYTES}" if bytes > MAX_PAYLOAD_BYTES
          end
        end

        def refuse_all(messages, reason)
          messages.each_index.map { |index| Outcome.new(status: :refused, index: index, reason: reason) }
        end

        def classify(status)
          return [:ok, nil] if status.between?(200, 299)
          return [:refused, REFUSED[status]] if REFUSED.key?(status)
          return [:retry, RETRY[status]] if RETRY.key?(status)
          return [:retry, :provider_error] if status >= 500
          return [:refused, :client_error] if status.between?(400, 499)

          [:retry, :unexpected_status]
        end

        def url(path, body)
          api_path = "/apps/#{@app_id}#{path}"
          query = Signature.query(key: @key, secret: @secret, method: "POST", path: api_path, body: body, timestamp: now.to_i)
          "#{@scheme}://#{@host || "api-#{@cluster || DEFAULT_CLUSTER}.pusher.com"}#{api_path}?#{query}"
        end

        def now = @clock.respond_to?(:call) ? @clock.call : @clock.now

        # The body, or nil when it is over the limit. Reads at most one byte past the limit, then rewinds.
        def read_body(env)
          input = env["rack.input"]
          return "" unless input

          declared = env["CONTENT_LENGTH"].to_s
          return nil if declared.match?(/\A\d+\z/) && declared.to_i > MAX_WEBHOOK_BYTES

          body = input.read(MAX_WEBHOOK_BYTES + 1).to_s
          input.rewind if input.respond_to?(:rewind)
          body.bytesize > MAX_WEBHOOK_BYTES ? nil : body
        end

        def vacated(body)
          data = JSON.parse(body)
          time_ms = data.is_a?(Hash) ? data["time_ms"] : nil
          events = data["events"] if data.is_a?(Hash)
          return [:refused, :malformed] unless time_ms.is_a?(Integer) && events.is_a?(Array)
          return [:refused, :stale] if (now.to_f * 1000) - time_ms > WEBHOOK_MAX_AGE_MS

          channels = events.select { |event| event.is_a?(Hash) && event["name"] == "channel_vacated" }.map { |event| event["channel"] }
          [:ok, channels.select { |channel| id_from(channel) }.uniq]
        rescue JSON::ParserError
          [:refused, :malformed]
        end
      end
    end
  end
end
