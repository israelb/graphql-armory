# frozen_string_literal: true

require "spec_helper"
require_relative "../graphql/subscriptions/core/core_helpers"

# Guarantee 8: every record ends by max_lifetime at the latest. No provider reports a gone client reliably, so the
# lifetime is required, the record carries its expiry, and an expired record is never run: the client gets
# `{ more: false }` and re-subscribes. Webhooks only bring the end forward.
RSpec.describe "subscriptions: lifetime" do
  include SubscriptionsCoreHelpers

  let(:posted) { "subscription { messagePosted(roomId: 5) { id } }" }

  it "stamps every record with created_at + max_lifetime and hands the store that expiry" do
    channel = subscribed(posted)

    expect(record_of(channel).expires_at).to eq(SubscriptionsCoreHelpers::START + 3_600_000)
    expect(store.calls.find { |call| call.first == :write }.last[:expires_at]).to eq(SubscriptionsCoreHelpers::START + 3_600_000)
  end

  it "ends an expired subscription with { more: false } at its next trigger, running nothing, even if the store still answers it" do
    channel = subscribed(posted)
    clock.advance(3_600_000)
    store.answer(:ids, [transport.id_from(channel)])
    schema.armory_controls[:adapter].asked.clear

    backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

    expect(payloads(channel)).to eq([{ more: false }])
    expect(schema.armory_controls[:adapter].asked).to be_empty
    expect(store.records).to be_empty
  end

  it "refuses channel authorization once expired, and cleanup removes it" do
    channel = subscribed(posted)
    clock.advance(3_600_000)

    expect(backend.authorize_channel(channel: channel, socket_id: "1.1", context: context_for("user-1"))).to be_nil
    expect(backend.cleanup).to eq(1)
    expect(store.records).to be_empty
  end

  it "ends a subscription early on a verified gone webhook, never later" do
    channel = subscribed(posted)
    transport.answer(:webhook, [:ok, [channel]])
    backend.webhook({})

    expect(store.records).to be_empty
  end
end
