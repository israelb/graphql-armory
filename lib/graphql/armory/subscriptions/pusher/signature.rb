# frozen_string_literal: true

require "openssl"
require "digest"

module GraphQL
  module Armory
    module Subscriptions
      class Pusher
        # Pusher's two HMAC-SHA256 signatures, as documented (no SDK):
        #
        # - REST requests: https://pusher.com/docs/channels/library_auth_reference/rest-api/
        # - private channel authorization: https://pusher.com/docs/channels/library_auth_reference/auth-signatures/
        module Signature
          AUTH_VERSION = "1.0"

          module_function

          def hmac(secret, text)
            OpenSSL::HMAC.hexdigest("SHA256", secret, text)
          end

          # The signed query string of one request: auth_key, auth_timestamp, auth_version, body_md5 (when there is a
          # body) and auth_signature = hex HMAC of "METHOD\nPATH\nsorted query". Every value is URL safe as it is.
          def query(key:, secret:, method:, path:, body:, timestamp:)
            params = { "auth_key" => key, "auth_timestamp" => timestamp.to_s, "auth_version" => AUTH_VERSION }
            params["body_md5"] = Digest::MD5.hexdigest(body) unless body.empty?
            unsigned = params.sort.map { |name, value| "#{name}=#{value}" }.join("&")
            "#{unsigned}&auth_signature=#{hmac(secret, "#{method.upcase}\n#{path}\n#{unsigned}")}"
          end

          # "<key>:<hex HMAC(secret, "socket_id:channel")>", what a client sends as `auth` to subscribe.
          def channel_auth(key:, secret:, socket_id:, channel:)
            "#{key}:#{hmac(secret, "#{socket_id}:#{channel}")}"
          end

          # Constant time; false for any length mismatch (the lengths are not secret).
          def same?(left, right)
            left.is_a?(String) && right.is_a?(String) && left.bytesize == right.bytesize && OpenSSL.fixed_length_secure_compare(left, right)
          end
        end
      end
    end
  end
end
