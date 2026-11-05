# frozen_string_literal: true

require_relative "ably_helper"

RSpec.describe "GraphQL::Armory::Subscriptions::Ably#authorize_viewer" do
  include AblyHelper

  let(:request) { ably.authorize_viewer(digest) }
  let(:capability) { %({"graphql:#{digest}:*":["presence","subscribe"]}) }

  # https://ably.com/docs/api/token-request-spec : the signing text is keyName, ttl (ms), capability, clientId
  # (empty when omitted), timestamp (ms) and nonce, each followed by a newline; mac = base64(HMAC-SHA256(secret, text)).
  let(:signing_text) { "appId.keyId\n3600000\n#{capability}\n\n#{AblyHelper::NOW_MS}\nfixed-nonce-0123456789\n" }

  it "answers a TokenRequest Ably's token endpoint accepts: the documented fields, no clientId" do
    expect(request).to eq(
      "keyName" => "appId.keyId",
      "ttl" => 3_600_000,
      "capability" => capability,
      "timestamp" => AblyHelper::NOW_MS,
      "nonce" => "fixed-nonce-0123456789",
      "mac" => base64_hmac(AblyHelper::KEY_SECRET, signing_text)
    )
    expect(request).not_to include("clientId")
  end

  it "signs with the key secret over the newline-joined fields (a mac computed here from the documented text)" do
    fixed = ably.authorize_viewer("a" * 64)
    text = "appId.keyId\n3600000\n{\"graphql:#{"a" * 64}:*\":[\"presence\",\"subscribe\"]}\n\n1800000000000\nfixed-nonce-0123456789\n"

    expect(fixed["mac"]).to eq(base64_hmac(AblyHelper::KEY_SECRET, text))
    expect(fixed["mac"]).not_to eq(base64_hmac("other-secret", text))
  end

  it "uses the configured ttl in milliseconds" do
    expect(ably(token_ttl: 600).authorize_viewer(digest)).to include("ttl" => 600_000)
  end

  it "draws a new nonce for every request" do
    counter = 0
    drawn = subscriptions::Ably.build(key: AblyHelper::KEY, http: http, clock: clock, nonce: -> { "nonce-#{counter += 1}-0123456789" })

    expect([drawn.authorize_viewer(digest)["nonce"], drawn.authorize_viewer(digest)["nonce"]].uniq.size).to eq(2)
  end

  it "reads the clock for each request" do
    later = Time.at(1_800_000_060)
    moving = subscriptions::Ably.build(key: AblyHelper::KEY, http: http, clock: -> { later }, nonce: nonce)

    expect(moving.authorize_viewer(digest)["timestamp"]).to eq(1_800_000_060_000)
  end

  describe "capability scoping" do
    it "names the viewer's own namespace only, with subscribe and presence" do
      parsed = JSON.parse(request["capability"])

      expect(parsed).to eq("graphql:#{digest}:*" => %w[presence subscribe])
    end

    it "never names another digest, another prefix or a bare wildcard" do
      other = controls::Digest.example("someone else")
      grants = JSON.parse(ably(prefix: "app").authorize_viewer(digest)["capability"])

      expect(grants.keys).to eq(["app:#{digest}:*"])
      expect(grants.keys.join).not_to include(other)
      expect(grants.values.flatten).not_to include("publish", "*", "history")
    end

    it "gives two viewers disjoint namespaces" do
      a = JSON.parse(ably.authorize_viewer(digest)["capability"]).keys
      b = JSON.parse(ably.authorize_viewer(controls::Digest.example("someone else"))["capability"]).keys

      expect(a & b).to eq([])
    end

    it "serves an anonymous viewer its own namespace" do
      expect(JSON.parse(ably.authorize_viewer(subscriptions::Record::ANONYMOUS)["capability"]).keys).to eq(["graphql:anonymous:*"])
    end

    it "answers nil for a digest that is not a viewer digest, so a crafted value cannot widen the scope" do
      ["*", "#{digest}:*", "#{digest}*", "", nil, 5, digest.upcase, "a" * 63, "#{digest}\n"].each do |bad|
        expect(ably.authorize_viewer(bad)).to be_nil
      end
    end
  end

  it "makes no request to Ably and answers nil to authorize_channel" do
    request
    expect(ably.authorize_channel(channel: channel, socket_id: "1.2")).to be_nil
    expect(http.requests).to eq([])
  end
end
