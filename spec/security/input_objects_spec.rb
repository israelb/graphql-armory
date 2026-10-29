# frozen_string_literal: true

# A `loads:` argument inside an input object is loaded by the input object class, not by the field.
# With `include Base` in the base input object, it goes through the user's scope like any other `loads:`.
RSpec.describe "loads: inside input objects" do
  let(:world) { Dummy::World.build }

  def schema_for(adapter, scoped: true, on_unauthorized: :null)
    armory = GraphQL::Armory::Authorization
    base_field = Class.new(GraphQL::Schema::Field) { include armory::Base }
    base_object = Class.new(GraphQL::Schema::Object) do
      include armory::Base
      field_class base_field
      default_action :read
    end
    base_input = Class.new(GraphQL::Schema::InputObject)
    base_input.include(armory::Base) if scoped
    invoice = Class.new(base_object) do
      graphql_name "Invoice"
      field :number, String, null: false
    end
    filter = Class.new(base_input) do
      graphql_name "InvoiceFilter"
      argument :invoice_id, GraphQL::Types::ID, loads: invoice
    end
    query = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root type; each field declares its own rule"
      field :invoice_by_filter, invoice, authorize: :none, reason: "loads through the scope" do
        argument :filter, filter
      end
    end
    Class.new(ArmoryEngine.base_schema) do
      query query
      use armory, adapter: adapter, on_unauthorized: on_unauthorized
    end
  end

  let(:root) do
    Class.new do
      def invoice_by_filter(filter:)
        filter[:invoice]
      end
    end.new
  end

  def lookup(schema, id, user)
    execute_query(schema, "query($id: ID!) { invoiceByFilter(filter: { invoiceId: $id }) { number } }",
                  variables: { "id" => id }, context: { current_user: user }, root_value: root)
  end

  %i[pundit cancan].each do |adapter|
    context "with #{adapter}" do
      it "loads the user's own record" do
        result = lookup(schema_for(adapter), world.a1.id.to_s, world.alice)

        expect(result.to_h).to eq("data" => { "invoiceByFilter" => { "number" => "A-1" } })
      end

      %i[null error].each do |mode|
        it "answers a foreign id exactly like a missing one (on_unauthorized: :#{mode})" do
          schema = schema_for(adapter, on_unauthorized: mode)
          foreign = lookup(schema, world.b1.id.to_s, world.alice)
          missing = lookup(schema, "0", world.alice)

          expect([foreign.to_h, foreign.to_h["data"]&.fetch("invoiceByFilter")]).to eq([missing.to_h, nil])
        end
      end
    end
  end

  it "reports in the audit an input object whose loads skip the scope" do
    schema = schema_for(:pundit, scoped: false)
    problems = GraphQL::Armory::Authorization::Audit.build(schema).call(schema).problems

    expect(problems.map { |p| [p.kind, p.path] }).to include([:unscoped_load, "InvoiceFilter(invoice_id)"])
  end

  it "reports nothing for an input object that includes Base" do
    schema = schema_for(:pundit)
    problems = GraphQL::Armory::Authorization::Audit.build(schema).call(schema).problems

    expect(problems).to eq([])
  end
end
