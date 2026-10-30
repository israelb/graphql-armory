# frozen_string_literal: true

module GraphQL
  module Armory
    class Keyset
      # Test data for keyset connections, reusable by apps and other gems.
      module Controls
        # A schema with one connection field, `items`, that answers what the root value holds.
        module Schema
          def self.example(base: GraphQL::Schema, cursor_encoder: nil, max_page_size: nil)
            item = Class.new(GraphQL::Schema::Object) do
              graphql_name "Item"
              field :id, String, null: false
            end
            root = Class.new(GraphQL::Schema::Object) do
              graphql_name "Query"
              field :items, item.connection_type, null: false
            end
            Class.new(base) do
              query(root)
              cursor_encoder(cursor_encoder) if cursor_encoder
              default_max_page_size(max_page_size) if max_page_size
            end
          end
        end

        # The root value `Schema.example` reads its connection from.
        module Root
          def self.example(connection)
            Struct.new(:items).new(connection)
          end
        end
      end
    end
  end
end
