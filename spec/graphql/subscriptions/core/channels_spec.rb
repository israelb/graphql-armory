# frozen_string_literal: true

require "spec_helper"
require_relative "core_helpers"

# Channel and viewer authorization, webhooks and cleanup.
RSpec.describe "GraphQL::Armory::Subscriptions::Core channels" do
  include SubscriptionsCoreHelpers

  let(:subscriptions) { GraphQL::Armory::Subscriptions }
  let(:posted) { "subscription { messagePosted(roomId: 5) { id body } }" }

  describe "#authorize_channel" do
    it "answers the transport's signature for the viewer that created the channel" do
      channel = subscribed(posted)

      expect(backend.authorize_channel(channel: channel, socket_id: "123.456", context: context_for("user-1"))).to eq(auth: "substitute:123.456:#{channel}")
      expect(transport.calls.last).to eq([:authorize_channel, { channel: channel, socket_id: "123.456" }])
    end

    it "answers nil to another viewer, an unknown viewer, a bad socket id, an unknown or deleted channel, never asking the transport" do
      channel = subscribed(posted)
      id = transport.id_from(channel)
      other_digest = backend.encoder.mac("user-2", purpose: "subscription-viewer").unpack1("H*")
      answers = [
        backend.authorize_channel(channel: channel, socket_id: "1.2", context: context_for("user-2")),
        backend.authorize_channel(channel: channel, socket_id: "1.2", context: {}),
        backend.authorize_channel(channel: channel, socket_id: "1.2; drop", context: context_for("user-1")),
        backend.authorize_channel(channel: "elsewhere", socket_id: "1.2", context: context_for("user-1")),
        backend.authorize_channel(channel: transport.channel_for(id, other_digest), socket_id: "1.2", context: context_for("user-2"))
      ]
      backend.delete_subscription(id)
      answers << backend.authorize_channel(channel: channel, socket_id: "1.2", context: context_for("user-1"))

      expect(answers).to eq([nil] * 6)
      expect(transport.calls.map(&:first)).not_to include(:authorize_channel)
    end

    it "answers nil once the subscription expired, or when the transport authorizes per viewer" do
      channel = subscribed(posted)
      clock.advance(3_600_000)

      expect(backend.authorize_channel(channel: channel, socket_id: "1.2", context: context_for("user-1"))).to be_nil

      self.transport = controls::Transport.example(authorization: :viewer)
      per_viewer = build_schema
      fresh = subscribed(posted, on: per_viewer)
      expect(per_viewer.subscriptions.authorize_channel(channel: fresh, socket_id: "1.2", context: context_for("user-1"))).to be_nil
    end
  end

  describe "#authorize_viewer" do
    before { self.transport = controls::Transport.example(authorization: :viewer) }

    it "answers the transport's credentials for the requesting viewer's digest" do
      digest = backend.encoder.mac("user-1", purpose: "subscription-viewer").unpack1("H*")

      expect(backend.authorize_viewer(context: context_for("user-1"))).to eq(token: "substitute:#{digest}")
    end

    it "answers nil when the context names no viewer, or when the transport authorizes per channel" do
      expect(backend.authorize_viewer(context: {})).to be_nil

      self.transport = controls::Transport.example(authorization: :channel)
      expect(build_schema.subscriptions.authorize_viewer(context: context_for("user-1"))).to be_nil
    end
  end

  describe "#webhook" do
    it "deletes the subscriptions whose channels the transport reports gone, and answers 200" do
      gone = subscribed(posted)
      kept = subscribed(posted, user: "user-2")
      transport.answer(:webhook, [:ok, [gone, "not-a-channel"]])

      status, headers, body = backend.webhook("rack.input" => StringIO.new("{}"))

      expect([status, headers["content-type"], body]).to eq([200, "application/json", ["{}"]])
      expect(store.records.keys).to eq([transport.id_from(kept)])
      expect(signals(:subscription_ended).map { |data| data[:reason] }).to eq([:webhook])
    end

    it "answers 401 to a refused webhook, deleting nothing, and records why" do
      subscribed(posted)
      transport.answer(:webhook, [:refused, :signature])

      expect(backend.webhook({}).first).to eq(401)
      expect(store.records.size).to eq(1)
      expect(signals(:subscription_webhook_refused)).to eq([{ reason: :signature }])
    end

    it "answers 401 when the transport raises, recording the error class only" do
      transport.fail_with(IOError.new("secret detail"), on: :webhook)

      expect(backend.webhook({}).first).to eq(401)
      expect(signals(:subscription_webhook_refused)).to eq([{ reason: :error }])
    end

    it "is mounted through WebhookApp, which answers 404 for a schema without this backend" do
      gone = subscribed(posted)
      transport.answer(:webhook, [:ok, [gone]])

      expect(subscriptions::WebhookApp.new(schema).call({}).first).to eq(200)
      expect(store.records).to be_empty
      expect(subscriptions::WebhookApp.new.call({}).first).to eq(404)
      expect(subscriptions::WebhookApp.new(controls::Schema.example).call({}).first).to eq(404)
    end
  end

  describe "#cleanup" do
    it "removes the records expired at now (a Time, Integer milliseconds, or the clock) and answers how many" do
      subscribed(posted)
      clock.advance(1_000)
      subscribed(posted, user: "user-2")

      expect(backend.cleanup(now: SubscriptionsCoreHelpers::START + 3_600_000)).to eq(1)
      expect(backend.cleanup(now: Time.at((SubscriptionsCoreHelpers::START + 3_601_000) / 1000r))).to eq(1)
      expect(backend.cleanup).to eq(0)
      expect { backend.cleanup(now: "soon") }.to raise_error(ArgumentError)
    end
  end

  def transport=(value)
    @transport = value
  end

  def transport
    @transport ||= controls::Transport.example
  end
end
