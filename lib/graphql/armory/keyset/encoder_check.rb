# frozen_string_literal: true

require "json"

module GraphQL
  module Armory
    class Keyset < GraphQL::Pagination::Connection
      # Asks an encoder whether it can keep a keyset cursor private, raising `ConfigurationError` when it cannot. It catches
      # what is common: no encryption, a reversible form, a fixed key, and a chain that decodes forged text. It cannot prove
      # encryption. It has no dependencies, so `new` is ready at once and there is nothing to `build`.
      class EncoderCheck
        NEEDLE = "graphql-armory-probe"
        # Shaped like a real cursor, because an encoder may parse what it is given. They differ in their first value.
        PROBE = JSON.generate({ "v" => 1, "o" => "0" * 32, "k" => ["#{NEEDLE}-values"] }).freeze
        OTHER = PROBE.sub('"v":1', '"v":2').freeze

        def self.call(encoder)
          new.(encoder)
        end

        def call(encoder)
          first = encoded(encoder, PROBE)
          refuse("does not give back what it encoded") unless decoded(encoder, first) == PROBE
          refuse("leaves the cursor readable: it holds the ordering values") if readable?(first)
          refuse("changes only part of its output when the input changes, as a fixed key or a fixed nonce does") if local?(first, encoded(encoder, OTHER))
          refuse("decodes forged text, so a client can make its own cursors") if forged?(encoder)
          nil
        rescue ConfigurationError
          raise
        rescue StandardError => error
          # The class only: an encoder's message may hold a key.
          refuse("could not be probed: #{error.class}")
        end

        private

        def encoded(encoder, text)
          answer = encoder.encode(text, nonce: true)
          answer.is_a?(String) ? answer.b : refuse("answers #{answer.class}, not a String")
        end

        def decoded(encoder, text)
          answer = encoder.decode(text, nonce: true)
          answer.is_a?(String) ? answer.b : answer
        end

        def readable?(output)
          needle = NEEDLE.b
          [output, output.reverse, output.tr("A-Za-z", "N-ZA-Mn-za-m")].any? do |form|
            ([form, form.delete("\0")] + unpacked(form)).any? { |text| text.include?(needle) }
          end
        end

        # Each long run of Base64 or hex inside the output, so a prefix does not hide it.
        def unpacked(form)
          base64 = form.scan(%r{[A-Za-z0-9+/_-]{16,}}).map { |run| run.tr("-_", "+/").unpack1("m").b }
          hex = form.scan(/\h{16,}/).map { |run| [run].pack("H*").b }
          base64 + hex
        end

        # A one-byte change near the start changes most of what a sound encoder answers.
        def local?(one, other)
          size = [one.size, other.size].max
          changed = (0...size).count { |index| one.getbyte(index) != other.getbyte(index) }
          changed < size / 2
        end

        def forged?(encoder)
          [PROBE, [PROBE].pack("m0"), [PROBE].pack("m0").tr("+/", "-_").delete("=")].any? do |forgery|
            decoded(encoder, forgery) == PROBE.b
          rescue StandardError
            false
          end
        end

        def refuse(what)
          raise ConfigurationError,
                "this cursor_encoder #{what}. A keyset cursor holds the row's ordering values: use a GraphQL::Armory::Encoder " \
                "subclass, or `use GraphQL::Armory::Keyset, plain_cursors: true` if those values are not secret"
        end
      end

      # What `use GraphQL::Armory::Keyset` adds to a schema. A subclass inherits it, so an encoder set there is checked too.
      module SchemaChecks
        def armory_keyset_plain_cursors
          return @armory_keyset_plain_cursors unless @armory_keyset_plain_cursors.nil?

          superclass.respond_to?(:armory_keyset_plain_cursors) ? superclass.armory_keyset_plain_cursors : false
        end

        attr_writer :armory_keyset_plain_cursors

        def cursor_encoder(new_encoder = nil)
          EncoderCheck.(new_encoder) if new_encoder && !armory_keyset_plain_cursors
          super
        end
      end
    end
  end
end
