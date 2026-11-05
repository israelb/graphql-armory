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
    #
    # It also seals other data for storage (`seal`/`open`, response cache entries) and answers keyed digests (`mac`),
    # each under a key derived for its purpose, so a sealed value is never an ID or a cursor and the reverse.
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
      # A purpose for `seal`, `open` and `mac` (`cache`, `cache-digest`): lowercase words joined by dashes. With no
      # `/` in it, its HKDF info (`seal/<purpose>/cipher`, `mac/<purpose>/hmac`) never equals another purpose's, nor
      # the IDs' and cursors'.
      PURPOSE = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

      # Checks the arguments every `seal`, `open` and `mac` takes, before anything is encrypted. Raises ArgumentError:
      # a wrong purpose or additional data is a bug in the caller, never an input to hide behind InvalidError.
      def self.check_sealing(purpose:, aad: "")
        raise ArgumentError, "purpose: must be lowercase words joined by dashes (\"cache\"), got #{purpose.inspect}" unless purpose.is_a?(String) && PURPOSE.match?(purpose)
        raise ArgumentError, "aad: must be a String, got #{aad.class}" unless aad.is_a?(String)
      end

      class << self
        # The key, at least 32 bytes. With no argument, answers it (inherited from the parent class).
        def key(*value)
          return setting(:@key, nil) if value.empty?

          secret = value.first
          unless secret.is_a?(String) && secret.bytesize >= MINIMUM_KEY_BYTES
            raise ConfigurationError, "an Encoder key must be a String of at least #{MINIMUM_KEY_BYTES} bytes (try SecureRandom.hex(32))"
          end

          @key = secret
        end

        # Authenticated data: an ID made with another tag does not decode. Use it to separate apps or versions.
        def tag(*value)
          return setting(:@tag, "") if value.empty?
          raise ConfigurationError, "an Encoder tag cannot be nil" if value.first.nil?

          @tag = value.first.to_s
        end

        # Turns the encrypted bytes into text and back. Anything with `encode(bytes)` and `decode(text)`.
        def codec(*value)
          return setting(:@codec, URLSafeBase64) if value.empty?
          raise ConfigurationError, "an Encoder codec must respond to encode and decode" unless %i[encode decode].all? { |name| value.first.respond_to?(name) }

          @codec = value.first
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
        rescue ConfigurationError
          raise
        rescue StandardError
          # Whatever the codec, OpenSSL or the input raise, the client learns only that it did not decode.
          raise InvalidError
        end

        # Encrypts and authenticates `bytes` for storage with AES-256-GCM, a random nonce and a key derived for
        # `purpose` alone; `aad` (additional data, such as the store key the value is written under) and the
        # encoder's tag are authenticated, not stored, so the value opens only with the same `aad`, `purpose`, key
        # and tag. Answers base64url text without padding, whatever `codec` IDs use.
        def seal(bytes, aad:, purpose:)
          Encoder.check_sealing(purpose: purpose, aad: aad)
          raise ArgumentError, "bytes: must be a String, got #{bytes.class}" unless bytes.is_a?(String)

          iv = OpenSSL::Random.random_bytes(NONCE_BYTES)
          cipher = OpenSSL::Cipher.new(CIPHER).encrypt
          cipher.key = subkey(sealing(purpose), :cipher)
          cipher.iv = iv
          cipher.auth_data = framed(aad)
          sealed = cipher_update(cipher, bytes.b) + cipher.final
          URLSafeBase64.encode(iv + sealed + cipher.auth_tag)
        end

        # The bytes `seal` sealed under the same `aad` and `purpose`, as binary. Raises InvalidError for anything
        # else (tampered, moved under other additional data, another key, tag or purpose, an ID or a cursor).
        def open(text, aad:, purpose:)
          Encoder.check_sealing(purpose: purpose, aad: aad)
          raise InvalidError unless text.is_a?(String)

          key = subkey(sealing(purpose), :cipher)
          begin
            bytes = URLSafeBase64.decode(text)
            # One text form only, as for IDs.
            raise InvalidError unless URLSafeBase64.encode(bytes) == text
            raise InvalidError if bytes.bytesize < NONCE_BYTES + AUTH_TAG_BYTES

            cipher = OpenSSL::Cipher.new(CIPHER).decrypt
            cipher.key = key
            cipher.iv = bytes[0, NONCE_BYTES]
            cipher.auth_tag = bytes[-AUTH_TAG_BYTES..]
            cipher.auth_data = framed(aad)
            cipher_update(cipher, bytes[NONCE_BYTES...-AUTH_TAG_BYTES]) + cipher.final
          rescue StandardError
            # Whatever base64 or OpenSSL raise, the caller learns only that it did not open.
            raise InvalidError
          end
        end

        # The raw 32-byte HMAC-SHA256 of `bytes` (and the encoder's tag) under a key derived for `purpose` alone:
        # keyed digests, such as response cache keys and tags, that whoever reads the store cannot confirm a guess
        # against.
        def mac(bytes, purpose:)
          Encoder.check_sealing(purpose: purpose)
          raise ArgumentError, "bytes: must be a String, got #{bytes.class}" unless bytes.is_a?(String)

          OpenSSL::HMAC.digest("SHA256", subkey("mac/#{purpose}", :hmac), framed(bytes))
        end

        private

        def setting(ivar, default)
          return instance_variable_get(ivar) if instance_variable_defined?(ivar)

          superclass.respond_to?(:key) ? superclass.send(:setting, ivar, default) : default
        end

        def derived_nonce(bytes)
          OpenSSL::HMAC.digest("SHA256", subkey(:id, :nonce), tag.b + "\0".b + bytes)[0, NONCE_BYTES]
        end

        def sealing(purpose) = "seal/#{purpose}"

        # OpenSSL refuses to update with no data; sealing nothing still authenticates the additional data.
        def cipher_update(cipher, bytes)
          bytes.empty? ? "".b : cipher.update(bytes)
        end

        # The encoder's tag, length-prefixed, then `bytes`: no tag and data can be split another way.
        def framed(bytes)
          [tag.bytesize].pack("N") + tag.b + bytes.b
        end

        # Separate keys per purpose and use, derived with HKDF and cached by the secret they come from, so a key
        # changed later (here or in a parent class) is used at once. IDs use `id/cipher` and `id/nonce`, cursors
        # `cursor/cipher`, sealed values `seal/<purpose>/cipher` and digests `mac/<purpose>/hmac`: no two share a key.
        def subkey(purpose, use)
          secret = key or raise ConfigurationError, "#{name || "Encoder"} has no key: call `key` in its class body"
          @subkeys ||= {}
          @subkeys[[secret, purpose, use]] ||= OpenSSL::KDF.hkdf(secret, salt: "graphql-armory", info: "#{purpose}/#{use}",
                                                                         length: 32, hash: "SHA256")
        end
      end
    end
  end
end

require "graphql/armory/encoder/versioned"
require "graphql/armory/encoder/legacy"
require "graphql/armory/encoder/default"
require "graphql/armory/encoder/null"
require "graphql/armory/encoder/substitute"
