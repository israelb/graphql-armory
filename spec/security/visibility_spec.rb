# frozen_string_literal: true

# A type or field hidden with `visible_when:` is absent for users the policy says no to, in introspection
# and in error suggestions. The question is asked of the model's class, so it works with either adapter.
RSpec.describe "Visibility driven by the policy" do
  Reports = Struct.new(:my_invoice, :export)

  let(:world) { Dummy::World.build }

  def schema_for(adapter, visible_when: :export)
    armory = GraphQL::Armory::Authorization
    base_field = Class.new(GraphQL::Schema::Field) { include armory::Base }
    base = Class.new(GraphQL::Schema::Object) do
      include armory::Base
      field_class base_field
      default_action :read
    end
    invoice = Class.new(base) do
      graphql_name "Invoice"
      field :number, String, null: false
      field :internal_notes, String, authorize: :manage, visible_when: visible_when
    end
    export = Class.new(base) do
      graphql_name "InvoiceExport"
      authorize :read, model: Invoice, visible_when: visible_when
      field :number, String, null: false
    end
    query = Class.new(base) do
      graphql_name "Query"
      authorize :none, reason: "root type"
      field :my_invoice, invoice, authorize: :none, reason: "test root field"
      field :export, export, authorize: :none, reason: "test root field"
    end

    Class.new(ArmoryEngine.base_schema) do
      query query
      use armory, adapter: adapter
    end
  end

  def run(schema, user, query)
    execute_query(schema, query, context: { current_user: user }, root_value: Reports.new(world.a1, world.a1))
  end

  %i[pundit cancan].each do |adapter|
    describe "with #{adapter}" do
      let(:schema) { schema_for(adapter) }

      def field_names(user)
        run(schema, user, '{ __type(name: "Invoice") { fields { name } } }').dig("data", "__type", "fields").map { |f| f["name"] }.sort
      end

      it "hides a field from a user who cannot export, and shows it to one who can" do
        expect([field_names(world.alice), field_names(world.carol)]).to eq([%w[number], %w[internalNotes number]])
      end

      it "hides a type, and the root field that returns it" do
        types = ->(user) { run(schema, user, "{ __schema { types { name } } }").dig("data", "__schema", "types").map { |t| t["name"] } }
        roots = ->(user) { run(schema, user, '{ __type(name: "Query") { fields { name } } }').dig("data", "__type", "fields").map { |f| f["name"] } }

        expect([types.(world.alice).include?("InvoiceExport"), types.(world.carol).include?("InvoiceExport"),
                roots.(world.alice).include?("export"), roots.(world.carol).include?("export")]).to eq([false, true, false, true])
      end

      it "does not suggest a hidden field when a name is mistyped" do
        typo = "{ myInvoice { internalNote } }"

        hidden = run(schema, world.alice, typo)["errors"].to_s
        shown = run(schema, world.carol, typo)["errors"].to_s

        expect([hidden.include?("internalNotes"), shown.include?("internalNotes")]).to eq([false, true])
      end

      it "answers a query for a hidden field like one that never existed" do
        hidden = run(schema, world.alice, "{ myInvoice { internalNotes } }")["errors"].map { |e| e["message"].sub("internalNotes", "X") }
        never = run(schema, world.alice, "{ myInvoice { neverExisted } }")["errors"].map { |e| e["message"].sub("neverExisted", "X") }

        expect(hidden).to eq(never)
      end

      it "leaves a schema dump complete when it asks for the full schema" do
        expect(schema.to_definition(context: { armory_full_schema: true })).to include("internalNotes", "InvoiceExport")
      end

      it "is checked by the audit, which flags an action the policy does not define" do
        broken = schema_for(adapter, visible_when: :no_such_action)

        problems = GraphQL::Armory::Authorization::Audit.(broken).problems.select { |p| p.kind == :adapter }

        expect(problems.empty?).to be(adapter == :cancan)
      end
    end
  end

  it "never gives the full schema to a request that does not ask for it, user or not" do
    schema = schema_for(GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: false))

    definition = schema.to_definition(context: {})

    expect([definition.include?("internalNotes"), definition.include?("InvoiceExport")]).to eq([false, false])
  end
end
