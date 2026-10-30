# frozen_string_literal: true

require "base64"

# `use GraphQL::Armory::IDs` gives a schema encrypted global IDs in one line. Every ID that cannot be honoured —
# tampered, of an unknown type, of another model, out of the user's scope — answers exactly like a missing one.
RSpec.describe "use GraphQL::Armory::IDs" do
  let(:world) { Dummy::World.build }
  let(:encoder) { GraphQL::Armory::IDs::Controls::Encoder.example }

  def schema_for(adapter, encoder:, find: nil, plain_account: false)
    armory = GraphQL::Armory
    base_argument = Class.new(GraphQL::Schema::Argument) { include armory::Authorization::Base }
    base_field = Class.new(GraphQL::Schema::Field) do
      include armory::Authorization::Base
      argument_class base_argument
    end
    base_object = Class.new(GraphQL::Schema::Object) do
      include armory::Authorization::Base
      field_class base_field
      default_action :read
    end
    invoice = Class.new(base_object) do
      graphql_name "Invoice"
      implements GraphQL::Types::Relay::Node
      field :number, String, null: false
    end
    account = Class.new(plain_account ? GraphQL::Schema::Object : base_object) do
      graphql_name "Account"
      implements GraphQL::Types::Relay::Node
      field :name, String, null: false
    end
    node_lookup = Class.new(GraphQL::Schema::Resolver) do
      include armory::Authorization::Base
      authorize :none, reason: "looks the node up by its encrypted ID"
      type GraphQL::Types::Relay::Node, null: true
      argument :id, GraphQL::Types::ID

      def resolve(id:)
        context.schema.object_from_id(id, context)
      end
    end
    query = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root type; each field declares its own rule"
      field :node, resolver: node_lookup
      field :invoice_by_ref, invoice, authorize: :none, reason: "loads through the scope" do
        argument :invoice_id, GraphQL::Types::ID, loads: invoice
      end
      field :invoices, [invoice], null: false, authorize: :none, reason: "scoped"
    end
    # Hidden from non-admins: an ID naming it must answer like a missing one for them.
    invoice_export = Class.new(base_object) do
      graphql_name "InvoiceExport"
      authorize :read, model: Invoice, visible_when: :export
      implements GraphQL::Types::Relay::Node
      field :number, String, null: false
    end
    types = { invoice => Invoice, account => Account }
    Class.new(ArmoryEngine.base_schema) do
      query query
      orphan_types invoice, account, invoice_export
      use armory::Authorization, adapter: adapter
      use armory::IDs, encoder: encoder, **(find ? { find: find } : {})
      define_singleton_method(:resolve_type) { |_abstract, obj, _ctx| types.find { |_type, model| obj.is_a?(model) }&.first }
    end
  end

  let(:root) do
    Class.new do
      def initialize(invoices) = @invoices = invoices
      def invoices = @invoices
      def invoice_by_ref(invoice:) = invoice
    end.new(Invoice.all)
  end

  %i[pundit cancan].each do |adapter|
    context "with #{adapter}" do
      let(:schema) { schema_for(adapter, encoder: encoder) }

      def run(schema, query, user, variables = {})
        execute_query(schema, query, variables: variables, context: { current_user: user }, root_value: root).to_h
      end

      def node(schema, id, user)
        run(schema, "query($id: ID!) { node(id: $id) { ... on Invoice { number } } }", user, { "id" => id })
      end

      it "hands out encrypted IDs that load the user's own record back" do
        id = run(schema, "{ invoices { id } }", world.alice).dig("data", "invoices", 0, "id")
        id = run(schema, "{ invoices { id } }", world.alice).dig("data", "invoices", 0, "id")
        expect([encoder.decode(id), node(schema, id, world.alice)]).to eq(["Invoice/#{world.a1.id}", { "data" => { "node" => { "number" => "A-1" } } }])
      end

      it "answers every ID it cannot honour exactly like a missing one" do
        missing = node(schema, encoder.encode("Invoice/0"), world.alice)
        refused = [
          encoder.encode("Invoice/#{world.b1.id}"),           # another tenant's record
          encoder.encode("Invoice/#{world.a1.id}").reverse,   # tampered
          encoder.encode("Ghost/1"),                          # a type the schema does not have
          encoder.encode("Node/#{world.a1.id}"),              # not an object type
          encoder.encode("String/1"),
          encoder.encode("Query/1"),                          # an object type that never had IDs, whose model cannot be told
          encoder.encode("__Type/1"),
          encoder.encode("InvoiceExport/#{world.a1.id}"),     # a type hidden from this user
          encoder.encode("no-separator"),
          GraphQL::Armory::IDs::Controls::Encoder.example(key: "x" * 32).encode("Invoice/#{world.a1.id}")
        ]

        expect(refused.map { |id| node(schema, id, world.alice) }).to all(eq(missing))
        expect(missing).to eq("data" => { "node" => nil })
      end

      it "does not let a forged legacy ID name a root type when Legacy is in the chain" do
        chain = GraphQL::Armory::Encoder.versioned(encoder, GraphQL::Armory::Encoder::Legacy)
        legacy_schema = schema_for(adapter, encoder: chain)

        expect(node(legacy_schema, Base64.urlsafe_encode64("Query/1", padding: false), world.alice)).to eq("data" => { "node" => nil })
      end

      it "still honours a hidden type's ID for a user who may see it" do
        id = encoder.encode("InvoiceExport/#{world.a1.id}")
        result = run(schema, "query($id: ID!) { node(id: $id) { __typename } }", world.carol, { "id" => id })

        expect(result.dig("data", "node")).not_to be_nil
      end

      it "refuses an ID of another model in loads:, like a missing one" do
        lookup = ->(id) { run(schema, "query($id: ID!) { invoiceByRef(invoiceId: $id) { number } }", world.alice, { "id" => id }) }

        expect([lookup.(encoder.encode("Account/#{world.a1.id}")), lookup.(encoder.encode("Invoice/#{world.a1.id}"))])
          .to eq([lookup.(encoder.encode("Invoice/0")), { "data" => { "invoiceByRef" => { "number" => "A-1" } } }])
      end
    end
  end

  it "uses the default encoder when none is given, and fails at boot without a key" do
    armory = GraphQL::Armory
    expect { Class.new(GraphQL::Schema) { use armory::IDs, encoder: nil } }.to raise_error(armory::Encoder::ConfigurationError, /GRAPHQL_ARMORY_KEY/)
  end

  it "loads types without the authorization module through find:, and refuses them without it" do
    # Only Node types reach find:, so a naive lookup never sees Query or __Type.
    find = ->(type, key, _context) { Object.const_get(type.graphql_name).find_by(id: key) }
    query = "query($id: ID!) { node(id: $id) { ... on Account { name } } }"
    id = encoder.encode("Account/#{world.account_a.id}")
    run = ->(schema) { execute_query(schema, query, variables: { "id" => id }, context: { current_user: world.alice }, root_value: root).to_h }

    expect([run.(schema_for(:pundit, encoder: encoder, find: find, plain_account: true)), run.(schema_for(:pundit, encoder: encoder, plain_account: true))])
      .to eq([{ "data" => { "node" => { "name" => "A" } } }, { "data" => { "node" => nil } }])
  end
end
