# frozen_string_literal: true

require "spec_helper"
require "graphql/armory/subscriptions"

RSpec.describe "GraphQL::Armory::Subscriptions::Store" do
  let(:subscriptions) { GraphQL::Armory::Subscriptions }
  let(:topic) { SecureRandom.hex(32) }
  let(:viewer) { SecureRandom.hex(32) }

  describe "Store::Substitute" do
    let(:store) { subscriptions::Controls::Store.example }
    let(:now) { store.now }

    it_behaves_like "a subscription store"

    def write_one(id, **options)
      defaults = { topics: [topic], viewer: viewer, expires_at: store.now + 1_000, viewer_cap: nil, topic_cap: nil, now: store.now }
      store.write(id, "sealed", **defaults, **options)
    end

    it "records its calls, with every argument but the sealed record" do
      write_one("a" * 43)
      store.read("a" * 43)
      store.ids(topic, now: 5)
      store.count(viewer, now: 5)
      store.delete("a" * 43)
      store.cleanup(now: 5)

      expect(store.calls.map(&:first)).to eq(%i[write read ids count delete cleanup])
      expect(store.calls.first).to eq([:write, "a" * 43, { topics: [topic], viewer: viewer, expires_at: store.now + 1_000, viewer_cap: nil, topic_cap: nil, now: store.now }])
      expect(store.calls[2]).to eq([:ids, topic, { now: 5 }])
    end

    it "fails when told, on one operation or all, for a number of calls or until it recovers" do
      store.fail_with(IOError.new("down"), on: :read, times: 1)

      expect { store.read("x") }.to raise_error(IOError)
      expect(store.read("x")).to be_nil

      store.fail_with(IOError.new("down"))
      expect { store.ids(topic, now: 1) }.to raise_error(IOError)
      store.recover
      expect(store.ids(topic, now: 1)).to eq([])
      expect { store.fail_with(IOError.new, on: :purge) }.to raise_error(ArgumentError)
      expect { store.fail_with(IOError.new, times: 0) }.to raise_error(ArgumentError)
    end

    it "answers what it is told instead of the real answer" do
      store.answer(:write, :topic_cap)

      expect(write_one("b" * 43)).to eq(:topic_cap)
      expect(store.read("b" * 43)).to be_nil
      expect { store.answer(:flush, 1) }.to raise_error(ArgumentError)
    end

    it "writes a raw record as someone with store access could, without recording it" do
      store.poison("c" * 43, "forged", topics: [topic], viewer: viewer)

      expect([store.read("c" * 43), store.ids(topic, now: store.now), store.count(viewer, now: store.now)]).to eq(["forged", ["c" * 43], 1])
      expect(store.calls.map(&:first)).to eq(%i[read ids count])
      expect(store.records).to eq("c" * 43 => "forged")
    end

    it "refuses arguments of the wrong shape, as a caller's bug" do
      expect { write_one(nil) }.to raise_error(ArgumentError)
      expect { write_one("d" * 43, topics: []) }.to raise_error(ArgumentError)
      expect { write_one("d" * 43, viewer_cap: 0) }.to raise_error(ArgumentError)
      expect { write_one("d" * 43, expires_at: store.now) }.to raise_error(ArgumentError)
      expect { store.ids(topic, now: 1.5) }.to raise_error(ArgumentError)
    end

    it "refuses a clock that is not Integer milliseconds" do
      expect { subscriptions::Store::Substitute.new(now: 1.5) }.to raise_error(ArgumentError)
    end
  end

  describe "Store::Null" do
    let(:store) { subscriptions::Store::Null.new }

    it "refuses every write and holds nothing" do
      expect(store.write("e" * 43, "sealed", topics: [topic], viewer: viewer, expires_at: 2, viewer_cap: nil, topic_cap: nil, now: 1)).to eq(:refused)
      expect([store.read("e" * 43), store.ids(topic, now: 1), store.delete("e" * 43), store.count(viewer, now: 1), store.cleanup(now: 1)])
        .to eq([nil, [], false, 0, 0])
    end
  end
end
