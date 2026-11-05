# frozen_string_literal: true

require "json"

module GraphQL
  module Armory
    module Subscriptions
      # The store's key for "subscribers of this field with these arguments in this scope": a keyed digest of
      #
      #   [FORMAT, field.graphql_name, args(field, arguments), tagged(scope)]
      #
      # as JSON. Every part is a JSON value inside a fixed-arity array, so a ":" inside a value is just a character
      # (graphql-ruby's own topic joins the parts with unescaped ":"), and `1` and `"1"` scopes differ.
      #
      # The write side (graphql-ruby's coerced Ruby keyword arguments, InputObject instances, defaults filled) and the
      # trigger side (GraphQL names or keywords, the app's raw values) meet because `args` canonicalises through the
      # field's argument definitions: each key becomes its argument's GraphQL name, missing defaults are filled, each
      # leaf becomes its type's result coercion (an ID its String, an enum its GraphQL name, a custom scalar what its
      # `coerce_result` answers), input objects recurse, lists map, and pairs are sorted by name.
      #
      #   topic = Topic.build(encoder: AppEncoder)
      #   topic.(field, { "roomId" => 5 }, scope)       # => 64 hex characters
      #
      # Limits: an argument whose `prepare:` changes its value, or a `loads:` argument (the write side holds the loaded
      # object), cannot meet its trigger: the leaf is refused or digested apart.
      class Topic
        FORMAT = 1
        PURPOSE = "subscription-topic"
        # How deep a scope or an input value may nest: a cycle is refused, never followed.
        MAX_DEPTH = 32

        def self.build(encoder:)
          raise ConfigurationError, "encoder: must answer mac(bytes, purpose:) (an Encoder subclass), got #{encoder.class}" unless encoder.respond_to?(:mac)

          new(encoder: encoder)
        end

        # Inert: Encoder::Null refuses to digest.
        def initialize(encoder: Encoder::Null)
          @encoder = encoder
        end

        def call(field, arguments, scope, context: nil)
          self.class.digest(@encoder, field, arguments, scope, context: context)
        end

        # The keyed digest of `canonical`, as 64 lowercase hex characters.
        def self.digest(encoder, field, arguments, scope, context: nil)
          encoder.mac(canonical(field, arguments, scope, context: context), purpose: PURPOSE).unpack1("H*")
        end

        # The JSON text the digest is made of.
        def self.canonical(field, arguments, scope, context: nil)
          JSON.generate([FORMAT, field.graphql_name, args(field, arguments, context: context), tagged(scope)])
        rescue JSON::GeneratorError, EncodingError
          raise ArgumentError, "the arguments of #{field.path} do not make a topic: a value is not valid UTF-8"
        end

        # `arguments` (a Hash, graphql-ruby's interpreter Arguments, or nil) as sorted [GraphQL name, canonical value]
        # pairs. Raises ArgumentError for an unknown key, the same argument twice, a missing required argument or a
        # value its type cannot coerce. Messages name the argument, never its value.
        def self.args(field, arguments, context: nil)
          context ||= GraphQL::Query::NullContext.instance
          given = arguments.nil? ? {} : Canonical.hash_of(arguments, field.path)
          extras = field.respond_to?(:extras) ? field.extras.map(&:to_s) : [] # an input object class has none
          Canonical.new(context).object(field, given.reject { |key, _| extras.include?(key.to_s) }, field.path, 0)
        end

        # The scope, which has no GraphQL type, tagged with its Ruby type: ["s", string], ["i", integer], ["f", float],
        # ["b", bool], ["n"], ["a", [...]], ["h", sorted pairs], a record ["g", its global id]. Raises ArgumentError for
        # anything else (a Symbol, a non-finite Float, two keys that stringify alike, an object without `to_gid`).
        def self.tagged(scope, depth = 0)
          raise ArgumentError, "a subscription scope nests deeper than #{MAX_DEPTH}" if depth > MAX_DEPTH

          case scope
          when nil then ["n"]
          when true, false then ["b", scope]
          when String then ["s", utf8(scope)]
          when Integer then ["i", scope]
          when Float
            raise ArgumentError, "a subscription scope Float must be finite" unless scope.finite?

            ["f", scope]
          when Array then ["a", scope.map { |item| tagged(item, depth + 1) }]
          when Hash then ["h", tagged_pairs(scope, depth)]
          else
            raise ArgumentError, "a subscription scope must be nil, a boolean, a String, a number, an Array, a Hash or a record with to_gid, got a #{scope.class}" unless scope.respond_to?(:to_gid)

            ["g", utf8(global_id(scope))]
          end
        end

        def self.utf8(string)
          text = string.encoding == Encoding::UTF_8 ? string : string.encode(Encoding::UTF_8)
          raise ArgumentError, "a subscription topic String must be valid UTF-8" unless text.valid_encoding?

          text
        rescue EncodingError
          raise ArgumentError, "a subscription topic String must be valid UTF-8"
        end

        def self.tagged_pairs(hash, depth)
          pairs = hash.map do |key, value|
            raise ArgumentError, "a subscription scope Hash must have String or Symbol keys, got a #{key.class}" unless key.is_a?(String) || key.is_a?(Symbol)

            [utf8(key.to_s), tagged(value, depth + 1)]
          end
          raise ArgumentError, "a subscription scope Hash has two keys that stringify alike" unless pairs.map(&:first).uniq.size == pairs.size

          pairs.sort_by(&:first)
        end

        def self.global_id(record)
          gid = record.to_gid
          text = gid.to_s
          raise ArgumentError, "a subscription scope record must have a global id" if gid.nil? || text.empty?

          text
        rescue ArgumentError
          raise
        rescue StandardError
          raise ArgumentError, "a subscription scope record must have a global id (#{record.class} has none)"
        end

        private_class_method :utf8, :tagged_pairs, :global_id

        # Walks one set of arguments through their definitions. `context` is what argument and enum value
        # definitions are looked up with (a query's, or NullContext).
        class Canonical
          # A Hash of arguments from what either side holds: a Hash, an InputObject, or graphql-ruby's interpreter
          # Arguments.
          def self.hash_of(value, path)
            return value.to_h if value.is_a?(GraphQL::Schema::InputObject)
            return value.to_h if defined?(GraphQL::Execution::Interpreter::Arguments) && value.is_a?(GraphQL::Execution::Interpreter::Arguments)
            return value if value.is_a?(Hash)

            raise ArgumentError, "the arguments of #{path} must be a Hash, got a #{value.class}"
          end

          def initialize(context)
            @context = context
          end

          # The sorted pairs of an argument owner (a field or an input object class).
          def object(owner, given, path, depth)
            raise ArgumentError, "the arguments of #{path} nest deeper than #{MAX_DEPTH}" if depth > MAX_DEPTH

            definitions = owner.arguments(@context)
            pairs = {}
            given.each do |key, value|
              definition = find(definitions, key)
              raise ArgumentError, "unknown argument #{key.to_s.inspect} for #{path}" unless definition

              name = definition.graphql_name
              raise ArgumentError, "argument #{name} of #{path} given twice" if pairs.key?(name)

              pairs[name] = value(definition.type, value, "#{path}.#{name}", depth)
            end
            definitions.each_value do |definition|
              next if pairs.key?(definition.graphql_name)

              if definition.default_value?
                pairs[definition.graphql_name] = value(definition.type, definition.default_value, "#{path}.#{definition.graphql_name}", depth)
              elsif definition.type.non_null?
                raise ArgumentError, "required argument #{definition.graphql_name} of #{path} is missing"
              end
            end
            pairs.sort_by(&:first)
          end

          private

          # By GraphQL name first, then by Ruby keyword: the trigger side names arguments in GraphQL, the write side
          # by keyword (an `as:` keyword included).
          def find(definitions, key)
            return nil unless key.is_a?(String) || key.is_a?(Symbol)

            name = key.to_s
            definitions[name] || definitions.each_value.find { |definition| definition.keyword.to_s == name }
          end

          def value(type, value, path, depth)
            if type.non_null?
              raise ArgumentError, "argument #{path} cannot be null" if value.nil?

              return value(type.of_type, value, path, depth)
            end
            return nil if value.nil?

            if type.list?
              # GraphQL coerces a single value given for a list into a list of one.
              items = value.is_a?(Array) ? value : [value]
              return items.map { |item| value(type.of_type, item, path, depth + 1) }
            end

            if type.kind.input_object?
              object(type, Canonical.hash_of(value, path), path, depth + 1)
            else
              leaf(type, value, path)
            end
          rescue ArgumentError
            raise
          rescue StandardError
            raise ArgumentError, "argument #{path} has a value its type cannot coerce"
          end

          # A scalar or an enum value as its result coercion. The value is either already coerced (the write side:
          # its result coercion coerces back to it), or raw input (the trigger side: coerced as a query argument would
          # be, then result-coerced). Anything else is refused.
          def leaf(type, value, path)
            canonical = coerced(type, value)
            canonical = raw(type, value) if canonical.equal?(NONE)
            raise ArgumentError, "argument #{path} has a value its type cannot coerce" if canonical.equal?(NONE) || !json_value?(canonical)

            canonical
          end

          NONE = Object.new.freeze
          private_constant :NONE

          def coerced(type, value)
            result = type.coerce_result(value, @context)
            type.coerce_input(result, @context) == value ? result : NONE
          rescue StandardError
            NONE
          end

          def raw(type, value)
            return NONE unless type.valid_input?(value, @context)

            input = type.coerce_input(value, @context)
            input.nil? ? NONE : type.coerce_result(input, @context)
          rescue StandardError
            NONE
          end

          def json_value?(value, depth = 0)
            return false if depth > MAX_DEPTH

            case value
            when nil, true, false, Integer then true
            when Float then value.finite?
            when String then value.encoding == Encoding::UTF_8 ? value.valid_encoding? : value.ascii_only?
            when Array then value.all? { |item| json_value?(item, depth + 1) }
            when Hash then value.all? { |key, item| key.is_a?(String) && json_value?(item, depth + 1) }
            else false
            end
          end
        end
      end
    end
  end
end
