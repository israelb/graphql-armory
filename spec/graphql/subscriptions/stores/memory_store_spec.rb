# frozen_string_literal: true

require "spec_helper"
require "securerandom"
require "graphql/armory/subscriptions"
require "graphql/armory/subscriptions/memory_store"

RSpec.describe GraphQL::Armory::Subscriptions::MemoryStore do
  let(:store) { described_class.new }
  let(:now) { 1_800_000_000_000 }
  let(:topic) { SecureRandom.hex(32) }
  let(:viewer) { SecureRandom.hex(32) }

  it_behaves_like "a subscription store"

  def write(id, **options)
    defaults = { topics: [topic], viewer: viewer, expires_at: now + 60_000, viewer_cap: nil, topic_cap: nil, now: now }
    store.write(id, "sealed-#{id}", **defaults, **options)
  end

  def threads(count, &block)
    gate = Queue.new
    workers = Array.new(count) { |index| Thread.new { gate.pop; block.call(index) } }
    count.times { gate << true }
    workers.map(&:value)
  end

  describe "under concurrent writes" do
    it "never goes over a topic cap, whoever writes" do
      answers = threads(40) { |index| write("id-#{index}", viewer: SecureRandom.hex(32), topic_cap: 7) }

      expect(answers.tally).to eq(ok: 7, topic_cap: 33)
      expect(store.ids(topic, now: now).size).to eq(7)
    end

    it "never goes over a viewer cap" do
      answers = threads(40) { |index| write("id-#{index}", topics: [SecureRandom.hex(32)], viewer_cap: 5) }

      expect(answers.tally).to eq(ok: 5, viewer_cap: 35)
      expect(store.count(viewer, now: now)).to eq(5)
    end

    it "stores one of several writes of the same id" do
      answers = threads(20) { write("same", topics: [SecureRandom.hex(32)]) }

      expect(answers.tally).to eq(ok: 1, exists: 19)
    end

    it "keeps its indexes whole while writes, deletes and cleanups race" do
      threads(30) do |index|
        id = "id-#{index}"
        write(id, expires_at: now + 1_000)
        store.cleanup(now: now + 1_000) if index.odd?
        store.delete(id) if (index % 3).zero?
      end

      store.cleanup(now: now + 1_000)
      expect([store.ids(topic, now: now), store.count(viewer, now: now)]).to eq([[], 0])
    end
  end

  it "reveals nothing it holds when inspected" do
    store.write("a" * 43, "opaque-blob", topics: [topic], viewer: viewer, expires_at: now + 1_000, viewer_cap: nil, topic_cap: nil, now: now)

    expect([store.inspect, store.to_s].join).not_to include("opaque-blob", topic, viewer)
  end

  it "keeps a copy of what it was given: changing a topic list or a record afterwards changes nothing" do
    sealed = +"opaque"
    topics = [topic]
    store.write("b" * 43, sealed, topics: topics, viewer: viewer, expires_at: now + 1_000, viewer_cap: nil, topic_cap: nil, now: now)
    sealed << "-changed"
    topics << "other"

    expect([store.read("b" * 43), store.ids("other", now: now)]).to eq(["opaque", []])
  end

  it "refuses arguments of the wrong shape, as a caller's bug" do
    expect { write(nil) }.to raise_error(ArgumentError)
    expect { write("c" * 43, topics: []) }.to raise_error(ArgumentError)
    expect { write("c" * 43, viewer: "") }.to raise_error(ArgumentError)
    expect { write("c" * 43, viewer_cap: 0) }.to raise_error(ArgumentError)
    expect { write("c" * 43, expires_at: now) }.to raise_error(ArgumentError)
    expect { store.ids(topic, now: 1.5) }.to raise_error(ArgumentError)
    expect { store.cleanup(now: "1") }.to raise_error(ArgumentError)
  end
end
