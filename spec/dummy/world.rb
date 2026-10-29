# frozen_string_literal: true

module Dummy
  # Two accounts that must never see each other's data.
  #   account_a: alice (member), carol (admin), invoices a1 and a2
  #   account_b: bob (member), invoice b1
  World = Struct.new(:account_a, :account_b, :alice, :carol, :bob, :a1, :a2, :b1, keyword_init: true) do
    def self.build
      account_a = Account.create!(name: "A")
      account_b = Account.create!(name: "B")

      new(
        account_a: account_a,
        account_b: account_b,
        alice: User.create!(account: account_a, name: "alice"),
        carol: User.create!(account: account_a, name: "carol", admin: true),
        bob: User.create!(account: account_b, name: "bob"),
        a1: Invoice.create!(account: account_a, number: "A-1", internal_notes: "secret A-1"),
        a2: Invoice.create!(account: account_a, number: "A-2"),
        b1: Invoice.create!(account: account_b, number: "B-1", internal_notes: "secret B-1")
      )
    end
  end
end
