# frozen_string_literal: true

require "spec_helper"
require_relative "../graphql/subscriptions/core/core_helpers"

# Guarantee 4 (unsafe behaviour 4): graphql-ruby fingerprints broadcast groups by topic, query and variables, never by
# viewer, so A's answer reaches B when a field is wrongly `broadcastable: true`. Here nothing is broadcast: every
# subscriber is executed with its own context and its result goes to its own channel only.
RSpec.describe "subscriptions: no broadcast" do
  include SubscriptionsCoreHelpers

  let(:document) { "subscription { inboxChanged { unread } }" }
  let(:inbox) { controls::Schema::Inbox.new(unread: 3) }

  it "runs the same document once per subscriber, each on its own channel, even for a field marked broadcastable" do
    schema.subscription.get_field("inboxChanged").instance_variable_set(:@broadcastable, true)
    ada = subscribed(document, current_user_id: "user-1")
    grace = subscribed(document, user: "user-2", current_user_id: "user-2")
    directory.revoke("user-2")
    schema.armory_controls[:adapter].asked.clear

    backend.trigger(:inbox_changed, {}, inbox, scope: "user-1")
    backend.trigger(:inbox_changed, {}, inbox, scope: "user-2")

    expect(ada).not_to eq(grace)
    expect(payloads(ada)).to eq([{ result: { "data" => { "inboxChanged" => { "unread" => 3 } } }, more: true }])
    expect(payloads(grace)).to eq([{ result: { "data" => { "inboxChanged" => nil } }, more: false }])
    expect(transport.published.map(&:channel)).to eq([ada, grace])
    expect(schema.armory_controls[:adapter].asked.map(&:first)).to eq(%w[user-1 user-2])
  end

  it "answers false to broadcastable? for any query" do
    expect(backend.broadcastable?(document)).to be(false)
  end
end
