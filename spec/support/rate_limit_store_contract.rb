# frozen_string_literal: true

# What every rate limit store answers, whatever keeps its state. The including group defines `store`, built on
# a clock that reads `now[0]`, an Array holding the time in seconds.
RSpec.shared_examples "a rate limit store" do
  describe "#take" do
    it "starts a client with a full bucket and takes the cost when it is there" do
      expect(store.take("user:1", cost: 40, limit: 100, window: 60)).to eq([true, 60])
    end

    it "refuses a cost that is not there, taking nothing" do
      2.times { store.take("user:1", cost: 40, limit: 100, window: 60) }

      expect(store.take("user:1", cost: 40, limit: 100, window: 60)).to eq([false, 20])
      expect(store.take("user:1", cost: 20, limit: 100, window: 60)).to eq([true, 0])
    end

    it "takes the cost anyway with force, down to zero" do
      expect(store.take("user:1", cost: 150, limit: 100, window: 60, force: true)).to eq([false, 0])
    end

    it "refills limit points every window, continuously, never past the limit" do
      2.times { store.take("user:1", cost: 40, limit: 100, window: 60) }
      now[0] += 12

      expect(store.take("user:1", cost: 0, limit: 100, window: 60)).to eq([true, 40])
      now[0] += 600
      expect(store.take("user:1", cost: 1, limit: 100, window: 60)).to eq([true, 99])
    end

    it "keeps fractional refills between calls and answers whole points" do
      store.take("user:1", cost: 10, limit: 10, window: 60)
      3.times do
        now[0] += 3
        store.take("user:1", cost: 0, limit: 10, window: 60)
      end

      expect(store.take("user:1", cost: 0, limit: 10, window: 60)).to eq([true, 1])
    end

    it "does not hand out points when the clock goes backwards and forwards again" do
      store.take("user:1", cost: 80, limit: 100, window: 60)
      now[0] -= 30
      store.take("user:1", cost: 0, limit: 100, window: 60)
      now[0] += 30

      expect(store.take("user:1", cost: 0, limit: 100, window: 60)).to eq([true, 20])
    end

    it "keeps a bucket per key" do
      store.take("user:1", cost: 100, limit: 100, window: 60)

      expect(store.take("user:2", cost: 1, limit: 100, window: 60)).to eq([true, 99])
    end
  end

  describe "#acquire and #release" do
    it "holds up to limit slots per key" do
      expect(store.acquire("user:1", token: "a", limit: 2, ttl: 60)).to eq([true, 1])
      expect(store.acquire("user:1", token: "b", limit: 2, ttl: 60)).to eq([true, 2])
      expect(store.acquire("user:1", token: "c", limit: 2, ttl: 60)).to eq([false, 2])
      expect(store.acquire("user:2", token: "d", limit: 2, ttl: 60)).to eq([true, 1])
    end

    it "takes a slot anyway with force" do
      store.acquire("user:1", token: "a", limit: 1, ttl: 60)

      expect(store.acquire("user:1", token: "b", limit: 1, ttl: 60, force: true)).to eq([false, 2])
    end

    it "frees a slot on release, and ignores an unknown token" do
      store.acquire("user:1", token: "a", limit: 1, ttl: 60)
      store.release("user:1", token: "a")
      store.release("user:1", token: "never-held")
      store.release("user:9", token: "a")

      expect(store.acquire("user:1", token: "b", limit: 1, ttl: 60)).to eq([true, 1])
    end

    it "frees a slot once its ttl has passed, as for a crashed process" do
      store.acquire("user:1", token: "a", limit: 1, ttl: 60)
      now[0] += 60

      expect(store.acquire("user:1", token: "b", limit: 1, ttl: 60)).to eq([true, 1])
    end
  end
end
