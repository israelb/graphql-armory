# frozen_string_literal: true

require "spec_helper"
require "graphql/armory/caching/memory_store"

RSpec.describe GraphQL::Armory::Caching::MemoryStore do
  let(:now) { [1_000_000] }
  let(:clock) { -> { now[0] } }
  let(:travel) { ->(ms) { now[0] += ms } }
  let(:store) { described_class.new(max_bytes: 4_096, clock: clock, max_ttl: 1) }

  def hex = SecureRandom.hex(32)

  def store_after_lookup(store, key, blob: "blob", tags: [], ttl: 1)
    lookup = store.lookup(key)
    store.write(key, blob, tags: tags, ttl: ttl, seq: lookup.seq, epoch: lookup.epoch, stored_at: lookup.now)
  end

  it_behaves_like "a caching store", prunes: true

  describe "settings" do
    it "is useful from new: a process-local store on a monotonic clock in Integer milliseconds" do
      store = described_class.new
      key = hex
      store_after_lookup(store, key, ttl: 60)

      expect(store.lookup(key)).to have_attributes(blob: "blob", now: an_instance_of(Integer))
      expect([store.max_bytes, store.max_ttl]).to eq([described_class::DEFAULT_MAX_BYTES, 3600])
    end

    it "refuses settings it cannot use" do
      invalid = [{ max_bytes: 0 }, { max_bytes: 1.5 }, { max_ttl: 0 }, { max_ttl: "60" }, { clock: 5 }]

      invalid.each do |settings|
        expect { described_class.new(**settings) }.to raise_error(GraphQL::Armory::Caching::ConfigurationError)
      end
    end

    it "refuses a clock that does not answer Integer milliseconds" do
      store = described_class.new(clock: -> { 1.5 })

      expect { store.lookup(hex) }.to raise_error(GraphQL::Armory::Caching::ConfigurationError, /Integer milliseconds/)
    end
  end

  describe "#write arguments" do
    it "refuses a TTL above max_ttl, since marks are pruned once older than max_ttl" do
      lookup = store.lookup(hex)

      expect { store.write(hex, "blob", tags: [], ttl: 2, seq: lookup.seq, epoch: lookup.epoch, stored_at: lookup.now) }
        .to raise_error(ArgumentError, /max_ttl/)
    end

    it "refuses arguments the gate never sends" do
      lookup = store.lookup(hex)
      valid = { tags: [], ttl: 1, seq: lookup.seq, epoch: lookup.epoch, stored_at: lookup.now }

      [{ tags: "a" }, { tags: [1] }, { ttl: 0 }, { seq: -1 }, { epoch: "" }, { stored_at: 1.5 }].each do |bad|
        expect { store.write(hex, "blob", **valid, **bad) }.to raise_error(ArgumentError)
      end
      expect { store.write(:key, "blob", **valid) }.to raise_error(ArgumentError)
      expect { store.write(hex, nil, **valid) }.to raise_error(ArgumentError)
      expect { store.purge("tag") }.to raise_error(ArgumentError)
    end
  end

  describe "least recently used eviction" do
    # Each entry holds a 64-byte key and a 960-byte blob: four fit in 4096 bytes.
    let(:keys) { Array.new(5) { hex } }

    it "evicts the least recently used entries once it holds more than max_bytes" do
      keys.first(4).each { |key| store_after_lookup(store, key, blob: "x" * 960) }
      store.lookup(keys[0])
      store_after_lookup(store, keys[4], blob: "x" * 960)

      expect(keys.map { |key| store.lookup(key).found? }).to eq([true, false, true, true, true])
    end

    it "never evicts the meta record: epoch, seq and marks outlive any number of entries" do
      early = store.lookup(hex)
      store.purge([tag = hex])
      epoch = store.lookup(hex).epoch
      50.times { store_after_lookup(store, hex, blob: "x" * 960, tags: [tag]) }

      expect(store.lookup(hex)).to have_attributes(seq: 1, epoch: epoch)
      expect(store.write(hex, "blob", tags: [tag], ttl: 1, seq: early.seq, epoch: early.epoch, stored_at: early.now)).to be(false)
    end

    it "does not store an entry larger than max_bytes, and evicts nothing for it" do
      store_after_lookup(store, keys[0])

      expect(store_after_lookup(store, keys[1], blob: "x" * 4_096)).to be(false)
      expect(keys.first(2).map { |key| store.lookup(key).found? }).to eq([true, false])
    end
  end

  describe "pruning marks" do
    # Room for one entry carrying 150 tag digests.
    let(:store) { described_class.new(clock: clock, max_ttl: 1) }

    it "prunes at most 100 marks per purge, once they are older than max_ttl" do
      tags = Array.new(150) { hex }
      store.purge(tags)
      travel.call(600)
      key = hex
      store_after_lookup(store, key, tags: tags)
      travel.call(500)

      store.purge([hex])
      after_one = store.lookup(key).marks.size
      store.purge([hex])

      expect([after_one, store.lookup(key).marks.size]).to eq([50, 0])
    end
  end

  it "keeps purges atomic across threads: every purge answers its own seq" do
    seqs = Array.new(8) { Thread.new { Array.new(25) { store.purge([hex]) } } }.flat_map(&:value)

    expect(seqs.sort).to eq((1..200).to_a)
  end
end
