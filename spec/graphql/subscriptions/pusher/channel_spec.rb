# frozen_string_literal: true

require_relative "support"

RSpec.describe "GraphQL::Armory::Subscriptions::Pusher channels and authorization" do
  include PusherSpecSupport

  it "declares its capabilities and the :channel authorization" do
    expect(transport.capabilities).to have_attributes(viewer_bound?: true, max_payload_bytes: 10_240, max_batch: 10, webhooks: :existence, compress?: false)
    expect(build(compress: true).capabilities.compress?).to be(true)
    expect(transport.authorization).to eq(:channel)
  end

  it "names a private channel from the prefix and the id, and reads the id back" do
    channel = transport.channel_for(id, digest)

    expect(channel).to eq("private-graphql-#{id}")
    expect(transport.id_from(channel)).to eq(id)
    expect(build(prefix: "app-1").channel_for(id, digest)).to eq("private-app-1-#{id}")
  end

  it "reads an id only from a channel it named" do
    odd = [nil, 1, "", "graphql-#{id}", "presence-graphql-#{id}", "private-other-#{id}", "private-graphql-", "private-graphql-#{id}\n", "private-graphql-#{id}:x",
           "private-graphql-a b", "private-graphql-#{'a' * 200}", "private-graphql-#{id}#"]

    expect(odd.map { |channel| transport.id_from(channel) }).to all(be_nil)
  end

  it "names no channel for an id it cannot carry" do
    expect([transport.channel_for("a:b", digest), transport.channel_for("", digest), transport.channel_for(nil, digest)]).to all(be_nil)
  end

  # https://pusher.com/docs/channels/library_auth_reference/auth-signatures/
  it "signs a channel for a socket as key:hex(HMAC(secret, socket_id:channel))" do
    channel = transport.channel_for(id, digest)

    expect(transport.authorize_channel(channel: channel, socket_id: "1234.5678")).to eq("auth" => "#{app_key}:#{hmac("1234.5678:#{channel}")}")
  end

  it "refuses a socket_id that is not digits.digits" do
    channel = transport.channel_for(id, digest)
    bad = [nil, "", "1234", "1234.", ".5", "12.34\n", "12.34.56", "a.b", " 1.2", "1.2 ", "1234.5678:x", 12.5]

    expect(bad.map { |socket| transport.authorize_channel(channel: channel, socket_id: socket) }).to all(be_nil)
  end

  it "refuses a channel it did not name" do
    channels = [nil, "private-foobar", "presence-graphql-#{id}", "private-graphql-#{id}\n"]

    expect(channels.map { |c| transport.authorize_channel(channel: c, socket_id: "1.2") }).to all(be_nil)
  end

  it "answers nil to authorize_viewer" do
    expect(transport.authorize_viewer(digest)).to be_nil
  end
end
