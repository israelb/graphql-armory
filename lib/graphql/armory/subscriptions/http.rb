# frozen_string_literal: true

require "net/http"
require "uri"

module GraphQL
  module Armory
    module Subscriptions
      # The HTTP client transports post through: Net::HTTP with open, read and write timeouts, one connection per
      # request. `Http::Null` refuses every request (a transport nobody wired), `Http::Substitute` records them.
      #
      #   http = Http.build(timeout: 5)
      #   http.post("https://api-mt1.pusher.com/apps/1/batch_events?...", body, { "Content-Type" => "application/json" })
      #   # => #<Http::Response status=200>
      #
      # Any status is a Response; only a failure to get one (a timeout, a refused connection, a TLS error) raises
      # `TransportError`, whose message names the error class and the host, never the path, query or body.
      class Http
        DEFAULT_TIMEOUT = 5
        SCHEMES = %w[http https].freeze

        # What the provider answered: `status` (Integer), `body` (String) and `headers` (lowercase names to values).
        Response = Struct.new(:status, :body, :headers, keyword_init: true) do
          def initialize(status:, body: "", headers: {})
            raise ArgumentError, "Response status: must be an Integer" unless status.is_a?(Integer)
            raise ArgumentError, "Response body: must be a String" unless body.is_a?(String)
            raise ArgumentError, "Response headers: must be a Hash" unless headers.is_a?(Hash)

            super(status: status, body: body.dup.freeze, headers: headers.dup.freeze)
            freeze
          end

          def success? = status.between?(200, 299)

          def inspect = "#<#{self.class.name} status=#{status}>"
          alias_method :to_s, :inspect
        end

        def self.build(timeout: DEFAULT_TIMEOUT)
          unless timeout.is_a?(Numeric) && timeout.positive?
            raise ConfigurationError, "timeout: must be a positive number of seconds, got #{timeout.inspect}"
          end

          new(timeout: timeout)
        end

        attr_reader :timeout

        def initialize(timeout: DEFAULT_TIMEOUT)
          @timeout = timeout
        end

        def post(url, body, headers = {})
          uri = parse(url)
          raise ArgumentError, "body must be a String" unless body.is_a?(String)
          raise ArgumentError, "headers must be a Hash" unless headers.is_a?(Hash)

          request = Net::HTTP::Post.new(uri.request_uri, headers)
          request.body = body
          response = connection(uri).start { |http| http.request(request) }
          Response.new(status: Integer(response.code), body: response.body.to_s, headers: response.each_header.to_h)
        rescue ArgumentError
          raise
        rescue StandardError => error
          raise TransportError, "HTTP POST to #{uri&.host} failed: #{error.class}"
        end

        private

        def parse(url)
          uri = URI.parse(url.to_s)
          raise ArgumentError, "url must be an http or https URL with a host" unless SCHEMES.include?(uri.scheme) && uri.host && !uri.host.empty?

          uri
        rescue URI::InvalidURIError
          raise ArgumentError, "url must be an http or https URL with a host"
        end

        def connection(uri)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = timeout
          http.read_timeout = timeout
          http.write_timeout = timeout
          http
        end
      end
    end
  end
end

require "graphql/armory/subscriptions/http/null"
require "graphql/armory/subscriptions/http/substitute"
