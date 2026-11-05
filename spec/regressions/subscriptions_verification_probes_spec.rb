# frozen_string_literal: true

# Independent verifier probes for module 6, Subscriptions over hosted pub/sub (PR #78), kept as regressions. Probes of
# documented limits are pending with the limit they pin: they fail today, and RSpec reports them the day they pass. One
# probe per `it`, each labelled
# "security" (the feature must change its outcome) or "preservation" (existing behaviour must hold).
require "spec_helper"
require "date"
require "json"
require "stringio"
require "openssl"
require "base64"
require "zlib"
require "digest"
require "securerandom"

module SubscriptionsVerifierProbes
  Armory = GraphQL::Armory
  Subs = GraphQL::Armory::Subscriptions
  Ctl = Subs::Controls
  NEXT_OPTS = Ctl::Schema::NEXT_FIELD_OPTIONS
  LABELS = Armory::Versioning::Controls::Versions::LABELS

  OwnedMessage = Struct.new(:id, :body, :room_id, :edited, :owner, keyword_init: true)

  # The control policy, plus: a record with an owner is readable by that owner only.
  class OwnerPolicy < Ctl::Policy
    def authorized?(actor, subject, rule)
      return false unless super

      !subject.respond_to?(:owner) || subject.owner.nil? || subject.owner == actor&.id
    end
  end

  class AllowAll < Ctl::Policy
    def authorized?(_actor, _subject, _rule) = true
    def scope(_actor, items, _rule) = items
  end

  # Controls::Schema.example, parameterised: retired versions, broadcastable, extra limiters, a context-reporting field.
  def self.schema(subscriptions: nil, directory: Ctl::Directory.example, adapter: nil, on_unauthorized: :null, strict: true,
                  documents: Ctl::Schema::DOCUMENTS, retired: %w[2024-01-15], rate_store: nil, rate_limit: 1_000, broadcastable: false,
                  time_store: nil, concurrency_store: nil, extra_subscription: nil)
    adapter ||= OwnerPolicy.new(directory)
    rate_store ||= Armory::RateLimits::Store::Substitute.new
    manifest = Armory::PersistedQueries::Manifest.new(documents, digest: false)
    types = Ctl::Schema::Types.example
    types[:message].class_eval do
      field :seen_by, String, null: true, **NEXT_OPTS
      define_method(:seen_by) do
        [context[:current_user]&.id, context[:admin].inspect, context[:armory_version].inspect, context[:tenant_id].inspect].join("|")
      end
      field :big, String, null: true, **NEXT_OPTS
      define_method(:big) { "x" * 20_000 }
      field :boom, String, null: true, **NEXT_OPTS
      define_method(:boom) { raise "boom from a subscriber" }
      field :echo, String, null: true, **NEXT_OPTS do
        argument :value, GraphQL::Types::JSON
      end
      define_method(:echo) { |value:| value.inspect }
    end
    query = Class.new(types.fetch(:object)) do
      graphql_name "Query"
      authorize :none, reason: "probe root", covers_fields: true
      field :ping, String, null: false, **NEXT_OPTS
      define_method(:ping) { "pong" }
      field :fire, String, null: false, **NEXT_OPTS
      define_method(:fire) do
        context.schema.subscriptions.trigger(:message_posted, { "roomId" => "5" },
                                             OwnedMessage.new(id: "m9", body: "FIRED-FOR-USER-1", room_id: "5", edited: false, owner: "user-1"), scope: "t1")
        "fired"
      end
    end
    sub_options = broadcastable ? { broadcastable: true } : {}
    subscription = Class.new(types.fetch(:object)) do
      graphql_name "Subscription"
      authorize :none, reason: "each payload type is read through the policy", covers_fields: true
      field :message_posted, types.fetch(:message), null: true, subscription_scope: :tenant_id, **sub_options do
        argument :room_id, GraphQL::Types::ID
        argument :priority, types.fetch(:priority), required: false
        argument :on, types.fetch(:date), required: false
        argument :filter, types.fetch(:filter), required: false, default_value: { "priority" => "LOW" }
      end
      field :room_updated, types.fetch(:room), null: false do
        argument :room_id, GraphQL::Types::ID
        argument :thread, GraphQL::Types::ID, required: false
      end
      field :inbox_changed, types.fetch(:inbox), null: true, subscription_scope: :current_user_id
      instance_exec(types, &extra_subscription) if extra_subscription
    end
    armory = Armory
    subs = Subs
    Class.new(GraphQL::Schema) do
      use GraphQL::Execution::Next if defined?(GraphQL::Execution::Next)
      query(query)
      subscription(subscription)
      use armory::Versioning, versions: LABELS, retired: retired, default: :latest
      use armory::Authorization, adapter: adapter, on_unauthorized: on_unauthorized
      use armory::PersistedQueries, store: manifest, strict: strict
      use armory::RateLimits::Points, store: rate_store, limit: rate_limit, soft: false
      use armory::RateLimits::Time, store: time_store, limit: 1_000_000, soft: false if time_store
      use armory::RateLimits::Concurrency, store: concurrency_store, limit: 5, soft: false if concurrency_store
      use subs, **subscriptions if subscriptions
    end
  end

  def self.mini_schema(&block)
    q = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :ping, String, null: true
    end
    s = Class.new(GraphQL::Schema::Object) do
      graphql_name "Subscription"
    end
    s.class_eval(&block)
    Class.new(GraphQL::Schema) do
      query(q)
      subscription(s)
    end
  end
end

RSpec.describe "Verifier probes: subscriptions over hosted pub/sub (PR #78)" do
  include SubscriptionsVerifierProbes

  let(:subs) { SubscriptionsVerifierProbes::Subs }
  let(:ctl) { SubscriptionsVerifierProbes::Ctl }
  let(:directory) { ctl::Directory.example }
  let(:store) { ctl::Store.example }
  let(:transport) { ctl::Transport.example }
  let(:encoder) { ctl::AppEncoder.example }
  let(:signals) { [] }
  let(:sink) { ->(signal, data) { signals << [signal, data] } }
  let(:msg_doc) { "subscription($roomId: ID!) { messagePosted(roomId: $roomId) { id body seenBy } }" }

  def opts(**overrides)
    ctl::Options.example(directory: directory, store: store, transport: transport, encoder: encoder, sinks: [sink], **overrides)
  end

  def build(**options)
    SubscriptionsVerifierProbes.schema(directory: directory, **options)
  end

  def user(id) = directory.find(id)

  def subscribe(schema, uid, doc = msg_doc, variables: { "roomId" => "5" }, context: {})
    ctx = { current_user: uid && user(uid), current_user_id: uid, rate_limit_key: "key-#{uid}", tenant_id: "t1", armory_allow_raw_query: true }.merge(context)
    result = execute_query(schema, doc, variables: variables, context: ctx)
    [result, schema.subscriptions.channel_for(result.query)]
  end

  def post(schema, owner: nil, body: "hello", room: "5", scope: "t1", args: nil, **kw)
    message = SubscriptionsVerifierProbes::OwnedMessage.new(id: "m1", body: body, room_id: room, edited: false, owner: owner)
    schema.subscriptions.trigger(:message_posted, args || { "roomId" => room }, message, scope: scope, **kw)
  end

  def payloads(channel) = transport.delivered_to(channel).map(&:payload)
  def id_of(channel) = transport.id_from(channel)

  def record_of(channel)
    id = id_of(channel)
    JSON.parse(encoder.open(store.records.fetch(id), aad: id, purpose: "subscription"))
  end

  def far_future = (Time.now.to_f * 1000).to_i + 3_600_000

  def anon(**o) = opts(viewer: nil, anonymous: "public feed", cap_key: ->(c) { c[:ip] }, context_keys: { tenant_id: "tenant", current_user_id: "inbox scope" }, **o)

  def codes(result) = (result["errors"] || []).map { |error| error.dig("extensions", "code") }

  # A stand-in GlobalID::Locator that would hand back a record holding a secret, removed again afterwards. It yields
  # the ids it was asked to locate.
  def with_fake_global_id
    skip "a real GlobalID is loaded" if defined?(::GlobalID)
    calls = []
    record = Struct.new(:secret) { def inspect = "#<Invoice 42 secret=INVOICE-42-SECRET>" }.new("INVOICE-42-SECRET")
    locator = Module.new
    locator.define_singleton_method(:locate) { |id, *| calls << id && record }
    locator.define_singleton_method(:locate_many) { |ids, *| calls.concat(ids) && [] }
    installed = Object.const_set(:GlobalID, Module.new)
    installed.const_set(:Locator, locator)
    yield calls
  ensure
    Object.send(:remove_const, :GlobalID) if installed
  end

  # ---------------------------------------------------------------------------------------------------------------
  # 1. Cross-viewer delivery
  describe "1 cross-viewer" do
    it "[security] 1.1 B never receives A's message on the same topic (owner policy)" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1")
      _, b = subscribe(schema, "user-2")
      post(schema, owner: "user-1", body: "SECRET-A")
      expect(payloads(a).first.dig(:result, "data", "messagePosted", "body")).to eq("SECRET-A")
      expect(JSON.generate(payloads(b))).not_to include("SECRET-A")
      expect(payloads(b).last[:more]).to be(false)
      # documented limit: a null root field ends the subscription, so user-1's message ended user-2's subscription
      expect(store.records.keys).to eq([id_of(a)])
    end

    it "[security] 1.2 a field marked broadcastable: true still runs per subscriber" do
      schema = build(subscriptions: opts, broadcastable: true)
      _, a = subscribe(schema, "user-1")
      _, b = subscribe(schema, "user-2")
      post(schema, owner: "user-1", body: "SECRET-A")
      expect(payloads(a).first.dig(:result, "data", "messagePosted", "body")).to eq("SECRET-A")
      expect(JSON.generate(payloads(b))).not_to include("SECRET-A")
      expect(payloads(b).first.dig(:result, "data", "messagePosted", "seenBy")).to be_nil
    end

    it "[security] 1.3 a subscription_scope from the viewer reaches only that viewer" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1", "subscription { inboxChanged { unread } }", variables: {})
      _, b = subscribe(schema, "user-2", "subscription { inboxChanged { unread } }", variables: {})
      schema.subscriptions.trigger(:inbox_changed, {}, ctl::Schema::Inbox.new(unread: 7), scope: "user-1")
      expect(payloads(a).map { |p| p.dig(:result, "data", "inboxChanged", "unread") }).to eq([7])
      expect(payloads(b)).to eq([])
    end

    it "[security] 1.4 anonymous mode executes each subscriber on its own channel" do
      schema = build(subscriptions: anon, adapter: SubscriptionsVerifierProbes::AllowAll.new(directory))
      _, a = subscribe(schema, nil, context: { ip: "1.1.1.1" })
      _, b = subscribe(schema, nil, context: { ip: "2.2.2.2" })
      expect(a).not_to eq(b)
      post(schema, body: "public")
      expect(transport.published.size).to eq(2)
      expect(transport.published.map(&:channel).sort).to eq([a, b].sort)
    end

    it "[security] 1.5 each subscriber gets exactly one message on its own channel" do
      schema = build(subscriptions: opts)
      channels = %w[user-1 user-2 user-1].map { |u| subscribe(schema, u)[1] }
      post(schema, body: "x")
      expect(transport.published.map(&:channel).sort).to eq(channels.sort)
    end

    it "[security] 1.6 a trigger from inside user-2's request delivers to user-1 as user-1, and nothing to user-2" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1")
      _, b = subscribe(schema, "user-2")
      result = execute_query(schema, "{ fire }", context: { current_user: user("user-2"), rate_limit_key: "k2", armory_allow_raw_query: true, admin: true })
      expect(result["data"]).to eq("fire" => "fired")
      seen = payloads(a).first.dig(:result, "data", "messagePosted", "seenBy")
      expect(seen).to start_with("user-1|nil|")
      expect(JSON.generate(payloads(b))).not_to include("FIRED-FOR-USER-1")
    end
  end

  # ---------------------------------------------------------------------------------------------------------------
  # 2. Trigger context
  describe "2 trigger context" do
    it "[security] 2.1 trigger context: with a viewer raises (Symbol and String keys) and publishes nothing" do
      schema = build(subscriptions: opts)
      subscribe(schema, "user-1")
      expect { post(schema, context: { current_user: user("user-2") }) }.to raise_error(ArgumentError)
      expect { post(schema, context: { "current_user" => user("user-2") }) }.to raise_error(ArgumentError)
      expect { post(schema, context: { armory_version: "2024-06-01" }) }.to raise_error(ArgumentError)
      expect(transport.published).to eq([])
    end

    it "[preservation] 2.2 trigger with context: {} and context: nil delivers" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1")
      post(schema, context: {})
      post(schema, context: nil)
      expect(payloads(a).size).to eq(2)
    end

    it "[security] 2.3 trigger version: never reaches the delivery (a field of the latest version still resolves)" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1", "subscription($roomId: ID!) { messagePosted(roomId: $roomId) { id edited seenBy } }")
      post(schema, version: "2024-06-01")
      payload = payloads(a).first
      expect(payload[:more]).to be(true)
      expect(payload.dig(:result, "data", "messagePosted", "edited")).to be(false)
      expect(payload.dig(:result, "data", "messagePosted", "seenBy")).to include('"2025-01-01"')
    end

    it "[security] 2.4 a context value the app copied at subscribe (admin: true, not in context_keys) is not restored" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1", context: { admin: true })
      post(schema)
      expect(payloads(a).first.dig(:result, "data", "messagePosted", "seenBy")).to eq('user-1|nil|"2025-01-01"|"t1"')
    end

    it "[preservation] 2.5 keyword-style Symbol args and GraphQL-named String args both deliver" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1")
      post(schema, args: { room_id: "5" })
      post(schema, args: { roomId: 5 })
      post(schema, args: { "roomId" => "5" })
      expect(payloads(a).size).to eq(3)
    end
  end

  # ---------------------------------------------------------------------------------------------------------------
  # 3. Topics
  describe "3 topics" do
    let(:full_doc) { "subscription($roomId: ID!, $p: Priority, $on: Date, $f: MessageFilter) { messagePosted(roomId: $roomId, priority: $p, on: $on, filter: $f) { id } }" }

    it "[preservation] 3.4 defaults: omitted on both sides meet; the default given explicitly meets; another value does not" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1")
      post(schema, args: { "roomId" => "5" })
      post(schema, args: { "roomId" => "5", "filter" => { "priority" => "LOW" } })
      post(schema, args: { "roomId" => "5", "filter" => { priority: :low } })
      post(schema, args: { "roomId" => "5", "filter" => { "priority" => "HIGH" } })
      expect(payloads(a).size).to eq(3)
    end

    it "[preservation] 3.5 a nested input object with a Date meets a trigger with a Date object" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1", full_doc, variables: { "roomId" => "5", "f" => { "window" => { "from" => "2025-03-01" } } })
      post(schema, args: { "roomId" => "5", "filter" => { "window" => { "from" => Date.new(2025, 3, 1) } } })
      post(schema, args: { roomId: "5", filter: { window: { from: "2025-03-01" }, priority: "LOW" } })
      expect(payloads(a).size).to eq(2)
    end

    it "[preservation] 3.6 list wrapping: a single value subscribed meets a one-item list trigger" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1", "subscription { messagePosted(roomId: 5, filter: { priorities: HIGH }) { id } }", variables: {})
      post(schema, args: { "roomId" => "5", "filter" => { "priorities" => ["HIGH"] } })
      post(schema, args: { "roomId" => "5", "filter" => { "priorities" => [:high] } })
      expect(payloads(a).size).to eq(2)
    end

    it "[preservation] 3.6b a single (unwrapped) value in a trigger for a list argument delivers or raises ArgumentError, never NoMethodError" do
      pending "documented limit: a single value for a list argument in trigger raises graphql-ruby's own NoMethodError"

      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1", "subscription { messagePosted(roomId: 5, filter: { priorities: HIGH }) { id } }", variables: {})
      outcome = begin
        post(schema, args: { "roomId" => "5", "filter" => { "priorities" => "HIGH" } })
        :returned
      rescue StandardError => error
        error.class
      end
      expect([:returned, ArgumentError, GraphQL::Subscriptions::InvalidTriggerError]).to include(outcome)
      expect(payloads(a).size).to eq(1) if outcome == :returned
    end

    it "[preservation] 3.7 a Float argument meets Integer and Float triggers of the same value only" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1", "subscription { messagePosted(roomId: 5, filter: { minScore: 1 }) { id } }", variables: {})
      post(schema, args: { "roomId" => "5", "filter" => { "minScore" => 1 } })
      post(schema, args: { "roomId" => "5", "filter" => { "minScore" => 1.0 } })
      post(schema, args: { "roomId" => "5", "filter" => { "minScore" => 1.5 } })
      expect(payloads(a).size).to eq(2)
    end

    it "[preservation] 3.10 Hash key order and String vs Symbol keys give one digest" do
      schema = build(subscriptions: opts)
      field = schema.subscription.fields["messagePosted"]
      d1 = subs::Topic.digest(encoder, field, { roomId: "5", priority: "HIGH" }, "t")
      d2 = subs::Topic.digest(encoder, field, { "priority" => :high, "room_id" => 5 }, "t")
      expect(d1).to eq(d2)
    end

    it "[security] 3.11 two fields with the same arguments never share a digest" do
      schema = build(subscriptions: opts)
      m = subs::Topic.digest(encoder, schema.subscription.fields["messagePosted"], { roomId: "5" }, nil)
      r = subs::Topic.digest(encoder, schema.subscription.fields["roomUpdated"], { roomId: "5" }, nil)
      expect(m).not_to eq(r)
    end

    it "[preservation] 3.12 NFC and NFD stay distinct; invalid UTF-8 raises ArgumentError" do
      schema = build(subscriptions: opts)
      field = schema.subscription.fields["roomUpdated"]
      nfc = subs::Topic.digest(encoder, field, { roomId: "café" }, nil)
      nfd = subs::Topic.digest(encoder, field, { roomId: "café" }, nil)
      expect(nfc).not_to eq(nfd)
      expect { subs::Topic.digest(encoder, field, { roomId: "\xff".dup.force_encoding("UTF-8") }, nil) }.to raise_error(ArgumentError)
    end

    it "[preservation] 3.13 an omitted nullable argument and a trigger passing it as nil (graphql-ruby parity)" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1", "subscription { roomUpdated(roomId: \"5\") { id } }", variables: {})
      schema.subscriptions.trigger(:room_updated, { "roomId" => "5", "thread" => nil }, ctl::Schema::Room.new(id: "5", name: "n"))
      graphql_same = GraphQL::Subscriptions::Event.serialize("roomUpdated", { "roomId" => "5" }, schema.subscription.fields["roomUpdated"], scope: nil) ==
                     GraphQL::Subscriptions::Event.serialize("roomUpdated", { "roomId" => "5", "thread" => nil }, schema.subscription.fields["roomUpdated"], scope: nil)
      expect(payloads(a).size).to eq(graphql_same ? 1 : 0)
    end

    it "[security] 3.14 a scope Hash with keys that stringify alike, and a Symbol scope, raise" do
      schema = build(subscriptions: opts)
      expect { post(schema, scope: { "a" => 1, a: 2 }) }.to raise_error(ArgumentError)
      expect { post(schema, scope: :t1) }.to raise_error(ArgumentError)
    end

    it "[preservation] 3.15 a scope restored through viewer: { sets: } fires on delivery" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1", "subscription { inboxChanged { unread } }", variables: {})
      schema.subscriptions.trigger(:inbox_changed, {}, ctl::Schema::Inbox.new(unread: 3), scope: "user-1")
      schema.subscriptions.trigger(:inbox_changed, {}, ctl::Schema::Inbox.new(unread: 4), scope: "user-1")
      expect(payloads(a).map { |p| p[:more] }).to eq([true, true])
    end
  end

  # ---------------------------------------------------------------------------------------------------------------
  # 4. Lost access
  describe "4 lost access" do
    it "[security] 4.5 a stored version retired by a later deploy ends the subscription without data" do
      first = build(subscriptions: opts)
      _, a = subscribe(first, "user-1", context: { armory_version: "2024-06-01" })
      later = build(subscriptions: opts, retired: %w[2024-01-15 2024-06-01])
      post(later, body: "RETIRED-DATA")
      expect(JSON.generate(payloads(a))).not_to include("RETIRED-DATA")
      expect(payloads(a).last[:more]).to be(false)
      expect(store.records).to be_empty
    end

    it "[security] 4.6 PersistedQueries strict: the stored operation removed ends the subscription without data" do
      first = build(subscriptions: opts)
      result = execute_query(first, nil, variables: { "roomId" => "5" }, context: { current_user: user("user-1"), rate_limit_key: "k", tenant_id: "t1", operation_id: "message-posted" })
      a = first.subscriptions.channel_for(result.query)
      expect(a).to be_a(String)
      later = build(subscriptions: opts, documents: ctl::Schema::DOCUMENTS.reject { |k, _| k == "message-posted" })
      post(later, body: "UNPERSISTED-DATA")
      expect(JSON.generate(payloads(a))).not_to include("UNPERSISTED-DATA")
      expect(payloads(a).last[:more]).to be(false)
      expect(store.records).to be_empty
    end

    it "[security] 4.8 a refused subscribe (retired version) stores nothing" do
      schema = build(subscriptions: opts)
      result, channel = subscribe(schema, "user-1", context: { armory_version: "2024-01-15" })
      expect(result["data"]).to be_nil.or eq({})
      expect(channel).to be_nil
      expect(store.records).to be_empty
    end

    it "[security] 4.9 a resolver-class subscription (install template shape) whose authorized? fails on update ends" do
      dir = directory
      sub_class = Class.new(GraphQL::Schema::Subscription) do
        graphql_name "WatchRoom"
        argument :room_id, GraphQL::Types::ID
        type GraphQL::Types::String, null: true
        define_method(:authorized?) { |**_args| dir.allowed?(context[:current_user]) }
        def update(room_id:) = object
      end
      schema = build(subscriptions: opts, extra_subscription: ->(_types) { field :watch_room, subscription: sub_class })
      _, a = subscribe(schema, "user-1", "subscription { watchRoom(roomId: 1) }", variables: {})
      schema.subscriptions.trigger(:watch_room, { "roomId" => "1" }, "FIRST")
      directory.revoke("user-1")
      schema.subscriptions.trigger(:watch_room, { "roomId" => "1" }, "SECOND-SECRET")
      expect(payloads(a).first.dig(:result, "data", "watchRoom")).to eq("FIRST")
      expect(JSON.generate(payloads(a))).not_to include("SECOND-SECRET")
      expect(payloads(a).last[:more]).to be(false)
      expect(store.records).to be_empty
    end

    it "[preservation] 4.10 unsubscribe in update sends the final result with more:false and deletes" do
      sub_class = Class.new(GraphQL::Schema::Subscription) do
        graphql_name "LastWord"
        type GraphQL::Types::String, null: true
        def update
          unsubscribe(object)
        end
      end
      schema = build(subscriptions: opts, extra_subscription: ->(_types) { field :last_word, subscription: sub_class })
      _, a = subscribe(schema, "user-1", "subscription { lastWord }", variables: {})
      schema.subscriptions.trigger(:last_word, {}, "bye")
      expect(payloads(a)).to eq([{ result: { "data" => { "lastWord" => "bye" } }, more: false }])
      expect(store.records).to be_empty
    end

    it "[security] 4.11 a revoked subscriber is reported: the subscribe itself (no object yet) is stored, and ends at the first trigger" do
      directory.revoke("user-2")
      schema = build(subscriptions: opts)
      _, b = subscribe(schema, "user-2")
      stored_before = store.records.size
      post(schema, owner: "user-2", body: "REVOKED-AT-SUBSCRIBE")
      expect(JSON.generate(payloads(b))).not_to include("REVOKED-AT-SUBSCRIBE")
      expect(store.records).to be_empty
      expect(stored_before).to eq(1) # documented limit: a refused viewer holds a subscription until the first trigger
    end
  end

  # ---------------------------------------------------------------------------------------------------------------
  # 5. Context restoration
  describe "5 context restoration" do
    it "[security] 5.1 the decided version label is stored and a delivery runs it, whatever the trigger's version" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1", context: { armory_version: "2024-06-01" })
      _, b = subscribe(schema, "user-2")
      expect(record_of(a)["version"]).to eq("2024-06-01")
      expect(record_of(b)["version"]).to eq("2025-01-01")
      post(schema, version: "2025-01-01")
      expect(payloads(a).first.dig(:result, "data", "messagePosted", "seenBy")).to include('"2024-06-01"')
    end

    %i[armory_version operation_id armory_allow_raw_query visibility_profile subscription_id].each do |key|
      it "[security] 5.2 context_keys: #{key} is refused" do
        expect { build(subscriptions: opts(context_keys: { key => "a reason" })) }.to raise_error(subs::ConfigurationError)
      end
    end

    it "[security] 5.3 a context_keys value that does not round-trip refuses the subscription and stores nothing" do
      schema = build(subscriptions: opts)
      result, channel = subscribe(schema, "user-1", context: { tenant_id: Object.new })
      expect(codes(result)).to include("SUBSCRIPTION_REFUSED")
      expect(channel).to be_nil
      expect(store.records).to be_empty
    end

    it "[security] 5.4 a load that leaves another viewer ends the subscription with no data" do
      dir = directory
      bad = { dump: ->(c) { c[:current_user]&.id }, load: ->(_id, c) { c[:current_user] = dir.find("user-2"); c[:current_user_id] = "user-2" }, sets: %i[current_user current_user_id] }
      schema = build(subscriptions: opts(viewer: bad))
      _, a = subscribe(schema, "user-1")
      post(schema, owner: "user-2", body: "USER-2-ONLY")
      expect(payloads(a)).to eq([{ more: false }])
      expect(store.records).to be_empty
    end

    it "[security] 5.5 the stored engine is the engine that ran, not a client-set __graphql_execute_next" do
      # On Next graphql-ruby sets the key itself; on the interpreter a context that copies client input decides it.
      pending "documented limit: the stored engine comes from context[:__graphql_execute_next]" unless ArmoryEngine.next?

      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1", context: { __graphql_execute_next: true })
      expected = ArmoryEngine.next? ? "next" : "interpreter"
      engine = record_of(a)["engine"]
      post(schema, body: "E")
      expect(payloads(a).size).to eq(1)
      expect(engine).to eq(expected)
    end

    it "[security] 5.7 a client operation_id that does not match the text refuses the subscribe and stores nothing" do
      schema = build(subscriptions: opts)
      result = execute_query(schema, msg_doc, variables: { "roomId" => "5" }, context: { current_user: user("user-1"), rate_limit_key: "k", tenant_id: "t1", operation_id: "room-updated" })
      expect(result["errors"]).not_to be_empty
      expect(store.records).to be_empty
    end

    it "[security] 5.8 the record holds no context value outside context_keys (sealed JSON)" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1", context: { admin: true, secret_token: "TOKEN-XYZ" })
      record = record_of(a)
      expect(record["context"].keys).to eq(["tenant_id"])
      expect(JSON.generate(record)).not_to include("TOKEN-XYZ")
    end
  end

  # ---------------------------------------------------------------------------------------------------------------
  # 6. RateLimits exemption (positive side; the negative side is in verify_rate_limits_probes_spec.rb)
  describe "6 rate limits" do

    it "[security] 6.4 Subscriptions.delivery? is false for anything but a delivery the core built" do
      schema = build(subscriptions: opts)
      q = GraphQL::Query.new(schema, "{ ping }", context: { subscription_delivery: true, armory: { subscription_delivery: true } })
      expect(subs.delivery?(q.context)).to be(false)
      expect(subs.delivery?({ subscription_delivery: true })).to be(false)
      expect(subs.delivery?(nil)).to be(false)
      expect(subs.delivery?(GraphQL::Query::NullContext.instance)).to be(false)
      sub_ctx = Class.new(GraphQL::Query::Context)
      expect(subs.delivery?(sub_ctx.new(query: q, values: { subscription_delivery: true }))).to be(false)
      delivered = GraphQL::Query.new(schema, "{ ping }")
      subs.delivery!(delivered.context, "x")
      expect(subs.delivery?(delivered.context)).to be(true)
      copied = GraphQL::Query.new(schema, "{ ping }", context: delivered.context.to_h)
      expect(subs.delivery?(copied.context)).to be(false)
    end
  end

  # ---------------------------------------------------------------------------------------------------------------
  # 7. Ids and channels
  describe "7 ids and channels" do
    [["Symbol", :victim], ["false", false], ["empty String", ""]].each do |name, value|
      it "[security] 7.1 a client-set subscription_id (#{name}) is refused and nothing is stored" do
        schema = build(subscriptions: opts)
        result, channel = subscribe(schema, "user-1", context: { subscription_id: value })
        expect(codes(result)).to include("SUBSCRIPTION_REFUSED")
        expect(channel).to be_nil
        expect(store.records).to be_empty
      end
    end

    it "[preservation] 7.1b subscription_id: nil is accepted with a server-built id" do
      schema = build(subscriptions: opts)
      _, channel = subscribe(schema, "user-1", context: { subscription_id: nil })
      expect(id_of(channel)).to match(/\A[A-Za-z0-9_-]{43}\z/)
    end

    describe "Pusher" do
      let(:http) { subs::Http::Substitute.new }
      let(:transport) { subs::Pusher.build(app_id: "3", key: "278d425bdf160c739803", secret: "7ad3773142a6692b25b8", cluster: "eu", http: http) }
      let(:schema) { build(subscriptions: opts) }

      it "[security] 7.3 own channel signs; another viewer's channel, malformed socket ids and altered channels do not" do
        _, a = subscribe(schema, "user-1")
        _, b = subscribe(schema, "user-2")
        core = schema.subscriptions
        me = { current_user: user("user-1") }
        auth = core.authorize_channel(channel: a, socket_id: "1234.1234", context: me)
        expect(auth).to eq("auth" => "278d425bdf160c739803:#{OpenSSL::HMAC.hexdigest("SHA256", "7ad3773142a6692b25b8", "1234.1234:#{a}")}")
        expect(core.authorize_channel(channel: b, socket_id: "1234.1234", context: me)).to be_nil
        ["1234.1234\n", "1234.1234:x", "a.b", " 1234.1234", "", nil, 1234].each do |socket|
          expect(core.authorize_channel(channel: a, socket_id: socket, context: me)).to be_nil
        end
        ["#{a}\n", "#{a}-x", a.sub("private-", "PRIVATE-"), "#{a}:x", "presence-#{a.delete_prefix("private-")}", a.sub("graphql", "graphqlx")].each do |channel|
          expect(core.authorize_channel(channel: channel, socket_id: "1234.1234", context: me)).to be_nil
        end
        expect(core.authorize_channel(channel: a, socket_id: "1234.1234", context: {})).to be_nil
        expect(core.authorize_channel(channel: a, socket_id: "1234.1234", context: { current_user: user("user-2") })).to be_nil
      end

      it "[security] 7.4 a deleted or expired subscription's channel is not signed" do
        clock = subs::Core::Clock::Substitute.new(now: 5_000_000_000)
        schema.subscriptions.clock = clock
        _, a = subscribe(schema, "user-1")
        me = { current_user: user("user-1") }
        clock.advance(3_600_000)
        expect(schema.subscriptions.authorize_channel(channel: a, socket_id: "1.1", context: me)).to be_nil
        _, b = subscribe(schema, "user-1")
        schema.subscriptions.delete_subscription(id_of(b))
        expect(schema.subscriptions.authorize_channel(channel: b, socket_id: "1.1", context: me)).to be_nil
      end

      it "[security] 7.5 authorize_viewer answers nil on a channel transport" do
        expect(schema.subscriptions.authorize_viewer(context: { current_user: user("user-1") })).to be_nil
      end
    end

    describe "Ably" do
      let(:http) { subs::Http::Substitute.new }
      let(:transport) { subs::Ably.build(key: "appid.keyid:secretsecret", http: http, nonce: -> { "n" * 24 }) }
      let(:schema) { build(subscriptions: opts) }

      it "[security] 7.6 the token names the viewer's own channels only, with the viewer digest as clientId; no viewer, no token; authorize_channel nil" do
        _, a = subscribe(schema, "user-1")
        _, b = subscribe(schema, "user-2")
        token = schema.subscriptions.authorize_viewer(context: { current_user: user("user-1") })
        capability = JSON.parse(token["capability"])
        expect(capability.keys.size).to eq(1)
        resource = capability.keys.first
        expect(resource).to end_with(":*")
        expect(a).to start_with(resource.delete_suffix("*"))
        expect(b).not_to start_with(resource.delete_suffix("*"))
        expect(resource.split(":").size).to eq(3)
        expect(capability.values.first).to eq(%w[presence subscribe])
        expect(token["clientId"]).to eq(resource.split(":")[1])
        expect(schema.subscriptions.authorize_viewer(context: {})).to be_nil
        expect(schema.subscriptions.authorize_channel(channel: a, socket_id: "1.1", context: { current_user: user("user-1") })).to be_nil
      end
    end
  end

  # ---------------------------------------------------------------------------------------------------------------
  # 8. Sealing and the store
  describe "8 sealing and store" do
    it "[security] 8.1 swapped sealed blobs between two ids are never loaded: both deleted, nothing published" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1")
      _, b = subscribe(schema, "user-2")
      ia = id_of(a)
      ib = id_of(b)
      sealed = store.records
      digest = JSON.parse(encoder.open(sealed[ia], aad: ia, purpose: "subscription"))["events"].first["digest"]
      store.poison(ia, sealed[ib], topics: [digest], expires_at: far_future)
      store.poison(ib, sealed[ia], topics: [digest], expires_at: far_future)
      post(schema, owner: "user-1", body: "SWAP")
      expect(transport.published).to eq([])
      expect(store.records).to be_empty
      expect(signals.map(&:first).count(:subscription_record_unreadable)).to eq(2)
    end

    it "[security] 8.2 garbage and another key's seal are deleted, never loaded" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1")
      ia = id_of(a)
      digest = record_of(a)["events"].first["digest"]
      other = ctl::AppEncoder.example("another-key-entirely-another-key")
      store.poison(ia, other.seal(JSON.generate(record_of(a)), aad: ia, purpose: "subscription"), topics: [digest], expires_at: far_future)
      post(schema)
      expect(transport.published).to eq([])
      expect(store.records).to be_empty
      store.poison("Z" * 43, "garbage", topics: [digest], expires_at: far_future)
      post(schema)
      expect(transport.published).to eq([])
      expect(store.records).to be_empty
    end

    it "[security] 8.3 index/record drift: a record listed under another topic is dropped, never executed" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1")
      _, b = subscribe(schema, "user-2", variables: { "roomId" => "6" })
      d5 = record_of(a)["events"].first["digest"]
      ib = id_of(b)
      store.poison(ib, store.records[ib], topics: [d5], expires_at: far_future)
      post(schema, body: "DRIFT")
      expect(payloads(b)).to eq([])
      expect(store.records.keys).to eq([id_of(a)])
    end

    it "[security] 8.9 a client variable with graphql-ruby's reserved key (__sym__) reaches the delivery as the client sent it" do
      echo = Class.new(GraphQL::Schema::Subscription) do
        graphql_name "EchoJson"
        argument :payload, GraphQL::Types::JSON
        type GraphQL::Types::String, null: true
        def update(payload:) = "#{payload.class}:#{payload.inspect}"
      end
      schema = build(subscriptions: opts, extra_subscription: ->(_types) { field :echo_json, subscription: echo })
      _, a = subscribe(schema, "user-1", "subscription($p: JSON!) { echoJson(payload: $p) }", variables: { "p" => { "__sym__" => "admin" } })
      expect(a).to be_a(String)
      schema.subscriptions.trigger(:echo_json, { "payload" => { "__sym__" => "admin" } }, "x")
      expect(payloads(a).first.dig(:result, "data", "echoJson")).to start_with("Hash:")
    end

    it "[security] 8.10 a client variable naming a GlobalID never makes a delivery locate a record" do
      with_fake_global_id do |calls|
        echo = Class.new(GraphQL::Schema::Subscription) do
          graphql_name "EchoGid"
          argument :payload, GraphQL::Types::JSON
          type GraphQL::Types::String, null: true
          def update(payload:) = "#{payload.class}:#{payload.inspect}"
        end
        schema = build(subscriptions: opts, extra_subscription: ->(_types) { field :echo_gid, subscription: echo })
        variables = { "p" => { "__gid__" => "gid://app/Invoice/42" } }
        _, a = subscribe(schema, "user-1", "subscription($p: JSON!) { echoGid(payload: $p) }", variables: variables)
        schema.subscriptions.trigger(:echo_gid, { "payload" => { "__gid__" => "gid://app/Invoice/42" } }, "x")
        expect(calls).to eq([])
        expect(JSON.generate(payloads(a))).not_to include("INVOICE-42-SECRET")
        expect(payloads(a).first.dig(:result, "data", "echoGid")).to start_with("Hash:")
      end
    end

    it "[security] 8.11 a client variable naming a GlobalID in a nested field argument never reaches the result as a located record" do
      with_fake_global_id do |calls|
        schema = build(subscriptions: opts)
        doc = "subscription($roomId: ID!, $p: JSON!) { messagePosted(roomId: $roomId) { id echo(value: $p) } }"
        _, a = subscribe(schema, "user-1", doc, variables: { "roomId" => "5", "p" => { "__gid__" => "gid://app/Invoice/42" } })
        post(schema, owner: "user-1")
        expect(calls).to eq([])
        expect(JSON.generate(payloads(a))).not_to include("INVOICE-42-SECRET")
        expect(payloads(a).first.dig(:result, "data", "messagePosted", "echo")).to eq('{"__gid__"=>"gid://app/Invoice/42"}').or eq('{"__gid__" => "gid://app/Invoice/42"}')
      end
    end

    it "[security] 8.4 a replayed record (deleted, then put back) runs only as its own viewer (informational)" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1")
      ia = id_of(a)
      sealed = store.records[ia]
      digest = record_of(a)["events"].first["digest"]
      schema.subscriptions.delete_subscription(ia)
      store.poison(ia, sealed, topics: [digest], expires_at: far_future)
      post(schema, owner: "user-1", body: "REPLAY")
      expect(payloads(a).first.dig(:result, "data", "messagePosted", "seenBy")).to start_with("user-1|")
    end

    describe "RedisStore" do
      before do
        require "redis"
      end

      let(:redis) { Redis.new(url: ENV.fetch("REDIS_URL", "redis://redis:6379/0")) }
      let(:prefix) { "verify:{#{SecureRandom.hex(4)}}:" }
      let(:store) { subs::RedisStore.build(redis: redis, prefix: prefix) }

      it "[security] 8.5 a raw Redis write swapping sealed blobs is deleted, never loaded" do
        schema = build(subscriptions: opts)
        _, a = subscribe(schema, "user-1")
        _, b = subscribe(schema, "user-2")
        ia = id_of(a)
        ib = id_of(b)
        sa = redis.call("HGET", "#{prefix}r:#{ia}", "sealed")
        sb = redis.call("HGET", "#{prefix}r:#{ib}", "sealed")
        redis.call("HSET", "#{prefix}r:#{ia}", "sealed", sb)
        redis.call("HSET", "#{prefix}r:#{ib}", "sealed", sa)
        post(schema, owner: "user-1", body: "REDIS-SWAP")
        expect(transport.published).to eq([])
        expect(redis.call("EXISTS", "#{prefix}r:#{ia}")).to eq(0)
        expect(redis.call("EXISTS", "#{prefix}r:#{ib}")).to eq(0)
      end

      it "[security] 8.6 the viewer cap holds under 20 concurrent writers" do
        now = 1_000_000
        answers = Array.new(20) do |i|
          Thread.new { store.write("id#{i}#{"x" * 30}", "sealed", topics: ["t" * 64], viewer: "v", expires_at: now + 60_000, viewer_cap: 5, topic_cap: nil, now: now) }
        end.map(&:value)
        expect(answers.count(:ok)).to eq(5)
        expect(store.count("v", now: now)).to eq(5)
      end

      it "[security] 8.7 the topic cap holds under 20 concurrent writers, and expired records free it" do
        now = 1_000_000
        answers = Array.new(20) do |i|
          Thread.new { store.write("id#{i}#{"y" * 30}", "sealed", topics: ["u" * 64], viewer: "v#{i}", expires_at: now + 60_000, viewer_cap: nil, topic_cap: 3, now: now) }
        end.map(&:value)
        expect(answers.count(:ok)).to eq(3)
        later = now + 60_000
        expect(store.write("late#{"z" * 30}", "s", topics: ["u" * 64], viewer: "w", expires_at: later + 1, viewer_cap: nil, topic_cap: 3, now: later)).to eq(:ok)
      end

      it "[security] 8.8 a Redis id planted in a topic index without its record is skipped" do
        schema = build(subscriptions: opts)
        _, a = subscribe(schema, "user-1")
        digest = record_of_redis(a)["events"].first["digest"]
        redis.call("ZADD", "#{prefix}t:#{digest}", (Time.now.to_f * 1000).to_i + 600_000, "Q" * 43)
        post(schema, owner: "user-1")
        expect(transport.published.map(&:channel)).to eq([a])
      end

      def record_of_redis(channel)
        id = id_of(channel)
        JSON.parse(encoder.open(redis.call("HGET", "#{prefix}r:#{id}", "sealed"), aad: id, purpose: "subscription"))
      end
    end
  end

  # ---------------------------------------------------------------------------------------------------------------
  # 9. Webhooks
  describe "9 webhooks" do
    def env_for(body, headers = {}, length: body.bytesize.to_s)
      { "rack.input" => StringIO.new(body), "CONTENT_LENGTH" => length }.merge(headers)
    end

    describe "Pusher" do
      let(:secret) { "7ad3773142a6692b25b8" }
      let(:key) { "278d425bdf160c739803" }
      let(:http) { subs::Http::Substitute.new }
      let(:transport) { subs::Pusher.build(app_id: "3", key: key, secret: secret, cluster: "eu", http: http) }
      let(:schema) { build(subscriptions: opts) }
      let(:now_ms) { (Time.now.to_f * 1000).to_i }

      def pusher_body(channel, name: "channel_vacated", time_ms: now_ms) = JSON.generate(time_ms: time_ms, events: [{ name: name, channel: channel }])

      def signed(body, key: self.key, secret: self.secret)
        { "HTTP_X_PUSHER_KEY" => key, "HTTP_X_PUSHER_SIGNATURE" => OpenSSL::HMAC.hexdigest("SHA256", secret, body) }
      end

      it "[security] 9.1 forged, wrong-key, stale, oversized and Content-Length-lying webhooks are refused and delete nothing" do
        _, a = subscribe(schema, "user-1")
        core = schema.subscriptions
        body = pusher_body(a)
        expect(core.webhook(env_for(body, signed(body, secret: "wrong"))).first).to eq(401)
        expect(core.webhook(env_for(body, signed(body).merge("HTTP_X_PUSHER_KEY" => "other"))).first).to eq(401)
        stale = pusher_body(a, time_ms: now_ms - 6 * 60_000)
        expect(core.webhook(env_for(stale, signed(stale))).first).to eq(401)
        big = JSON.generate(time_ms: now_ms, events: [{ name: "channel_vacated", channel: a }], pad: "p" * 1_048_576)
        expect(core.webhook(env_for(big, signed(big))).first).to eq(401)
        expect(core.webhook(env_for(big, signed(big), length: "10")).first).to eq(401)
        expect(core.webhook(env_for(body, signed(body), length: "99999999")).first).to eq(401)
        expect(core.webhook(env_for(body, {})).first).to eq(401)
        expect(store.records.size).to eq(1)
      end

      it "[security] 9.2 a signed vacated event for another viewer's channel only ends it, never delivers" do
        _, a = subscribe(schema, "user-1")
        _, b = subscribe(schema, "user-2")
        body = pusher_body(b)
        status, = schema.subscriptions.webhook(env_for(body, signed(body)))
        expect(status).to eq(200)
        expect(store.records.keys).to eq([id_of(a)])
        expect(http.requests).to eq([])
      end

      it "[security] 9.3 other event names (occupied, member_removed, client_event) delete nothing" do
        _, a = subscribe(schema, "user-1")
        %w[channel_occupied member_removed client_event].each do |name|
          body = pusher_body(a, name: name)
          schema.subscriptions.webhook(env_for(body, signed(body)))
        end
        expect(store.records.size).to eq(1)
      end

      it "[security] 9.4 a future-dated signed webhook (1 h ahead) is refused as stale and deletes nothing" do
        _, a = subscribe(schema, "user-1")
        body = pusher_body(a, time_ms: now_ms + 3_600_000)
        status, = schema.subscriptions.webhook(env_for(body, signed(body)))
        expect(status).to eq(401)
        expect(signals.select { |s, _| s == :subscription_webhook_refused }.map { |_, d| d[:reason] }).to eq([:stale])
        expect(store.records.size).to eq(1)
      end
    end

    describe "Ably" do
      let(:http) { subs::Http::Substitute.new }
      let(:transport) { subs::Ably.build(key: "appid.keyid:secretsecret", http: http) }
      let(:schema) { build(subscriptions: opts) }
      let(:now_ms) { (Time.now.to_f * 1000).to_i }

      def ably_body(channel, action: 3, timestamp: now_ms)
        JSON.generate(items: [{ source: "channel.presence", timestamp: timestamp, data: { channelId: channel, presence: [{ action: action, clientId: "c", timestamp: timestamp }] } }])
      end

      def signed(body, secret: "secretsecret", key: "appid.keyid")
        { "HTTP_X_ABLY_KEY" => key, "HTTP_X_ABLY_SIGNATURE" => Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret, body)) }
      end

      it "[security] 9.5 Ably: bad signature, wrong key, stale and future events are refused; enter deletes nothing; leave ends" do
        _, a = subscribe(schema, "user-1")
        core = schema.subscriptions
        body = ably_body(a)
        expect(core.webhook(env_for(body, signed(body, secret: "nope"))).first).to eq(401)
        expect(core.webhook(env_for(body, signed(body).merge("HTTP_X_ABLY_SIGNATURE" => "short"))).first).to eq(401)
        expect(core.webhook(env_for(body, signed(body, key: "other.key"))).first).to eq(401)
        stale = ably_body(a, timestamp: now_ms - 6 * 60_000)
        expect(core.webhook(env_for(stale, signed(stale))).first).to eq(401)
        future = ably_body(a, timestamp: now_ms + 6 * 60_000)
        expect(core.webhook(env_for(future, signed(future))).first).to eq(401)
        enter = ably_body(a, action: 2)
        expect(core.webhook(env_for(enter, signed(enter))).first).to eq(200)
        expect(store.records.size).to eq(1)
        expect(core.webhook(env_for(body, signed(body, key: "keyid"))).first).to eq(200)
        expect(store.records).to be_empty
        expect(http.requests).to eq([])
      end
    end

    it "[security] 9.6 WebhookApp answers 404 without this backend (none, graphql-ruby's own, new)" do
      plain = build
      expect(subs::WebhookApp.new(plain).call({}).first).to eq(404)
      expect(subs::WebhookApp.new.call({}).first).to eq(404)
      log = SubscriptionsVerifierProbes.schema(directory: directory)
      log.use(ctl::EventLog)
      expect(subs::WebhookApp.new(log).call({}).first).to eq(404)
    end
  end

  # ---------------------------------------------------------------------------------------------------------------
  # 10. Payload limits and errors
  describe "10 payloads and errors" do
    it "[security] 10.1 a result over the limit becomes RESULT_TOO_LARGE, never a truncated result; the subscription stays" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1", "subscription($roomId: ID!) { messagePosted(roomId: $roomId) { id big } }")
      post(schema)
      payload = payloads(a).first
      expect(payload[:result].dig("errors", 0, "extensions", "code")).to eq("RESULT_TOO_LARGE")
      expect(payload[:result]).not_to have_key("data")
      expect(payload[:more]).to be(true)
      expect(store.records.size).to eq(1)
    end

    it "[preservation] 10.2 compression: compressed_result inflates to the result" do
      transport = ctl::Transport.example(capabilities: ctl::Capabilities.example(compress: true))
      schema = build(subscriptions: opts(transport: transport))
      result = execute_query(schema, msg_doc, variables: { "roomId" => "5" }, context: { current_user: user("user-1"), rate_limit_key: "k", tenant_id: "t1", armory_allow_raw_query: true })
      a = schema.subscriptions.channel_for(result.query)
      post(schema, owner: "user-1", body: "Z")
      payload = transport.delivered_to(a).first.payload
      expect(payload).not_to have_key(:result)
      expect(JSON.parse(Zlib::Inflate.inflate(Base64.strict_decode64(payload[:compressed_result]))).dig("data", "messagePosted", "body")).to eq("Z")
    end

    it "[security] 10.3 transport :gone deletes; :retry and :refused keep" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1")
      _, b = subscribe(schema, "user-1")
      _, c = subscribe(schema, "user-1")
      transport.answer_publish(:gone, channel: a)
      transport.answer_publish(:retry, channel: b)
      transport.answer_publish(:refused, channel: c, reason: :x)
      post(schema)
      expect(store.records.keys.sort).to eq([id_of(b), id_of(c)].sort)
    end

    it "[security] 10.4 an exception in one subscriber does not stop the others (on_delivery_error: :record)" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1", "subscription($roomId: ID!) { messagePosted(roomId: $roomId) { id boom } }")
      _, b = subscribe(schema, "user-2")
      post(schema)
      expect(payloads(b).size).to eq(1)
      expect(signals.map(&:first)).to include(:subscription_delivery_error)
      expect(payloads(a)).to eq([])
    end

    it "[security] 10.5 on_delivery_error: :raise raises after the whole topic was processed" do
      schema = build(subscriptions: opts(on_delivery_error: :raise))
      subscribe(schema, "user-1", "subscription($roomId: ID!) { messagePosted(roomId: $roomId) { id boom } }")
      _, b = subscribe(schema, "user-2")
      expect { post(schema) }.to raise_error(RuntimeError, /boom/)
      expect(payloads(b).size).to eq(1)
    end

    it "[security] 10.6 a publish that raises still deletes the subscriptions that ended" do
      schema = build(subscriptions: opts)
      _, a = subscribe(schema, "user-1")
      _, b = subscribe(schema, "user-2")
      directory.revoke("user-2")
      transport.fail_with(subs::TransportError.new("down"), on: :publish)
      post(schema)
      expect(store.records.keys).to eq([id_of(a)])
      expect(signals.map(&:first)).to include(:subscription_transport_error)
    end

    it "[security] 10.7 a limit too small even for RESULT_TOO_LARGE sends nothing and still ends refused subscribers" do
      transport = ctl::Transport.example(capabilities: ctl::Capabilities.example(max_payload_bytes: 10))
      schema = build(subscriptions: opts(transport: transport))
      execute_query(schema, msg_doc, variables: { "roomId" => "5" }, context: { current_user: user("user-1"), rate_limit_key: "k", tenant_id: "t1", armory_allow_raw_query: true })
      execute_query(schema, msg_doc, variables: { "roomId" => "5" }, context: { current_user: user("user-2"), rate_limit_key: "k2", tenant_id: "t1", armory_allow_raw_query: true })
      directory.revoke("user-2")
      post(schema)
      expect(transport.published).to eq([])
      expect(store.records.size).to eq(1)
    end
  end

  # ---------------------------------------------------------------------------------------------------------------
  # 11. Caps
  describe "11 caps" do
    it "[security] 11.1 max_per_viewer refuses with SUBSCRIPTION_LIMIT and frees on expiry" do
      schema = build(subscriptions: opts(max_per_viewer: 2))
      clock = subs::Core::Clock::Substitute.new(now: 5_000_000_000)
      schema.subscriptions.clock = clock
      2.times { subscribe(schema, "user-1") }
      result, channel = subscribe(schema, "user-1")
      expect(codes(result)).to include("SUBSCRIPTION_LIMIT")
      expect(channel).to be_nil
      expect(subscribe(schema, "user-2")[1]).to be_a(String)
      clock.advance(3_600_000)
      expect(subscribe(schema, "user-1")[1]).to be_a(String)
    end

    it "[security] 11.2 max_per_topic refuses across viewers" do
      schema = build(subscriptions: opts(max_per_topic: 1))
      subscribe(schema, "user-1")
      result, = subscribe(schema, "user-2")
      expect(codes(result)).to include("SUBSCRIPTION_LIMIT")
      expect(subscribe(schema, "user-2", variables: { "roomId" => "6" })[1]).to be_a(String)
    end

    it "[security] 11.3 anonymous cap_key counts per client" do
      schema = build(subscriptions: anon(max_per_viewer: 1), adapter: SubscriptionsVerifierProbes::AllowAll.new(directory))
      expect(subscribe(schema, nil, context: { ip: "1.1.1.1" })[1]).to be_a(String)
      expect(codes(subscribe(schema, nil, context: { ip: "1.1.1.1" })[0])).to include("SUBSCRIPTION_LIMIT")
      expect(subscribe(schema, nil, context: { ip: "2.2.2.2" })[1]).to be_a(String)
      expect(codes(subscribe(schema, nil, context: {})[0])).to include("SUBSCRIPTION_REFUSED")
    end

    it "[security] 11.4 max_executions_per_trigger bounds work, and repeated triggers never starve the same subscribers" do
      schema = build(subscriptions: opts(max_executions_per_trigger: 2))
      channels = Array.new(3) { subscribe(schema, "user-1")[1] }
      post(schema)
      expect(transport.published.size).to eq(2)
      29.times { post(schema) }
      expect(transport.published.size).to eq(60)
      starved = channels.reject { |c| transport.delivered_to(c).any? }
      expect(starved).to eq([])
      expect(signals.select { |s, _| s == :subscription_trigger_budget }.map { |_, d| d[:skipped] }).to eq([1] * 30)
    end
  end

  # ---------------------------------------------------------------------------------------------------------------
  # 12. Options and Doctrine
  describe "12 options" do
    it "[security] 12.1 an unknown or typo'd option raises" do
      expect { build(subscriptions: opts(max_per_viewr: 5)) }.to raise_error(subs::ConfigurationError)
      expect { build(subscriptions: opts(context_key: {})) }.to raise_error(subs::ConfigurationError)
    end

    %i[broadcast default_broadcastable validate_update].each do |name|
      it "[security] 12.2 #{name}: is refused" do
        expect { build(subscriptions: opts(name => false)) }.to raise_error(subs::ConfigurationError)
      end
    end

    it "[security] 12.3 viewer: with an unknown key, viewer with anonymous:, anonymous without cap_key, cap_key with viewer are refused" do
      expect { build(subscriptions: opts(viewer: ctl::Viewer.example(directory).merge(sets_typo: []))) }.to raise_error(subs::ConfigurationError)
      expect { build(subscriptions: opts(anonymous: "x", cap_key: ->(_) { "k" })) }.to raise_error(subs::ConfigurationError)
      expect { build(subscriptions: opts(viewer: nil, anonymous: "x")) }.to raise_error(subs::ConfigurationError)
      expect { build(subscriptions: opts(cap_key: ->(_) { "k" })) }.to raise_error(subs::ConfigurationError)
      expect { build(subscriptions: opts(viewer: nil)) }.to raise_error(subs::ConfigurationError)
    end

    it "[security] 12.4 Subscriptions.new is inert: refuses subscriptions, authorizes nothing, webhook 401" do
      inert = subs.new
      expect(inert.authorize_channel(channel: "substitute:x:y", socket_id: "1.1", context: { current_user: user("user-1") })).to be_nil
      expect(inert.authorize_viewer(context: { current_user: user("user-1") })).to be_nil
      expect(inert.webhook({}).first).to eq(401)
      schema = build
      schema.subscriptions = subs.new(schema: schema)
      schema.add_subscription_extension_if_necessary
      result, channel = subscribe(schema, "user-1")
      expect(codes(result)).to include("SUBSCRIPTION_REFUSED")
      expect(channel).to be_nil
    end

    it "[security] 12.5 Store::Null, Transport::Null and a non-viewer-bound transport with a viewer are refused" do
      expect { build(subscriptions: opts(store: subs::Store::Null.new)) }.to raise_error(subs::ConfigurationError)
      expect { build(subscriptions: opts(transport: subs::Transport::Null.new)) }.to raise_error(subs::ConfigurationError)
      unbound = ctl::Transport.example(capabilities: ctl::Capabilities.example(viewer_bound: false))
      expect { build(subscriptions: opts(transport: unbound)) }.to raise_error(subs::ConfigurationError)
      expect { build(subscriptions: anon(transport: unbound), adapter: SubscriptionsVerifierProbes::AllowAll.new(directory)) }.not_to raise_error
      expect { build(subscriptions: opts(encoder: nil)) }.to raise_error(subs::ConfigurationError)
      expect { build(subscriptions: opts(encoder: SubscriptionsVerifierProbes::Armory::Encoder::Null)) }.to raise_error(subs::ConfigurationError)
    end

    it "[security] 12.6 invalid context_keys, lifetimes, caps and on_delivery_error are refused" do
      [{ context_keys: { tenant_id: "" } }, { context_keys: { "tenant_id" => "r" } }, { context_keys: [:tenant_id] },
       { max_lifetime: 0 }, { max_lifetime: -1 }, { max_lifetime: nil }, { max_lifetime: Float::INFINITY }, { max_lifetime: "3600" },
       { max_per_viewer: 0 }, { max_per_topic: nil }, { max_executions_per_trigger: 1.5 }, { on_delivery_error: :ignore }].each do |bad|
        expect { build(subscriptions: opts(**bad)) }.to raise_error(subs::ConfigurationError), bad.inspect
      end
    end

    describe "12.7 schema checks" do
      def install(schema) = schema.use(subs, **opts)

      it "[security] a scope key a delivery cannot restore is refused (field and resolver-class shapes)" do
        expect { install(SubscriptionsVerifierProbes.mini_schema { field :x, String, null: true, subscription_scope: :org_id }) }.to raise_error(subs::ConfigurationError)
        resolver = Class.new(GraphQL::Schema::Subscription) do
          graphql_name "Scoped"
          type GraphQL::Types::String, null: true
          subscription_scope :org_id
        end
        expect { install(SubscriptionsVerifierProbes.mini_schema { field :y, subscription: resolver }) }.to raise_error(subs::ConfigurationError)
      end

      it "[security] topic_for overrides, loads:, prepare: and an input object with prepare are refused" do
        tf = Class.new(GraphQL::Schema::Subscription) do
          graphql_name "Tf"
          type GraphQL::Types::String, null: true
          def self.topic_for(arguments:, field:, scope:) = "x"
        end
        room = Class.new(GraphQL::Schema::Object) do
          graphql_name "RoomT"
          field :id, GraphQL::Types::ID, null: true
        end
        input = Class.new(GraphQL::Schema::InputObject) do
          graphql_name "Prep"
          argument :a, String
          def prepare = to_h
        end
        expect { install(SubscriptionsVerifierProbes.mini_schema { field :a, subscription: tf }) }.to raise_error(subs::ConfigurationError)
        expect { install(SubscriptionsVerifierProbes.mini_schema { field(:b, String, null: true) { argument :room_id, GraphQL::Types::ID, loads: room } }) }.to raise_error(subs::ConfigurationError)
        expect { install(SubscriptionsVerifierProbes.mini_schema { field(:c, String, null: true) { argument :s, String, prepare: ->(v, _c) { v.upcase } } }) }.to raise_error(subs::ConfigurationError)
        expect { install(SubscriptionsVerifierProbes.mini_schema { field(:d, String, null: true) { argument :items, [input], required: false } }) }.to raise_error(subs::ConfigurationError)
        expect { install(SubscriptionsVerifierProbes.mini_schema { field(:e, String, null: true) { argument :s, String } }) }.not_to raise_error
      end
    end

    it "[security] 12.8 a second install and an install on a child of an installed schema are refused" do
      schema = build(subscriptions: opts)
      expect { schema.use(subs, **opts) }.to raise_error(subs::ConfigurationError)
      expect { Class.new(schema).use(subs, **opts) }.to raise_error(subs::ConfigurationError)
    end

    it "[security] 12.9 transports and stores refuse unknown keywords" do
      expect { subs::Pusher.build(app_id: "3", key: "k", secret: "s", cluster: "eu", encrypted: true) }.to raise_error(ArgumentError)
      expect { subs::Ably.build(key: "a.b:c", cipher: true) }.to raise_error(ArgumentError)
      expect { subs::RedisStore.build(redis: Object.new, ttl: 5) }.to raise_error(ArgumentError)
      expect { subs::Pusher.build(app_id: "3", key: "k", secret: "s", cluster: "eu", host: "x.y") }.to raise_error(subs::ConfigurationError)
    end

    it "[security] 12.10 the backend answers every overridden method itself (method owners)" do
      schema = build(subscriptions: opts)
      core = schema.subscriptions
      %i[write_subscription execute_all delete_subscription execute_update execute deliver trigger build_id broadcastable? validate_update?].each do |name|
        expect(core.method(name).owner).to eq(subs::Core), name.to_s
      end
      expect(subs::Core.method(:use).owner).to eq(subs::Core.singleton_class)
      expect(core.broadcastable?("subscription { x }")).to be(false)
      expect { core.execute_update("id", nil, nil) }.to raise_error(NotImplementedError)
    end

    it "[preservation] 12.11 sinks: receive the module's signals" do
      schema = build(subscriptions: opts)
      subscribe(schema, "user-1")
      post(schema)
      expect(signals.map(&:first)).to include(:subscription_created, :subscription_delivered)
      expect(JSON.generate(signals.map(&:last).map { |d| d.reject { |k, _| k == :context } }.map(&:to_s))).not_to match(/[A-Za-z0-9_-]{43}/)
    end

    it "[security] 12.12 the audit reports broadcastable fields and child schemas" do
      schema = build(subscriptions: opts, broadcastable: true)
      report = subs::Audit.call(schema)
      expect(report.findings.map(&:kind)).to include(:broadcastable)
      expect(subs::Audit.call(Class.new(schema)).ok?).to be(false)
    end
  end

  # ---------------------------------------------------------------------------------------------------------------
  # 14. Signing (no network)
  describe "14 signing" do
    let(:sig) { subs::Pusher::Signature }

    it "[security] 14.1 Pusher private-channel auth matches the documented example" do
      auth = sig.channel_auth(key: "278d425bdf160c739803", secret: "7ad3773142a6692b25b8", socket_id: "1234.1234", channel: "private-foobar")
      expect(auth).to eq("278d425bdf160c739803:58df8b0c36d6982b82c3ecf6b4662e34fe8c25bba48f5369f135bf843651c3a4")
    end

    it "[security] 14.2 Pusher REST signature matches the documented example" do
      body = '{"name":"foo","channels":["project-3"],"data":"{\"some\":\"data\"}"}'
      query = sig.query(key: "278d425bdf160c739803", secret: "7ad3773142a6692b25b8", method: "POST", path: "/apps/3/events", body: body, timestamp: 1_353_088_179)
      params = query.split("&").to_h { |pair| pair.split("=", 2) }
      expect(params["body_md5"]).to eq("ec365a775a4cd0599faeb73354201b6f")
      expect(params["auth_signature"]).to eq("da454824c97ba181a32ccc17a72625ba02771f50b50e1e7430e47a1f3f457e6c")
    end

    it "[security] 14.3 Pusher publish request is signed over its own body and path" do
      http = subs::Http::Substitute.new
      pusher = subs::Pusher.build(app_id: "3", key: "kkk", secret: "sss", cluster: "eu", http: http)
      pusher.publish([subs::Message.new(channel: "private-graphql-abc", payload: { result: { "data" => {} }, more: true })])
      request = http.requests.first
      uri = URI(request[:url])
      params = URI.decode_www_form(uri.query).to_h
      expect(params["body_md5"]).to eq(Digest::MD5.hexdigest(request[:body]))
      unsigned = params.except("auth_signature").sort.map { |k, v| "#{k}=#{v}" }.join("&")
      expect(params["auth_signature"]).to eq(OpenSSL::HMAC.hexdigest("SHA256", "sss", "POST\n#{uri.path}\n#{unsigned}"))
      expect(uri.host).to eq("api-eu.pusher.com")
      expect(JSON.parse(request[:body])["batch"].first).to include("name" => "update", "channel" => "private-graphql-abc")
    end

    it "[security] 14.4 Ably TokenRequest mac follows the token request spec, clientId included" do
      ably = subs::Ably.build(key: "appid.keyid:secretsecret", clock: -> { Time.at(1_700_000_000) }, nonce: -> { "abcdefghijklmnopqrstuvwx" }, http: subs::Http::Substitute.new)
      token = ably.authorize_viewer("a" * 64)
      expect(token["clientId"]).to eq("a" * 64)
      text = ["appid.keyid", token["ttl"], token["capability"], "a" * 64, token["timestamp"], token["nonce"]].map { |f| "#{f}\n" }.join
      expect(token["mac"]).to eq(Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", "secretsecret", text)))
      expect(token["capability"]).to eq(%({"graphql:#{"a" * 64}:*":["presence","subscribe"]}))
      expect(token["timestamp"]).to eq(1_700_000_000_000)
      expect(token["ttl"]).to eq(3_600_000)
    end

    it "[security] 14.5 Ably publish uses Basic auth with the key and one spec per channel" do
      http = subs::Http::Substitute.new
      http.answer(status: 201, body: JSON.generate([{ channel: "graphql:#{"a" * 64}:#{"I" * 43}", messageId: "m" }]))
      ably = subs::Ably.build(key: "appid.keyid:secretsecret", http: http)
      channel = ably.channel_for("I" * 43, "a" * 64)
      outcomes = ably.publish([subs::Message.new(channel: channel, payload: { result: { "data" => {} }, more: true })])
      request = http.requests.first
      expect(request[:headers]["Authorization"]).to eq("Basic #{Base64.strict_encode64("appid.keyid:secretsecret")}")
      expect(request[:url]).to eq("https://rest.ably.io/messages")
      expect(JSON.parse(request[:body])).to eq([{ "channels" => [channel], "messages" => [{ "name" => "update", "data" => JSON.generate(result: { "data" => {} }, more: true), "encoding" => "json" }] }])
      expect(outcomes.map(&:status)).to eq([:ok])
    end

    it "[security] 14.6 Ably id_from refuses another prefix, a missing digest and extra segments" do
      ably = subs::Ably.build(key: "appid.keyid:secretsecret", http: subs::Http::Substitute.new)
      id = "I" * 43
      d = "a" * 64
      expect(ably.id_from("graphql:#{d}:#{id}")).to eq(id)
      ["other:#{d}:#{id}", "graphql:#{id}", "graphql:#{d}:#{id}:x", "graphql:#{d.upcase}:#{id}", "graphql:#{d}:#{id}\n", "graphql:anonymousx:#{id}"].each do |channel|
        expect(ably.id_from(channel)).to be_nil, channel.inspect
      end
    end
  end
end
