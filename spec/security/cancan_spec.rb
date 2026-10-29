# frozen_string_literal: true

# The same guarantees as the Pundit suite, with CanCanCan behind the adapter.
RSpec.describe "Authorization with CanCanCan" do
  let(:world) { Dummy::World.build }

  def ask(user, query, schema: IntegrationSchema.build(adapter: :cancan, flawed: false), variables: {}, **root)
    execute_query(schema, query, variables: variables, context: { current_user: user },
                                 root_value: IntegrationSchema::Root.new(**root))
  end

  it "answers null for an object of another account" do
    result = ask(world.alice, "{ myInvoice { number } }", my_invoice: world.b1)

    expect(result["data"]).to eq("myInvoice" => nil)
  end

  it "answers the object to its owner" do
    result = ask(world.alice, "{ myInvoice { number } }", my_invoice: world.a1)

    expect(result.dig("data", "myInvoice", "number")).to eq("A-1")
  end

  it "never lists an object of another account" do
    result = ask(world.alice, "{ invoices { number } }", invoices: Invoice.order(:id))

    expect(result.dig("data", "invoices").map { |invoice| invoice["number"] }).to eq(%w[A-1 A-2])
  end

  it "looks an object up inside the scope: a foreign id answers like a missing one" do
    query = "query($id: ID!) { invoice(id: $id) { number } }"
    answer = ->(id) { ask(world.alice, query, variables: { "id" => id.to_s }) }

    expect(answer.(world.b1.id)).to eq(answer.(999_999))
  end

  it "loads an argument inside the scope: a foreign id answers like a missing one" do
    query = "query($id: ID!) { invoiceViaRef(invoiceId: $id) { number } }"
    answer = ->(id) { ask(world.alice, query, variables: { "id" => id.to_s }) }

    expect(answer.(world.b1.id)).to eq(answer.(999_999))
  end

  it "asks the ability about a field's action: only an admin reads internalNotes" do
    notes = ->(user) { ask(user, "{ myInvoice { internalNotes } }", my_invoice: world.a1).dig("data", "myInvoice", "internalNotes") }

    expect([notes.(world.alice), notes.(world.carol)]).to eq([nil, "secret A-1"])
  end

  it "denies a type no ability mentions" do
    result = ask(world.alice, "{ myAdminInvoice { number } }", my_admin_invoice: world.a1)

    expect(result["data"]).to eq("myAdminInvoice" => nil)
  end

  describe "a block-only rule" do
    let(:schema) { IntegrationSchema.build(adapter: GraphQL::Armory::Authorization::Adapters::CanCan.new(ability_class: BlockAbility), flawed: false) }

    it "fails a list of a relation instead of guessing" do
      expect { ask(world.alice, "{ invoices { number } }", schema: schema, invoices: Invoice.order(:id)) }
        .to raise_error(GraphQL::Armory::Authorization::MissingScopeError, /in_memory/)
    end

    it "still protects an Array, which is filtered with can?" do
      result = ask(world.alice, "{ invoices { number } }", schema: schema, invoices: [world.a1, world.b1])

      expect(result.dig("data", "invoices").map { |invoice| invoice["number"] }).to eq(%w[A-1])
    end
  end
end
