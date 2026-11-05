# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      module Controls
        # The application objects `Controls::Schema` resolves.
        module Records
          Product = Struct.new(:name, :price, :stock_level)
          Money = Struct.new(:amount, :currency)
          Invoice = Struct.new(:number, :total)

          def self.products
            [Product.new("Lamp", Money.new(1200, "EUR"), 3), Product.new("Desk", Money.new(30_000, "EUR"), 0)]
          end

          def self.invoices
            [Invoice.new("A-1", 1200), Invoice.new("A-2", 30_000)]
          end
        end

        # A minimal schema for the caching specs, built fresh on every call:
        #
        # - `Product` (public catalog, `authorize :none`, `cache_fields ttl: 300, scope: :public, tags: ["catalog"]`) with
        #   `price` narrowed to TTL 60 and tag "pricing", and `stockLevel` declared `cache: false`;
        # - `Money` (`cache_fields ttl: 60, scope: :public`);
        # - `Invoice` (`cache_fields ttl: 30`, scope `:viewer`) behind an Authorization rule;
        # - `Query` (`products`, `product(name:)`, `invoices`) and `Mutation` (`touch`);
        # - PersistedQueries with `Operations.manifest`, strict.
        #
        # `authorization: false` leaves Authorization out; `adapter:` is its adapter (default: an allowing
        # `Authorization::Adapters::Substitute`). `next_default: true` makes `Execution::Next` the default engine.
        # `caching:` are `use GraphQL::Armory::Caching` options; without it caching is not installed (units that test
        # declarations and the walk do not need it).
        module Schema
          def self.example(authorization: true, adapter: nil, next_default: false, caching: nil, sinks: [])
            auth = authorization
            armory_auth = Authorization
            caching_base = Caching::Base
            legacy = NEXT_FIELD_OPTIONS

            base_field = Class.new(GraphQL::Schema::Field) do
              include armory_auth::Base if auth
              include caching_base
            end
            base_object = Class.new(GraphQL::Schema::Object) do
              include armory_auth::Base if auth
              include caching_base
              field_class base_field
              default_action :read if auth
            end

            money = Class.new(base_object) do
              graphql_name "Money"
              authorize :none, reason: "a price is public with its product", covers_fields: true if auth
              cache_fields ttl: 60, scope: :public, reason: "prices are the same for every viewer and tenant"
              field :amount, Integer, null: false
              field :currency, String, null: false
            end

            product = Class.new(base_object) do
              graphql_name "Product"
              authorize :none, reason: "public catalog", covers_fields: true if auth
              cache_fields ttl: 300, scope: :public, tags: ["catalog"], reason: "the catalog is the same for every viewer and tenant"
              field :name, String, null: false
              field :price, money, null: false, cache: { ttl: 60, tags: ["pricing"] }
              field :stock_level, Integer, null: false, cache: false
            end

            invoice = Class.new(base_object) do
              graphql_name "Invoice"
              cache_fields ttl: 30
              field :number, String, null: false
              field :total, Integer, null: false
            end

            root_rule = auth ? { authorize: :none, reason: "root field; its type decides" } : {}
            query = Class.new(base_object) do
              graphql_name "Query"
              authorize :none, reason: "root type; each field declares its own rule" if auth
              cache_fields ttl: 300, scope: :public, reason: "root fields: the types they return decide"
              field :products, [product], null: false, **root_rule, **legacy
              field :product, product, **root_rule, **legacy do
                argument :name, String
              end
              field :invoices, [invoice], null: false, cache: { ttl: 30, scope: :viewer }, **root_rule, **legacy

              define_method(:products) { Records.products }
              define_method(:product) { |name:| Records.products.find { |item| item.name == name } }
              define_method(:invoices) { Records.invoices }
            end

            mutation = Class.new(base_object) do
              graphql_name "Mutation"
              authorize :none, reason: "test mutation" if auth
              field :touch, GraphQL::Types::Boolean, null: false, **root_rule, **legacy
              define_method(:touch) { true }
            end

            adapter ||= Authorization::Adapters::Substitute.new(allow: true) if auth
            manifest = Operations.manifest
            Class.new(GraphQL::Schema) do
              use GraphQL::Execution::Next, **(next_default ? { as_default: true } : {}) if defined?(GraphQL::Execution::Next)
              query(query)
              mutation(mutation)
              use armory_auth, adapter: adapter, sinks: sinks if auth
              use PersistedQueries, store: manifest, strict: true, sinks: sinks
              use Caching, **caching if caching
            end
          end

          # Root fields resolve with the type's instance methods; Execution::Next needs to be told so.
          NEXT_FIELD_OPTIONS =
            if GraphQL::Schema::Field.instance_method(:initialize).parameters.any? { |_, name| name == :resolve_legacy_instance_method }
              { resolve_legacy_instance_method: true }.freeze
            else
              {}.freeze
            end
        end
      end
    end
  end
end
