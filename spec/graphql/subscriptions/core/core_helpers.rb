# frozen_string_literal: true

require "graphql/armory/subscriptions"

# What the core and security specs of subscriptions share: a control schema with the backend installed on a test clock
# and a telemetry Substitute, and a client that subscribes the way a request does (on the engine of this run).
module SubscriptionsCoreHelpers
  CONTROLS = GraphQL::Armory::Subscriptions::Controls
  START = 1_000_000

  def self.included(base)
    base.let(:controls) { CONTROLS }
    base.let(:directory) { CONTROLS::Directory.example }
    base.let(:store) { CONTROLS::Store.example(now: START) }
    base.let(:transport) { CONTROLS::Transport.example }
    base.let(:clock) { GraphQL::Armory::Subscriptions::Core::Clock::Substitute.new(now: START) }
    base.let(:telemetry) { GraphQL::Armory::Telemetry::Substitute.new }
    base.let(:schema) { build_schema }
    base.let(:backend) { schema.subscriptions }
  end

  # The control schema with the backend wired to this example's store, transport, clock and telemetry.
  def build_schema(schema_options: {}, **options)
    schema = CONTROLS::Schema.example(directory: directory, subscriptions: CONTROLS::Options.example(directory: directory, store: store, transport: transport, **options),
                                      **schema_options)
    schema.subscriptions.clock = clock
    schema.subscriptions.telemetry = telemetry
    schema
  end

  def context_for(user, tenant: "acme", **context)
    { current_user: directory.find(user), tenant_id: tenant, rate_limit_key: "client:#{user}", armory_allow_raw_query: true, **context }
  end

  # Subscribes as `user` on the engine of this run; answers the Query::Result.
  def subscribe(document, user: "user-1", tenant: "acme", variables: {}, on: schema, **context)
    execute_query(on, document, variables: variables, context: context_for(user, tenant: tenant, **context))
  end

  # Subscribes and answers the channel the backend exposed for it, failing the example when it refused.
  def subscribed(document, **options)
    result = subscribe(document, **options)
    raise "subscribe failed: #{result.to_h["errors"].inspect}" if result.to_h["errors"]

    channel = schema.subscriptions.channel_for(result)
    raise "no channel for #{document}" unless channel

    channel
  end

  def payloads(channel)
    transport.delivered_to(channel).map(&:payload)
  end

  def signals(name)
    telemetry.recorded.select { |signal, _| signal == name }.map(&:last)
  end

  def message(id: "m1", body: "hi", room_id: "5")
    CONTROLS::Schema::Message.new(id: id, body: body, room_id: room_id)
  end

  def room(id: "5", name: "general")
    CONTROLS::Schema::Room.new(id: id, name: name)
  end

  # The stored record of `channel`, opened with the backend's encoder.
  def record_of(channel)
    id = transport.id_from(channel)
    sealed = store.records.fetch(id)
    GraphQL::Armory::Subscriptions::Record.from_h(JSON.parse(schema.subscriptions.encoder.open(sealed, aad: id, purpose: "subscription")))
  end

  def codes(result)
    Array(result.to_h["errors"]).map { |error| error.dig("extensions", "code") }
  end
end
