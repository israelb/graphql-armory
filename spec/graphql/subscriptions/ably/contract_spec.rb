# frozen_string_literal: true

require_relative "ably_helper"

# The Transport contract of lib/graphql/armory/subscriptions/transport.rb, checked on Ably (focused: U0 has no shared
# transport contract).
RSpec.describe "GraphQL::Armory::Subscriptions::Ably keeps the Transport contract" do
  include AblyHelper

  let(:transport) { ably }

  it "answers the whole interface" do
    %i[capabilities authorization channel_for id_from publish authorize_channel authorize_viewer webhook].each do |name|
      expect(transport).to respond_to(name)
    end
    expect(transport.capabilities).to be_a(subscriptions::Capabilities)
    expect(subscriptions::Transport::AUTHORIZATIONS).to include(transport.authorization)
  end

  it "binds the channel to the viewer as well as the id, and round-trips the id" do
    a = transport.channel_for(id, controls::Digest.example("a"))
    b = transport.channel_for(id, controls::Digest.example("b"))

    expect(a).not_to eq(b)
    expect([transport.id_from(a), transport.id_from(b)]).to eq([id, id])
  end

  it "is viewer bound, so build accepts it with a viewer" do
    expect(transport.capabilities).to be_viewer_bound
  end

  it "publishes within its own declared limits and answers one Outcome per message, by index" do
    capabilities = transport.capabilities
    names = Array.new(capabilities.max_batch) { |index| transport.channel_for(controls::Id.example(index), digest) }
    http.answer(status: 200, body: JSON.generate(names.map { |name| { "channel" => name, "messageId" => "m" } }))

    outcomes = transport.publish(names.map { |name| message(name) })

    expect(outcomes).to all(be_a(subscriptions::Outcome))
    expect(outcomes.map(&:index)).to eq((0...capabilities.max_batch).to_a)
    expect(http.requests.size).to eq(1)
  end

  it "answers :gone only for a gone channel, which Ably never reports on publish" do
    http.answer(status: 404, body: "{}")

    expect(transport.publish([message]).map(&:status)).not_to include(:gone)
  end

  it "answers the mode it implements and nil in the other" do
    expect(transport.authorization).to eq(:viewer)
    expect(transport.authorize_viewer(digest)).to be_a(Hash)
    expect(transport.authorize_channel(channel: channel, socket_id: "1.2")).to be_nil
  end

  it "answers a webhook with [:ok, channels] or [:refused, reason]" do
    verdict = transport.webhook({})

    expect(verdict.first).to eq(:refused)
    expect(verdict.last).to be_a(Symbol)
  end

  it "raises nothing for a provider answer: every failure is an Outcome" do
    [[500, "boom"], [429, ""], [401, "{}"], [200, "garbage"]].each do |status, text|
      http.answer(status: status, body: text)

      expect { transport.publish([message]) }.not_to raise_error
    end
    http.fail_with(subscriptions::TransportError.new("down"))
    expect(transport.publish([message]).map(&:status)).to eq([:retry])
  end
end
