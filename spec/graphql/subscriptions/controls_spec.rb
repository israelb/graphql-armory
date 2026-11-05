# frozen_string_literal: true

require "spec_helper"
require "graphql/armory/subscriptions"

RSpec.describe GraphQL::Armory::Subscriptions::Controls do
  let(:subscriptions) { GraphQL::Armory::Subscriptions }
  let(:controls) { described_class }

  describe "ids and digests" do
    it "are deterministic, distinct per index or text, in the shapes the core makes" do
      expect(controls::Id.example).to match(/\A[A-Za-z0-9_-]{43}\z/).and(eq(controls::Id.example(0)))
      expect(controls::Id.example(1)).not_to eq(controls::Id.example(0))
      expect(controls::Digest.example("a")).to match(/\A[0-9a-f]{64}\z/).and(eq(controls::Digest.example("a")))
      expect(controls::Digest.example("b")).not_to eq(controls::Digest.example("a"))
    end
  end

  describe "Record, Capabilities, Store, Transport and Message" do
    it "are valid examples of each value and dependency" do
      expect(controls::Record.example).to be_a(subscriptions::Record)
      expect(controls::Record.example(id: controls::Id.example(2)).id).to eq(controls::Id.example(2))
      expect(controls::Capabilities.example).to be_a(subscriptions::Capabilities)
      expect(controls::Store.example(now: 5)).to be_a(subscriptions::Store::Substitute).and(have_attributes(now: 5))
      expect(controls::Transport.example).to be_a(subscriptions::Transport::Substitute)
      expect(controls::Message.example).to have_attributes(event: "update", payload: { result: { "data" => { "messagePosted" => { "id" => "m1" } } }, more: true })
    end
  end

  describe "Viewer" do
    let(:directory) { controls::Directory.example }
    let(:viewer) { controls::Viewer.example(directory) }

    it "dumps the current user's id and loads it back into the keys it declares" do
      context = {}

      expect(viewer[:dump].call({ current_user: directory.find("user-1") })).to eq("user-1")
      expect(viewer[:dump].call({})).to be_nil
      viewer[:load].call("user-2", context)
      expect(context).to eq(current_user: directory.find("user-2"), current_user_id: "user-2")
      expect(viewer[:sets]).to eq(%i[current_user current_user_id])
    end

    it "loads no one for a user that is gone" do
      context = {}
      directory.remove("user-1")
      viewer[:load].call("user-1", context)

      expect(context).to eq(current_user: nil, current_user_id: nil)
    end
  end

  describe "Schema" do
    let(:directory) { controls::Directory.example }
    let(:schema) { controls::Schema.example(directory: directory, subscriptions: {}, plugin: controls::EventLog) }
    let(:message) { controls::Schema::Message.new(id: "m1", body: "hi", room_id: "5") }
    let(:room) { controls::Schema::Room.new(id: "5", name: "general") }

    def context_for(user, **context)
      { current_user: directory.find(user), current_user_id: user, rate_limit_key: "spec", armory_allow_raw_query: true, **context }
    end

    def run(document, user: "user-1", **context)
      schema.execute(document, context: context_for(user, **context)).to_h
    end

    # Subscribes, then runs what graphql-ruby runs for a trigger: the same document under the event's topic, with the
    # triggered object as root value.
    def deliver(document, object, user: "user-1", **context)
      subscribed = run(document, user: user, **context)
      raise "subscribe failed: #{subscribed["errors"].inspect}" if subscribed["errors"]

      topic = schema.subscriptions.events.last.topic
      schema.execute(document, subscription_topic: topic, root_value: object, context: context_for(user, **context)).to_h
    end

    it "has a Subscription root with an ID, an enum, a Date scalar and an input object with a default, scopes, and both nullabilities" do
      posted = schema.subscription.get_field("messagePosted")
      updated = schema.subscription.get_field("roomUpdated")
      changed = schema.subscription.get_field("inboxChanged")

      expect(posted.arguments.transform_values { |argument| argument.type.to_type_signature }).to eq(
        "roomId" => "ID!", "priority" => "Priority", "on" => "Date", "filter" => "MessageFilter"
      )
      expect(posted.arguments["filter"].default_value).to eq("priority" => "LOW")
      expect(schema.get_type("MessageFilter").arguments.keys).to contain_exactly("priority", "priorities", "window", "minScore")
      expect(schema.get_type("Priority").values.transform_values(&:value)).to eq("LOW" => :low, "HIGH" => :high)
      expect([posted.subscription_scope, updated.subscription_scope, changed.subscription_scope]).to eq([:tenant_id, nil, :current_user_id])
      expect([posted.type.non_null?, updated.type.non_null?, changed.type.non_null?]).to eq([false, true, false])
      expect(updated.arguments.keys).to eq(%w[roomId thread])
    end

    it "installs no subscriptions plugin unless given options, then hands them to the plugin's use" do
      used = []
      plugin = Module.new { define_singleton_method(:use) { |schema, **options| used << [schema, options] } }
      with = controls::Schema.example(subscriptions: { max_lifetime: 60 }, plugin: plugin)

      expect(controls::Schema.example.subscriptions).to be_nil
      expect(used).to eq([[with, { max_lifetime: 60 }]])
      expect(schema.subscriptions).to be_a(controls::EventLog)
    end

    it "exposes its dependencies for assertions" do
      expect(schema.armory_controls).to include(directory: directory, adapter: a_kind_of(controls::Policy),
                                                rate_store: a_kind_of(GraphQL::Armory::RateLimits::Store::Substitute))
    end

    it "runs persisted operations in strict mode and refuses raw ones without the flag" do
      persisted = schema.execute(nil, context: { operation_id: "ping", rate_limit_key: "spec" }).to_h
      raw = schema.execute("query { ping }", context: { rate_limit_key: "spec" }).to_h

      expect(persisted).to eq("data" => { "ping" => "pong" })
      expect(raw["errors"]).not_to be_nil
      expect(raw["data"]).to be_nil
    end

    it "charges the rate limit of a request" do
      run("query { ping }")

      expect(schema.armory_controls[:rate_store].calls.map(&:first)).to include(:take)
    end

    it "hands graphql-ruby's events to the backend on subscribe, scoped by the context key the field names" do
      run("subscription { messagePosted(roomId: 5) { id } }", tenant_id: "acme")
      run("subscription { inboxChanged { unread } }", user: "user-2")

      expect(schema.subscriptions.events.map(&:name)).to eq(%w[messagePosted inboxChanged])
      expect(schema.subscriptions.events.map(&:topic)).to all(be_a(String))
      expect(schema.subscriptions.events.first.topic).to include("acme")
      expect(schema.subscriptions.events.last.topic).to include("user-2")
    end

    it "authorizes the delivered data through the policy: a revoked user gets a null root, or no data for a non-null one" do
      allowed = deliver("subscription { messagePosted(roomId: 5) { id body } }", message)
      directory.revoke("user-1")
      nullable = deliver("subscription { messagePosted(roomId: 5) { id body } }", message)
      non_null = deliver("subscription { roomUpdated(roomId: 5) { name } }", room)

      expect(allowed).to eq("data" => { "messagePosted" => { "id" => "m1", "body" => "hi" } })
      expect(nullable).to eq("data" => { "messagePosted" => nil })
      expect(non_null["data"]).to be_nil
      expect(schema.armory_controls[:adapter].asked.map { |id, subject, rule| [id, subject, rule.action] }).to include(["user-1", controls::Schema::Message, :read])
    end

    it "serves a field from its version on only, and refuses a retired version" do
      latest = deliver("subscription { messagePosted(roomId: 5) { edited } }", message, armory_version: "2025-01-01")
      older = run("subscription { messagePosted(roomId: 5) { edited } }", armory_version: "2024-06-01")
      retired = run("subscription { messagePosted(roomId: 5) { id } }", armory_version: "2024-01-15")

      expect(latest).to eq("data" => { "messagePosted" => { "edited" => false } })
      expect([older["data"], older["errors"]&.size]).to eq([nil, 1])
      expect(retired["data"]).to be_nil
      expect(retired["errors"]).not_to be_empty
    end
  end
end
