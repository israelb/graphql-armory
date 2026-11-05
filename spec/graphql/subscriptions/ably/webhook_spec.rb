# frozen_string_literal: true

require_relative "ably_helper"
require "stringio"

RSpec.describe "GraphQL::Armory::Subscriptions::Ably#webhook" do
  include AblyHelper

  # https://ably.com/docs/platform/integrations/webhooks : X-Ably-Key names the key, X-Ably-Signature is the base64
  # HMAC-SHA256 of the raw body under the key secret. A batched presence body is {"items" => [{"source" =>
  # "channel.presence", "timestamp" => ms, "data" => {"channelId" => ..., "presence" => [{"action" => 3, ...}]}}]};
  # a presence action is the number of https://ably.com/docs/api/realtime-sdk/presence (enter 2, leave 3, update 4)
  # or, decoded by an SDK, its name.
  def item(channel, action, timestamp: AblyHelper::NOW_MS, client: "graphql-subscriber")
    { "webhookId" => "w1", "source" => "channel.presence", "serial" => "1", "timestamp" => timestamp, "name" => "presence.message",
      "data" => { "channelId" => channel, "site" => "eu-west-1-A", "presence" => [{ "clientId" => client, "action" => action, "timestamp" => timestamp }] } }
  end

  def body(*items) = JSON.generate("items" => items)

  def env(raw, key: AblyHelper::KEY_NAME, secret: AblyHelper::KEY_SECRET, signature: nil, length: nil)
    headers = {
      "HTTP_X_ABLY_KEY" => key,
      "HTTP_X_ABLY_SIGNATURE" => signature || base64_hmac(secret, raw),
      "CONTENT_LENGTH" => (length || raw.bytesize).to_s,
      "rack.input" => StringIO.new(raw)
    }
    headers.compact
  end

  it "answers the subscription channels whose clients left (any clientId)" do
    other = ably.channel_for(controls::Id.example(1), digest)
    raw = body(item(channel, 3), item(other, "leave", client: "someone-else"))

    expect(ably.webhook(env(raw))).to eq([:ok, [channel, other]])
  end

  it "reports a channel once" do
    expect(ably.webhook(env(body(item(channel, 3), item(channel, 3))))).to eq([:ok, [channel]])
  end

  it "answers no channel for events that are not a leave: enter, update, present" do
    raw = body(item(channel, 2), item(channel, 4), item(channel, 1), item(channel, "enter"))

    expect(ably.webhook(env(raw))).to eq([:ok, []])
  end

  it "ignores channels it would not have named: another prefix, another shape" do
    foreign = "other:#{digest}:#{controls::Id.example(2)}"
    raw = body(item(foreign, 3), item("graphql:not-a-digest:#{id}", 3), item("graphql", 3), item(channel, 3))

    expect(ably.webhook(env(raw))).to eq([:ok, [channel]])
  end

  it "reads the single (not batched) enveloped presence shape too" do
    raw = JSON.generate("source" => "channel.presence", "channel" => channel, "timestamp" => AblyHelper::NOW_MS,
                        "presence" => [{ "clientId" => "c", "action" => 3, "timestamp" => AblyHelper::NOW_MS }])

    expect(ably.webhook(env(raw))).to eq([:ok, [channel]])
  end

  it "ignores other event sources" do
    raw = JSON.generate("items" => [{ "source" => "channel.message", "timestamp" => AblyHelper::NOW_MS, "data" => { "channelId" => channel } }])

    expect(ably.webhook(env(raw))).to eq([:ok, []])
  end

  it "accepts the key by its full name or by its key id part" do
    raw = body(item(channel, 3))

    expect(ably.webhook(env(raw, key: "keyId"))).to eq([:ok, [channel]])
    expect(ably.webhook(env(raw, key: "appId.keyId"))).to eq([:ok, [channel]])
  end

  describe "refused" do
    let(:raw) { body(item(channel, 3)) }

    it "when the key is not ours or is missing" do
      expect(ably.webhook(env(raw, key: "appId.other"))).to eq([:refused, :unknown_key])
      expect(ably.webhook(env(raw, key: "keyId.x"))).to eq([:refused, :unknown_key])
      expect(ably.webhook(env(raw, key: nil))).to eq([:refused, :unknown_key])
    end

    it "when the signature is missing, wrong, from another secret, or for another body" do
      expect(ably.webhook(env(raw, signature: ""))).to eq([:refused, :bad_signature])
      expect(ably.webhook(env(raw, signature: "AAAA"))).to eq([:refused, :bad_signature])
      expect(ably.webhook(env(raw, secret: "not-our-secret"))).to eq([:refused, :bad_signature])
      expect(ably.webhook(env(raw, signature: base64_hmac(AblyHelper::KEY_SECRET, body(item(channel, 2)))))).to eq([:refused, :bad_signature])
      expect(ably.webhook(env(raw).tap { |e| e.delete("HTTP_X_ABLY_SIGNATURE") })).to eq([:refused, :bad_signature])
    end

    it "when the signature is a hex digest instead of base64" do
      hex = OpenSSL::HMAC.hexdigest("SHA256", AblyHelper::KEY_SECRET, raw)

      expect(ably.webhook(env(raw, signature: hex))).to eq([:refused, :bad_signature])
    end

    it "when an event is older than 5 minutes (a replay), or from the far future" do
      old = body(item(channel, 3, timestamp: AblyHelper::NOW_MS - 300_001))
      future = body(item(channel, 3, timestamp: AblyHelper::NOW_MS + 300_001))
      mixed = body(item(channel, 3), item(channel, 3, timestamp: AblyHelper::NOW_MS - 600_000))

      expect([old, future, mixed].map { |text| ably.webhook(env(text)) }).to eq([[:refused, :stale]] * 3)
    end

    it "accepts an event exactly 5 minutes old" do
      edge = body(item(channel, 3, timestamp: AblyHelper::NOW_MS - 300_000))

      expect(ably.webhook(env(edge))).to eq([:ok, [channel]])
    end

    it "when an event carries no timestamp" do
      bare = JSON.generate("items" => [{ "source" => "channel.presence", "data" => { "channelId" => channel, "presence" => [{ "action" => 3 }] } }])

      expect(ably.webhook(env(bare))).to eq([:refused, :missing_timestamp])
    end

    it "when the body is over 1 MB, by its declared length or by what it holds, without reading it all" do
      huge = "x" * (1_048_576 + 1)
      declared = env(raw, length: 2_000_000)
      streamed = env(huge, signature: base64_hmac(AblyHelper::KEY_SECRET, huge), length: nil).tap { |e| e.delete("CONTENT_LENGTH") }

      expect(ably.webhook(declared)).to eq([:refused, :too_large])
      expect(ably.webhook(streamed)).to eq([:refused, :too_large])
      expect(declared["rack.input"].pos).to eq(0)
    end

    it "accepts a body of exactly 1 MB" do
      bare = JSON.generate("items" => [item(channel, 3)], "pad" => "")
      exact = JSON.generate("items" => [item(channel, 3)], "pad" => "x" * (1_048_576 - bare.bytesize))

      expect(exact.bytesize).to eq(1_048_576)
      expect(ably.webhook(env(exact))).to eq([:ok, [channel]])
    end

    it "when the signed body is not JSON, or not an object" do
      ["not json", "[]", "null", "5", ""].each do |text|
        expect(ably.webhook(env(text))).to eq([:refused, :bad_body])
      end
    end

    it "when there is no body to read" do
      expect(ably.webhook("HTTP_X_ABLY_KEY" => AblyHelper::KEY_NAME, "HTTP_X_ABLY_SIGNATURE" => "x")).to eq([:refused, :bad_signature])
      expect(ably.webhook(nil)).to eq([:refused, :bad_signature])
    end

    it "always, when no key is configured" do
      expect(subscriptions::Ably.new.webhook(env(raw))).to eq([:refused, :not_configured])
    end
  end

  it "does not parse a body whose signature failed (the verdict comes before the content)" do
    expect(ably.webhook(env("{" * 100, signature: "AAAA"))).to eq([:refused, :bad_signature])
  end
end
