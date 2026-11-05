# frozen_string_literal: true

require "securerandom"

# The contract every subscription store keeps (`lib/graphql/armory/subscriptions/store.rb`), whatever holds its state.
# The including group defines:
#
# - `store`: an empty store;
# - `now`: the store's current time in Integer milliseconds. Every call that depends on time takes `now:` from the
#   caller, so the examples never wait: they pass later values of `now` instead. A store with a server-side TTL
#   (Redis) only needs `now` close to its real clock, so that the records the examples write are still held.
RSpec.shared_examples "a subscription store" do
  let(:topic) { SecureRandom.hex(32) }
  let(:other_topic) { SecureRandom.hex(32) }
  let(:viewer) { SecureRandom.hex(32) }
  let(:other_viewer) { SecureRandom.hex(32) }
  let(:lifetime) { 60_000 }

  def new_id = SecureRandom.urlsafe_base64(32)

  def write(id, sealed: "sealed-#{id}", topics: [topic], viewer: self.viewer, expires_at: now + lifetime, viewer_cap: nil, topic_cap: nil, at: now)
    store.write(id, sealed, topics: topics, viewer: viewer, expires_at: expires_at, viewer_cap: viewer_cap, topic_cap: topic_cap, now: at)
  end

  describe "#write and #read" do
    it "stores the sealed record under its id and answers :ok" do
      id = new_id

      expect(write(id, sealed: "opaque")).to eq(:ok)
      expect(store.read(id)).to eq("opaque")
    end

    it "answers nil for an id nobody wrote" do
      write(new_id)

      expect(store.read(new_id)).to be_nil
    end

    it "answers :exists for an id already stored and keeps the first record" do
      id = new_id
      write(id, sealed: "first", topics: [topic])

      expect(write(id, sealed: "second", topics: [other_topic])).to eq(:exists)
      expect([store.read(id), store.ids(topic, now: now), store.ids(other_topic, now: now)]).to eq(["first", [id], []])
    end

    it "keeps reading a record until its expiry at least" do
      id = new_id
      write(id, expires_at: now + 1_000)

      expect(store.read(id)).to eq("sealed-#{id}")
    end
  end

  describe "#ids" do
    it "answers the live ids of a topic, each record under every topic it was written with" do
      first = new_id
      second = new_id
      write(first, topics: [topic, other_topic])
      write(second, topics: [topic])

      expect(store.ids(topic, now: now)).to contain_exactly(first, second)
      expect(store.ids(other_topic, now: now)).to eq([first])
      expect(store.ids(SecureRandom.hex(32), now: now)).to eq([])
    end

    it "skips a record from its expiry on" do
      short = new_id
      long = new_id
      write(short, expires_at: now + 1_000)
      write(long, expires_at: now + 5_000)

      expect(store.ids(topic, now: now + 999)).to contain_exactly(short, long)
      expect(store.ids(topic, now: now + 1_000)).to eq([long])
    end
  end

  describe "#delete" do
    it "removes the record, its id from every topic and from its viewer's count, and answers true once" do
      id = new_id
      kept = new_id
      write(id, topics: [topic, other_topic])
      write(kept, topics: [topic])

      expect(store.delete(id)).to be(true)
      expect(store.delete(id)).to be(false)
      expect([store.read(id), store.ids(topic, now: now), store.ids(other_topic, now: now), store.count(viewer, now: now)]).to eq([nil, [kept], [], 1])
    end

    it "answers false for an id nobody wrote" do
      expect(store.delete(new_id)).to be(false)
    end
  end

  describe "#count" do
    it "counts a viewer's live records only" do
      write(new_id, expires_at: now + 1_000)
      write(new_id, expires_at: now + 5_000)
      write(new_id, viewer: other_viewer)

      expect([store.count(viewer, now: now), store.count(viewer, now: now + 1_000), store.count(other_viewer, now: now)]).to eq([2, 1, 1])
      expect(store.count(SecureRandom.hex(32), now: now)).to eq(0)
    end
  end

  describe "caps" do
    it "refuses a viewer's write over viewer_cap and writes nothing of it" do
      2.times { expect(write(new_id, viewer_cap: 2)).to eq(:ok) }
      refused = new_id

      expect(write(refused, viewer_cap: 2, topics: [topic, other_topic])).to eq(:viewer_cap)
      expect([store.read(refused), store.ids(other_topic, now: now), store.count(viewer, now: now)]).to eq([nil, [], 2])
      expect(store.ids(topic, now: now)).not_to include(refused)
    end

    it "counts the viewer cap per viewer" do
      2.times { write(new_id, viewer_cap: 2) }

      expect(write(new_id, viewer: other_viewer, viewer_cap: 2)).to eq(:ok)
    end

    it "refuses a write over topic_cap on any of its topics, from any viewer, and writes nothing of it" do
      write(new_id, topics: [other_topic], viewer: other_viewer)
      refused = new_id

      expect(write(refused, topics: [topic, other_topic], topic_cap: 1)).to eq(:topic_cap)
      expect([store.read(refused), store.ids(topic, now: now), store.ids(other_topic, now: now).size, store.count(viewer, now: now)]).to eq([nil, [], 1, 0])
    end

    it "checks the viewer cap first when both are reached" do
      write(new_id)

      expect(write(new_id, viewer_cap: 1, topic_cap: 1)).to eq(:viewer_cap)
    end

    it "counts live records only: an expired record frees its place before any cleanup" do
      write(new_id, expires_at: now + 1_000)

      expect(write(new_id, viewer_cap: 1, at: now + 500, expires_at: now + 10_000)).to eq(:viewer_cap)
      expect(write(new_id, topic_cap: 1, at: now + 500, expires_at: now + 10_000)).to eq(:topic_cap)
      expect(write(new_id, viewer_cap: 1, topic_cap: 1, at: now + 1_000, expires_at: now + 10_000)).to eq(:ok)
    end

    it "has no cap when a cap is nil" do
      expect(Array.new(5) { write(new_id) }).to all(eq(:ok))
      expect(store.count(viewer, now: now)).to eq(5)
    end
  end

  describe "#cleanup" do
    it "removes every expired record with its index entries, answers how many, and keeps the live ones" do
      expired = Array.new(2) { new_id }
      live = new_id
      expired.each { |id| write(id, expires_at: now + 1_000, topics: [topic, other_topic]) }
      write(live, expires_at: now + 5_000)

      expect(store.cleanup(now: now + 1_000)).to eq(2)
      expect(expired.map { |id| store.read(id) }).to eq([nil, nil])
      expect([store.read(live), store.ids(topic, now: now), store.ids(other_topic, now: now), store.count(viewer, now: now)])
        .to eq(["sealed-#{live}", [live], [], 1])
      expect(store.cleanup(now: now + 1_000)).to eq(0)
    end
  end
end
