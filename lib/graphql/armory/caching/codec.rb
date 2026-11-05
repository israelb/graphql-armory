# frozen_string_literal: true

require "openssl"

module GraphQL
  module Armory
    module Caching
      # Turns an Entry into the String a store keeps, and back. JSON only: a store's contents are never handed to a
      # deserializer that can build objects.
      #
      #   Codec.new                         # plain JSON: for a process-local store nobody else can write
      #   Codec.build(encoder: AppEncoder)  # sealed with `encoder.seal` (AES-256-GCM, purpose "cache")
      #   codec.encode(entry, key_digest)   # => String
      #   codec.decode(blob, key_digest)    # => Entry, or raises Entry::Rejected (:format, :key or :decrypt)
      #
      # A sealed entry is bound to the entry format and to the key digest it was written under (the additional
      # data), and to the encoder's key and tag (`Encoder.seal` binds them): an entry moved under another key, forged
      # in clear, edited, or written by another app does not open (`:decrypt`). Whatever opens must still name the
      # same key inside (`:key`) and parse as an entry of this format (`:format`).
      class Codec
        PURPOSE = "cache"
        AAD_LABEL = "graphql-armory/cache-entry"

        # Encrypts nothing: the plain JSON codec's sealer.
        module Plain
          def self.seal(bytes, aad:, purpose:) = bytes
          def self.open(text, aad:, purpose:) = text
        end

        # The additional data an entry under `key_digest` is sealed with: the entry format and the key digest.
        def self.additional_data(key_digest)
          check_key(key_digest)

          "#{AAD_LABEL}/#{Entry::FORMAT}\0#{key_digest}"
        end

        # Seals with `encoder` (an Encoder subclass, `Encoder.versioned(...)`, or anything with `seal` and `open`).
        # Tries one seal and open at boot, so an encoder without a key, `Encoder::Null` or `Encoder::Legacy` fails
        # here instead of on the first request.
        def self.build(encoder:)
          unless %i[seal open].all? { |name| encoder.respond_to?(name) }
            raise ConfigurationError, "encoder: must answer seal and open (an Encoder subclass), got #{encoder.inspect}"
          end

          probe(encoder)
          new(sealer: encoder)
        end

        def self.probe(encoder)
          aad = additional_data("0" * 64)
          sealed = encoder.seal("{}", aad: aad, purpose: PURPOSE)
          raise ConfigurationError, "encoder: #{encoder.inspect} did not open what it sealed" unless encoder.open(sealed, aad: aad, purpose: PURPOSE) == "{}".b
        rescue Encoder::ConfigurationError, Encoder::InvalidError => error
          raise ConfigurationError, "encoder: #{encoder.inspect} cannot seal cache entries (#{error.message})"
        end
        private_class_method :probe

        def self.check_key(key_digest)
          raise ArgumentError, "key digest: must be 64 hex characters" unless key_digest.is_a?(String) && Key::HEX.match?(key_digest)
        end
        private_class_method :check_key

        def initialize(sealer: Plain)
          @sealer = sealer
        end

        def encode(entry, key_digest)
          raise ArgumentError, "a Codec encodes an Entry, got #{entry.class}" unless entry.is_a?(Entry)
          raise ArgumentError, "the entry's key is not the key digest it is written under" unless entry.key == key_digest

          @sealer.seal(entry.to_json_string, aad: self.class.additional_data(key_digest), purpose: PURPOSE)
        end

        def decode(blob, key_digest)
          aad = self.class.additional_data(key_digest)
          raise Entry::Rejected, :format unless blob.is_a?(String)

          entry = Entry.parse(utf8(open(blob, aad)))
          raise Entry::Rejected, :key unless OpenSSL.fixed_length_secure_compare(entry.key, key_digest)

          entry
        end

        def sealed? = !@sealer.equal?(Plain)

        def inspect = "#<#{self.class.name} sealed=#{sealed?}>"

        private

        def open(blob, aad)
          @sealer.open(blob, aad: aad, purpose: PURPOSE)
        rescue Encoder::ConfigurationError, ConfigurationError, ArgumentError
          raise
        rescue StandardError
          # Tampered, moved, forged, foreign, or the encoder failed: a miss, never an error the request sees.
          raise Entry::Rejected, :decrypt
        end

        def utf8(bytes)
          text = bytes.dup.force_encoding(Encoding::UTF_8)
          raise Entry::Rejected, :format unless text.valid_encoding?

          text
        end
      end
    end
  end
end
