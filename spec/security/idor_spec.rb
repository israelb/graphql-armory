# frozen_string_literal: true

# User A tries to read user B's objects by every path a client can use.
# The invariant: it fails, and the response is indistinguishable from asking for an object that does not exist.
RSpec.describe "IDOR: reading another account's objects" do
  %i[null error].each do |mode|
    context "when denials answer #{mode.inspect}" do
      it "fails on a root field that looks an object up by id, like a missing id" do
        foreign = lookup(world.alice, world.b1.id, mode: mode)
        missing = lookup(world.alice, missing_id, mode: mode)

        expect(foreign["data"]).to eq("invoice" => nil)
        expect(foreign).to eq(missing)
      end

      it "fails on a loads: argument, like a missing id" do
        foreign = load_by(world.alice, world.b1.id, mode: mode)
        missing = load_by(world.alice, missing_id, mode: mode)

        expect(foreign["data"]).to eq("invoiceViaRef" => nil)
        expect(foreign).to eq(missing)
      end

      it "fails on a nested association that reaches a foreign object" do
        result = as(world.alice, "{ myAccount { name invoices { number internalNotes } } }", mode: mode,
                                                                                                my_account: world.account_b)

        expect(result["data"]).to eq("myAccount" => nil)
        expect(result.to_s).not_to match(/B-1|secret|"B"/)
      end

      it "fails on an account looked up by id" do
        foreign = as(world.alice, "query($id: ID!) { account(id: $id) { name } }", mode: mode,
                                                                                    variables: { "id" => world.account_b.id.to_s })
        missing = as(world.alice, "query($id: ID!) { account(id: $id) { name } }", mode: mode,
                                                                                    variables: { "id" => missing_id.to_s })

        expect(foreign["data"]).to eq("account" => nil)
        expect(foreign).to eq(missing)
      end
    end
  end

  it "does not let the same id through when it is aliased, repeated or reached by a fragment" do
    query = <<~GRAPHQL
      query($id: ID!) {
        one: invoice(id: $id) { number }
        two: invoice(id: $id) { ...Fields }
        three: invoiceViaRef(invoiceId: $id) { ... on Invoice { number } }
      }
      fragment Fields on Invoice { number internalNotes }
    GRAPHQL

    result = as(world.alice, query, variables: { "id" => world.b1.id.to_s })

    expect(result["data"]).to eq("one" => nil, "two" => nil, "three" => nil)
  end

  it "lets the owner through, so the checks above are not just denying everything" do
    own = lookup(world.alice, world.a1.id)

    expect(own["data"]).to eq("invoice" => { "number" => "A-1", "internalNotes" => nil })
  end

  describe "lists" do
    it "never include another account's objects, whatever the list is" do
      result = as(world.alice, "{ invoices { number } myAccount { allInvoices { number } } }",
                  invoices: Invoice.order(:id).to_a, my_account: world.account_a)

      numbers = [result["data"]["invoices"], result["data"]["myAccount"]["allInvoices"]].map { |list| list.map { |i| i["number"] } }

      expect(numbers).to eq([%w[A-1 A-2], %w[A-1 A-2]])
    end

    it "never include another account's objects in a connection or in its total" do
      result = as(world.alice, "{ invoicesConnection { nodes { number } totalCount } }",
                  invoices_connection: Invoice.order(:id))

      expect(result["data"]["invoicesConnection"]).to eq("nodes" => [{ "number" => "A-1" }, { "number" => "A-2" }], "totalCount" => 2)
    end

    it "are empty for a user who owns nothing" do
      Invoice.where(account_id: world.account_b.id).delete_all
      result = as(world.bob, "{ invoices { number } }", invoices: Invoice.order(:id).to_a)

      expect(result["data"]["invoices"]).to eq([])
    end
  end

  describe "what a denied object reveals" do
    it "never reads the data of an object the user may not see" do
      reads = []
      world.b1.define_singleton_method(:number) { reads << :number; super() }
      world.b1.define_singleton_method(:internal_notes) { reads << :internal_notes; super() }

      as(world.alice, "{ myInvoice { number internalNotes } }", my_invoice: world.b1)

      expect(reads).to eq([])
    end

    it "does not hand a field the user may see on an object they may not" do
      result = as(world.carol, "{ myInvoice { number internalNotes } }", my_invoice: world.b1)

      expect(result["data"]).to eq("myInvoice" => nil)
    end
  end
end
