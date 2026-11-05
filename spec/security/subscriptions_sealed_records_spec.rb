# frozen_string_literal: true

require "spec_helper"
require_relative "../graphql/subscriptions/core/core_helpers"

# Guarantee 7: a stored record cannot be forged into one that loads other records. Records are sealed (AES-GCM, the
# subscription id as additional data), so whoever can write the store cannot make `Serialize.load` locate arbitrary
# records or re-run a query as someone else: a record that does not open is deleted and recorded, never loaded.
RSpec.describe "subscriptions: sealed records" do
  include SubscriptionsCoreHelpers

  let(:posted) { "subscription { messagePosted(roomId: 5) { id body } }" }

  def forged_record(channel, **changes)
    record = record_of(channel)
    GraphQL::Armory::Subscriptions::Record.new(**record.to_h.except("v").transform_keys(&:to_sym).merge(engine: record.engine, events: record.events), **changes)
  end

  it "deletes a record sealed with another key, never running it" do
    channel = subscribed(posted)
    id = transport.id_from(channel)
    forged = forged_record(channel, viewer_id: "user-2", viewer_digest: controls::Digest.example("x"), variables: '{"__gid__":"gid://app/User/1"}')
    sealed = controls::AppEncoder.example("another-key-that-is-long-enough-for-aes").seal(JSON.generate(forged.to_h), aad: id, purpose: "subscription")
    store.poison(id, sealed, topics: forged.topics, viewer: "x")
    schema.armory_controls[:adapter].asked.clear

    backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

    expect(payloads(channel)).to be_empty
    expect(store.records).to be_empty
    expect(schema.armory_controls[:adapter].asked).to be_empty
    expect(signals(:subscription_record_unreadable).size).to eq(1)
  end

  it "deletes a genuine record moved under another id (the id is sealed in), keeping the original" do
    victim = subscribed(posted, user: "user-2")
    attacker = subscribed(posted)
    store.poison(transport.id_from(attacker), store.records.fetch(transport.id_from(victim)), topics: record_of(victim).topics, viewer: "x")

    backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

    expect([payloads(victim).size, payloads(attacker).size]).to eq([1, 0])
    expect(store.records.keys).to eq([transport.id_from(victim)])
  end

  it "keeps no viewer, document or context value in clear in the store" do
    subscribed(posted, tenant: "acme-secret-tenant")

    expect(store.records.values.join).not_to include("user-1", "messagePosted", "acme-secret-tenant")
  end
end
