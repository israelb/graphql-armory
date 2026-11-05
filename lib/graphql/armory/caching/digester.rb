# frozen_string_literal: true

require "openssl"
require "securerandom"

module GraphQL
  module Armory
    module Caching
      # Keyed digests (HMAC-SHA256, hex) for store keys and tags, so whoever reads the store cannot confirm a guess
      # such as `viewer:User:7`.
      #
      #   Digester.new                     # a random key for this process: entries are not shared across processes
      #   Digester.build(encoder: AppEncoder)  # the encoder's `mac(bytes, purpose: "cache-digest")`, shared by every process
      #   digester.("viewer:User:7")       # => "9f86d0..." (64 hex characters)
      class Digester
        PURPOSE = "cache-digest"

        # `encoder.mac(bytes, purpose:)` answers the raw 32-byte HMAC (an Encoder).
        def self.build(encoder:)
          raise ConfigurationError, "encoder: must answer mac(bytes, purpose:) (an Encoder subclass)" unless encoder.respond_to?(:mac)

          digester = new(mac: ->(bytes) { encoder.mac(bytes, purpose: PURPOSE) })
          # Once at boot: an encoder that cannot digest (Legacy, Null, no key) fails here, not on the first request.
          digester.("")
          digester
        end

        def initialize(mac: nil)
          raise ConfigurationError, "mac: must be a callable taking the bytes" unless mac.nil? || mac.respond_to?(:call)

          key = SecureRandom.random_bytes(32)
          @mac = mac || ->(bytes) { OpenSSL::HMAC.digest("SHA256", key, bytes) }
        end

        def call(string)
          raise ArgumentError, "a Digester digests Strings, got #{string.class}" unless string.is_a?(String)

          raw = @mac.call(string.b)
          raise ConfigurationError, "the mac answered #{raw.class}, not 32 bytes" unless raw.is_a?(String) && raw.bytesize == 32

          raw.unpack1("H*")
        end

        def inspect = "#<#{self.class.name}>"
      end
    end
  end
end
