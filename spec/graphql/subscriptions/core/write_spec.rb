# frozen_string_literal: true

require "spec_helper"
require_relative "core_helpers"

# write_subscription: what subscribing stores, and what it refuses.
RSpec.describe "GraphQL::Armory::Subscriptions::Core#write_subscription" do
  include SubscriptionsCoreHelpers

  let(:subscriptions) { GraphQL::Armory::Subscriptions }
  let(:posted) { "subscription { messagePosted(roomId: 5) { id body } }" }

  it "stores a sealed record with a server-made id and exposes its viewer-bound channel" do
    result = subscribe(posted)
    channel = backend.channel_for(result)
    id = transport.id_from(channel)
    record = record_of(channel)
    viewer_digest = backend.encoder.mac("user-1", purpose: "subscription-viewer").unpack1("H*")

    expect(result.to_h["errors"]).to be_nil
    expect(id).to match(/\A[A-Za-z0-9_-]{43}\z/)
    expect(result.context[:subscription_id]).to eq(id)
    expect(channel).to eq(transport.channel_for(id, viewer_digest))
    expect(result.to_h.dig("extensions", "subscription", "channel")).to eq(channel)
    expect(store.records.fetch(id)).not_to include("user-1")
    expect(record).to have_attributes(
      id: id, document: posted, operation_name: nil, variables: "{}", operation_id: nil, raw_query: true, version: "2025-01-01",
      visibility_profile: nil, engine: ArmoryEngine.next? ? :next : :interpreter, viewer_id: "user-1", viewer_digest: viewer_digest,
      context: { "tenant_id" => '"acme"' }, created_at: SubscriptionsCoreHelpers::START, expires_at: SubscriptionsCoreHelpers::START + 3_600_000
    )
    expect(record.events.size).to eq(1)
    expect(record.events.first.graphql_topic).to include("messagePosted")
    write = store.calls.find { |call| call.first == :write }
    expect(write.last).to include(topics: record.topics, viewer: viewer_digest, viewer_cap: 100, topic_cap: 10_000, now: SubscriptionsCoreHelpers::START,
                                  expires_at: record.expires_at)
  end

  it "digests the topic from the field's arguments and scope through the encoder" do
    channel = subscribed(posted, tenant: "acme")
    field = schema.subscription.get_field("messagePosted")

    expect(record_of(channel).topics).to eq([subscriptions::Topic.digest(backend.encoder, field, { room_id: "5" }, "acme")])
  end

  it "stores the persisted operation's id and printed document, without the raw-query flag" do
    result = execute_query(schema, nil, context: context_for("user-1", operation_id: "message-posted", armory_allow_raw_query: false), variables: { "roomId" => "5" })
    record = record_of(backend.channel_for(result))

    expect(result.to_h["errors"]).to be_nil
    expect(record).to have_attributes(operation_id: "message-posted", raw_query: false, operation_name: "MessagePosted", variables: '{"roomId":"5"}')
    expect(record.document).to eq(controls::Schema.example.armory_controls[:manifest].fetch("message-posted").document.to_query_string)
  end

  it "stores the version Versioning decided, not the raw armory_version" do
    record = record_of(subscribed(posted, armory_version: "2024-06-01"))

    expect(record.version).to eq("2024-06-01")
  end

  it "stores only the context keys it was given, each as Serialize dumps it" do
    schema = build_schema(context_keys: { tenant_id: "scopes messages", region: "picks the replica" })
    result = subscribe(posted, on: schema, secret_token: "s3cr3t", tenant: { "id" => 7 }, region: :eu)
    record = record_of(schema.subscriptions.channel_for(result))

    expect(record.context.keys).to contain_exactly("tenant_id", "region")
    expect(record.context.transform_values { |dumped| GraphQL::Subscriptions::Serialize.load(dumped) }).to eq("tenant_id" => { "id" => 7 }, "region" => :eu)
    expect(record_of(schema.subscriptions.channel_for(result)).to_h.to_s).not_to include("s3cr3t")
  end

  it "refuses a context key value that does not come back the same from Serialize, storing nothing" do
    schema = build_schema(context_keys: { tenant_id: "scopes messages", region: "picks the replica" })
    result = subscribe(posted, on: schema, region: Object.new)
    backend = schema.subscriptions

    expect(codes(result)).to eq(["SUBSCRIPTION_REFUSED"])
    expect([store.records, backend.channel_for(result), result.context[:subscription_id]]).to eq([{}, nil, nil])
    expect(signals(:subscription_refused)).to eq([{ reason: :context }])
  end

  it "refuses a subscription_id the app or the client put in the context" do
    result = subscribe(posted, subscription_id: controls::Id.example)

    expect(codes(result)).to eq(["SUBSCRIPTION_REFUSED"])
    expect(store.records).to be_empty
    expect(signals(:subscription_refused)).to eq([{ reason: :client_id }])
  end

  it "refuses a viewer that does not dump to a non-empty String" do
    result = subscribe(posted, current_user: nil)

    expect(codes(result)).to eq(["SUBSCRIPTION_REFUSED"])
    expect(signals(:subscription_refused)).to eq([{ reason: :viewer }])
    expect(store.records).to be_empty
  end

  it "refuses a subscription over the viewer's cap or the topic's cap with SUBSCRIPTION_LIMIT" do
    schema = build_schema(max_per_viewer: 2, max_per_topic: 3)
    2.times { subscribe(posted, on: schema) }
    over_viewer = subscribe(posted, on: schema)
    subscribe(posted, user: "user-2", on: schema)
    over_topic = subscribe(posted, user: "user-2", on: schema)

    expect([codes(over_viewer), codes(over_topic)]).to eq([["SUBSCRIPTION_LIMIT"], ["SUBSCRIPTION_LIMIT"]])
    expect(over_viewer.to_h["errors"].first["message"]).to eq("Too many subscriptions")
    expect(signals(:subscription_refused)).to eq([{ reason: :viewer_cap }, { reason: :topic_cap }])
    expect(store.records.size).to eq(3)
  end

  it "counts an anonymous subscription against its cap_key's digest" do
    schema = build_schema(viewer: nil, anonymous: "public room feed", cap_key: ->(context) { context[:ip] },
                          context_keys: { tenant_id: "x", current_user_id: "x" }, max_per_viewer: 1)
    first = subscribe(posted, on: schema, ip: "10.0.0.1")
    second = subscribe(posted, on: schema, ip: "10.0.0.1")
    other = subscribe(posted, on: schema, ip: "10.0.0.2")
    nameless = subscribe(posted, on: schema)

    expect([codes(first), codes(second), codes(other), codes(nameless)]).to eq([[], ["SUBSCRIPTION_LIMIT"], [], ["SUBSCRIPTION_REFUSED"]])
    expect(record_of(schema.subscriptions.channel_for(first))).to have_attributes(viewer_id: nil, viewer_digest: "anonymous")
    expect(store.calls.select { |call| call.first == :write }.map { |call| call.last[:viewer] }.uniq.size).to eq(2)
    expect(signals(:subscription_refused).last).to eq(reason: :cap_key)
  end

  it "refuses when the store fails, and records it" do
    store.fail_with(IOError.new("down"), on: :write)
    result = subscribe(posted)

    expect(codes(result)).to eq(["SUBSCRIPTION_REFUSED"])
    expect(signals(:subscription_refused)).to eq([{ reason: :store }])
  end

  it "records the creation without an id, a viewer or a document" do
    subscribe(posted)

    expect(signals(:subscription_created)).to eq([{ engine: ArmoryEngine.next? ? :next : :interpreter, events: 1 }])
  end
end
