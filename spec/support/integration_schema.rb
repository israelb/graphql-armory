# frozen_string_literal: true

# Builds a small schema over the dummy app, with the armory integration wired in.
# Fields resolve from the application objects (the root value), so it runs on both engines.
module IntegrationSchema
  Root = Struct.new(:my_invoice, :my_admin_invoice, :my_account, :forgotten, :invoices, :invoices_connection, :ghost, keyword_init: true) do
    def invoice_via_ref(invoice:)
      invoice
    end

    def ping
      "pong"
    end

    def no_rule
      "open?"
    end
  end

  # `flawed: false` leaves out what an audit must report: a type nobody protected, a type without
  # policy, a field with no rule on a bypassed type, and a `loads:` that skips the scope.
  def self.build(adapter: :pundit, on_unauthorized: :null, type_action: :read, sinks: [], plugin: true, flawed: true)
    armory = GraphQL::Armory::Authorization

    base_field = Class.new(GraphQL::Schema::Field) { include armory::Base }
    base_object = Class.new(GraphQL::Schema::Object) do
      include armory::Base
      field_class base_field
      default_action type_action if type_action
    end

    invoice = Class.new(base_object) do
      graphql_name "Invoice"
      field :id, "GraphQL::Types::ID", null: false, authorize: :none, reason: "ids are public"
      field :number, String, null: false
      field :account_id, Integer, null: false, authorize: true
      field :internal_notes, String, authorize: :manage
    end

    account = Class.new(base_object) do
      graphql_name "Account"
      field :name, String, null: false
      field :invoices, [invoice, { null: true }], null: false
      field :all_invoices, [invoice, { null: true }], null: false
    end
    invoice.field :account, account, null: false

    connection = Class.new(GraphQL::Types::Relay::BaseConnection) do
      field :total_count, Integer, null: false, **(ArmoryEngine.supported? ? { resolve_legacy_instance_method: true } : {})

      def total_count
        object.items.size
      end
    end
    invoice.connection_type_class(connection)

    admin_invoice = Class.new(base_object) do
      graphql_name "AdminInvoice"
      authorize :manage, model: Invoice
      field :number, String, null: false
    end

    forgotten = Class.new(GraphQL::Schema::Object) do
      graphql_name "Forgotten"
      field :secret, String, null: false
    end

    ghost = Class.new(base_object) do
      graphql_name "Ghost"
      field :label, String, null: false, authorize: :none, reason: "no policy on purpose"
    end

    query = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root type; each field declares its own rule"
      field :my_invoice, invoice, authorize: :none, reason: "test root field"
      field :my_admin_invoice, admin_invoice, authorize: :none, reason: "test root field"
      field :my_account, account, authorize: :none, reason: "test root field"
      field :account, account, authorize: :none, reason: "looked up through the scope", find_by: :id do
        argument :id, "GraphQL::Types::ID"
      end
      field :invoices, [invoice, { null: true }], null: false, authorize: :none, reason: "test root field"
      if flawed
        field :ghost, ghost, authorize: :none, reason: "test root field"
        field :forgotten, forgotten, authorize: :none, reason: "test root field"
        field :invoice_unscoped, invoice, authorize: :none, reason: "test root field", load_through_scope: false do
          argument :invoice_id, "GraphQL::Types::ID", loads: invoice
        end
        field :no_rule, String, null: false
      end
      field :invoices_connection, invoice.connection_type, null: false, authorize: :none, reason: "test root field"
      field :invoice, invoice, authorize: :none, reason: "looked up through the scope", find_by: :id do
        argument :id, "GraphQL::Types::ID"
      end
      field :invoice_via_ref, invoice, authorize: :none, reason: "loaded through the scope" do
        argument :invoice_id, "GraphQL::Types::ID", loads: invoice
      end
      field :ping, String, null: false, authorize: :none, reason: "health check"
    end

    Class.new(ArmoryEngine.base_schema) do
      query query
      use armory, adapter: adapter, on_unauthorized: on_unauthorized, sinks: sinks if plugin
    end
  end
end
