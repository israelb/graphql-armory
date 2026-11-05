# frozen_string_literal: true

require_relative "support"

RSpec.describe "GraphQL::Armory::Subscriptions::Pusher#webhook" do
  include PusherSpecSupport

  let(:channel) { transport.channel_for(id, digest) }

  # https://pusher.com/docs/channels/server_api/webhooks/ (X-Pusher-Key, X-Pusher-Signature, channel_vacated, time_ms)
  it "answers the subscription channels of channel_vacated events" do
    other = transport.channel_for(id(1), digest)

    expect(transport.webhook(rack_env(webhook_body([channel, other])))).to eq([:ok, [channel, other]])
  end

  it "answers each channel once and leaves out channels it did not name" do
    expect(transport.webhook(rack_env(webhook_body([channel, "private-foobar", channel])))).to eq([:ok, [channel]])
  end

  it "ignores events other than channel_vacated" do
    expect(transport.webhook(rack_env(webhook_body([channel], name: "channel_occupied")))).to eq([:ok, []])
  end

  it "leaves the body readable after it (the app may need it)" do
    env = rack_env(webhook_body([channel]))
    transport.webhook(env)

    expect(env["rack.input"].read).to eq(webhook_body([channel]))
  end

  it "refuses a bad signature, a missing signature and a signature of another secret" do
    body = webhook_body([channel])
    forged = OpenSSL::HMAC.hexdigest("SHA256", "other", body)

    expect(transport.webhook(rack_env(body, signature: forged))).to eq([:refused, :bad_signature])
    expect(transport.webhook(rack_env(body, signature: nil))).to eq([:refused, :bad_signature])
    expect(transport.webhook(rack_env(body, signature: hmac(body)[0, 10]))).to eq([:refused, :bad_signature])
    expect(transport.webhook(rack_env("#{body} ", signature: hmac(body)))).to eq([:refused, :bad_signature])
  end

  it "refuses another key, or none" do
    body = webhook_body([channel])

    expect(transport.webhook(rack_env(body, key: "other"))).to eq([:refused, :wrong_key])
    expect(transport.webhook(rack_env(body, key: nil))).to eq([:refused, :wrong_key])
  end

  it "refuses a body over 1 MB, whatever Content-Length says" do
    body = "x" * ((1024 * 1024) + 1)

    expect(transport.webhook(rack_env(body))).to eq([:refused, :too_large])
    expect(transport.webhook(rack_env(body, extra: { "CONTENT_LENGTH" => "5" }))).to eq([:refused, :too_large])
  end

  it "refuses an event older than 5 minutes and accepts one just inside" do
    old = webhook_body([channel], time_ms: (now * 1000) - (5 * 60 * 1000) - 1)
    fresh = webhook_body([channel], time_ms: (now * 1000) - (5 * 60 * 1000))

    expect(transport.webhook(rack_env(old))).to eq([:refused, :stale])
    expect(transport.webhook(rack_env(fresh))).to eq([:ok, [channel]])
  end

  it "refuses a signed body that is not a webhook" do
    ["not json", "[]", '{"events":[]}', '{"time_ms":"x","events":[]}', %({"time_ms":#{now * 1000},"events":{}})].each do |body|
      expect(transport.webhook(rack_env(body))).to eq([:refused, :malformed])
    end
  end

  it "refuses everything when it was not given a secret" do
    expect(GraphQL::Armory::Subscriptions::Pusher.new.webhook(rack_env(webhook_body([channel])))).to eq([:refused, :not_configured])
  end
end
