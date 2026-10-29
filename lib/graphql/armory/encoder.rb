# frozen_string_literal: true

require "openssl"
require "base64"

module GraphQL
  module Armory
    # Encrypts and authenticates IDs and cursors with AES-256-GCM. Subclass it and set a key:
    #
    #   class AppEncoder < GraphQL::Armory::Encoder
    #     key ENV.fetch("GRAPHQL_ARMORY_KEY")
    #   end
    #
    # Cursors (`nonce: true`, as graphql-ruby's connections ask) get a random nonce, so the same position
    # never gives the same cursor. IDs must be stable, so their nonce is derived from the ID itself with an
    # HMAC: the same ID always encrypts the same way, and two different IDs never share a nonce.
    # IDs and cursors use separate keys, so one is never accepted as the other.
    class Encoder
      # Raised for anything that does not decode: tampered, foreign, malformed. The message never says which.
      class InvalidError < GraphQL::ExecutionError
        def initialize(message = "Invalid ID or cursor")
          super
        end
      end

      class ConfigurationError < Armory::Error; end

      # graphql-ruby's default text form for cursors: base64url without padding.
      module URLSafeBase64
        def self.encode(bytes)
          Base64.urlsafe_encode64(bytes, padding: false)
        end

        def self.decode(text)
          Base64.urlsafe_decode64(text)
        end
      end

      MINIMUM_KEY_BYTES = 32
      NONCE_BYTES = 12
      AUTH_TAG_BYTES = 16
      CIPHER = "aes-256-gcm"

      class << self
        def key(value = nil)
          return @key || (superclass.respond_to?(:key) ? superclass.key : nil) if value.nil?
          raise ConfigurationError, "an Encoder key must be at least #{MINIMUM_KEY_BYTES} bytes (try SecureRandom.hex(32))" if value.bytesize < MINIMUM_KEY_BYTES

          @subkeys = nil
          @key = value
        end

        # Authenticated data: an ID made with another tag does not decode. Use it to separate apps or versions.
        def tag(value = nil)
          return @tag || (superclass.respond_to?(:tag) ? superclass.tag : "") if value.nil?

          @subkeys = nil
          @tag = value.to_s
        end

        # Turns the encrypted bytes into text and back. Anything with `encode(bytes)` and `decode(text)`.
        def codec(value = nil)
          return @codec || (superclass.respond_to?(:codec) ? superclass.codec : URLSafeBase64) if value.nil?

          @codec = value
        end

        def encode(text, nonce: false)
          purpose = nonce ? :cursor : :id
          bytes = text.to_s.b
          iv = nonce ? OpenSSL::Random.random_bytes(NONCE_BYTES) : derived_nonce(bytes)
          cipher = OpenSSL::Cipher.new(CIPHER).encrypt
          cipher.key = subkey(purpose, :cipher)
          cipher.iv = iv
          cipher.auth_data = tag
          sealed = cipher.update(bytes) + cipher.final
          codec.encode(iv + sealed + cipher.auth_tag)
        end

        def decode(text, nonce: false)
          purpose = nonce ? :cursor : :id
          bytes = codec.decode(text.to_s)
          # One text form only: a base64 variant with other padding bits is not the same ID.
          raise InvalidError unless codec.encode(bytes) == text.to_s
          raise InvalidError if bytes.bytesize < NONCE_BYTES + AUTH_TAG_BYTES

          iv = bytes[0, NONCE_BYTES]
          cipher = OpenSSL::Cipher.new(CIPHER).decrypt
          cipher.key = subkey(purpose, :cipher)
          cipher.iv = iv
          cipher.auth_tag = bytes[-AUTH_TAG_BYTES..]
          cipher.auth_data = tag
          plain = cipher.update(bytes[NONCE_BYTES...-AUTH_TAG_BYTES]) + cipher.final
          # An ID has one valid form only: its nonce must be the one derived from it.
          raise InvalidError if !nonce && !OpenSSL.fixed_length_secure_compare(iv, derived_nonce(plain))

          plain.force_encoding(Encoding::UTF_8)
        rescue ArgumentError, OpenSSL::Cipher::CipherError
          raise InvalidError
        end

        private

        def derived_nonce(bytes)
          OpenSSL::HMAC.digest("SHA256", subkey(:id, :nonce), tag.b + "\0".b + bytes)[0, NONCE_BYTES]
        end

        # Separate keys per purpose and use, derived once from the configured key with HKDF.
        def subkey(purpose, use)
          secret = key or raise ConfigurationError, "#{name || "Encoder"} has no key: call `key` in its class body"
          @subkeys ||= {}
          @subkeys[[purpose, use]] ||= OpenSSL::KDF.hkdf(secret, salt: "graphql-armory", info: "#{purpose}/#{use}",
                                                                 length: 32, hash: "SHA256")
        end
      end
    end
  end
end
