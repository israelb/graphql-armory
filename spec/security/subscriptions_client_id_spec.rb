# frozen_string_literal: true

require "spec_helper"
require_relative "../graphql/subscriptions/core/core_helpers"

# Guarantee 6: a client cannot choose its subscription id. graphql-ruby's ActionCable backend takes
# `context[:subscription_id] ||= build_id`, so a client whose request copies that key picks a victim's id. Here an id
# already in the context refuses the subscription; the id is always the server's.
RSpec.describe "subscriptions: server-made ids" do
  include SubscriptionsCoreHelpers

  let(:posted) { "subscription { messagePosted(roomId: 5) { id } }" }

  it "refuses a subscription whose context already holds a subscription_id, keeping the victim's record" do
    victim = subscribed(posted, user: "user-2")
    victim_id = transport.id_from(victim)
    result = subscribe(posted, subscription_id: victim_id)

    expect(codes(result)).to eq(["SUBSCRIPTION_REFUSED"])
    expect(backend.channel_for(result)).to be_nil
    expect(store.records.keys).to eq([victim_id])
    expect(record_of(victim).viewer_id).to eq("user-2")
  end

  it "makes a fresh 32-byte id for every subscription" do
    ids = Array.new(3) { transport.id_from(subscribed(posted)) }

    expect(ids.uniq.size).to eq(3)
    expect(ids).to all(match(/\A[A-Za-z0-9_-]{43}\z/))
  end
end
