# frozen_string_literal: true

require "spec_helper"
require "graphql/armory/caching/codec"

# G6: whoever can read or write the cache store can neither read an entry nor make the app serve one it did not
# store under that key. Entries go through a real store round trip (`Store::Substitute`), then the attacker edits the
# store, and the next read must reject the entry (the query runs instead).
RSpec.describe "Response cache entry integrity" do
  let(:caching) { GraphQL::Armory::Caching }
  let(:encoder) { Class.new(GraphQL::Armory::Encoder) { key("k" * 32) } }
  let(:digester) { caching::Digester.build(encoder: encoder) }
  let(:alice_key) { digester.("[\"armory-cache/2\",\"viewer\",[\"User\",7]]") }
  let(:bob_key) { digester.("[\"armory-cache/2\",\"viewer\",[\"User\",8]]") }
  let(:viewer_tag) { digester.(caching::Tags.viewer("User", 7)) }
  let(:store) { caching::Controls::Store.example }
  let(:sealed) { caching::Codec.build(encoder: encoder) }
  let(:plain) { caching::Codec.new }

  def entry_for(key, data: { "me" => { "email" => "alice@example.com", "balance" => "1200.50" } })
    lookup = store.lookup(key)
    caching::Entry.new(key: key, data: data, stored_at: lookup.now, ttl: 60, scope: :viewer, seq: lookup.seq, epoch: lookup.epoch,
                       tags: [viewer_tag], cost: 2)
  end

  def write(codec, key, entry = entry_for(key))
    expect(store.write(key, codec.encode(entry, key), tags: entry.tags, ttl: entry.ttl, seq: entry.seq, epoch: entry.epoch,
                                                      stored_at: entry.stored_at)).to be(true)
  end

  def read(codec, key)
    codec.decode(store.lookup(key).blob, key)
  end

  def rejected(reason, &block)
    expect(&block).to raise_error(caching::Entry::Rejected) { |error| expect(error.reason).to eq(reason) }
  end

  it "serves the entry back from the store under the key it was written with" do
    write(sealed, alice_key)

    expect(read(sealed, alice_key).data).to eq("me" => { "email" => "alice@example.com", "balance" => "1200.50" })
  end

  it "rejects Alice's entry copied under Bob's key: sealed (:decrypt) and plain (:key)" do
    [[sealed, :decrypt], [plain, :key]].each do |codec, reason|
      write(codec, alice_key)
      store.poison(bob_key, store.blobs.fetch(alice_key), tags: [viewer_tag])

      rejected(reason) { read(codec, bob_key) }
    end
  end

  it "rejects an entry forged in clear by someone who can write the store, even one naming the right key" do
    store.poison(bob_key, entry_for(bob_key, data: { "me" => { "email" => "attacker@example.com" } }).to_json_string)

    rejected(:decrypt) { read(sealed, bob_key) }
  end

  it "rejects a sealed entry edited in the store" do
    write(sealed, alice_key)
    blob = store.blobs.fetch(alice_key)
    store.poison(alice_key, blob.dup.tap { |copy| copy[blob.length / 2] = copy[blob.length / 2] == "A" ? "B" : "A" }, tags: [viewer_tag])

    rejected(:decrypt) { read(sealed, alice_key) }
  end

  it "rejects an entry another app sealed with its own key or tag" do
    other_key = caching::Codec.build(encoder: Class.new(GraphQL::Armory::Encoder) { key("o" * 32) })
    other_tag = caching::Codec.build(encoder: Class.new(encoder) { tag("staging") })

    [other_key, other_tag].each do |foreign|
      write(foreign, alice_key)

      rejected(:decrypt) { read(sealed, alice_key) }
    end
  end

  it "rejects a non-JSON value, a truncated value and an empty value" do
    ["\x04\bo:\vObject\x00".b, "{\"v\":2", ""].each do |junk|
      store.poison(alice_key, junk)

      rejected(:decrypt) { read(sealed, alice_key) }
      rejected(:format) { read(plain, alice_key) }
    end
  end

  it "keeps the store blind: no data, epoch, tag or key digest in the stored value, and no viewer in the key" do
    write(sealed, alice_key)
    blob = store.blobs.fetch(alice_key)

    expect(["alice", "1200.50", "email", store.epoch, viewer_tag, alice_key].select { |text| blob.include?(text) }).to eq([])
    expect(store.blobs.keys.join).not_to include("User")
  end

  it "never accepts a sealed entry as an ID or cursor, nor an ID as an entry" do
    write(sealed, alice_key)
    blob = store.blobs.fetch(alice_key)

    expect { encoder.decode(blob) }.to raise_error(GraphQL::Armory::Encoder::InvalidError)
    expect { encoder.decode(blob, nonce: true) }.to raise_error(GraphQL::Armory::Encoder::InvalidError)
    store.poison(alice_key, encoder.encode(entry_for(alice_key).to_json_string, nonce: true))
    rejected(:decrypt) { read(sealed, alice_key) }
  end
end
