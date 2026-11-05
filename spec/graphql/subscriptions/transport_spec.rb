# frozen_string_literal: true

require "spec_helper"
require "graphql/armory/subscriptions"

RSpec.describe "GraphQL::Armory::Subscriptions::Transport" do
  let(:subscriptions) { GraphQL::Armory::Subscriptions }
  let(:controls) { subscriptions::Controls }
  let(:id) { controls::Id.example }
  let(:digest) { controls::Digest.example("viewer") }

  def message(channel, payload = { result: { "data" => { "x" => 1 } }, more: true })
    subscriptions::Message.new(channel: channel, payload: payload)
  end

  describe "Transport::Null" do
    let(:transport) { subscriptions::Transport::Null.new }

    it "is not viewer bound and fits nothing" do
      expect(transport.capabilities).to have_attributes(viewer_bound?: false, max_payload_bytes: 0, max_batch: 1, webhooks: nil, compress?: false)
      expect(transport.authorization).to eq(:channel)
    end

    it "names no channel and reads no id from one" do
      expect([transport.channel_for(id, digest), transport.id_from("private-x-#{id}")]).to eq([nil, nil])
    end

    it "refuses every publish, every authorization and every webhook" do
      outcomes = transport.publish([message("a"), message("b")])

      expect(outcomes.map { |outcome| [outcome.status, outcome.index, outcome.reason] }).to eq([[:refused, 0, :null_transport], [:refused, 1, :null_transport]])
      expect([transport.authorize_channel(channel: "a", socket_id: "1.2"), transport.authorize_viewer(digest)]).to eq([nil, nil])
      expect(transport.webhook({})).to eq([:refused, :null_transport])
    end
  end

  describe "Transport::Substitute" do
    let(:transport) { controls::Transport.example }

    it "names a channel from the id and the viewer digest, and reads the id back" do
      channel = transport.channel_for(id, digest)

      expect(channel).to eq("substitute:#{digest}:#{id}")
      expect(transport.id_from(channel)).to eq(id)
      expect(transport.id_from(transport.channel_for(id, subscriptions::Record::ANONYMOUS))).to eq(id)
      expect([transport.id_from("other:#{digest}:#{id}"), transport.id_from("substitute:#{id}"), transport.id_from(nil)]).to eq([nil, nil, nil])
    end

    it "records each published batch and answers :ok for each message by default" do
      outcomes = transport.publish([message("a"), message("b")])
      transport.publish([message("c")])

      expect(outcomes.map { |outcome| [outcome.status, outcome.index] }).to eq([[:ok, 0], [:ok, 1]])
      expect(transport.published.map(&:channel)).to eq(%w[a b c])
      expect(transport.batches.map(&:size)).to eq([2, 1])
      expect(transport.delivered_to("b").map(&:payload)).to eq([{ result: { "data" => { "x" => 1 } }, more: true }])
    end

    it "answers the outcome it is told, for one channel or every channel" do
      transport.answer_publish(:gone, channel: "b")
      transport.answer_publish(:retry, channel: "c", reason: :rate_limited)

      outcomes = transport.publish([message("a"), message("b"), message("c")])
      expect(outcomes.map { |outcome| [outcome.status, outcome.reason] }).to eq([[:ok, nil], [:gone, nil], [:retry, :rate_limited]])

      transport.answer_publish(:refused)
      expect(transport.publish([message("a"), message("b")]).map(&:status)).to eq(%i[refused gone])
      expect { transport.answer_publish(:lost) }.to raise_error(ArgumentError)
    end

    it "refuses a batch larger than max_batch, a payload over max_payload_bytes and anything but Messages" do
      small = controls::Transport.example(capabilities: controls::Capabilities.example(max_batch: 1, max_payload_bytes: 40))

      expect { small.publish([message("a"), message("b")]) }.to raise_error(ArgumentError, /max_batch/)
      expect { small.publish([message("a", { result: "x" * 64 })]) }.to raise_error(ArgumentError, /max_payload_bytes/)
      expect { transport.publish(["a"]) }.to raise_error(ArgumentError)
      expect { transport.publish([]) }.to raise_error(ArgumentError)
      expect(small.published).to eq([])
    end

    it "authorizes channels or viewers as its declared mode says" do
      viewer_mode = controls::Transport.example(authorization: :viewer)

      expect(transport.authorization).to eq(:channel)
      expect(transport.authorize_channel(channel: "c", socket_id: "1.2")).to eq(auth: "substitute:1.2:c")
      expect(transport.authorize_viewer(digest)).to be_nil
      expect(viewer_mode.authorize_viewer(digest)).to eq(token: "substitute:#{digest}")
      expect(viewer_mode.authorize_channel(channel: "c", socket_id: "1.2")).to be_nil
      expect { controls::Transport.example(authorization: :socket) }.to raise_error(ArgumentError)
    end

    it "declares the capabilities it is given" do
      capabilities = controls::Capabilities.example(viewer_bound: false, compress: true)

      expect(controls::Transport.example(capabilities: capabilities).capabilities).to be(capabilities)
      expect { controls::Transport.example(capabilities: {}) }.to raise_error(ArgumentError)
    end

    it "answers webhooks with nothing gone by default, or what it is told" do
      expect(transport.webhook({ "rack.input" => nil })).to eq([:ok, []])

      transport.answer(:webhook, [:ok, ["substitute:#{digest}:#{id}"]])
      expect(transport.webhook({})).to eq([:ok, ["substitute:#{digest}:#{id}"]])
      transport.answer(:authorize_channel, { auth: "told" })
      expect(transport.authorize_channel(channel: "c", socket_id: "1.2")).to eq(auth: "told")
      expect { transport.answer(:publish, []) }.to raise_error(ArgumentError)
    end

    it "fails when told and records every call" do
      transport.fail_with(subscriptions::TransportError.new("down"), on: :publish, times: 1)

      expect { transport.publish([message("a")]) }.to raise_error(subscriptions::TransportError)
      expect(transport.publish([message("a")]).map(&:status)).to eq([:ok])
      transport.fail_with(IOError.new)
      expect { transport.webhook({}) }.to raise_error(IOError)
      transport.recover
      expect(transport.calls.map(&:first)).to eq(%i[publish publish webhook])
    end
  end
end
