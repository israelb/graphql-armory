# frozen_string_literal: true

require_relative "support"

# The Transport contract (lib/graphql/armory/subscriptions/transport.rb), checked against Pusher.
RSpec.describe "GraphQL::Armory::Subscriptions::Pusher keeps the Transport contract" do
  include PusherSpecSupport

  it "answers the whole interface" do
    expect(transport).to respond_to(:capabilities, :authorization, :channel_for, :id_from, :publish, :authorize_channel, :authorize_viewer, :webhook)
    expect(transport.capabilities).to be_a(GraphQL::Armory::Subscriptions::Capabilities)
    expect(GraphQL::Armory::Subscriptions::Transport::AUTHORIZATIONS).to include(transport.authorization)
  end

  it "binds channel_for and id_from as inverse functions" do
    ids = Array.new(5) { |index| id(index) }

    expect(ids.map { |each| transport.id_from(transport.channel_for(each, digest)) }).to eq(ids)
  end

  it "answers one Outcome per message, by index" do
    outcomes = transport.publish(Array.new(3) { message })

    expect(outcomes).to all(be_a(GraphQL::Armory::Subscriptions::Outcome))
    expect(outcomes.map(&:index)).to eq([0, 1, 2])
  end

  it "never raises for a provider answer or a provider failure" do
    [200, 400, 401, 403, 413, 429, 500].each do |status|
      http.answer(status: status)
      expect { transport.publish([message]) }.not_to raise_error
    end
    http.fail_with(GraphQL::Armory::Subscriptions::TransportError.new("x"))
    expect { transport.publish([message]) }.not_to raise_error
  end

  it "never answers :gone (Pusher does not say a channel is gone on publish)" do
    [200, 404, 410, 500].each do |status|
      http.answer(status: status)
      expect(transport.publish([message]).map(&:status)).not_to include(:gone)
    end
  end

  it "answers the webhook shapes the core reads" do
    ok = transport.webhook(rack_env(webhook_body([transport.channel_for(id, digest)])))
    refused = transport.webhook(rack_env("{}", signature: "0"))

    expect(ok.first).to eq(:ok)
    expect(ok.last).to all(be_a(String))
    expect(refused.first).to eq(:refused)
    expect(refused.last).to be_a(Symbol)
  end
end
