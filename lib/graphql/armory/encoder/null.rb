# frozen_string_literal: true

module GraphQL
  module Armory
    class Encoder
      # The encoder of an object nobody wired: it hands out no ID and honours none, seals and digests nothing, and
      # opens nothing.
      module Null
        def self.encode(_text, nonce: false)
          raise ConfigurationError, "no encoder wired: give an Encoder (or use Encoder.default)"
        end

        def self.decode(_text, nonce: false)
          raise InvalidError
        end

        def self.seal(_bytes, aad:, purpose:)
          raise ConfigurationError, "#{name} cannot seal: no encoder wired, give an Encoder (or use Encoder.default)"
        end

        def self.open(_text, aad:, purpose:)
          raise InvalidError
        end

        def self.mac(_bytes, purpose:)
          raise ConfigurationError, "#{name} cannot digest: no encoder wired, give an Encoder (or use Encoder.default)"
        end
      end
    end
  end
end
