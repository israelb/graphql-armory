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

        # A schema that evolves from 2024-06-01 to 2025-01-01 with one change of each kind `Diff` classifies, under
        # `Schema::Visibility` or the legacy Warden. `Evolution::BREAKING`, `DANGEROUS` and `SAFE` list what `Diff` answers.
        #
        # - Money changes shape (a type twin: `cents`, then `amount` and `currency`); Ref changes kind (a scalar, then an
        #   object); Customer is renamed Client; Receipt leaves and Contract arrives (both in the Document union);
        #   Archivable leaves, and with it Invoice's `archived`.
        # - Invoice: `amount` removed; `note` String to String! (an output made stricter); `code` String! to String;
        #   `label` deprecated; `tags` gains a required `after:` and an optional `last:`.
        # - Status: VOID added, CANCELLED removed. InvoiceFilter: `code` removed, `since` added, a required `kind` added.
        # - Query.invoices: `first:` default 10 to 20; `page:` Int! to Int; `limit:` Int to Int!.
        module Evolution
          FROM = "2024-06-01"
          TO = "2025-01-01"

          BREAKING = [
            ["Archivable", "type removed"],
            ["Customer", "type removed"],
            ["Document", "member Receipt removed"],
            ["Invoice", "no longer implements Archivable"],
            ["Invoice.amount", "field removed"],
            ["Invoice.archived", "field removed"],
            ["Invoice.code", "type changed from String! to String"],
            ["Invoice.tags.after", "required argument added"],
            ["InvoiceFilter.code", "input field removed"],
            ["InvoiceFilter.kind", "required input field added"],
            ["Money.cents", "field removed"],
            ["Query.customer", "type changed from Customer to Client"],
            ["Query.invoices.limit", "type changed from Int to Int!"],
            ["Receipt", "type removed"],
            ["Ref", "kind changed from SCALAR to OBJECT"],
            ["Status.CANCELLED", "value removed"],
          ].freeze

          DANGEROUS = [
            ["Document", "member Contract added"],
            ["Invoice.label", "deprecated: Use `number`"],
            ["Invoice.note", "type changed from String to String!"],
            ["Query.invoices.first", "default value changed from 10 to 20"],
            ["Status.VOID", "value added"],
          ].freeze

          SAFE = [
            ["Client", "type added"],
            ["Contract", "type added"],
            ["Invoice.tags.last", "argument added"],
            ["InvoiceFilter.since", "input field added"],
            ["Money.amount", "field added"],
            ["Money.currency", "field added"],
            ["Query.invoices.page", "type changed from Int! to Int"],
          ].freeze

          def self.example(visibility: :visibility, base: GraphQL::Schema)
            base_argument = Argument.example
            base_field = Class.new(GraphQL::Schema::Field) { include Versioning::Base; argument_class(base_argument) }
            base_object = Class.new(GraphQL::Schema::Object) { include Versioning::Base; field_class(base_field) }
            base_value = EnumValue.example
            base_input = Class.new(GraphQL::Schema::InputObject) { include Versioning::Base; argument_class(base_argument) }

            archivable = Module.new do
              include GraphQL::Schema::Interface
              include Versioning::Base
              graphql_name "Archivable"
              field_class(base_field)
              lifecycle removed: TO
              field :archived, GraphQL::Types::Boolean, null: false
            end
            money_v1 = Class.new(base_object) { graphql_name "Money"; lifecycle removed: TO; field :cents, Integer, null: false }
            money_v2 = Class.new(base_object) do
              graphql_name "Money"
              lifecycle added: TO
              field :amount, String, null: false
              field :currency, String, null: false
            end
            status = Class.new(GraphQL::Schema::Enum) do
              include Versioning::Base
              graphql_name "Status"
              enum_value_class(base_value)
              value "PAID"
              value "VOID", added: TO
              value "CANCELLED", removed: TO
            end
            invoice = Class.new(base_object) do
              graphql_name "Invoice"
              implements archivable
              field :number, String, null: false
              field :total, money_v1, null: false, removed: TO
              field :total, money_v2, null: false, added: TO
              field :amount, Integer, null: false, removed: TO
              field :note, String, null: true, removed: TO
              field :note, String, null: false, added: TO
              field :code, String, null: false, removed: TO
              field :code, String, null: true, added: TO
              field :label, String, null: true, removed: TO
              field :label, String, null: true, added: TO, deprecation_reason: "Use `number`"
              field :status, status, null: false
              field :tags, [String], null: false do
                argument :first, Integer, required: false
                argument :after, String, required: true, added: TO
                argument :last, Integer, required: false, added: TO
              end
            end
            receipt = Class.new(base_object) { graphql_name "Receipt"; lifecycle removed: TO; field :number, String, null: false }
            contract = Class.new(base_object) { graphql_name "Contract"; lifecycle added: TO; field :party, String, null: false }
            document = Class.new(GraphQL::Schema::Union) do
              graphql_name "Document"
              possible_types invoice, receipt, contract
            end
            filter = Class.new(base_input) do
              graphql_name "InvoiceFilter"
              argument :status, status, required: false
              argument :code, String, required: false, removed: TO
              argument :since, String, required: false, added: TO
              argument :kind, String, required: true, added: TO
            end
            ref_v1 = Class.new(GraphQL::Schema::Scalar) { include Versioning::Base; graphql_name "Ref"; lifecycle removed: TO }
            ref_v2 = Class.new(base_object) { graphql_name "Ref"; lifecycle added: TO; field :id, String, null: false }
            customer = Class.new(base_object) { graphql_name "Customer"; lifecycle removed: TO; field :name, String, null: false }
            client = Class.new(base_object) { graphql_name "Client"; lifecycle added: TO; field :name, String, null: false }

            query = Class.new(base_object) do
              graphql_name "Query"
              field :invoice, invoice, null: false
              field :document, document, null: true
              field :ref, ref_v1, null: true, removed: TO
              field :ref, ref_v2, null: true, added: TO
              field :customer, customer, null: true, removed: TO
              field :customer, client, null: true, added: TO
              field :invoices, [String], null: false do
                argument :filter, filter, required: false
                argument :first, Integer, required: false, default_value: 10, removed: TO
                argument :first, Integer, required: false, default_value: 20, added: TO
                argument :page, Integer, required: true, removed: TO
                argument :page, Integer, required: false, added: TO
                argument :limit, Integer, required: false, removed: TO
                argument :limit, Integer, required: true, added: TO
              end
            end

            Schema.example(visibility: visibility, query: query, base: base)
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
