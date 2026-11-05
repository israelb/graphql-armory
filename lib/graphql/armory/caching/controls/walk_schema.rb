# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      module Controls
        # The shapes the walk must judge, built fresh on every call (no Authorization, no PersistedQueries: the walk
        # reads only declarations and `query.types`):
        #
        # - `Node` (interface, `cache_fields ttl: 300, scope: :public`) with `id`, `label` and `summary`, implemented
        #   by `Product` (overrides `label` narrower: TTL 10, tag "labels"), `Invoice` (`cache_fields ttl: 30`, scope
        #   `:viewer`, which reaches the `label` it redefines but not the `id` and `summary` it inherits) and `Secret`
        #   (overrides `summary` with `cache: false`; its own `code` is undeclared);
        # - `SearchResult`, a union of `Product` and `Invoice`;
        # - `Parent` (no `cache_fields`) with `secret`, and `Child < Parent` with a wider `cache_fields ttl: 3600,
        #   scope: :public` and its own `name`: the inherited `secret` stays undeclared;
        # - Relay connections: `Query.products` (graphql-ruby's generated connection and edge, on the app's own base
        #   connection), `Query.counted` (adds `totalCount`, undeclared) and `Query.curated` (overrides `nodes` with
        #   its own resolver method, so `nodes` needs a declaration);
        # - `Query.internalNote`, hidden when the context holds `hide_internal_note: true` (a member `query.types`
        #   does not show);
        # - directives `@hint` (`cache_safe`) and `@flagged` (not), on every executable location;
        # - `Mutation.touch` and `Subscription.ticked`.
        #
        # `partial: true` adds `Query.partial`, whose `Partial.code` declares `cache: { tags: ["x"] }` on a type with
        # no `cache_fields`: a definition error that `armory_cache` raises when the walk reaches it. `replaced_skip: true`
        # registers an app directive class named `skip` (a subclass of graphql-ruby's) in place of the built-in one.
        # `next_default: true` makes `Execution::Next` the default engine.
        module WalkSchema
          module Records
            Product = Struct.new(:id, :label, :name)
            Invoice = Struct.new(:id, :label, :number)

            def self.products
              [Product.new("P1", "lamp", "Lamp"), Product.new("P2", "desk", "Desk")]
            end
          end

          LOCATIONS = %i[QUERY FIELD FRAGMENT_DEFINITION FRAGMENT_SPREAD INLINE_FRAGMENT VARIABLE_DEFINITION].freeze

          def self.example(next_default: false, partial: false, replaced_skip: false)
            caching_base = Caching::Base
            legacy = Schema::NEXT_FIELD_OPTIONS
            records = Records
            locations = LOCATIONS.map { |name| GraphQL::Schema::Directive.const_get(name) }

            base_field = Class.new(GraphQL::Schema::Field) { include caching_base }
            base_object = Class.new(GraphQL::Schema::Object) do
              include caching_base
              field_class base_field
            end
            base_edge = Class.new(base_object) { include GraphQL::Types::Relay::EdgeBehaviors }
            base_connection = Class.new(base_object) { include GraphQL::Types::Relay::ConnectionBehaviors }
            base_object.edge_type_class(base_edge)
            base_object.connection_type_class(base_connection)

            node = Module.new do
              include GraphQL::Schema::Interface
              include caching_base
              graphql_name "Node"
              field_class base_field
              cache_fields ttl: 300, scope: :public, reason: "ids and labels are the same for every viewer"
              field :id, GraphQL::Types::ID, null: false
              field :label, String, null: false
              field :summary, String, null: false
            end

            product = Class.new(base_object) do
              graphql_name "Product"
              implements node
              cache_fields ttl: 300, scope: :public, tags: ["catalog"], reason: "the catalog is the same for every viewer"
              field :name, String, null: false
              field :label, String, null: false, cache: { ttl: 10, tags: ["labels"] }
            end

            invoice = Class.new(base_object) do
              graphql_name "Invoice"
              implements node
              cache_fields ttl: 30
              field :number, String, null: false
              field :label, String, null: false
            end

            secret = Class.new(base_object) do
              graphql_name "Secret"
              implements node
              field :summary, String, null: false, cache: false
              field :code, String, null: false
            end

            search_result = Class.new(GraphQL::Schema::Union) do
              graphql_name "SearchResult"
              possible_types product, invoice
            end

            parent = Class.new(base_object) do
              graphql_name "Parent"
              field :secret, String, null: false
            end
            child = Class.new(parent) do
              graphql_name "Child"
              cache_fields ttl: 3600, scope: :public, reason: "the child's own fields are public"
              field :name, String, null: false
            end

            counted = Class.new(base_connection) do
              graphql_name "CountedProductConnection"
              edge_type product.edge_type
              field :total_count, Integer, null: false
            end

            curated = Class.new(base_connection) do
              graphql_name "CuratedProductConnection"
              edge_type product.edge_type, nodes_field: false
              field :nodes, [product], null: false
              define_method(:nodes) { records.products.reverse }
            end

            partial_type = if partial
              Class.new(base_object) do
                graphql_name "Partial"
                field :code, String, null: false, cache: { tags: ["x"] }
              end
            end

            query = Class.new(base_object) do
              graphql_name "Query"
              cache_fields ttl: 300, scope: :public, reason: "root fields: the types they return decide"
              field :node, node, **legacy do
                argument :id, GraphQL::Types::ID
              end
              field :nodes, [node], null: false, **legacy
              field :search, [search_result], null: false, **legacy
              field :child, child, **legacy
              field :products, product.connection_type, null: false, **legacy
              field :counted, counted, null: false, **legacy
              field :curated, curated, null: false, **legacy
              field :invoices, [invoice], null: false, cache: { ttl: 30, scope: :viewer }, **legacy
              field :internal_note, String, **legacy do
                define_singleton_method(:visible?) { |context| super(context) && !context[:hide_internal_note] }
              end
              field :partial, partial_type, **legacy if partial_type

              define_method(:node) { |id:| records.products.find { |item| item.id == id } }
              define_method(:nodes) { records.products }
              define_method(:search) { records.products }
              define_method(:child) { nil }
              define_method(:products) { records.products }
              define_method(:counted) { records.products }
              define_method(:curated) { records.products }
              define_method(:invoices) { [] }
              define_method(:internal_note) { "note" }
              define_method(:partial) { nil }
            end

            mutation = Class.new(base_object) do
              graphql_name "Mutation"
              field :touch, GraphQL::Types::Boolean, null: false, **legacy
              define_method(:touch) { true }
            end

            subscription = Class.new(base_object) do
              graphql_name "Subscription"
              field :ticked, GraphQL::Types::Boolean, null: false, **legacy
            end

            hint = Class.new(GraphQL::Schema::Directive) do
              include caching_base
              graphql_name "hint"
              locations(*locations)
              cache_safe reason: "a client hint; it changes nothing in the answer"
            end
            flagged = Class.new(GraphQL::Schema::Directive) do
              include caching_base
              graphql_name "flagged"
              locations(*locations)
            end

            # An app class that takes over the name `skip`: it is not graphql-ruby's, so the walk does not ignore it.
            own_skip = (Class.new(GraphQL::Schema::Directive::Skip) { graphql_name "skip" } if replaced_skip)

            product_type = product
            Class.new(GraphQL::Schema) do
              use GraphQL::Execution::Next, **(next_default ? { as_default: true } : {}) if defined?(GraphQL::Execution::Next)
              query(query)
              mutation(mutation)
              subscription(subscription)
              orphan_types(invoice, secret)
              directives(hint, flagged, *own_skip)
              define_singleton_method(:resolve_type) { |_abstract, _object, _context| product_type }
            end
          end
        end
      end
    end
  end
end
