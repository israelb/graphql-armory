# frozen_string_literal: true

require "spec_helper"
require "redis"
require "securerandom"
require "graphql/armory/subscriptions"
require "graphql/armory/subscriptions/redis_store"

# RedisStore against the real Redis service (docker compose and CI set REDIS_URL). The store uses the `now:` it is given,
# so the shared examples move time by passing later values; only the record's PX TTL follows Redis's own clock.
RSpec.describe GraphQL::Armory::Subscriptions::RedisStore do
  let(:subscriptions) { GraphQL::Armory::Subscriptions }
  let(:redis) { Redis.new(url: ENV.fetch("REDIS_URL")) }
  let(:prefix) { "graphql-armory-test:subs:#{SecureRandom.hex(8)}:" }
  let(:store) { described_class.build(redis: redis, prefix: prefix) }
  let(:now) { (Time.now.to_f * 1000).to_i }
  let(:topic) { SecureRandom.hex(32) }
  let(:viewer) { SecureRandom.hex(32) }
  let(:id) { SecureRandom.urlsafe_base64(32) }

  before do
    skip "REDIS_URL is not set (docker compose and CI set it)" if ENV["REDIS_URL"].to_s.empty? && ENV["CI"].to_s.empty?
  end

  after do
    keys = ENV["REDIS_URL"].to_s.empty? ? [] : redis.keys("#{prefix}*")
    redis.del(*keys) unless keys.empty?
  end

  it_behaves_like "a subscription store"

  def write(record_id = id, sealed: "sealed-#{record_id}", **options)
    defaults = { topics: [topic], viewer: viewer, expires_at: now + 60_000, viewer_cap: nil, topic_cap: nil, now: now }
    store.write(record_id, sealed, **defaults, **options)
  end

  def dump(key)
    case redis.type(key)
    when "hash" then redis.hgetall(key).flatten.join(" ")
    when "zset" then redis.zrange(key, 0, -1).join(" ")
    else redis.get(key).to_s
    end
  end

  describe ".new" do
    it "is inert: it holds nothing and refuses every write, like Store::Null" do
      inert = described_class.new

      expect(inert.write(id, "sealed", topics: [topic], viewer: viewer, expires_at: now + 1_000, viewer_cap: nil, topic_cap: nil, now: now)).to eq(:refused)
      expect([inert.read(id), inert.ids(topic, now: now), inert.delete(id), inert.count(viewer, now: now), inert.cleanup(now: now)])
        .to eq([nil, [], false, 0, 0])
    end
  end

  describe ".build" do
    it "validates every setting" do
      [{ redis: Object.new }, { prefix: "" }, { prefix: :subs }].each do |settings|
        expect { described_class.build(**{ redis: redis }.merge(settings)) }.to raise_error(subscriptions::ConfigurationError)
      end
    end

    it "reports its prefix and never the client" do
      built = described_class.build(redis: redis)

      expect(built.prefix).to eq("graphql-armory:subscriptions:")
      expect(built.inspect).to include("graphql-armory:subscriptions:")
    end
  end

  describe "the keyspace" do
    it "keeps one hash per record, one sorted set per topic and per viewer scored by expires_at, and one expiry set" do
      other_topic = SecureRandom.hex(32)
      write(id, topics: [topic, other_topic], expires_at: now + 5_000)

      expect(redis.keys("#{prefix}*")).to contain_exactly("#{prefix}r:#{id}", "#{prefix}t:#{topic}", "#{prefix}t:#{other_topic}", "#{prefix}v:#{viewer}", "#{prefix}x")
      expect(redis.type("#{prefix}r:#{id}")).to eq("hash")
      expect(redis.zrange("#{prefix}t:#{topic}", 0, -1, with_scores: true)).to eq([[id, (now + 5_000).to_f]])
      expect(redis.zrange("#{prefix}v:#{viewer}", 0, -1, with_scores: true)).to eq([[id, (now + 5_000).to_f]])
      expect(redis.zrange("#{prefix}x", 0, -1, with_scores: true)).to eq([[id, (now + 5_000).to_f]])
    end

    it "makes the record and every index expire with the record, and keeps the expiry set" do
      write(id, expires_at: now + 5_000)

      ["r:#{id}", "t:#{topic}", "v:#{viewer}"].each do |key|
        expect(redis.pttl("#{prefix}#{key}")).to be_between(1, 5_000)
      end
      expect(redis.ttl("#{prefix}x")).to eq(-1)
    end

    it "keeps an index as long as its longest record" do
      write(SecureRandom.urlsafe_base64(32), expires_at: now + 50_000)
      write(SecureRandom.urlsafe_base64(32), expires_at: now + 5_000)

      expect(redis.pttl("#{prefix}t:#{topic}")).to be_between(5_001, 50_000)
    end

    it "holds nothing in clear besides the sealed record: keys carry ids and digests, the rest are scores" do
      write(id, sealed: "opaque-blob")

      holders = redis.keys("#{prefix}*").select { |key| dump(key).include?("opaque-blob") }
      expect(holders).to eq(["#{prefix}r:#{id}"])
      expect(redis.hkeys("#{prefix}r:#{id}")).to contain_exactly("sealed", "viewer", "topics", "expires_at")
    end
  end

  describe "the clock" do
    it "uses the now: it is given, not Redis's own, so it agrees with the core and with MemoryStore" do
      far = now + (10 * 365 * 24 * 3_600_000)
      write(id, expires_at: far + 1_000, now: far)

      expect(store.ids(topic, now: far)).to eq([id])
      expect(store.ids(topic, now: far + 1_000)).to eq([])
    end

    it "trims an index on read: expired ids leave the sorted set" do
      write(id, expires_at: now + 1_000)
      store.ids(topic, now: now + 1_000)

      expect([redis.zcard("#{prefix}t:#{topic}"), redis.exists?("#{prefix}r:#{id}")]).to eq([0, true])
    end
  end

  describe "under concurrent writes" do
    def threads(count, &block)
      gate = Queue.new
      workers = Array.new(count) { |index| Thread.new { gate.pop; block.call(index, described_class.build(redis: Redis.new(url: ENV.fetch("REDIS_URL")), prefix: prefix)) } }
      count.times { gate << true }
      workers.map(&:value)
    end

    it "never goes over a topic cap, from any connection" do
      answers = threads(30) do |index, racer|
        racer.write("id-#{index}", "sealed", topics: [topic], viewer: SecureRandom.hex(32), expires_at: now + 60_000, viewer_cap: nil, topic_cap: 6, now: now)
      end

      expect(answers.tally).to eq(ok: 6, topic_cap: 24)
      expect(store.ids(topic, now: now).size).to eq(6)
    end

    it "never goes over a viewer cap, from any connection" do
      answers = threads(30) do |index, racer|
        racer.write("id-#{index}", "sealed", topics: [SecureRandom.hex(32)], viewer: viewer, expires_at: now + 60_000, viewer_cap: 4, topic_cap: nil, now: now)
      end

      expect(answers.tally).to eq(ok: 4, viewer_cap: 26)
      expect(store.count(viewer, now: now)).to eq(4)
    end

    it "stores one of several writes of the same id" do
      answers = threads(20) do |_index, racer|
        racer.write("same", "sealed", topics: [SecureRandom.hex(32)], viewer: viewer, expires_at: now + 60_000, viewer_cap: nil, topic_cap: nil, now: now)
      end

      expect(answers.tally).to eq(ok: 1, exists: 19)
    end
  end

  describe "#cleanup" do
    it "removes a record whose key already expired by its TTL: it leaves the expiry set, and its index entries by score" do
      write(id, expires_at: now + 1_000)
      redis.del("#{prefix}r:#{id}")

      expect(store.cleanup(now: now + 1_000)).to eq(1)
      expect(redis.zcard("#{prefix}x")).to eq(0)
      expect(store.ids(topic, now: now + 1_000)).to eq([])
      expect(redis.zcard("#{prefix}t:#{topic}")).to eq(0)
    end

    it "answers the whole count even when there are more records than one batch" do
      count = described_class::CLEANUP_BATCH + 5
      count.times { |index| write("id-#{index}", expires_at: now + 1_000) }

      expect(store.cleanup(now: now + 1_000)).to eq(count)
      expect(redis.keys("#{prefix}*")).to eq([])
    end

    it "leaves a live record and its indexes alone" do
      write(id)

      expect(store.cleanup(now: now)).to eq(0)
      expect([store.read(id), store.ids(topic, now: now)]).to eq(["sealed-#{id}", [id]])
    end
  end

  describe "#delete" do
    it "answers true for an id whose record key expired but whose expiry entry is still there, and forgets it" do
      write(id)
      redis.del("#{prefix}r:#{id}")

      expect(store.delete(id)).to be(true)
      expect([store.delete(id), redis.zcard("#{prefix}x")]).to eq([false, 0])
    end
  end

  describe "scripts" do
    it "loads again after Redis forgets them" do
      write(id)
      redis.call("SCRIPT", "FLUSH")

      expect(store.ids(topic, now: now)).to eq([id])
      expect(write(SecureRandom.urlsafe_base64(32))).to eq(:ok)
    end

    it "lets a Redis error reach the caller unchanged" do
      client = Class.new(Redis) { def evalsha(*, **) = raise(Redis::TimeoutError, "down") }.new(url: ENV.fetch("REDIS_URL"))

      expect { described_class.build(redis: client, prefix: prefix).ids(topic, now: now) }.to raise_error(Redis::TimeoutError, "down")
    end

    it "refuses arguments of the wrong shape before it reaches Redis" do
      expect { write(nil) }.to raise_error(ArgumentError)
      expect { write(id, topics: []) }.to raise_error(ArgumentError)
      expect { write(id, viewer_cap: 0) }.to raise_error(ArgumentError)
      expect { write(id, expires_at: now) }.to raise_error(ArgumentError)
      expect { store.count(viewer, now: 1.5) }.to raise_error(ArgumentError)
      expect(redis.keys("#{prefix}*")).to eq([])
    end
  end
end
