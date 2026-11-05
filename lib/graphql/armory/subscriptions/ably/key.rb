# frozen_string_literal: true

require "base64"
require "openssl"

module GraphQL
  module Armory
    module Subscriptions
      class Ably
        # An Ably API key, `"<keyName>:<keySecret>"` (keyName is `<appId>.<keyId>`). It signs and never shows the
        # secret: `inspect` names nothing.
        class Key
          NAME = /\A[A-Za-z0-9_.-]+\z/
          SECRET = /\A\S+\z/

          attr_reader :name

          def self.parse(text)
            raise ConfigurationError, "key: must be \"<keyName>:<keySecret>\"" unless text.is_a?(String)

            name, secret = text.split(":", 2)
            unless name && secret && NAME.match?(name) && SECRET.match?(secret)
              raise ConfigurationError, "key: must be \"<keyName>:<keySecret>\" (the Ably API key, no spaces)"
            end

            new(name, secret)
          end

          def initialize(name, secret)
            @name = name.dup.freeze
            @secret = secret.dup.freeze
            freeze
          end

          # The key id (the part of the name after the app id): what `X-Ably-Key` may carry instead of the name.
          def id = name.split(".", 2).last

          def basic_auth = "Basic #{Base64.strict_encode64("#{name}:#{@secret}")}"

          # base64(HMAC-SHA256(secret, text)): the `mac` of a TokenRequest and the `X-Ably-Signature` of a webhook.
          def sign(text) = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", @secret, text))

          def inspect = "#<#{self.class.name}>"
          alias_method :to_s, :inspect
        end
      end
    end
  end
end
