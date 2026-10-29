# frozen_string_literal: true

RSpec.describe GraphQL::Armory::Authorization::Telemetry do
  it "does nothing without sinks" do
    expect(described_class.new.record(:denied, type: "Invoice")).to be_nil
  end

  it "hands every signal to every sink" do
    seen = []
    telemetry = described_class.new(sinks: [->(signal, data) { seen << [:a, signal, data] },
                                            ->(signal, data) { seen << [:b, signal, data] }])

    telemetry.record(:denied, type: "Invoice")

    expect(seen).to eq([[:a, :denied, { type: "Invoice" }], [:b, :denied, { type: "Invoice" }]])
  end

  it "is built with the sinks it is given" do
    seen = []
    telemetry = described_class.build(sinks: [->(signal, _data) { seen << signal }])

    telemetry.record(:bypassed)

    expect(seen).to eq([:bypassed])
  end

  describe "Substitute" do
    let(:telemetry) { described_class::Substitute.new }

    it "keeps what was recorded" do
      telemetry.record(:denied, type: "Invoice")

      expect(telemetry.recorded).to eq([[:denied, { type: "Invoice" }]])
    end

    it "answers whether a signal was recorded" do
      telemetry.record(:denied, type: "Invoice")

      expect([telemetry.recorded?(:denied), telemetry.recorded?(:allowed)]).to eq([true, false])
    end
  end
end
