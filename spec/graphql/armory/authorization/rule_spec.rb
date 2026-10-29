# frozen_string_literal: true

RSpec.describe GraphQL::Armory::Authorization::Rule do
  let(:rule_class) { described_class }

  it "holds what was declared" do
    rule = rule_class.new(:read, policy: :InvoicePolicy, attribute: :notes)

    expect([rule.action, rule.policy, rule.attribute]).to eq([:read, :InvoicePolicy, :notes])
    expect(rule).not_to be_none
  end

  it "is immutable" do
    expect(rule_class.new(:read)).to be_frozen
  end

  it "is equal to another rule with the same declaration" do
    a = rule_class.new(:read, policy: :P)
    b = rule_class.new(:read, policy: :P)

    expect([a == b, a.eql?(b), a.hash == b.hash]).to eq([true, true, true])
    expect(a).not_to eq(rule_class.new(:manage, policy: :P))
  end

  it "needs an action" do
    expect { rule_class.new(nil) }.to raise_error(ArgumentError, /action/)
  end

  describe "a declared bypass" do
    it "is none and carries its reason" do
      rule = rule_class.none(reason: "public marketing data")

      expect(rule).to be_none
      expect(rule.reason).to eq("public marketing data")
    end

    it "refuses to exist without a reason" do
      expect { rule_class.none(reason: " ") }.to raise_error(ArgumentError, /reason/)
    end
  end

  it "has a control example" do
    expect(GraphQL::Armory::Authorization::Controls::Rule.example).to be_a(rule_class)
  end
end
