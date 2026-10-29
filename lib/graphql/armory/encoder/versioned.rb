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

          encoders.each { |encoder| check(encoder) }
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
            data = encoder.decode(text, nonce: nonce)
            return [data, encoder] if data.is_a?(String)
          rescue ConfigurationError
            raise
          rescue StandardError
            next
          end
          [nil, nil]
        end

        private

        # Fails at boot for a member that would otherwise refuse every value at request time.
        def check(encoder)
          unless %i[encode decode].all? { |name| encoder.respond_to?(name) }
            raise ConfigurationError, "#{encoder.inspect} cannot be versioned: it must respond to encode and decode"
          end
          unless %i[encode decode].all? { |name| accepts_nonce?(encoder.method(name)) }
            raise ConfigurationError, "#{encoder.inspect} cannot be versioned: encode and decode must accept `nonce:`"
          end
          return unless encoder.respond_to?(:key) && encoder.respond_to?(:tag) && encoder.key.nil?

          raise ConfigurationError, "#{encoder.inspect} cannot be versioned: it has no key"
        end

        def accepts_nonce?(method)
          method.parameters.any? { |kind, name| kind == :keyrest || (%i[key keyreq].include?(kind) && name == :nonce) }
        end
      end

      def self.versioned(*encoders)
        Versioned.new(encoders)
      end
    end
  end
end
