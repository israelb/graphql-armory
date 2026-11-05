# frozen_string_literal: true

require "spec_helper"
require "graphql/armory/caching/codec"

# `Codec` turns an Entry into the String a store keeps and back: plain JSON with `Codec.new`, sealed with the
# encoder (bound to the entry format and the key digest) with `Codec.build(encoder:)`. Anything it cannot give back
# as the entry stored under that key is rejected with a reason, never served.
RSpec.describe GraphQL::Armory::Caching::Codec do
  let(:caching) { GraphQL::Armory::Caching }
  let(:key_digest) { "a" * 64 }
  let(:other_digest) { "b" * 64 }
  let(:encoder) { Class.new(GraphQL::Armory::Encoder) { key("k" * 32) } }
  let(:entry) { entry_for(key_digest) }

  def entry_for(key)
    caching::Entry.new(key: key, data: { "products" => [{ "name" => "Lamp", "price" => "9.99" }] }, stored_at: 5_000, ttl: 60,
                       scope: :public, seq: 3, epoch: "epoch-1", tags: ["c" * 64], cost: 4)
  end

  def rejected(reason, &block)
    expect(&block).to raise_error(caching::Entry::Rejected) { |error| expect(error.reason).to eq(reason) }
  end

  def fields(entry)
    [entry.key, entry.data, entry.stored_at, entry.ttl, entry.scope, entry.seq, entry.epoch, entry.tags, entry.cost]
  end

  describe ".new (plain JSON)" do
    let(:codec) { described_class.new }

    it "writes the entry's JSON and reads it back under the same key" do
      blob = codec.encode(entry, key_digest)

      expect(blob).to eq(entry.to_json_string)
      expect(fields(codec.decode(blob, key_digest))).to eq(fields(entry))
    end

    it "rejects an entry read under another key (:key)" do
      rejected(:key) { codec.decode(codec.encode(entry, key_digest), other_digest) }
    end

    it "rejects what is not an entry of this format (:format)" do
      rejected(:format) { codec.decode(nil, key_digest) }
      rejected(:format) { codec.decode("not json", key_digest) }
      rejected(:format) { codec.decode(entry.to_json_string.sub("\"v\":2", "\"v\":1"), key_digest) }
      rejected(:format) { codec.decode("\xFF\xFE".b, key_digest) }
    end

    it "rejects a sealed entry, which it cannot read (:format)" do
      rejected(:format) { codec.decode(described_class.build(encoder: encoder).encode(entry, key_digest), key_digest) }
    end
  end

  describe ".build(encoder:) (sealed)" do
    let(:codec) { described_class.build(encoder: encoder) }

    it "round-trips the entry under the same key" do
      expect(fields(codec.decode(codec.encode(entry, key_digest), key_digest))).to eq(fields(entry))
    end

    it "hides everything the entry holds" do
      blob = codec.encode(entry, key_digest)

      expect(["Lamp", "9.99", "products", "epoch-1", "c" * 64, key_digest, "\"v\""].select { |text| blob.include?(text) }).to eq([])
    end

    it "rejects the entry under another key (:decrypt), so a moved entry never opens" do
      rejected(:decrypt) { codec.decode(codec.encode(entry, key_digest), other_digest) }
    end

    it "rejects a plain JSON entry, as someone with write access to the store could forge (:decrypt)" do
      rejected(:decrypt) { codec.decode(entry.to_json_string, key_digest) }
    end

    it "rejects an entry sealed with another key or tag, or tampered with (:decrypt)" do
      blob = codec.encode(entry, key_digest)

      rejected(:decrypt) { described_class.build(encoder: Class.new(GraphQL::Armory::Encoder) { key("j" * 32) }).decode(blob, key_digest) }
      rejected(:decrypt) { described_class.build(encoder: Class.new(encoder) { tag("other") }).decode(blob, key_digest) }
      rejected(:decrypt) { codec.decode(blob.dup.tap { |copy| copy[30] = copy[30] == "A" ? "B" : "A" }, key_digest) }
      rejected(:decrypt) { codec.decode(blob[0, 20], key_digest) }
      rejected(:format) { codec.decode(nil, key_digest) }
    end

    it "rejects sealed bytes that are not an entry of this format (:format)" do
      aad = described_class.additional_data(key_digest)

      rejected(:format) { codec.decode(encoder.seal("not json", aad: aad, purpose: "cache"), key_digest) }
      rejected(:format) { codec.decode(encoder.seal(entry.to_json_string.sub("\"v\":2", "\"v\":1"), aad: aad, purpose: "cache"), key_digest) }
    end

    it "rejects an entry sealed under its key but naming another key inside (:key)" do
      foreign = entry_for(other_digest).to_json_string

      rejected(:key) { codec.decode(encoder.seal(foreign, aad: described_class.additional_data(key_digest), purpose: "cache"), key_digest) }
    end

    it "seals under the purpose `cache`, bound to the entry format and the key digest" do
      substitute = GraphQL::Armory::Encoder::Substitute.new
      sealing = described_class.build(encoder: substitute)
      substitute.sealed.clear
      sealing.encode(entry, key_digest)

      expect(substitute.sealed.map { |call| call[:purpose] }).to eq(["cache"])
      expect(substitute.sealed.first[:aad]).to eq(described_class.additional_data(key_digest))
      expect(described_class.additional_data(key_digest)).to include(key_digest, "/#{caching::Entry::FORMAT}")
    end

    it "opens entries sealed before a key rotation through a versioned chain, and seals new ones with the newest key" do
      newest = Class.new(GraphQL::Armory::Encoder) { key("n" * 32) }
      before = codec.encode(entry, key_digest)
      rotated = described_class.build(encoder: GraphQL::Armory::Encoder.versioned(newest, encoder))

      expect(fields(rotated.decode(before, key_digest))).to eq(fields(entry))
      expect(fields(described_class.build(encoder: newest).decode(rotated.encode(entry, key_digest), key_digest))).to eq(fields(entry))
    end

    it "answers :decrypt when the encoder fails while opening, and lets its configuration errors through" do
      substitute = GraphQL::Armory::Encoder::Substitute.new
      sealing = described_class.build(encoder: substitute)
      blob = sealing.encode(entry, key_digest)
      substitute.fail_with(IOError.new("boom"))
      rejected(:decrypt) { sealing.decode(blob, key_digest) }

      substitute.fail_with(GraphQL::Armory::Encoder::ConfigurationError.new("no key"))
      expect { sealing.decode(blob, key_digest) }.to raise_error(GraphQL::Armory::Encoder::ConfigurationError)
    end
  end

  describe "refusals at build and at encode" do
    it "refuses an encoder that cannot seal, at build" do
      [GraphQL::Armory::Encoder::Null, GraphQL::Armory::Encoder::Legacy, Class.new(GraphQL::Armory::Encoder), Object.new,
       GraphQL::Armory::Encoder.versioned(GraphQL::Armory::Encoder::Legacy, encoder)].each do |unfit|
        expect { described_class.build(encoder: unfit) }.to raise_error(caching::ConfigurationError, /encoder/)
      end
    end

    it "refuses to encode something that is not an Entry, or an entry under a key that is not its own" do
      codec = described_class.new

      expect { codec.encode({ "data" => {} }, key_digest) }.to raise_error(ArgumentError, /Entry/)
      expect { codec.encode(entry, other_digest) }.to raise_error(ArgumentError, /key/)
      expect { codec.decode(entry.to_json_string, "short") }.to raise_error(ArgumentError, /key/)
    end
  end
end
