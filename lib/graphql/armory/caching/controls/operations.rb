# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      module Controls
        # The persisted operations of `Controls::Schema`, by id: one cacheable `:public`, one cacheable `:viewer`, one
        # with a declared variable, and one per refusal the walk or the gate must answer.
        module Operations
          ALL = {
            # Cacheable, :public, TTL 60 (Product.price narrows the catalog's 300), tags catalog and pricing.
            "catalog" => "query Catalog { products { name price { amount currency } } }",
            # Cacheable, :public, TTL 300.
            "names" => "query Names { products { name } }",
            # Cacheable, :viewer, TTL 30: invoices go through an Authorization rule.
            "invoices" => "query Invoices { invoices { number total } }",
            # Cacheable, :public, with a declared variable.
            "product" => "query Product($name: String!) { product(name: $name) { name } }",
            # Refused by the walk: stockLevel is `cache: false`.
            "stock" => "query Stock { products { name stockLevel } }",
            # Refused: introspection.
            "introspection" => "query Introspection { __schema { queryType { name } } }",
            # Refused: a mutation.
            "touch" => "mutation Touch { touch }"
          }.freeze

          def self.document(id) = ALL.fetch(id)

          # A PersistedQueries manifest holding every operation above (ids are not digests).
          def self.manifest
            PersistedQueries::Manifest.new(ALL, digest: false)
          end
        end
      end
    end
  end
end
