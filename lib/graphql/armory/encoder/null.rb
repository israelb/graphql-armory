# frozen_string_literal: true

module GraphQL
  module Armory
    class Encoder
      # The encoder of an object nobody wired: it hands out no ID and honours none.
      module Null
        def self.encode(_text, nonce: false)
          raise ConfigurationError, "no encoder wired: give an Encoder (or use Encoder.default)"
        end

        def self.decode(_text, nonce: false)
          raise InvalidError
        end
      end
    end
  end
end
