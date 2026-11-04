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

        # A base argument class with `Base`, for field arguments and input-object fields.
        module Argument
          def self.example
            Class.new(GraphQL::Schema::Argument) { include Versioning::Base }
          end
        end

        # A base enum value class with `Base`.
        module EnumValue
          def self.example
            Class.new(GraphQL::Schema::EnumValue) { include Versioning::Base }
          end
        end

        # `PAID` in every version; `VOID` from 2024-06-01; `CANCELLED` removed in 2025-01-01.
        module Status
          def self.example(base_value = EnumValue.example)
            Class.new(GraphQL::Schema::Enum) do
              graphql_name "Status"
              enum_value_class(base_value)
              value "PAID"
              value "VOID", added: "2024-06-01"
              value "CANCELLED", removed: "2025-01-01"
            end
          end
        end

        # `status` in every version; `since` from 2025-01-01; `code` removed in 2025-01-01.
        module InvoiceFilter
          def self.example(status = Status.example, base_argument = Argument.example)
            Class.new(GraphQL::Schema::InputObject) do
              graphql_name "InvoiceFilter"
              argument_class(base_argument)
              argument :status, status, required: false
              argument :since, String, required: false, added: "2025-01-01"
              argument :code, String, required: false, removed: "2025-01-01"
            end
          end
        end

        # `invoices(filter:, first:, page:)`: `first` from 2025-01-01, `page` removed in 2025-01-01; `status` answers what the
        # root holds, so a test can return a value outside the client's version.
        module MembersQuery
          def self.example(status: Status.example, base_argument: Argument.example)
            filter = InvoiceFilter.example(status, base_argument)
            base_field = Class.new(GraphQL::Schema::Field) { argument_class(base_argument) }

            Class.new(GraphQL::Schema::Object) do
              graphql_name "Query"
              field_class(base_field)
              field :invoices, [String], null: false do
                argument :filter, filter, required: false
                argument :first, Integer, required: false, added: "2025-01-01"
                argument :page, Integer, required: false, removed: "2025-01-01"
              end
              field :status, status, null: false
            end
          end
        end

        # The root object for MembersQuery.example: `invoices` adds `[:invoices, arguments]` to `resolved` and answers the
        # arguments as `name=value` Strings (`filter.key=value` for the filter's fields); `status` answers the value it was given.
        module MembersRoot
          def self.example(resolved = [], status: "PAID")
            Class.new do
              define_method(:invoices) do |filter: nil, first: nil, page: nil|
                arguments = { filter: filter&.to_h, first: first, page: page }.compact
                resolved << [:invoices, arguments]
                arguments.flat_map do |name, value|
                  value.is_a?(Hash) ? value.map { |key, item| "#{name}.#{key}=#{item}" } : ["#{name}=#{value}"]
                end
              end
              define_method(:status) { resolved << :status; status }
            end.new
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
