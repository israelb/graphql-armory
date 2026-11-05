# frozen_string_literal: true

require "spec_helper"
require_relative "../graphql/subscriptions/core/core_helpers"

# Guarantee 3 (unsafe behaviour 3): in graphql-ruby a failed `authorized?` on an update delivers an error and keeps the
# subscription, re-run on every trigger. Here a subscriber that lost access stops receiving data at the next trigger
# and is unsubscribed: the delivery ends on a result without data or with a null root field.
RSpec.describe "subscriptions: a subscriber that loses access" do
  include SubscriptionsCoreHelpers

  let(:posted) { "subscription { messagePosted(roomId: 5) { id body } }" }

  def trigger_twice
    2.times { backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme") }
  end

  it "is unsubscribed at the next trigger when revoked, with on_unauthorized: :null (a null root, no error)" do
    channel = subscribed(posted)
    directory.revoke("user-1")
    trigger_twice

    expect(payloads(channel)).to eq([{ result: { "data" => { "messagePosted" => nil } }, more: false }])
    expect(store.records).to be_empty
    expect(signals(:subscription_ended).map { |data| data[:reason] }).to eq([:refused])
  end

  it "is unsubscribed at the next trigger when revoked, with on_unauthorized: :error" do
    schema = build_schema(schema_options: { on_unauthorized: :error })
    channel = schema.subscriptions.channel_for(subscribe(posted, on: schema))
    directory.revoke("user-1")
    2.times { schema.subscriptions.trigger(:message_posted, { room_id: 5 }, message, scope: "acme") }

    expect(payloads(channel).size).to eq(1)
    expect(payloads(channel).first).to include(more: false)
    expect(payloads(channel).first[:result]["data"]).to eq("messagePosted" => nil).or(be_nil)
    expect(payloads(channel).first[:result]["errors"]).not_to be_empty
    expect(store.records).to be_empty
  end

  it "is unsubscribed when its non-null root is denied (no data at all)" do
    channel = subscribed("subscription { roomUpdated(roomId: 5) { name } }")
    directory.revoke("user-1")
    2.times { backend.trigger(:room_updated, { room_id: 5 }, room) }

    expect(payloads(channel).map { |payload| payload[:more] }).to eq([false])
    expect(payloads(channel).first[:result]["data"]).to be_nil
    expect(store.records).to be_empty
  end

  it "ends with :viewer_gone, sending no data, when the viewer no longer loads" do
    channel = subscribed(posted)
    directory.remove("user-1")
    trigger_twice

    expect(payloads(channel)).to eq([{ more: false }])
    expect(store.records).to be_empty
    expect(signals(:subscription_ended)).to match([{ reason: :viewer_gone, subscription: a_string_matching(/\A[0-9a-f]{16}\z/) }])
  end

  it "keeps the subscriptions of everyone else" do
    subscribed(posted)
    kept = subscribed(posted, user: "user-2")
    directory.revoke("user-1")
    trigger_twice

    expect(payloads(kept).size).to eq(2)
    expect(store.records.keys).to eq([transport.id_from(kept)])
  end
end
