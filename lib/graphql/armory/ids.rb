# frozen_string_literal: true

module GraphQL
  module Armory
    # Encrypted global IDs in one line:
    #
    #   class AppSchema < GraphQL::Schema
    #     use GraphQL::Armory::IDs                         # the default encoder
    #     use GraphQL::Armory::IDs, encoder: AppEncoder    # or your own
    #   end
    #
    # Defines `id_from_object` (the type name and the record's id, encrypted) and `object_from_id`. A type that
    # includes the authorization module's Base is looked up inside the user's scope; any other type only through
    # `find: ->(type, key, context) { ... }`. Every ID that cannot be honoured answers nil, like a missing record.
    module IDs
      SEPARATOR = "/"

      def self.use(schema, encoder: nil, find: nil)
        lookup = Lookup.new(encoder: encoder || Encoder.default, find: find)
        schema.define_singleton_method(:id_from_object) { |object, type, _context| lookup.id_for(object, type) }
        schema.define_singleton_method(:object_from_id) { |id, context| lookup.object_for(id, context) }
      end

      # Turns records into IDs and IDs back into records.
      class Lookup
        attr_reader :encoder, :find

        def initialize(encoder:, find: nil)
          @encoder = encoder
          @find = find
        end

        def id_for(object, type)
          key = object.id
          raise Encoder::ConfigurationError, "#{type.graphql_name} object has no id to build a global ID from" if key.nil?

          encoder.encode("#{type.graphql_name}#{SEPARATOR}#{key}")
        end

        def object_for(id, context)
          type_name, key = encoder.decode(id).split(SEPARATOR, 2)
          return nil if key.nil? || key.empty?

          # Asked with the query's context, so a type hidden from this user is unknown.
          type = context.schema.get_type(type_name, context)
          return nil unless type.respond_to?(:kind) && type.kind.object?

          load(type, key, context)
        rescue Encoder::InvalidError
          nil
        end

        private

        def load(type, key, context)
          return Authorization::Integration.find(type, nil, key, context) if type.respond_to?(:armory_model)

          find&.call(type, key, context)
        end
      end
    end
  end
end
