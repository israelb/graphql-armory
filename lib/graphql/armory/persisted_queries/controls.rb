# frozen_string_literal: true

module GraphQL
  module Armory
    module PersistedQueries
      # Test data for persisted queries, reusable by apps and other gems.
      module Controls
        # The operations a client build would persist for Query.example.
        module Operations
          def self.invoices = "query Invoices { invoices }"
          def self.greeting = "query Greeting($name: String!) { greeting(name: $name) }"
        end

        # A Query type with two persisted operations' fields and a `secret` no operation asks for.
        module Query
          def self.example
            Class.new(GraphQL::Schema::Object) do
              graphql_name "Query"
              field :invoices, [String], null: false
              field :greeting, String, null: false do
                argument :name, String
              end
              field :secret, String, null: false
            end
          end
        end

        # The root object for Query.example; it adds the name of each field it resolves to `resolved`.
        module Root
          def self.example(resolved = [])
            Class.new do
              define_method(:invoices) { resolved << :invoices; ["A-1"] }
              define_method(:greeting) { |name:| resolved << :greeting; "Hello #{name}" }
              define_method(:secret) { resolved << :secret; "s3cr3t" }
            end.new
          end
        end
      end
    end
  end
end
