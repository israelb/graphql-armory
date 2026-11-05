# frozen_string_literal: true

require "spec_helper"
require_relative "../graphql/subscriptions/core/core_helpers"

# Guarantee 5: a channel is authorized only for the viewer that created it. The subscription id is unguessable, but
# on a hosted transport it is a bearer token visible to anything that logs headers, so the core matches the stored
# viewer digest against the requester's (in constant time) before the transport signs anything.
RSpec.describe "subscriptions: channel and viewer authorization" do
  include SubscriptionsCoreHelpers

  let(:posted) { "subscription { messagePosted(roomId: 5) { id } }" }

  it "authorizes the owner's channel and refuses a stranger who knows its name" do
    channel = subscribed(posted)

    expect(backend.authorize_channel(channel: channel, socket_id: "1.1", context: context_for("user-1"))).to eq(auth: "substitute:1.1:#{channel}")
    expect(backend.authorize_channel(channel: channel, socket_id: "1.1", context: context_for("user-2"))).to be_nil
    expect(backend.authorize_channel(channel: channel, socket_id: "1.1", context: { current_user: nil })).to be_nil
    expect(transport.calls.count { |call| call.first == :authorize_channel }).to eq(1)
  end

  it "refuses a channel name that pairs the owner's id with the stranger's digest" do
    channel = subscribed(posted)
    stranger = backend.encoder.mac("user-2", purpose: "subscription-viewer").unpack1("H*")
    forged = transport.channel_for(transport.id_from(channel), stranger)

    expect(backend.authorize_channel(channel: forged, socket_id: "1.1", context: context_for("user-2"))).to be_nil
  end

  it "gives a per-viewer transport credentials for the requester's own digest only" do
    per_viewer = controls::Transport.example(authorization: :viewer)
    schema = controls::Schema.example(directory: directory, subscriptions: controls::Options.example(directory: directory, store: store, transport: per_viewer))
    ada = schema.subscriptions.authorize_viewer(context: context_for("user-1"))
    grace = schema.subscriptions.authorize_viewer(context: context_for("user-2"))
    channel = schema.subscriptions.channel_for(execute_query(schema, posted, context: context_for("user-1")))

    expect(ada).not_to eq(grace)
    expect(channel).to include(ada[:token].delete_prefix("substitute:"))
    expect(channel).not_to include(grace[:token].delete_prefix("substitute:"))
    expect(schema.subscriptions.authorize_viewer(context: {})).to be_nil
  end
end
