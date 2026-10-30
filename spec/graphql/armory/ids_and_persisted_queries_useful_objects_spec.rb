# frozen_string_literal: true

require "digest"

# Encrypted IDs and persisted queries as Useful Objects: an inert `new` that refuses, `build` that wires the real
# dependencies, `call` as the actuator, and a Null and a Substitute for each dependency in lib/.
RSpec.describe "encrypted IDs and persisted queries as useful objects" do
  let(:armory) { GraphQL::Armory }

  describe GraphQL::Armory::Encoder::Null do
    it "hands out no ID and honours none" do
      expect { armory::Encoder::Null.encode("Invoice/1") }.to raise_error(armory::Encoder::ConfigurationError, /no encoder/)
      expect { armory::Encoder::Null.decode("anything") }.to raise_error(armory::Encoder::InvalidError)
    end
  end

  describe GraphQL::Armory::Encoder::Substitute do
    let(:encoder) { armory::Encoder::Substitute.new }

    it "encodes reversibly without a key and records what it encoded and decoded" do
      id = encoder.encode("Invoice/1")

      expect(encoder.decode(id)).to eq("Invoice/1")
      expect([encoder.encoded, encoder.decoded]).to eq([["Invoice/1"], [id]])
    end

    it "refuses an ID it did not hand out" do
      expect { encoder.decode("forged") }.to raise_error(armory::Encoder::InvalidError)
    end
  end

  describe GraphQL::Armory::IDs::Lookup do
    let(:type) { Struct.new(:graphql_name).new("Invoice") }

    it "is inert with new: it hands out no ID and honours none" do
      lookup = armory::IDs::Lookup.new

      expect { lookup.id_for(armory::IDs::Controls::Record.example, type) }.to raise_error(armory::Encoder::ConfigurationError)
      expect(lookup.object_for("anything", nil)).to be_nil
    end

    it "encodes through the encoder build wires" do
      encoder = armory::Encoder::Substitute.new
      lookup = armory::IDs::Lookup.build(encoder: encoder)

      lookup.id_for(armory::IDs::Controls::Record.example(id: 7), type)

      expect(encoder.encoded).to eq(["Invoice/7"])
    end

    it "checks its settings in new" do
      expect { armory::IDs::Lookup.new(encoder: Object.new) }.to raise_error(armory::Encoder::ConfigurationError, /encoder/)
      expect { armory::IDs::Lookup.new(find: "Invoice") }.to raise_error(armory::Encoder::ConfigurationError, /find/)
    end

    it "has an example encoder with a test key" do
      encoder = armory::IDs::Controls::Encoder.example

      expect(encoder.decode(encoder.encode("Invoice/1"))).to eq("Invoice/1")
    end
  end

  describe GraphQL::Armory::PersistedQueries::Gate do
    let(:invoices) { armory::PersistedQueries::Controls::Operations.invoices }

    it "is inert with new: it refuses every request, with an id or a raw query" do
      gate = armory::PersistedQueries::Gate.new

      expect(gate.({ operation_id: "abc" }, nil, nil).first).to eq(armory::PersistedQueries::UNKNOWN_OPERATION)
      expect(gate.({}, invoices, nil).first).to eq(armory::PersistedQueries::RAW_QUERY_REFUSED)
    end

    it "answers the stored document for a known id, and records the lookup in the store" do
      store = armory::PersistedQueries::Store::Substitute.new(invoices)
      gate = armory::PersistedQueries::Gate.build(store: store)
      id = Digest::SHA256.hexdigest(invoices)

      refusal, document = gate.({ operation_id: id }, nil, nil)

      expect([refusal, document.to_query_string, store.fetched]).to eq([nil, GraphQL.parse(invoices).to_query_string, [id]])
    end

    it "lets a raw query through when not strict, and refuses a mismatch" do
      gate = armory::PersistedQueries::Gate.build(store: armory::PersistedQueries::Store::Substitute.new(invoices))

      expect(gate.({}, "{ secret }", nil)).to eq([nil, nil])
      expect(gate.({ operation_id: Digest::SHA256.hexdigest(invoices) }, "{ secret }", nil).first).to eq(armory::PersistedQueries::MISMATCH)
    end

    it "checks its settings in new" do
      expect { armory::PersistedQueries::Gate.new(store: {}) }.to raise_error(armory::PersistedQueries::ConfigurationError, /store/)
      expect { armory::PersistedQueries::Gate.new(strict: "yes") }.to raise_error(armory::PersistedQueries::ConfigurationError, /strict/)
      expect { armory::PersistedQueries::Gate.new(strict: false) }.to raise_error(armory::PersistedQueries::ConfigurationError, /store/)
    end
  end

  describe GraphQL::Armory::PersistedQueries::Store::Null do
    it "holds no operation" do
      expect(armory::PersistedQueries::Store::Null.new.fetch("abc")).to be_nil
    end
  end
end
