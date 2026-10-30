# frozen_string_literal: true

module GraphQL
  module Armory
    class Encoder
      # Encodes reversibly without a key or any cryptography, records what it encoded and decoded, and fails when
      # told: for tests of the objects that use an encoder. Never use it to hand out real IDs: anyone can forge them.
      class Substitute
        PREFIX = "substitute:"

        attr_reader :encoded, :decoded

        def initialize
          @encoded = []
          @decoded = []
          @failure = nil
        end

        # Raises `error` from every encode and decode until `recover`.
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
      end
    end
  end
end
