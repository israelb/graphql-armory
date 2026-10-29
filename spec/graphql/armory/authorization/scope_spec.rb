# frozen_string_literal: true

RSpec.describe GraphQL::Armory::Authorization::Scope do
  let(:authorization) { GraphQL::Armory::Authorization }
  let(:controls) { authorization::Controls }
  let(:context) { controls::Context.example }
  let(:rule) { controls::Rule.example }
  let(:adapters) { authorization::Adapters }

  it "scopes every list down to nothing when nothing was configured" do
    expect(described_class.new.([1, 2, 3], rule, context)).to eq([])
  end

  it "returns what the adapter lets the actor see" do
    adapter = adapters::Substitute.new(actor: :alice, scoped: ->(items) { items.select(&:odd?) })

    result = described_class.new(adapter: adapter, telemetry: authorization::Telemetry::Substitute.new).([1, 2, 3], rule, context)

    expect(result).to eq([1, 3])
  end

  it "scopes on behalf of the actor of the context" do
    adapter = adapters::Substitute.new(actor: :alice)

    described_class.new(adapter: adapter).([1], rule, context)

    expect(adapter.scoped_for).to eq([[:alice, [1], rule]])
  end

  it "leaves the list alone for a declared bypass" do
    adapter = adapters::Substitute.new
    bypass = authorization::Rule.none(reason: "public data")

    result = described_class.new(adapter: adapter).([1, 2], bypass, context)

    expect([result, adapter.scoped_for]).to eq([[1, 2], []])
  end

  it "lets MissingScopeError reach the caller" do
    adapter = adapters::Substitute.new(raises_on_scope: authorization::MissingScopeError.new("no scope"))

    expect { described_class.new(adapter: adapter).([1], rule, context) }
      .to raise_error(authorization::MissingScopeError, "no scope")
  end

  it "records that a list was scoped" do
    telemetry = authorization::Telemetry::Substitute.new

    described_class.new(adapter: adapters::Substitute.new, telemetry: telemetry).([1], rule, context)

    expect(telemetry.recorded.map(&:first)).to eq([:scoped])
  end

  describe ".call" do
    it "builds with the real wiring and answers" do
      adapter = adapters::Substitute.new(scoped: ->(items) { items.first(1) })

      expect(described_class.([1, 2], rule, context, adapter: adapter)).to eq([1])
    end
  end
end
