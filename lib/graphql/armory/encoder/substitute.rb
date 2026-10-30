# frozen_string_literal: true

module GraphQL
  module Armory
    class Encoder
      # Encodes reversibly without a key or any cryptography, and records what it encoded and decoded: for tests of
      # the objects that use an encoder. Never use it to hand out real IDs.
      class Substitute
        PREFIX = "substitute:"

        attr_reader :encoded, :decoded

        def initialize
          @encoded = []
          @decoded = []
        end

        def encode(text, nonce: false)
          @encoded << text.to_s
          PREFIX + URLSafeBase64.encode(text.to_s.b)
        end

        def decode(text, nonce: false)
          @decoded << text.to_s
          raise InvalidError unless text.to_s.start_with?(PREFIX)

          URLSafeBase64.decode(text.to_s.delete_prefix(PREFIX)).force_encoding(Encoding::UTF_8)
        rescue ArgumentError
          raise InvalidError
        end
      end
    end
  end
end
