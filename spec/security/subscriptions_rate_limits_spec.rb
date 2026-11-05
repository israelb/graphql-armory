# frozen_string_literal: true

require "spec_helper"
require_relative "../graphql/subscriptions/core/core_helpers"

# Guarantee 9: a delivery never charges the subscriber's rate-limit budget (whoever causes triggers could otherwise
# drain another user's budget), while the subscribe request is charged like any other and the analyzers still refuse
# an over-cost delivery, which ends the subscription.
RSpec.describe "subscriptions: rate limits" do
  include SubscriptionsCoreHelpers

  let(:posted) { "subscription { messagePosted(roomId: 5) { id body } }" }
  let(:rate_store) { schema.armory_controls[:rate_store] }

  it "charges the subscribe request, and no delivery" do
    channel = subscribed(posted)
    charged = rate_store.calls.map { |call| [call.first, call[1]] }
    rate_store.calls.clear
    3.times { backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme") }

    expect(charged).to eq([[:take, "client:user-1"]])
    expect(payloads(channel).size).to eq(3)
    expect(rate_store.calls).to be_empty
  end

  it "delivers to a subscriber whose budget is spent" do
    schema = build_schema(schema_options: { rate_limit: 3 }) # the subscribe below costs 3 points
    channel = schema.subscriptions.channel_for(subscribe(posted, on: schema))
    refused = subscribe("subscription { messagePosted(roomId: 6) { id } }", on: schema)
    schema.subscriptions.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

    expect(codes(refused)).to include("RATE_LIMITED")
    expect(payloads(channel).size).to eq(1)
  end

  it "still refuses an over-cost delivery through the analyzers, ending the subscription" do
    channel = subscribed(posted)
    schema.max_complexity(1)
    backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

    expect(payloads(channel).size).to eq(1)
    expect(payloads(channel).first).to include(more: false)
    expect(payloads(channel).first[:result]["errors"].first["message"]).to include("max complexity")
    expect(store.records).to be_empty
  end
end
