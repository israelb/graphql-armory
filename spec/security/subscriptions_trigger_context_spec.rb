# frozen_string_literal: true

require "spec_helper"
require_relative "../graphql/subscriptions/core/core_helpers"

# Guarantee 1 (unsafe behaviour 1): graphql-ruby's execute_update merges the trigger's `context:` over each subscriber's
# stored context, so a trigger could re-run every subscriber as another actor or another API version. A delivery here
# runs with the subscriber's own context only: the stored allow-listed keys and the reloaded viewer.
RSpec.describe "subscriptions: a delivery runs as its subscriber, never as the trigger" do
  include SubscriptionsCoreHelpers

  let(:posted) { "subscription { messagePosted(roomId: 5) { id body } }" }

  it "raises on a trigger with a non-empty context:, delivering nothing" do
    channel = subscribed(posted)

    expect { backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme", context: { current_user: directory.find("user-2") }) }
      .to raise_error(ArgumentError, /context: is refused/)
    expect { backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme", context: { armory_version: "2024-06-01" }) }
      .to raise_error(ArgumentError, /context: is refused/)
    expect(payloads(channel)).to be_empty
  end

  it "reloads each subscriber as itself: each one's own policy decision reaches its own channel" do
    ada = subscribed(posted)
    grace = subscribed(posted, user: "user-2")
    directory.revoke("user-2")
    policy = schema.armory_controls[:adapter]
    policy.asked.clear

    backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

    expect(payloads(ada)).to eq([{ result: { "data" => { "messagePosted" => { "id" => "m1", "body" => "hi" } } }, more: true }])
    expect(payloads(grace)).to eq([{ result: { "data" => { "messagePosted" => nil } }, more: false }])
    expect(policy.asked.map(&:first).uniq).to contain_exactly("user-1", "user-2")
  end

  it "never takes a key the subscribe request had beyond context_keys: and the viewer" do
    channel = subscribed(posted, current_user_id: "user-2", armory_version: "2025-01-01", impersonate: "user-2")
    record = record_of(channel)

    expect(record.context.keys).to eq(["tenant_id"])
    expect(record.viewer_id).to eq("user-1")
  end
end
