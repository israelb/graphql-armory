# frozen_string_literal: true

require "openssl"

module GraphQL
  module Armory
    class Encoder
      # Encodes reversibly without a key or any cryptography, records what it encoded and decoded, and fails when
      # told: for tests of the objects that use an encoder. Never use it to hand out real IDs: anyone can forge them.
      #
      # It also seals (`seal`/`open`, reversible, still bound to the additional data and purpose so a value moved
      # elsewhere does not open) and digests (`mac`, an unkeyed SHA-256 per purpose), recording each call in `sealed`,
      # `opened` and `macs`. None of it is secret.
      class Substitute
        PREFIX = "substitute:"
        SEALED_PREFIX = "substitute-sealed:"

        attr_reader :encoded, :decoded, :sealed, :opened, :macs

        def initialize
          @encoded = []
          @decoded = []
          @sealed = []
          @opened = []
          @macs = []
          @failure = nil
        end

        # Raises `error` from every encode, decode, seal, open and mac until `recover`.
        def fail_with(error)
          @failure = error
        end

        def recover
          @failure = nil
        end

        def encode(text, nonce: false)
          @encoded << text.to_s
          raise @failure if @failure

          PREFIX + URLSafeBase64.encode(text.to_s.b)
        end

        def decode(text, nonce: false)
          @decoded << text.to_s
          raise @failure if @failure
          raise InvalidError unless text.to_s.start_with?(PREFIX)

          URLSafeBase64.decode(text.to_s.delete_prefix(PREFIX)).force_encoding(Encoding::UTF_8)
        rescue ArgumentError
          raise InvalidError
        end

        # `substitute-sealed:<purpose>.<aad>.<bytes>`, the last two in base64url.
        def seal(bytes, aad:, purpose:)
          Encoder.check_sealing(purpose: purpose, aad: aad)
          raise ArgumentError, "bytes: must be a String, got #{bytes.class}" unless bytes.is_a?(String)

          @sealed << { bytes: bytes.b, aad: aad, purpose: purpose }
          raise @failure if @failure

          SEALED_PREFIX + [purpose, URLSafeBase64.encode(aad.b), URLSafeBase64.encode(bytes.b)].join(".")
        end

        def open(text, aad:, purpose:)
          Encoder.check_sealing(purpose: purpose, aad: aad)
          @opened << { text: text, aad: aad, purpose: purpose }
          raise @failure if @failure
          raise InvalidError unless text.is_a?(String) && text.start_with?(SEALED_PREFIX)

          sealed_purpose, sealed_aad, bytes = text.delete_prefix(SEALED_PREFIX).split(".", -1)
          raise InvalidError unless sealed_purpose == purpose && sealed_aad && bytes && base64(sealed_aad) == aad.b

          base64(bytes)
        end

        # SHA-256 of the purpose and the bytes: 32 bytes, as a real `mac`, but anyone can compute it.
        def mac(bytes, purpose:)
          Encoder.check_sealing(purpose: purpose)
          raise ArgumentError, "bytes: must be a String, got #{bytes.class}" unless bytes.is_a?(String)

          @macs << { bytes: bytes.b, purpose: purpose }
          raise @failure if @failure

          OpenSSL::Digest::SHA256.digest("#{purpose}\0".b + bytes.b)
        end

        private

        def base64(text)
          URLSafeBase64.decode(text)
        rescue ArgumentError
          raise InvalidError
        end
      end
    end
  end
end
