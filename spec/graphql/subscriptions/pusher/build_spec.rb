# frozen_string_literal: true

require_relative "support"

RSpec.describe "GraphQL::Armory::Subscriptions::Pusher.build and .new" do
  include PusherSpecSupport

  let(:pusher) { GraphQL::Armory::Subscriptions::Pusher }

  it "is inert when made with new: names no channel and refuses everything" do
    inert = pusher.new

    expect(inert.channel_for(id, digest)).to be_nil
    expect(inert.id_from("private-graphql-#{id}")).to be_nil
    expect(inert.publish([message("private-graphql-x")]).map { |o| [o.status, o.reason] }).to eq([[:refused, :not_configured]])
    expect(inert.authorize_channel(channel: "private-graphql-x", socket_id: "1.2")).to be_nil
    expect(inert.webhook({})).to eq([:refused, :not_configured])
  end

  it "defaults to an http client that raises, so new reaches no provider" do
    configured = pusher.new(app_id: app_id, key: app_key, secret: secret)

    expect(configured.publish([message("private-graphql-x")]).map(&:status)).to eq([:retry])
  end

  it "wires a real Http client in build" do
    expect(pusher.build(app_id: app_id, key: app_key, secret: secret).http).to be_a(GraphQL::Armory::Subscriptions::Http)
  end

  it "refuses invalid settings with ConfigurationError, never quoting the secret" do
    error = GraphQL::Armory::Subscriptions::ConfigurationError
    good = { app_id: app_id, key: app_key, secret: secret }
    bad = [{ app_id: nil }, { app_id: "a/b" }, { key: "" }, { key: "a:b" }, { secret: nil }, { secret: 12 }, { cluster: "EU/x" }, { host: "a b" }, { host: "x", scheme: "ftp" },
           { prefix: "a:b" }, { prefix: "" }, { compress: "yes" }, { http: Object.new }, { cluster: "eu", host: "x.test" }]

    bad.each do |override|
      expect { pusher.build(**good, **override) }.to raise_error(error) { |e| expect(e.message).not_to include(secret) }
    end
  end

  it "does not show the secret in inspect" do
    expect(transport.inspect).not_to include(secret)
  end
end
