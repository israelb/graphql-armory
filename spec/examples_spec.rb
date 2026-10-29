# frozen_string_literal: true

require_relative "../examples/invoices"

# The README points here, so the example must keep working.
RSpec.describe "examples/invoices.rb" do
  let(:alice) { InvoicesExample::User.new(id: 1, account_id: 1, admin: false) }
  let(:carol) { InvoicesExample::User.new(id: 3, account_id: 1, admin: true) }

  it "lists only the invoices of the user's account" do
    result = InvoicesExample.run(alice, "{ invoices { number } }")

    expect(result["data"]["invoices"].map { |invoice| invoice["number"] }).to eq(%w[A-1 A-2])
  end

  it "hides a field the user may not manage and shows it to an admin" do
    as_member = InvoicesExample.run(alice)["data"]["invoices"].first
    as_admin = InvoicesExample.run(carol)["data"]["invoices"].first

    expect([as_member["internalNotes"], as_admin["internalNotes"]]).to eq([nil, "pays late"])
  end

  it "has nothing the audit would flag" do
    expect(InvoicesExample.audit).to be_ok
  end
end
