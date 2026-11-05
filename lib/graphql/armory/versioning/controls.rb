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

        # `deprecated:` on every member kind, each deprecated from `FROM`: an interface's field, an object's field with
        # arguments of their own lifecycles in its block, a field argument, an input-object field, a resolver's argument, a
        # `resolver:` field and an enum value.
        module Deprecations
          FROM = "2025-01-01"

          # Base classes with `Base` for every owner and member kind; with `authorization: true`, Authorization's `Base` too.
          module Bases
            def self.example(authorization: false)
              mods = [Versioning::Base]
              mods << Armory::Authorization::Base if authorization
              argument = Class.new(GraphQL::Schema::Argument) { mods.each { |mod| include mod } }
              field = Class.new(GraphQL::Schema::Field) { mods.each { |mod| include mod }; argument_class(argument) }
              value = Class.new(GraphQL::Schema::EnumValue) { include Versioning::Base }
              {
                argument: argument, field: field,
                object: Class.new(GraphQL::Schema::Object) { mods.each { |mod| include mod }; field_class(field) },
                # Named as an app's `Types::BaseInterface` is: some walkers read the name of every interface an interface includes.
                interface: Module.new { include GraphQL::Schema::Interface; include Versioning::Base; graphql_name "BaseInterface"; field_class(field) },
                input: Class.new(GraphQL::Schema::InputObject) { mods.each { |mod| include mod }; argument_class(argument) },
                enum: Class.new(GraphQL::Schema::Enum) { include Versioning::Base; enum_value_class(value) },
                resolver: Class.new(GraphQL::Schema::Resolver) { include Versioning::Base; argument_class(argument) },
                subscription: Class.new(GraphQL::Schema::Subscription) { include Versioning::Base; argument_class(argument); field_class(field) }
              }
            end
          end

          # The query type. Objects declare an Authorization rule when their base has Authorization's `Base`.
          module Query
            def self.example(bases = Bases.example)
              from = FROM
              open = ->(type) { type.authorize(:none, reason: "test data", covers_fields: true) if type.respond_to?(:authorize) }
              status = Class.new(bases[:enum]) do
                graphql_name "Status"
                value "PAID", value: :paid
                value "CANCELLED", value: :cancelled, deprecated: from, deprecation_reason: "Use `VOID`"
              end
              filter = Class.new(bases[:input]) do
                graphql_name "InvoiceFilter"
                argument :code, String, required: false, deprecated: from, deprecation_reason: "Use `number`"
                argument :number, String, required: false
              end
              priced = Module.new do
                include bases[:interface]
                graphql_name "Priced"
                field :amount, Integer, null: true, deprecated: from, deprecation_reason: "Use `total`"
              end
              invoice = Class.new(bases[:object]) do
                graphql_name "Invoice"
                open.(self)
                implements priced
                field :total, Integer, null: true
                field :tags, [String], null: true, deprecated: from, deprecation_reason: "Use `labels`" do
                  argument :first, Integer, required: false, added: from
                  argument :page, Integer, required: false, removed: from
                end
              end
              lookup = Class.new(bases[:resolver]) do
                graphql_name "Lookup"
                type [String], null: false
                argument :code, String, required: false, deprecated: from, deprecation_reason: "Use `number`"
                argument :number, String, required: false
                define_method(:resolve) { |**arguments| arguments.map { |name, item| "#{name}=#{item}" }.sort }
              end
              Class.new(bases[:object]) do
                graphql_name "Query"
                open.(self)
                field :invoice, invoice, null: false
                field :invoices, [String], null: false do
                  argument :filter, filter, required: false
                  argument :page, Integer, required: false, deprecated: from, deprecation_reason: "Use `cursor`"
                end
                field :lookup, resolver: lookup
                field :find, resolver: lookup, deprecated: from, deprecation_reason: "Use `lookup`"
                field :status, status, null: false
              end
            end
          end

          # The root object for Query.example: `tags` and `invoices` answer their arguments as `name=value` Strings
          # (`filter.key=value` for the filter's fields); `status` answers CANCELLED.
          module Root
            def self.example
              strings = ->(arguments) { arguments.compact.flat_map { |name, item| item.is_a?(Hash) ? item.map { |key, inner| "#{name}.#{key}=#{inner}" } : ["#{name}=#{item}"] } }
              invoice = Class.new do
                define_method(:total) { 100 }
                define_method(:amount) { 100 }
                define_method(:tags) { |first: nil, page: nil| strings.(first: first, page: page) }
              end.new
              Class.new do
                define_method(:invoice) { invoice }
                define_method(:invoices) { |filter: nil, page: nil| strings.(filter: filter&.to_h, page: page) }
                define_method(:status) { :cancelled }
              end.new
            end
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
