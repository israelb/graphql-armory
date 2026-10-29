# frozen_string_literal: true

# Builds a small schema over the dummy app, with the armory integration wired in.
# Fields resolve from the application objects (the root value), so it runs on both engines.
module IntegrationSchema
  Root = Struct.new(:my_invoice, :my_admin_invoice, :invoices, :ghost, keyword_init: true) do
    def ping
      "pong"
    end

    def no_rule
      "open?"
    end
  end

  def self.build(adapter: :pundit, on_unauthorized: :null, type_action: :read, sinks: [], plugin: true)
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

    admin_invoice = Class.new(base_object) do
      graphql_name "AdminInvoice"
      authorize :manage
      field :number, String, null: false
    end

    ghost = Class.new(base_object) do
      graphql_name "GhostThing"
      field :label, String, null: false, authorize: :none, reason: "no policy on purpose"
    end

    query = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root type; each field declares its own rule"
      field :my_invoice, invoice, authorize: :none, reason: "test root field"
      field :my_admin_invoice, admin_invoice, authorize: :none, reason: "test root field"
      field :invoices, [invoice, { null: true }], null: false, authorize: :none, reason: "test root field"
      field :ghost, ghost, authorize: :none, reason: "test root field"
      field :ping, String, null: false, authorize: :none, reason: "health check"
      field :no_rule, String, null: false
    end

    Class.new(ArmoryEngine.base_schema) do
      query query
      use armory, adapter: adapter, on_unauthorized: on_unauthorized, sinks: sinks if plugin
    end
  end
end
