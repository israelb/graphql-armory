# frozen_string_literal: true

RSpec.describe GraphQL::Armory::Authorization::Adapters::Null do
  let(:adapter) { described_class.new }
  let(:controls) { GraphQL::Armory::Authorization::Controls }

  it "has no actor" do
    expect(adapter.actor(controls::Context.example)).to be_nil
  end

  it "denies everything" do
    expect(adapter.authorized?(controls::Actor.example, controls::Subject.example, controls::Rule.example)).to be(false)
  end

  it "scopes every list down to nothing" do
    expect(adapter.scope(controls::Actor.example, [1, 2, 3], controls::Rule.example)).to eq([])
  end

  it "reports that it is not a real adapter" do
    expect(adapter.check("Invoice", controls::Rule.example)).to eq(["no adapter is configured: everything is denied"])
  end
end
