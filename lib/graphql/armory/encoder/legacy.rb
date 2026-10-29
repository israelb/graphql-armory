# frozen_string_literal: true

require "base64"

module GraphQL
  module Armory
    class Encoder
      # graphql-ruby's default base64, to keep reading the cursors and IDs clients already hold while migrating to
      # encryption: put it last in `Encoder.versioned`. It reads base64 padded or not, url-safe or standard, and
      # only when it holds printable text, so a tampered encrypted value never comes back as garbage. It is not
      # encryption: anyone can forge what it reads. Remove it from the chain once old values have expired.
      module Legacy
        PRINTABLE = /\A[[:print:]]*\z/

        def self.encode(text, nonce: false)
          Base64.urlsafe_encode64(text.to_s, padding: false)
        end

        def self.decode(text, nonce: false)
          raise InvalidError unless text.is_a?(String) && !text.empty?

          plain = Base64.urlsafe_decode64(text.tr("+/", "-_").delete_suffix("==").delete_suffix("="))
          raise InvalidError if plain.empty?
          plain.force_encoding(Encoding::UTF_8)
          raise InvalidError unless plain.valid_encoding? && plain.match?(PRINTABLE)

          plain
        rescue StandardError
          raise InvalidError
        end
      end
    end
  end
end
