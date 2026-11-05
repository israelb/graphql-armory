# frozen_string_literal: true

require "spec_helper"
require "redis"
require "securerandom"
require "graphql/armory/caching/redis_store"

# RedisStore against the real Redis service (docker compose and CI set REDIS_URL). Redis's own clock cannot be moved,
# so these examples sleep; every TTL here is 1 second.
RSpec.describe GraphQL::Armory::Caching::RedisStore do
  let(:caching) { GraphQL::Armory::Caching }
  let(:redis) { Redis.new(url: ENV.fetch("REDIS_URL")) }
  # A fresh prefix per example: runs that share one Redis never see each other's keys. The meta hash has no TTL, so
  # every example deletes what it wrote.
  let(:prefix) { "graphql-armory-test:cache:#{SecureRandom.hex(8)}:" }
  let(:store) { described_class.build(redis: redis, prefix: prefix, max_ttl: 1) }
  let(:travel) { ->(ms) { sleep(ms / 1000.0) } }
  let(:meta) { "#{prefix}meta" }
  let(:lose_meta) { -> { redis.del(meta) } }
  let(:rewind_seq) { ->(seq) { redis.hset(meta, "seq", seq) } }

  def hex = SecureRandom.hex(32)

  def store_after_lookup(store, key, blob: "blob", tags: [], ttl: 1)
    lookup = store.lookup(key)
    store.write(key, blob, tags: tags, ttl: ttl, seq: lookup.seq, epoch: lookup.epoch, stored_at: lookup.now)
  end

  before do
    skip "REDIS_URL is not set (docker compose and CI set it)" if ENV["REDIS_URL"].to_s.empty? && ENV["CI"].to_s.empty?
  end

  after do
    keys = ENV["REDIS_URL"].to_s.empty? ? [] : redis.keys("#{prefix}*")
    redis.del(*keys) unless keys.empty?
  end

  it_behaves_like "a caching store", meta_loss: true, prunes: true

  describe ".new" do
    it "is inert: with no Redis wired every lookup misses and every write is refused" do
      store = described_class.new
      lookup = store.lookup(hex)

      expect(lookup).not_to be_found
      expect(store.write(hex, "blob", tags: [], ttl: 1, seq: lookup.seq, epoch: lookup.epoch, stored_at: lookup.now)).to be(false)
    end

    it "fails purges loudly: a purge that reached no Redis must never look done" do
      store = described_class.new

      expect { store.purge([hex]) }.to raise_error(caching::PurgeError, /no Redis/)
      expect { store.purge_all }.to raise_error(caching::PurgeError, /no Redis/)
    end
  end

  describe ".build" do
    it "validates every setting" do
      invalid = [
        { redis: Object.new },
        { prefix: "" },
        { prefix: :cache },
        { purge_replicas: 0 },
        { purge_replicas: "1" },
        { purge_timeout: 0 },
        { max_ttl: 0 },
        { max_ttl: 1.5 }
      ]

      invalid.each do |settings|
        expect { described_class.build(redis: redis, **settings) }.to raise_error(caching::ConfigurationError)
      end
    end

    it "reports its settings" do
      built = described_class.build(redis: redis, purge_replicas: 2, purge_timeout: 0.5)

      expect([built.prefix, built.max_ttl, built.purge_replicas, built.purge_timeout]).to eq(["graphql-armory:cache:", 3600, 2, 0.5])
    end
  end

  describe "the keyspace" do
    it "keeps one meta hash without a TTL and one key per entry, expiring with it, all under the prefix" do
      key = hex
      store_after_lookup(store, key, tags: [hex])

      expect(redis.keys("#{prefix}*").sort).to eq(["#{prefix}e:#{key}", meta].sort)
      expect(redis.ttl(meta)).to eq(-1)
      expect(redis.pttl("#{prefix}e:#{key}")).to be_between(1, 1_000)
    end

    it "holds nothing but digests, numbers and the blob" do
      tag = hex
      store_after_lookup(store, hex, tags: [tag])
      store.purge([tag])

      expect(redis.hkeys(meta)).to all(match(/\A(epoch|seq|cursor|max_ttl|m:\h{64})\z/))
      expect(redis.hvals(meta)).to all(match(/\A[\h:]+\z/))
    end

    it "shares the meta record between stores on one prefix, as the processes of one app do" do
      other = described_class.build(redis: Redis.new(url: ENV.fetch("REDIS_URL")), prefix: prefix, max_ttl: 1)
      lookup = store.lookup(key = hex)
      other.purge([tag = hex])

      expect(store.write(key, "blob", tags: [tag], ttl: 1, seq: lookup.seq, epoch: lookup.epoch, stored_at: lookup.now)).to be(false)
    end

    it "loads its scripts again after Redis forgot them" do
      store.lookup(hex)
      redis.script(:flush)

      expect(store_after_lookup(store, hex)).to be(true)
    end
  end

  describe "what someone else wrote in Redis" do
    it "answers a miss for an entry that is not one of its records, and the next write replaces it" do
      key = hex
      redis.set("#{prefix}e:#{key}", "planted")
      expect(store.lookup(key)).not_to be_found

      redis.del("#{prefix}e:#{key}")
      redis.hset("#{prefix}e:#{key}", "blob", "planted")
      expect(store.lookup(key)).not_to be_found

      expect(store_after_lookup(store, key, blob: "real")).to be(true)
      expect(store.lookup(key).blob).to eq("real")
    end

    it "treats a meta record it cannot read as lost: everything purged" do
      lookup = store.lookup(hex)
      redis.hset(meta, "seq", "many")

      expect(store.lookup(hex).epoch).not_to eq(lookup.epoch)
    end

    it "raises on a mark it cannot read instead of answering the entry without it" do
      key = hex
      store_after_lookup(store, key, tags: [tag = hex])
      redis.hset(meta, "m:#{tag}", "junk")

      expect { store.lookup(key) }.to raise_error(Redis::CommandError, /corrupt purge mark/)
    end
  end

  describe "failures" do
    let(:unreachable) { Redis.new(url: "redis://127.0.0.1:1/0", connect_timeout: 0.2, reconnect_attempts: 0) }

    it "raises from every operation when Redis cannot be reached; purges never answer as if done" do
      down = described_class.build(redis: unreachable, prefix: prefix)

      [-> { down.lookup(hex) }, -> { down.purge([hex]) }, -> { down.purge_all }].each do |operation|
        expect(&operation).to raise_error(Redis::BaseError)
      end
    end

    it "raises PurgeError when fewer replicas than purge_replicas acknowledged the purge" do
      waiting = described_class.build(redis: redis, prefix: prefix, purge_replicas: 1, purge_timeout: 0.05)

      expect { waiting.purge([hex]) }.to raise_error(caching::PurgeError, /0 of 1 replicas/)
      expect { waiting.purge_all }.to raise_error(caching::PurgeError, /0 of 1 replicas/)
    end
  end

  describe "write arguments" do
    it "refuses a TTL above max_ttl" do
      lookup = store.lookup(hex)

      expect { store.write(hex, "blob", tags: [], ttl: 2, seq: lookup.seq, epoch: lookup.epoch, stored_at: lookup.now) }
        .to raise_error(ArgumentError, /max_ttl/)
    end
  end

  describe "pruning marks" do
    it "prunes at most 100 marks per purge and reaches every old mark through its cursor" do
      tags = Array.new(150) { hex }
      store.purge(tags)
      travel.call(600)
      store_after_lookup(store, key = hex, tags: tags)
      travel.call(500)

      store.purge([hex])
      after_one = store.lookup(key).marks.size
      4.times { store.purge([hex]) }

      expect(after_one).to be >= 50
      expect(store.lookup(key).marks).to eq({})
    end
  end
end
