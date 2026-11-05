# frozen_string_literal: true

require "spec_helper"
require_relative "../graphql/subscriptions/core/core_helpers"

# A delivery goes through the schema's query class like a request, so Versioning, PersistedQueries and the engine the
# subscriber used decide it the same way.
RSpec.describe "subscriptions: deliveries through the other plugins" do
  include SubscriptionsCoreHelpers

  let(:posted) { "subscription { messagePosted(roomId: 5) { id body } }" }

  describe "Versioning with default: :refuse" do
    # The control types and policy, with Versioning refusing a request that names no version.
    let(:schema) do
      directory = self.directory
      next_options = controls::Schema::NEXT_FIELD_OPTIONS
      types = controls::Schema::Types.example
      root = Class.new(types.fetch(:object)) do
        graphql_name "Subscription"
        authorize :none, reason: "spec", covers_fields: true
        field :message_posted, types.fetch(:message), null: true, subscription_scope: :tenant_id do
          argument :room_id, GraphQL::Types::ID
        end
      end
      query = Class.new(types.fetch(:object)) do
        graphql_name "Query"
        authorize :none, reason: "spec", covers_fields: true
        field :ping, String, null: false, **next_options
      end
      options = controls::Options.example(directory: directory, store: store, transport: transport, viewer: controls::Viewer.example(directory))
      policy = controls::Policy.new(directory)
      armory = GraphQL::Armory
      built = Class.new(GraphQL::Schema) do
        use GraphQL::Execution::Next if defined?(GraphQL::Execution::Next)
        query(query)
        subscription(root)
        use armory::Versioning, versions: armory::Versioning::Controls::Versions::LABELS, retired: armory::Versioning::Controls::Versions::RETIRED, default: :refuse
        use armory::Authorization, adapter: policy
        use armory::Subscriptions, **options
      end
      built.subscriptions.clock = clock
      built.subscriptions.telemetry = telemetry
      built
    end

    it "needs trigger(version:) to find the field, and delivers under the subscriber's stored version" do
      channel = subscribed(posted, armory_version: "2024-06-01")

      expect { backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme") }.to raise_error(GraphQL::Error)
      backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme", version: "2025-01-01")

      expect(payloads(channel)).to eq([{ result: { "data" => { "messagePosted" => { "id" => "m1", "body" => "hi" } } }, more: true }])
      expect(record_of(channel).version).to eq("2024-06-01")
    end

    it "refuses an unknown version: label" do
      expect { backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme", version: "1999-01-01") }.to raise_error(GraphQL::Error)
    end
  end

  describe "PersistedQueries strict" do
    it "accepts the delivery of a persisted subscription, which runs no raw query" do
      result = execute_query(schema, nil, context: context_for("user-1", operation_id: "message-posted", armory_allow_raw_query: false), variables: { "roomId" => "5" })
      channel = backend.channel_for(result)
      backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

      expect(payloads(channel)).to eq([{ result: { "data" => { "messagePosted" => { "id" => "m1", "body" => "hi" } } }, more: true }])
      expect(record_of(channel)).to have_attributes(operation_id: "message-posted", raw_query: false)
    end

    it "refuses a raw subscription without the flag, so none is created" do
      result = subscribe(posted, armory_allow_raw_query: false)

      expect(codes(result)).to eq(["RAW_QUERY_REFUSED"])
      expect(store.records).to be_empty
    end
  end

  describe "the engine" do
    it "delivers a subscription on the engine it was created on" do
      skip "Execution::Next needs graphql >= 2.6.2" unless ArmoryEngine.supported?

      next_channel = schema.subscriptions.channel_for(schema.execute_next(posted, context: context_for("user-1")))
      interpreter_channel = schema.subscriptions.channel_for(schema.execute(posted, context: context_for("user-2")))
      backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

      expect([record_of(next_channel).engine, record_of(interpreter_channel).engine]).to eq(%i[next interpreter])
      expect([payloads(next_channel).size, payloads(interpreter_channel).size]).to eq([1, 1])
      expect(payloads(next_channel).first[:result]).to eq("data" => { "messagePosted" => { "id" => "m1", "body" => "hi" } })
    end

    it "ends a Next subscription that loses access, like an interpreter one" do
      skip "Execution::Next needs graphql >= 2.6.2" unless ArmoryEngine.supported?

      channel = schema.subscriptions.channel_for(schema.execute_next(posted, context: context_for("user-1")))
      directory.revoke("user-1")
      backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

      expect(payloads(channel)).to eq([{ result: { "data" => { "messagePosted" => nil } }, more: false }])
      expect(store.records).to be_empty
    end
  end
end
