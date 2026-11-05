# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # The one encoding of a key's components, so two requests share a key only when every component is the same value
      # of the same type. Written by hand, not with a JSON library's generator, so a library upgrade or a global option
      # never changes a key.
      #
      #   Canonical.json(["armory-cache/2", 1, 1.0, nil])   # => "[\"armory-cache/2\",1,1.0,null]"
      #   Canonical.typed(:en)                             # => ["sym", "en"]
      #   Canonical.typed("en")                            # => ["str", "en"]
      #
      # Every method raises `Canonical::Unsupported` for a value it cannot encode without ambiguity; the keyer turns it
      # into a refusal (`:variables`, `:vary_value`). The message names the type, never the value.
      module Canonical
        class Unsupported < Error; end

        # Deeper than any JSON a parser accepts by default (Ruby's `max_nesting` is 100); also stops a cyclic Array.
        MAX_DEPTH = 100

        ESCAPES = { '"' => '\\"', "\\" => "\\\\" }.freeze
        ESCAPED = /["\\\x00-\x1f]/

        module_function

        # JSON for String, Integer, finite Float, true, false, nil, Array and Hash with String keys. A Hash keeps its
        # key order: two orders are two keys, never one answer for two inputs. `1` and `1.0` stay apart.
        def json(value)
          out = +""
          write(value, out, 0)
          out
        end

        # A `vary:` value with its type, recursively: a Symbol and a String, or `1` and `"1"`, never collide.
        def typed(value, depth = 0)
          raise Unsupported, "a value nested deeper than #{MAX_DEPTH}" if depth > MAX_DEPTH

          case value
          when String then ["str", utf8(value)]
          when Symbol then ["sym", utf8(value.name)]
          when Integer then ["int", value]
          when Float then ["float", finite(value)]
          when true, false then ["bool", value]
          when nil then ["nil"]
          when Array then ["arr", value.map { |item| typed(item, depth + 1) }]
          when Hash then ["hash", value.map { |key, item| [typed(key, depth + 1), typed(item, depth + 1)] }]
          else raise Unsupported, "a #{value.class}"
          end
        end

        # `[name, provided?, value]` for each variable the operation declares, sorted by name. `provided?` keeps a variable
        # not sent apart from one sent as null; variables the operation does not declare are ignored, as graphql-ruby
        # ignores them. The values are the client's, before coercion (a scalar's `coerce_input` may read the context).
        # Top-level names may be Strings or Symbols, as graphql-ruby stringifies them; one name given both ways raises.
        def variables(operation, provided)
          provided = {} if provided.nil?
          raise Unsupported, "variables given as a #{provided.class}, not a Hash" unless provided.is_a?(Hash)

          given = {}
          provided.each do |name, value|
            raise Unsupported, "a variable named by a #{name.class}" unless name.is_a?(String) || name.is_a?(Symbol)
            raise Unsupported, "a variable given twice, as a String and a Symbol" if given.key?(name.to_s)

            given[name.to_s] = value
          end

          operation.variables.map(&:name).sort.map do |name|
            sent = given.key?(name)
            value = sent ? given[name] : nil
            json(value)
            [name, sent, value]
          end
        end

        def write(value, out, depth)
          raise Unsupported, "a value nested deeper than #{MAX_DEPTH}" if depth > MAX_DEPTH

          case value
          when String then string(value, out)
          when Integer then out << value.to_s
          when Float then out << finite(value).to_s
          when true then out << "true"
          when false then out << "false"
          when nil then out << "null"
          when Array then array(value, out, depth)
          when Hash then object(value, out, depth)
          else raise Unsupported, "a #{value.class}"
          end
        end

        def array(value, out, depth)
          out << "["
          value.each_with_index do |item, index|
            out << "," if index.positive?
            write(item, out, depth + 1)
          end
          out << "]"
        end

        def object(value, out, depth)
          out << "{"
          value.each_with_index do |(key, item), index|
            raise Unsupported, "a Hash key that is a #{key.class}, not a String" unless key.is_a?(String)

            out << "," if index.positive?
            string(key, out)
            out << ":"
            write(item, out, depth + 1)
          end
          out << "}"
        end

        def string(value, out)
          out << '"' << utf8(value).gsub(ESCAPED) { |char| ESCAPES[char] || format("\\u%04x", char.ord) } << '"'
        end

        # The same characters in another encoding are the same String; bytes that are not text are refused.
        def utf8(value)
          text = value.encoding == Encoding::UTF_8 ? value : value.encode(Encoding::UTF_8)
          raise Unsupported, "a String that is not valid UTF-8" unless text.valid_encoding?

          text
        rescue EncodingError
          raise Unsupported, "a String that is not valid UTF-8"
        end

        def finite(value)
          raise Unsupported, "a Float that is not finite" unless value.finite?

          value
        end

        private_class_method :write, :array, :object, :string, :utf8, :finite
      end
    end
  end
end
