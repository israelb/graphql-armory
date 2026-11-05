# frozen_string_literal: true

require "spec_helper"
require "json"
require "graphql/armory/subscriptions"

RSpec.describe "GraphQL::Armory::Subscriptions values" do
  let(:subscriptions) { GraphQL::Armory::Subscriptions }
  let(:controls) { subscriptions::Controls }

  describe "errors" do
    it "are armory errors; a refusal carries a Symbol reason" do
      expect(subscriptions::ConfigurationError.ancestors).to include(subscriptions::Error, GraphQL::Armory::Error)
      expect(subscriptions::TransportError.ancestors).to include(subscriptions::Error)
      expect(subscriptions::RefusedError.new("over the cap", reason: :viewer_cap)).to have_attributes(reason: :viewer_cap, message: "over the cap")
      expect { subscriptions::RefusedError.new("x", reason: "viewer_cap") }.to raise_error(ArgumentError)
    end
  end

  describe "Record" do
    let(:record) { controls::Record.example }

    it "holds every field of a subscription, frozen" do
      expect(record).to be_frozen
      expect(record).to have_attributes(
        id: controls::Id.example, document: a_string_starting_with("subscription"), operation_name: "MessagePosted",
        variables: a_kind_of(String), operation_id: "message-posted", raw_query: false, version: "2025-01-01",
        visibility_profile: nil, engine: :interpreter, viewer_id: "user-1", viewer_digest: controls::Digest.example("viewer"),
        context: { "tenant_id" => "\"acme\"" }, created_at: 1_000_000, expires_at: 1_000_000 + (3_600 * 1000)
      )
      expect(record.events.map(&:to_h)).to eq([{ graphql_topic: ":messagePosted:roomId:5", digest: controls::Digest.example("topic") }])
      expect(record.topics).to eq([controls::Digest.example("topic")])
    end

    it "answers the graphql-ruby topic stored beside one of its digests, and nil for a digest it does not hold" do
      expect(record.graphql_topic(controls::Digest.example("topic"))).to eq(":messagePosted:roomId:5")
      expect(record.graphql_topic(controls::Digest.example("other"))).to be_nil
    end

    it "is expired from expires_at on" do
      expect([record.expired?(record.expires_at - 1), record.expired?(record.expires_at)]).to eq([false, true])
    end

    it "round-trips through to_h and JSON, with String keys only" do
      hash = JSON.parse(JSON.generate(record.to_h))

      expect(subscriptions::Record.from_h(hash)).to eq(record)
      expect(record.to_h.keys).to all(be_a(String))
      expect(record.to_h["engine"]).to eq("interpreter")
    end

    it "round-trips an anonymous record on the next engine with every optional field set" do
      anonymous = controls::Record.example(viewer_id: nil, viewer_digest: subscriptions::Record::ANONYMOUS, engine: :next,
                                           operation_id: nil, raw_query: true, version: nil, visibility_profile: "2024-06-01",
                                           operation_name: nil, context: {})

      expect(subscriptions::Record.from_h(JSON.parse(JSON.generate(anonymous.to_h)))).to eq(anonymous)
      expect(anonymous).to be_anonymous
      expect(record).not_to be_anonymous
    end

    it "never shows its document, viewer or variables in inspect" do
      expect(record.inspect).not_to include("user-1", "subscription", "roomId", controls::Id.example)
    end

    {
      "id" => ["short", 5, nil, "has space#{"x" * 40}"],
      "document" => ["", nil, 5],
      "operation_name" => ["", 5],
      "variables" => [{}, nil],
      "operation_id" => ["", 5],
      "raw_query" => [nil, "true", 1],
      "version" => ["", :v1],
      "visibility_profile" => ["", :public],
      "engine" => [:ruby, nil, "interpreter"],
      "viewer_id" => ["", 5],
      "viewer_digest" => ["ABC", "", nil, "f" * 63],
      "context" => [{ tenant_id: "1" }, { "tenant_id" => 1 }, [], nil],
      "events" => [[], nil, [{ graphql_topic: 1, digest: "f" * 64 }], [{ graphql_topic: "t", digest: "nope" }]],
      "created_at" => [-1, 1.5, nil],
      "expires_at" => [1_000_000, 999, nil]
    }.each do |field, values|
      it "refuses a #{field} of the wrong shape" do
        values.each do |value|
          expect { controls::Record.example(field.to_sym => value) }.to raise_error(ArgumentError, /Record #{field}/), "#{field}: #{value.inspect}"
        end
      end
    end

    it "refuses the same digest twice and a viewer id that disagrees with an anonymous digest" do
      twice = [{ graphql_topic: "a", digest: "f" * 64 }, { graphql_topic: "b", digest: "f" * 64 }]

      expect { controls::Record.example(events: twice) }.to raise_error(ArgumentError, /Record events/)
      expect { controls::Record.example(viewer_digest: subscriptions::Record::ANONYMOUS) }.to raise_error(ArgumentError, /Record viewer_id/)
      expect { controls::Record.example(viewer_id: nil) }.to raise_error(ArgumentError, /Record viewer_id/)
    end

    describe ".from_h" do
      let(:hash) { JSON.parse(JSON.generate(record.to_h)) }

      it "refuses a missing key, an unknown key, another format and anything but a Hash" do
        expect { subscriptions::Record.from_h(hash.except("document")) }.to raise_error(ArgumentError)
        expect { subscriptions::Record.from_h(hash.merge("admin" => true)) }.to raise_error(ArgumentError)
        expect { subscriptions::Record.from_h(hash.merge("v" => 2)) }.to raise_error(ArgumentError)
        expect { subscriptions::Record.from_h(hash.transform_keys(&:to_sym)) }.to raise_error(ArgumentError)
        expect { subscriptions::Record.from_h("{}") }.to raise_error(ArgumentError)
        expect { subscriptions::Record.from_h(nil) }.to raise_error(ArgumentError)
      end

      it "refuses an engine it does not know and an event of another shape" do
        expect { subscriptions::Record.from_h(hash.merge("engine" => "instance_eval")) }.to raise_error(ArgumentError)
        expect { subscriptions::Record.from_h(hash.merge("events" => [{ "graphql_topic" => "t" }])) }.to raise_error(ArgumentError)
        expect { subscriptions::Record.from_h(hash.merge("events" => [["t", "f" * 64]])) }.to raise_error(ArgumentError)
        expect { subscriptions::Record.from_h(hash.merge("events" => [{ "graphql_topic" => "t", "digest" => "f" * 64, "x" => 1 }])) }.to raise_error(ArgumentError)
      end
    end
  end

  describe "Capabilities" do
    it "holds what a transport can do, frozen, with predicates" do
      capabilities = controls::Capabilities.example

      expect(capabilities).to be_frozen
      expect(capabilities).to have_attributes(viewer_bound?: true, max_payload_bytes: 10_240, max_batch: 10, webhooks: :existence, compress?: false)
      expect(controls::Capabilities.example(viewer_bound: false, compress: true, webhooks: nil)).to have_attributes(viewer_bound?: false, compress?: true, webhooks: nil)
      expect(subscriptions::Transport::Capabilities).to be(subscriptions::Capabilities)
    end

    {
      viewer_bound: [nil, "yes"], max_payload_bytes: [-1, 1.5, nil], max_batch: [0, nil, 2.0], webhooks: [:gone, "presence"], compress: [nil, 1]
    }.each do |field, values|
      it "refuses a #{field} of the wrong shape" do
        values.each do |value|
          expect { controls::Capabilities.example(field => value) }.to raise_error(ArgumentError, /Capabilities #{field}/), "#{field}: #{value.inspect}"
        end
      end
    end
  end

  describe "Message" do
    it "is a payload for one channel under the event the graphql-ruby client listens to" do
      message = subscriptions::Message.new(channel: "private-app-x", payload: { result: { "data" => nil }, more: true })

      expect(message).to be_frozen
      expect(message).to have_attributes(channel: "private-app-x", event: "update", payload: { result: { "data" => nil }, more: true })
      expect(message.inspect).not_to include("private-app-x")
    end

    it "refuses an empty channel, a payload that is not a Hash and an empty event" do
      expect { subscriptions::Message.new(channel: "", payload: {}) }.to raise_error(ArgumentError, /Message channel/)
      expect { subscriptions::Message.new(channel: "c", payload: "{}") }.to raise_error(ArgumentError, /Message payload/)
      expect { subscriptions::Message.new(channel: "c", payload: {}, event: "") }.to raise_error(ArgumentError, /Message event/)
    end
  end

  describe "Outcome" do
    it "is what happened to the message at an index" do
      outcomes = subscriptions::Outcome::STATUSES.each_with_index.map { |status, index| subscriptions::Outcome.new(status: status, index: index) }

      expect(outcomes.map { |outcome| [outcome.ok?, outcome.gone?, outcome.retry?, outcome.refused?] }).to eq([
        [true, false, false, false], [false, true, false, false], [false, false, true, false], [false, false, false, true]
      ])
      expect(subscriptions::Outcome.new(status: :refused, index: 3, reason: :too_large)).to have_attributes(index: 3, reason: :too_large)
      expect(outcomes).to all(be_frozen)
    end

    it "refuses another status, a negative index and a reason that is not a Symbol" do
      expect { subscriptions::Outcome.new(status: :lost, index: 0) }.to raise_error(ArgumentError, /Outcome status/)
      expect { subscriptions::Outcome.new(status: :ok, index: -1) }.to raise_error(ArgumentError, /Outcome index/)
      expect { subscriptions::Outcome.new(status: :ok, index: 0, reason: "x") }.to raise_error(ArgumentError, /Outcome reason/)
    end
  end
end
