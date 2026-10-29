# frozen_string_literal: true

module GraphQL
  module Armory
    class Encoder
      # A chain of encoders, newest first: encodes with the first, decodes with whichever accepts the value.
      # Build it with `Encoder.versioned(NewEncoder, OldEncoder, Encoder::Legacy)`.
      class Versioned
        attr_reader :encoders

        def initialize(encoders)
          raise ConfigurationError, "a versioned encoder needs at least one encoder" if encoders.empty?

          encoders.each do |encoder|
            next if %i[encode decode].all? { |name| encoder.respond_to?(name) }

            raise ConfigurationError, "#{encoder.inspect} cannot be versioned: it must respond to encode and decode"
          end
          @encoders = encoders.freeze
        end

        def encode(text, nonce: false)
          encoders.first.encode(text, nonce: nonce)
        end

        def decode(text, nonce: false)
          data, encoder = decode_versioned(text, nonce: nonce)
          raise InvalidError unless encoder

          data
        end

        # The data and the encoder that decoded it, or `[nil, nil]`, so the app can treat old values differently.
        def decode_versioned(text, nonce: false)
          encoders.each do |encoder|
            return [encoder.decode(text, nonce: nonce), encoder]
          rescue ConfigurationError
            raise
          rescue StandardError
            next
          end
          [nil, nil]
        end
      end

      def self.versioned(*encoders)
        Versioned.new(encoders)
      end
    end
  end
end
