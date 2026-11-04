# frozen_string_literal: true

module GraphQL
  module Armory
    module Versioning
      # Test data for versioning, reusable by apps and other gems.
      module Controls
        # Three versions: the oldest retired, two served.
        module Versions
          LABELS = %w[2024-01-15 2024-06-01 2025-01-01].freeze
          RETIRED = %w[2024-01-15].freeze

          def self.example = Versioning::Versions.new(LABELS, retired: RETIRED)
        end

        # A request's context naming a version.
        module Context
          def self.example(version: "2024-06-01") = { armory_version: version }
        end

        # A base field class with `Base`.
        module Field
          def self.example
            Class.new(GraphQL::Schema::Field) { include Versioning::Base }
          end
        end

        # `number` in every version; `total` from 2024-06-01; `amount` deprecated with graphql-ruby's own
        # `deprecation_reason:` and removed in 2025-01-01; `tags(first:)` from 2025-01-01.
        module Invoice
          def self.example(base_field = Field.example)
            Class.new(GraphQL::Schema::Object) do
              graphql_name "Invoice"
              field_class(base_field)
              field :number, String, null: false
              field :total, Integer, null: false, added: "2024-06-01"
              field :amount, Integer, null: false, deprecation_reason: "Use `total`", removed: "2025-01-01"
              field :tags, [String], null: false, added: "2025-01-01" do
                argument :first, Integer, required: false
              end
            end
          end
        end

        module Query
          def self.example(invoice = Invoice.example)
            Class.new(GraphQL::Schema::Object) do
              graphql_name "Query"
              field :invoice, invoice, null: false
            end
          end
        end

        # The root object for Query.example; it adds the name of each field it resolves to `resolved`.
        module Root
          def self.example(resolved = [])
            invoice = Class.new do
              define_method(:number) { resolved << :number; "A-1" }
              define_method(:total) { resolved << :total; 100 }
              define_method(:amount) { resolved << :amount; 100 }
              define_method(:tags) { |first: nil| resolved << :tags; %w[paid urgent].first(first || 2) }
            end.new
            Class.new { define_method(:invoice) { resolved << :invoice; invoice } }.new
          end
        end

        # The schema over Query.example and Versions.example, under `Schema::Visibility` (`visibility: :visibility`) or the
        # legacy `Schema::Warden` (`visibility: :warden`).
        module Schema
          PLUGINS = { visibility: GraphQL::Schema::Visibility, warden: GraphQL::Schema::Warden }.freeze

          def self.example(visibility: :visibility, default: :latest, query: Query.example, base: GraphQL::Schema, sinks: [], on_sink_error: nil)
            plugin = PLUGINS.fetch(visibility) { raise ArgumentError, "visibility: must be one of #{PLUGINS.keys.inspect}, got #{visibility.inspect}" }
            query_type = query

            Class.new(base) do
              query(query_type)
              use plugin
              use Versioning, versions: Versions::LABELS, retired: Versions::RETIRED, default: default, sinks: sinks, on_sink_error: on_sink_error
            end
          end
        end
      end
    end
  end
end
