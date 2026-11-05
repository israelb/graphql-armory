# frozen_string_literal: true

require "spec_helper"
require "redis"
require "securerandom"
require "graphql/armory/caching/memory_store"
require "graphql/armory/caching/redis_store"

# G5: a purge is never undone by a run that started before it, a store reset counts as a purge of everything, and a
# failed purge raises. Each example plays a run as the gate does: a lookup, the run, then a write stamped with the
# lookup's seq, epoch and clock. "Rejected" means what the gate sees on a read: a mark above the entry's seq, an epoch
# that is not the entry's, or a seq below the entry's.
RSpec.describe "response cache purge sequence" do
  def hex = SecureRandom.hex(32)

  def write(store, lookup, key, tags:, ttl: 1)
    store.write(key, "blob", tags: tags, ttl: ttl, seq: lookup.seq, epoch: lookup.epoch, stored_at: lookup.now)
  end

  def rejected_on_read?(found, written_with)
    found.epoch != written_with.epoch || found.seq < written_with.seq || found.marks.values.any? { |mark| mark > written_with.seq }
  end

  # The including group defines `store` and `other_process` (a second store on the same state, max_ttl 1 both) and
  # `travel` (milliseconds).
  shared_examples "a purge sequence nobody can undo" do
    it "refuses the write of a run whose lookup came before a purge from another process" do
      lookup = store.lookup(key = hex)
      other_process.purge([tag = hex])

      expect(write(store, lookup, key, tags: [tag])).to be(false)
      expect(store.lookup(key)).not_to be_found
    end

    it "rejects on read an entry written just before a purge from another process" do
      lookup = store.lookup(key = hex)
      write(store, lookup, key, tags: [tag = hex])
      other_process.purge([tag])

      expect(rejected_on_read?(store.lookup(key), lookup)).to be(true)
    end

    it "keeps every purge's seq distinct when processes purge at once" do
      seqs = [store, other_process].flat_map { |each| Array.new(4) { Thread.new { Array.new(5) { each.purge([hex]) } } } }.flat_map(&:value)

      expect(seqs.sort).to eq((1..40).to_a)
    end

    it "never lets a pruned mark undo its purge: the run's write is expired by then" do
      lookup = store.lookup(key = hex)
      other_process.purge([tag = hex])
      travel.call(1_100)
      other_process.purge([hex])

      expect(write(store, lookup, key, tags: [tag])).to be(false)
    end

    it "refuses a TTL longer than the time marks are kept" do
      lookup = store.lookup(hex)

      expect { write(store, lookup, hex, tags: [], ttl: store.max_ttl + 1) }.to raise_error(ArgumentError, /max_ttl/)
    end

    it "makes purge_all from another process reject everything written before it" do
      lookup = store.lookup(key = hex)
      write(store, lookup, key, tags: [])
      other_process.purge_all

      expect(rejected_on_read?(store.lookup(key), lookup)).to be(true)
      expect(write(store, lookup, hex, tags: [])).to be(false)
    end
  end

  describe GraphQL::Armory::Caching::Store::Substitute do
    let(:store) { described_class.new }
    let(:travel) { ->(ms) { store.now += ms } }
    let(:lose_meta) { -> { store.reset! } }
    let(:rewind_seq) { ->(seq) { store.rewind_seq(seq) } }

    # The reference every unit's specs run against keeps the same contract as the real stores.
    it_behaves_like "a caching store", meta_loss: true
  end

  describe GraphQL::Armory::Caching::MemoryStore do
    let(:now) { [5_000_000] }
    let(:store) { described_class.new(clock: -> { now[0] }, max_ttl: 1) }
    # One process: the other process is the same store, as threads of one server share it.
    let(:other_process) { store }
    let(:travel) { ->(ms) { now[0] += ms } }

    it_behaves_like "a purge sequence nobody can undo"
  end

  describe GraphQL::Armory::Caching::RedisStore do
    let(:redis) { Redis.new(url: ENV.fetch("REDIS_URL")) }
    let(:prefix) { "graphql-armory-test:cache:#{SecureRandom.hex(8)}:" }
    let(:store) { described_class.build(redis: redis, prefix: prefix, max_ttl: 1) }
    let(:other_process) { described_class.build(redis: Redis.new(url: ENV.fetch("REDIS_URL")), prefix: prefix, max_ttl: 1) }
    let(:travel) { ->(ms) { sleep(ms / 1000.0) } }
    let(:meta) { "#{prefix}meta" }

    before do
      skip "REDIS_URL is not set (docker compose and CI set it)" if ENV["REDIS_URL"].to_s.empty? && ENV["CI"].to_s.empty?
    end

    after do
      keys = ENV["REDIS_URL"].to_s.empty? ? [] : redis.keys("#{prefix}*")
      redis.del(*keys) unless keys.empty?
    end

    it_behaves_like "a purge sequence nobody can undo"

    it "never lets a process with a shorter max_ttl prune a mark a longer run still needs" do
      long = described_class.build(redis: Redis.new(url: ENV.fetch("REDIS_URL")), prefix: prefix, max_ttl: 3)
      lookup = long.lookup(key = hex)
      store.purge([tag = hex])
      travel.call(1_100)
      store.purge([hex])

      expect(write(long, lookup, key, tags: [tag], ttl: 3)).to be(false)
    end

    it "treats a deleted meta record as everything purged" do
      lookup = store.lookup(key = hex)
      write(store, lookup, key, tags: [])
      redis.del(meta)

      expect(rejected_on_read?(store.lookup(key), lookup)).to be(true)
    end

    it "rejects entries written ahead of a seq that went back (a failover to a replica that lost increments)" do
      3.times { store.purge([hex]) }
      lookup = store.lookup(key = hex)
      write(store, lookup, key, tags: [])
      redis.hset(meta, "seq", 1)

      expect(rejected_on_read?(store.lookup(key), lookup)).to be(true)
      expect(write(store, lookup, hex, tags: [])).to be(false)
    end

    it "raises when the purge reached fewer replicas than required, so the app retries it" do
      waiting = described_class.build(redis: redis, prefix: prefix, purge_replicas: 1, purge_timeout: 0.05)

      expect { waiting.purge([hex]) }.to raise_error(GraphQL::Armory::Caching::PurgeError)
    end
  end
end
