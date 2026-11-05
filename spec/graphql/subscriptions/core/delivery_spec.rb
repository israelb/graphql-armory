# frozen_string_literal: true

require "spec_helper"
require "zlib"
require "base64"
require_relative "core_helpers"

# trigger, execute_all and delivery: who a delivery runs as, what it sends, and when a subscription ends.
RSpec.describe "GraphQL::Armory::Subscriptions::Core delivery" do
  include SubscriptionsCoreHelpers

  let(:subscriptions) { GraphQL::Armory::Subscriptions }
  let(:posted) { "subscription { messagePosted(roomId: 5) { id body } }" }
  let(:too_large) { { "errors" => [{ "message" => "Result too large", "extensions" => { "code" => "RESULT_TOO_LARGE" } }] } }

  # A schema without the other plugins whose Subscription root has a graphql-ruby Subscription class (`ticker`, whose
  # update answers by `mode`) and a plain field with a nullable nested field (`feed`).
  def ticker_schema(**options)
    no_update = GraphQL::Schema::Subscription::NO_UPDATE
    resolver = Class.new(GraphQL::Schema::Subscription) do
      graphql_name "Ticker"
      argument :mode, String
      type String, null: true
      define_method(:update) do |mode:|
        case mode
        when "skip" then no_update
        when "stop" then unsubscribe
        when "last" then unsubscribe("bye")
        when "boom" then raise IOError, "resolver failed"
        else "tick"
        end
      end
    end
    item = Class.new(GraphQL::Schema::Object) do
      graphql_name "Item"
      field :title, String, null: true
    end
    root = Class.new(GraphQL::Schema::Object) do
      graphql_name "Subscription"
      field :ticker, resolver: resolver
      field :feed, item, null: true
    end
    query = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :ping, String, null: false
    end
    plugin_options = controls::Options.example(directory: directory, store: store, transport: transport, context_keys: {}, **options)
    built = Class.new(GraphQL::Schema) do
      use GraphQL::Execution::Next if defined?(GraphQL::Execution::Next)
      query(query)
      subscription(root)
      use GraphQL::Armory::Subscriptions, **plugin_options
    end
    built.subscriptions.clock = clock
    built.subscriptions.telemetry = telemetry
    built
  end

  describe "#trigger" do
    it "delivers the subscriber's result on its channel, with more: true" do
      channel = subscribed(posted)
      backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

      expect(payloads(channel)).to eq([{ result: { "data" => { "messagePosted" => { "id" => "m1", "body" => "hi" } } }, more: true }])
      expect(transport.published.map(&:event)).to eq(["update"])
    end

    it "reaches only the subscribers of the same field, arguments and scope" do
      five = subscribed(posted)
      six = subscribed("subscription { messagePosted(roomId: 6) { id } }")
      other_tenant = subscribed(posted, tenant: "globex")

      backend.trigger("messagePosted", { "roomId" => "5" }, message, scope: "acme")

      expect([payloads(five).size, payloads(six).size, payloads(other_tenant).size]).to eq([1, 0, 0])
    end

    it "raises on a non-empty context:, before running anything" do
      channel = subscribed(posted)

      expect { backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme", context: { current_user: directory.find("user-2") }) }
        .to raise_error(ArgumentError, /context: is refused/)
      expect(payloads(channel)).to be_empty
      expect { backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme", context: {}) }.not_to raise_error
    end

    it "raises on an unknown event, an unknown argument or a value its type cannot coerce" do
      expect { backend.trigger(:nothing, {}, message) }.to raise_error(GraphQL::Subscriptions::InvalidTriggerError)
      expect { backend.trigger(:message_posted, { room: 5 }, message, scope: "acme") }.to raise_error(GraphQL::Subscriptions::InvalidTriggerError)
      expect { backend.trigger(:message_posted, { room_id: 5, on: "not a date" }, message, scope: "acme") }.to raise_error(ArgumentError, /argument/)
    end

    it "executes at most max_executions_per_trigger subscribers and records how many it skipped" do
      schema = build_schema(max_executions_per_trigger: 2)
      3.times { |index| subscribe(posted, on: schema, user: index.even? ? "user-1" : "user-2") }
      schema.subscriptions.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

      expect(transport.published.size).to eq(2)
      expect(signals(:subscription_trigger_budget)).to eq([{ skipped: 1 }])
    end

    it "starts the budget at a random subscriber, so repeated triggers reach every subscriber" do
      schema = build_schema(max_executions_per_trigger: 2)
      channels = Array.new(3) { |index| schema.subscriptions.channel_for(subscribe(posted, on: schema, user: index.even? ? "user-1" : "user-2")) }
      30.times { schema.subscriptions.trigger(:message_posted, { room_id: 5 }, message, scope: "acme") }

      expect(transport.published.size).to eq(60)
      expect(channels.map { |channel| transport.delivered_to(channel).size }).to all(be_positive)
      expect(signals(:subscription_trigger_budget)).to eq([{ skipped: 1 }] * 30)
    end
  end

  describe "who the delivery runs as" do
    it "builds a fresh context: the stored keys and the reloaded viewer, nothing else from the subscribe request" do
      seen = []
      schema.subscription.get_field("messagePosted").extension(Class.new(GraphQL::Schema::FieldExtension) do
        define_method(:after_resolve) do |context:, **rest|
          seen << context.to_h.slice(:tenant_id, :current_user, :current_user_id, :secret_token, :armory_version, :operation_id, :armory_allow_raw_query, :rate_limit_key)
          rest.key?(:values) ? rest[:values] : rest[:value]
        end
      end)
      subscribe(posted, secret_token: "s3cr3t", armory_version: "2024-06-01")
      seen.clear
      backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

      expect(seen).to eq([{ tenant_id: "acme", current_user: directory.find("user-1"), current_user_id: "user-1", armory_version: "2024-06-01",
                            armory_allow_raw_query: true }])
    end

    it "marks the delivery, so no rate limiter charges the subscriber" do
      subscribe(posted)
      rate_store = schema.armory_controls[:rate_store]
      rate_store.calls.clear
      backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

      expect(transport.published.size).to eq(1)
      expect(rate_store.calls).to be_empty
    end

    it "runs a persisted subscription as its stored operation under PersistedQueries strict" do
      result = execute_query(schema, nil, context: context_for("user-1", operation_id: "message-posted", armory_allow_raw_query: false), variables: { "roomId" => "5" })
      channel = backend.channel_for(result)
      backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

      expect(payloads(channel)).to eq([{ result: { "data" => { "messagePosted" => { "id" => "m1", "body" => "hi" } } }, more: true }])
    end
  end

  describe "ending a subscription" do
    it "ends it when the root field is null: a final message with more: false, then the record is deleted" do
      channel = subscribed(posted)
      directory.revoke("user-1")
      2.times { backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme") }

      expect(payloads(channel)).to eq([{ result: { "data" => { "messagePosted" => nil } }, more: false }])
      expect(store.records).to be_empty
      expect(signals(:subscription_ended)).to match([{ reason: :refused, subscription: a_string_matching(/\A[0-9a-f]{16}\z/) }])
    end

    it "ends it when the result has no data (a non-null root denied)" do
      channel = subscribed("subscription { roomUpdated(roomId: 5) { name } }")
      directory.revoke("user-1")
      backend.trigger(:room_updated, { room_id: 5 }, room)

      expect(payloads(channel).map { |payload| [payload[:result]["data"], payload[:more]] }).to eq([[nil, false]])
      expect(store.records).to be_empty
    end

    it "keeps it when only a nested field is null" do
      schema = ticker_schema
      channel = schema.subscriptions.channel_for(subscribe("subscription { feed { title } }", on: schema))
      schema.subscriptions.trigger(:feed, {}, Struct.new(:title).new(nil))

      expect(payloads(channel)).to eq([{ result: { "data" => { "feed" => { "title" => nil } } }, more: true }])
      expect(store.records.size).to eq(1)
    end

    it "ends a viewer that no longer loads with { more: false }, running nothing" do
      channel = subscribed(posted)
      directory.remove("user-1")
      backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

      expect(payloads(channel)).to eq([{ more: false }])
      expect(store.records).to be_empty
      expect(signals(:subscription_ended).map { |data| data[:reason] }).to eq([:viewer_gone])
    end

    it "ends an expired record the store still lists with { more: false } instead of running it" do
      channel = subscribed(posted)
      clock.advance(3_600_000)
      store.answer(:ids, [transport.id_from(channel)]) # a store that has not dropped it from the index yet
      backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

      expect(payloads(channel)).to eq([{ more: false }])
      expect(store.records).to be_empty
      expect(signals(:subscription_ended).map { |data| data[:reason] }).to eq([:expired])
    end

    it "never runs a record past its expiry: a store that keeps its contract no longer lists it" do
      channel = subscribed(posted)
      clock.advance(3_600_000)
      backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

      expect(payloads(channel)).to be_empty
      expect(store.calls.map(&:first)).not_to include(:read)
    end

    it "honours graphql-ruby's :no_update and unsubscribe from a Subscription class" do
      schema = ticker_schema
      modes = %w[skip stop last tick]
      channels = modes.to_h { |mode| [mode, schema.subscriptions.channel_for(subscribe("subscription { ticker(mode: \"#{mode}\") }", on: schema))] }
      modes.each { |mode| schema.subscriptions.trigger(:ticker, { mode: mode }, :tick) }

      expect(channels.transform_values { |channel| payloads(channel) }).to eq(
        "skip" => [],
        "stop" => [{ more: false }],
        "last" => [{ result: { "data" => { "ticker" => "bye" } }, more: false }],
        "tick" => [{ result: { "data" => { "ticker" => "tick" } }, more: true }]
      )
      expect(store.records.keys).to contain_exactly(transport.id_from(channels["skip"]), transport.id_from(channels["tick"]))
      expect(signals(:subscription_ended).map { |data| data[:reason] }).to eq(%i[unsubscribed unsubscribed])
    end
  end

  describe "the payload" do
    it "replaces a result over the transport's limit with RESULT_TOO_LARGE, never truncating it" do
      self.transport = controls::Transport.example(capabilities: controls::Capabilities.example(max_payload_bytes: 120))
      channel = subscribed(posted)
      backend.trigger(:message_posted, { room_id: 5 }, message(body: "x" * 500), scope: "acme")

      expect(payloads(channel)).to eq([{ result: too_large, more: true }])
      expect(signals(:subscription_payload_too_large)).to match([{ subscription: a_string_matching(/\A[0-9a-f]{16}\z/), bytes: a_value > 120, limit: 120 }])
    end

    it "deflates and base64-encodes the result into compressed_result when the transport compresses" do
      self.transport = controls::Transport.example(capabilities: controls::Capabilities.example(compress: true))
      channel = subscribed(posted)
      backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")
      payload = payloads(channel).first

      expect(payload.keys).to eq(%i[compressed_result more])
      expect(JSON.parse(Zlib::Inflate.inflate(Base64.strict_decode64(payload[:compressed_result])))).to eq("data" => { "messagePosted" => { "id" => "m1", "body" => "hi" } })
    end

    it "publishes in batches of the transport's max_batch" do
      self.transport = controls::Transport.example(capabilities: controls::Capabilities.example(max_batch: 2))
      schema = build_schema(max_per_viewer: 10)
      5.times { subscribe(posted, on: schema) }
      schema.subscriptions.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

      expect(transport.batches.map(&:size)).to eq([2, 2, 1])
    end

    it "records the delivery with a digest of the id, its complexity and its size, never the result" do
      subscribed(posted)
      backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

      expect(signals(:subscription_delivered)).to match([{ subscription: a_string_matching(/\A[0-9a-f]{16}\z/), complexity: a_kind_of(Integer), bytes: a_kind_of(Integer) }])
    end
  end

  describe "telemetry" do
    it "carries no subscription id, channel, viewer id, document or result in any signal" do
      channel = subscribed(posted, secret_token: "s3cr3t")
      subscribed(posted, user: "user-2")
      directory.revoke("user-2")
      backend.trigger(:message_posted, { room_id: 5 }, message(body: "private body"), scope: "acme")
      transport.answer(:webhook, [:ok, [channel]])
      backend.webhook({})
      text = telemetry.recorded.map { |signal, data| [signal, data.values.map(&:to_s)] }.flatten.join(" ")

      expect(telemetry.recorded.map(&:first)).to include(:subscription_created, :subscription_delivered, :subscription_ended)
      expect(text).not_to include(transport.id_from(channel), channel, "user-1", "user-2", "messagePosted", "private body", "acme")
    end
  end

  describe "the store's records" do
    it "deletes a record that does not open, never running it" do
      channel = subscribed(posted)
      id = transport.id_from(channel)
      store.poison(id, "forged", topics: record_of(channel).topics, viewer: "x", expires_at: SubscriptionsCoreHelpers::START + 60_000)
      backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

      expect(payloads(channel)).to be_empty
      expect(store.records).to be_empty
      expect(signals(:subscription_record_unreadable)).to match([{ subscription: a_string_matching(/\A[0-9a-f]{16}\z/) }])
    end

    it "deletes a record whose topics do not hold the triggered one (the index drifted)" do
      channel = subscribed(posted)
      other = subscribed("subscription { messagePosted(roomId: 6) { id } }")
      store.poison(transport.id_from(other), store.records.fetch(transport.id_from(other)), topics: record_of(channel).topics, viewer: "x")
      backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

      expect([payloads(channel).size, payloads(other)]).to eq([1, []])
      expect(store.records.keys).to eq([transport.id_from(channel)])
    end
  end

  describe "transport outcomes and errors" do
    it "deletes a subscription the transport reports gone, keeps one it asks to retry" do
      gone = subscribed(posted)
      retried = subscribed(posted, user: "user-2")
      transport.answer_publish(:gone, channel: gone)
      transport.answer_publish(:retry, channel: retried)
      backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

      expect(store.records.keys).to eq([transport.id_from(retried)])
      expect(signals(:subscription_ended).map { |data| data[:reason] }).to eq([:gone])
    end

    it "records a subscriber whose delivery raised and goes on with the others" do
      schema = ticker_schema
      2.times { |index| subscribe("subscription { ticker(mode: \"tick\") }", on: schema, user: "user-#{index + 1}") }
      store.fail_with(IOError.new("read failed"), on: :read, times: 1)
      schema.subscriptions.trigger(:ticker, { mode: "tick" }, :tick)

      expect(transport.published.size).to eq(1)
      expect(signals(:subscription_delivery_error)).to match([{ error: "IOError", subscription: a_string_matching(/\A[0-9a-f]{16}\z/) }])
    end

    it "records a subscriber whose execution raised, keeping it" do
      schema = ticker_schema
      channel = schema.subscriptions.channel_for(subscribe("subscription { ticker(mode: \"boom\") }", on: schema))

      expect { schema.subscriptions.trigger(:ticker, { mode: "boom" }, :tick) }.not_to raise_error
      expect(payloads(channel)).to be_empty
      expect(signals(:subscription_delivery_error)).to match([{ error: "IOError", subscription: a_string_matching(/\A[0-9a-f]{16}\z/) }])
      expect(store.records.size).to eq(1)
    end

    it "with on_delivery_error: :raise, raises the first error after the whole topic was processed" do
      schema = ticker_schema(on_delivery_error: :raise)
      2.times { |index| subscribe("subscription { ticker(mode: \"tick\") }", on: schema, user: "user-#{index + 1}") }
      store.fail_with(IOError.new("read failed"), on: :read, times: 1)

      expect { schema.subscriptions.trigger(:ticker, { mode: "tick" }, :tick) }.to raise_error(IOError, "read failed")
      expect(transport.published.size).to eq(1)
    end

    it "records a transport failure and keeps the subscriptions by default; :raise raises it" do
      subscribed(posted)
      transport.fail_with(IOError.new("down"), on: :publish)

      expect { backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme") }.not_to raise_error
      expect(signals(:subscription_transport_error)).to eq([{ operation: :publish, error: "IOError" }])
      expect(store.records.size).to eq(1)

      raising = build_schema(on_delivery_error: :raise)
      expect { raising.subscriptions.trigger(:message_posted, { room_id: 5 }, message, scope: "acme") }.to raise_error(IOError, "down")
    end

    it "records a message the transport refused for good, keeping the subscription" do
      channel = subscribed(posted)
      transport.answer_publish(:refused, channel: channel, reason: :bad_request)
      backend.trigger(:message_posted, { room_id: 5 }, message, scope: "acme")

      expect(signals(:subscription_transport_error)).to eq([{ operation: :publish, outcome: :refused, reason: :bad_request }])
      expect(store.records.size).to eq(1)
    end
  end

  def transport=(value)
    @transport = value
  end

  def transport
    @transport ||= controls::Transport.example
  end
end
