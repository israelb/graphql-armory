# frozen_string_literal: true

require_relative "ably_helper"

RSpec.describe GraphQL::Armory::Subscriptions::Ably do
  include AblyHelper

  let(:ably_class) { subscriptions::Ably }

  describe ".new" do
    let(:inert) { ably_class.new }

    it "is inert: nothing publishes, authorizes or is accepted, and no request leaves" do
      expect(statuses(inert.publish([message("graphql:x:y")]))).to eq([[:refused, :not_configured]])
      expect([inert.authorize_viewer(digest), inert.authorize_channel(channel: "a", socket_id: "1.2")]).to eq([nil, nil])
      expect(inert.webhook({})).to eq([:refused, :not_configured])
    end

    it "does not show its key" do
      expect(ably.inspect).not_to include(AblyHelper::KEY_SECRET)
      expect(ably.inspect).not_to include(AblyHelper::KEY_NAME)
    end
  end

  describe ".build" do
    it "declares what Ably does" do
      expect(ably.capabilities).to have_attributes(viewer_bound?: true, max_payload_bytes: 65_536, webhooks: :presence, compress?: false)
      expect(ably.authorization).to eq(:viewer)
    end

    it "keeps a batch inside Ably's 2 MiB request limit, whatever the payload size" do
      [65_536, 262_144, 1].each do |bytes|
        batch = ably(max_payload_bytes: bytes).capabilities.max_batch
        expect(batch).to be_between(1, 100)
        expect(batch * (2 * bytes + 512)).to be <= 2 * 1024 * 1024 unless batch == 1
      end
    end

    it "takes a larger payload for plans that allow it, and compress when told" do
      expect(ably(max_payload_bytes: 262_144, compress: true).capabilities).to have_attributes(max_payload_bytes: 262_144, compress?: true)
    end

    it "refuses a key that is not <keyName>:<keySecret>" do
      ["", "nocolon", "name:", ":secret", "na me:secret", "name:sec\nret", nil, 12].each do |key|
        expect { ably_class.build(key: key) }.to raise_error(subscriptions::ConfigurationError, /key:/)
      end
    end

    it "refuses an unsafe prefix, host, size, token_ttl, http, clock, nonce or compress" do
      {
        prefix: ["", "a:b", "a b", nil],
        host: ["", "a/b", "https://x.com", "x.com:99", nil],
        max_payload_bytes: [0, -1, 262_145, "65536"],
        token_ttl: [0, 3601, 1.5, nil],
        http: [nil, Object.new],
        clock: [nil, 1],
        nonce: [nil, "x"],
        compress: [nil, "yes"]
      }.each do |option, values|
        values.each do |value|
          expect { ably(option => value) }.to raise_error(subscriptions::ConfigurationError, /#{option}:/)
        end
      end
    end
  end
end
