# frozen_string_literal: true

require "spec_helper"
require "date"
require "json"
require "graphql/armory/subscriptions"

RSpec.describe GraphQL::Armory::Subscriptions::Topic do
  let(:subscriptions) { GraphQL::Armory::Subscriptions }
  let(:controls) { subscriptions::Controls }
  let(:schema) { controls::Schema.example(subscriptions: {}, plugin: controls::EventLog) }
  let(:encoder) { GraphQL::Armory::Encoder::Substitute.new }
  let(:message_posted) { schema.subscription.get_field("messagePosted") }
  let(:room_updated) { schema.subscription.get_field("roomUpdated") }

  # The write side: the arguments of the Event graphql-ruby hands `write_subscription` (interpreter Arguments: Ruby
  # keywords, coerced values, defaults filled, input objects as InputObject instances).
  def write_side(document, variables: {})
    result = schema.execute(document, variables: variables, context: { armory_allow_raw_query: true, rate_limit_key: "spec" })
    raise "unexpected errors: #{result["errors"].inspect}" if result["errors"]

    schema.subscriptions.events.fetch(0).arguments
  end

  def digest(field, arguments, scope = nil)
    described_class.digest(encoder, field, arguments, scope)
  end

  describe "the same subscription from the write side and the trigger side" do
    it "meets for an ID given as an Integer or a String, by GraphQL name or keyword" do
      written = write_side("subscription { messagePosted(roomId: 5) { id } }")

      expect(written[:room_id]).to eq("5")
      expect([{ "roomId" => 5 }, { "roomId" => "5" }, { room_id: 5 }, { "room_id" => "5" }].map { |trigger| digest(message_posted, trigger) })
        .to all(eq(digest(message_posted, written)))
    end

    it "meets for an enum given by its Ruby value or its GraphQL name" do
      written = write_side("subscription { messagePosted(roomId: 5, priority: HIGH) { id } }")

      expect(written[:priority]).to eq(:high)
      expect([{ "roomId" => 5, "priority" => "HIGH" }, { "roomId" => 5, "priority" => :high }].map { |trigger| digest(message_posted, trigger) })
        .to all(eq(digest(message_posted, written)))
    end

    it "meets for a Date custom scalar given as a Date or as its String" do
      written = write_side("subscription { messagePosted(roomId: 5, on: \"2024-05-01\") { id } }")

      expect(written[:on]).to eq(Date.new(2024, 5, 1))
      expect([{ "roomId" => 5, "on" => Date.new(2024, 5, 1) }, { "roomId" => 5, "on" => "2024-05-01" }].map { |trigger| digest(message_posted, trigger) })
        .to all(eq(digest(message_posted, written)))
    end

    it "meets whether a default was omitted or given, on either side" do
      omitted = write_side("subscription { messagePosted(roomId: 5) { id } }")
      given = write_side("subscription { messagePosted(roomId: 5, filter: { priority: LOW }) { id } }")

      expect(omitted[:filter]).to be_a(GraphQL::Schema::InputObject)
      expect([digest(message_posted, given), digest(message_posted, { "roomId" => 5 }), digest(message_posted, { "roomId" => 5, "filter" => { "priority" => "LOW" } })])
        .to all(eq(digest(message_posted, omitted)))
    end

    it "meets for nested input objects, lists and floats, through variables or literals" do
      variables = { "filter" => { "window" => { "from" => "2024-01-01" }, "priorities" => %w[HIGH LOW], "minScore" => 0.5 } }
      written = write_side("subscription($filter: MessageFilter) { messagePosted(roomId: 5, filter: $filter) { id } }", variables: variables)
      trigger = { "roomId" => 5, "filter" => { "window" => { "from" => Date.new(2024, 1, 1) }, "priorities" => %i[high low], "minScore" => 0.5 } }

      expect(digest(message_posted, trigger)).to eq(digest(message_posted, written))
      expect(digest(message_posted, { "roomId" => 5, "filter" => { window: { from: "2024-01-01" }, priorities: [:high, "LOW"], min_score: 0.5 } }))
        .to eq(digest(message_posted, written))
    end

    it "accepts graphql-ruby's interpreter Arguments and InputObject instances as given" do
      written = write_side("subscription { messagePosted(roomId: 5, filter: { window: { from: \"2024-01-01\" } }) { id } }")

      expect(written[:filter][:window]).to be_a(GraphQL::Schema::InputObject)
      expect(written[:filter].arguments).to be_a(GraphQL::Execution::Interpreter::Arguments)
      expect(described_class.args(schema.get_type("MessageFilter"), written[:filter].arguments)).to eq(described_class.args(schema.get_type("MessageFilter"), written[:filter]))
      expect(digest(message_posted, { "roomId" => "5", "filter" => { "window" => { "from" => "2024-01-01" } } })).to eq(digest(message_posted, written))
      expect(digest(message_posted, { "roomId" => "5", "filter" => written[:filter] })).to eq(digest(message_posted, written))
    end
  end

  describe "distinct subscriptions" do
    it "never meet for distinct values" do
      digests = [
        { "roomId" => 5 }, { "roomId" => 6 }, { "roomId" => 5, "priority" => "HIGH" }, { "roomId" => 5, "on" => "2024-05-02" },
        { "roomId" => 5, "filter" => { "priority" => "HIGH" } }, { "roomId" => 5, "filter" => { "minScore" => 1.0 } }
      ].map { |arguments| digest(message_posted, arguments) }

      expect(digests.uniq.size).to eq(digests.size)
    end

    it "keep an explicit null apart from an omitted argument without a default" do
      expect(digest(message_posted, { "roomId" => 5, "priority" => nil })).not_to eq(digest(message_posted, { "roomId" => 5 }))
    end

    it "never meet across fields with the same arguments" do
      expect(digest(message_posted, { "roomId" => 5 })).not_to eq(digest(room_updated, { "roomId" => 5 }))
    end

    it "do not collide where graphql-ruby's colon-joined topic does" do
      joined = { "roomId" => "5:thread:9" }
      separate = { "roomId" => "5", "thread" => "9" }
      graphql_topics = [joined, separate].map { |arguments| GraphQL::Schema::Subscription.topic_for(arguments: arguments, field: room_updated, scope: nil) }

      expect(graphql_topics.uniq.size).to eq(1)
      expect(digest(room_updated, joined)).not_to eq(digest(room_updated, separate))
    end

    it "keep 1 and \"1\" scopes apart, and every scope apart from none" do
      scopes = [nil, 1, "1", 1.0, true, "true", [1], { "a" => 1 }, [], {}]

      expect(scopes.map { |scope| digest(message_posted, { "roomId" => 5 }, scope) }.uniq.size).to eq(scopes.size)
    end
  end

  describe ".canonical" do
    it "is a fixed-arity JSON array: format, field name, sorted argument pairs and the tagged scope" do
      canonical = described_class.canonical(message_posted, { room_id: 5, priority: :high }, "acme")

      expect(JSON.parse(canonical)).to eq([1, "messagePosted", [["filter", [["priority", "LOW"]]], ["priority", "HIGH"], ["roomId", "5"]], ["s", "acme"]])
    end
  end

  describe ".args" do
    it "refuses an unknown key, the same argument twice and a value of another shape" do
      expect { described_class.args(message_posted, { "roomId" => 5, "admin" => true }) }.to raise_error(ArgumentError, /unknown argument/)
      expect { described_class.args(message_posted, { "roomId" => 5, room_id: 6 }) }.to raise_error(ArgumentError, /twice/)
      expect { described_class.args(message_posted, [["roomId", 5]]) }.to raise_error(ArgumentError)
      expect { described_class.args(message_posted, { "roomId" => 5, "filter" => "LOW" }) }.to raise_error(ArgumentError, /filter/)
    end

    it "refuses a value its type cannot coerce, NaN and unknown objects, without quoting the value" do
      secret = Struct.new(:token).new("s3cret")
      [
        { "roomId" => 5, "priority" => "PURPLE" }, { "roomId" => 5, "on" => "not a date" }, { "roomId" => secret },
        { "roomId" => 5, "filter" => { "minScore" => Float::NAN } }, { "roomId" => 5, "filter" => { "minScore" => Float::INFINITY } },
        { "roomId" => 5.5 }, { "roomId" => nil }, { "roomId" => 5, "filter" => { "window" => { "from" => secret } } }
      ].each do |arguments|
        expect { described_class.args(message_posted, arguments) }.to raise_error(ArgumentError) { |error| expect(error.message).not_to include("s3cret", "PURPLE") }
      end
    end

    it "refuses a missing required argument" do
      expect { described_class.args(message_posted, {}) }.to raise_error(ArgumentError, /roomId/)
    end

    it "takes no arguments as none" do
      expect(described_class.args(schema.subscription.get_field("inboxChanged"), nil)).to eq([])
      expect(described_class.args(schema.subscription.get_field("inboxChanged"), {})).to eq([])
    end
  end

  describe ".tagged" do
    it "tags each scope with its type" do
      record = Struct.new(:to_gid).new("gid://app/User/1")

      expect([nil, true, "a", 1, 1.5, [1, "1"], { b: 1, "a" => nil }, record].map { |scope| described_class.tagged(scope) }).to eq([
        ["n"], ["b", true], ["s", "a"], ["i", 1], ["f", 1.5], ["a", [["i", 1], ["s", "1"]]], ["h", [["a", ["n"]], ["b", ["i", 1]]]], ["g", "gid://app/User/1"]
      ])
    end

    it "refuses NaN, infinities, symbols, unknown objects, a key clash and a cycle" do
      cycle = []
      cycle << cycle
      [Float::NAN, -Float::INFINITY, :admin, Object.new, { a: 1, "a" => 2 }, { 1 => 2 }, cycle, "\xFF".b].each do |scope|
        expect { described_class.tagged(scope) }.to raise_error(ArgumentError), scope.class.name
      end
    end
  end

  describe "the object" do
    it "is inert from new: the Null encoder refuses to digest" do
      expect { described_class.new.call(message_posted, { "roomId" => 5 }, nil) }.to raise_error(GraphQL::Armory::Encoder::ConfigurationError)
    end

    it "digests through the encoder's mac under the subscription-topic purpose, as 64 hex characters" do
      topic = described_class.build(encoder: encoder)
      answer = topic.call(message_posted, { "roomId" => 5 }, "acme")

      expect(answer).to match(/\A[0-9a-f]{64}\z/).and(eq(digest(message_posted, { "roomId" => 5 }, "acme")))
      expect(encoder.macs.last).to eq(bytes: described_class.canonical(message_posted, { "roomId" => 5 }, "acme").b, purpose: "subscription-topic")
    end

    it "depends on the encoder's key" do
      keyed = Class.new(GraphQL::Armory::Encoder) { key "k" * 32 }
      other = Class.new(GraphQL::Armory::Encoder) { key "o" * 32 }

      expect(described_class.digest(keyed, message_posted, { "roomId" => 5 }, nil)).not_to eq(described_class.digest(other, message_posted, { "roomId" => 5 }, nil))
    end

    it "refuses to build without an encoder that digests" do
      expect { described_class.build(encoder: Object.new) }.to raise_error(subscriptions::ConfigurationError, /encoder/)
      expect { described_class.build(encoder: nil) }.to raise_error(subscriptions::ConfigurationError, /encoder/)
    end
  end
end
