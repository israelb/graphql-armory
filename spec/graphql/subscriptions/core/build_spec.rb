# frozen_string_literal: true

require "spec_helper"
require_relative "core_helpers"

RSpec.describe GraphQL::Armory::Subscriptions::Core do
  include SubscriptionsCoreHelpers

  let(:subscriptions) { GraphQL::Armory::Subscriptions }
  let(:configuration_error) { subscriptions::ConfigurationError }

  def options(**overrides)
    controls::Options.example(directory: directory, store: store, transport: transport, **overrides)
  end

  def install(schema_options: {}, **overrides)
    controls::Schema.example(directory: directory, subscriptions: options(**overrides), **schema_options)
  end

  # A control schema whose Subscription root gets `fields` (evaluated in the root class) before the plugin is installed.
  def install_with_field(**overrides, &fields)
    types = controls::Schema::Types.example
    root = Class.new(types.fetch(:object)) do
      graphql_name "Subscription"
      authorize :none, reason: "spec", covers_fields: true
      class_exec(types, &fields)
    end
    query = Class.new(types.fetch(:object)) do
      graphql_name "Query"
      authorize :none, reason: "spec", covers_fields: true
      field :ping, String, null: false
    end
    plugin_options = options(**overrides)
    Class.new(GraphQL::Schema) do
      query(query)
      subscription(root)
      use GraphQL::Armory::Subscriptions, **plugin_options
    end
  end

  describe ".new" do
    it "is inert: Null store, transport and encoder, so it keeps, delivers and authorizes nothing" do
      core = described_class.new

      expect([core.store, core.transport, core.encoder]).to match([a_kind_of(subscriptions::Store::Null), a_kind_of(subscriptions::Transport::Null), GraphQL::Armory::Encoder::Null])
      expect(core.cleanup(now: 5)).to eq(0)
      expect(core.authorize_channel(channel: "substitute:x:y", socket_id: "1.2", context: {})).to be_nil
      expect(core.authorize_viewer(context: {})).to be_nil
      expect(core.webhook({}).first).to eq(401)
      expect(subscriptions.new).to be_a(described_class)
    end

    it "refuses every subscription it is handed" do
      schema = controls::Schema.example(directory: directory, subscriptions: {}, plugin: Class.new(described_class) {
        define_singleton_method(:use) do |schema, **|
          schema.subscriptions = new(schema: schema)
          schema.add_subscription_extension_if_necessary
        end
      })
      result = execute_query(schema, "subscription { messagePosted(roomId: 5) { id } }", context: context_for("user-1"))

      expect(codes(result)).to eq(["SUBSCRIPTION_REFUSED"])
      expect(schema.subscriptions.channel_for(result)).to be_nil
    end
  end

  describe ".use" do
    it "installs a built backend and graphql-ruby's subscription extension on every root field" do
      schema = install

      expect(schema.subscriptions).to be_a(described_class).and(have_attributes(store: store, transport: transport))
      expect(schema.subscription.get_field("messagePosted").extensions).to include(a_kind_of(GraphQL::Subscriptions::DefaultSubscriptionResolveExtension))
    end

    it "refuses a second install, and a child schema of one that has it" do
      schema = install
      child = Class.new(schema)

      expect { subscriptions.use(schema, **options) }.to raise_error(configuration_error, /already has subscriptions/)
      expect { subscriptions.use(child, **options) }.to raise_error(configuration_error, /inherits subscriptions/)
    end

    it "needs the Subscription root declared first" do
      plugin_options = options

      expect { Class.new(GraphQL::Schema) { use GraphQL::Armory::Subscriptions, **plugin_options } }.to raise_error(configuration_error, /no subscription root/)
    end
  end

  describe ".build" do
    it "refuses unknown options, graphql-ruby's broadcast options and validate_update:" do
      expect { install(braodcast: true) }.to raise_error(configuration_error, /unknown option :braodcast/)
      expect { install(broadcast: true) }.to raise_error(configuration_error, /broadcast: is refused/)
      expect { install(default_broadcastable: true) }.to raise_error(configuration_error, /default_broadcastable: is refused/)
      expect { install(validate_update: false) }.to raise_error(configuration_error, /validate_update: is refused/)
    end

    it "requires store:, transport:, encoder: and max_lifetime:" do
      %i[store transport encoder max_lifetime].each do |name|
        plugin_options = options.except(name)
        expect { controls::Schema.example(directory: directory, subscriptions: plugin_options) }.to raise_error(configuration_error, /missing #{name}:/)
      end
    end

    it "refuses the Null store, the Null transport, the Null encoder and objects that are not one" do
      expect { install(store: subscriptions::Store::Null.new) }.to raise_error(configuration_error, /Store::Null keeps no subscription/)
      expect { install(store: Object.new) }.to raise_error(configuration_error, /store: must answer/)
      expect { install(transport: subscriptions::Transport::Null.new) }.to raise_error(configuration_error, /Transport::Null delivers nothing/)
      expect { install(transport: Object.new) }.to raise_error(configuration_error, /transport: must answer/)
      expect { install(encoder: GraphQL::Armory::Encoder::Null) }.to raise_error(configuration_error, /encoder: is required/)
      expect { install(encoder: Object.new) }.to raise_error(configuration_error, /encoder: must answer/)
    end

    it "refuses a lifetime, a cap or an error mode that is not one" do
      [0, -1, Float::INFINITY, "60", nil].each do |value|
        expect { install(max_lifetime: value) }.to raise_error(configuration_error, /max_lifetime: must be a positive number of seconds/)
      end
      %i[max_per_viewer max_per_topic max_executions_per_trigger].each do |name|
        expect { install(name => 0) }.to raise_error(configuration_error, /#{name}: must be a positive Integer/)
        expect { install(name => nil) }.to raise_error(configuration_error, /#{name}: must be a positive Integer/)
      end
      expect { install(on_delivery_error: :ignore) }.to raise_error(configuration_error, /on_delivery_error: must be :record or :raise/)
    end

    it "keeps the settings it was given, the lifetime in milliseconds, with defaults for the caps" do
      settings = install(max_lifetime: 90, max_per_viewer: 7, on_delivery_error: :raise).subscriptions.settings

      expect(settings).to have_attributes(max_lifetime: 90_000, max_per_viewer: 7, max_per_topic: 10_000, max_executions_per_trigger: 10_000,
                                          on_delivery_error: :raise, context_keys: { tenant_id: a_kind_of(String) })
    end

    it "takes context_keys: only as Symbol keys with a reason, never a key the core restores itself" do
      expect { install(context_keys: [:tenant_id]) }.to raise_error(configuration_error, /context_keys: must map Symbol keys/)
      expect { install(context_keys: { tenant_id: "" }) }.to raise_error(configuration_error, /context_keys: must map Symbol keys/)
      expect { install(context_keys: { "tenant_id" => "why" }) }.to raise_error(configuration_error, /context_keys: must map Symbol keys/)
      expect { install(context_keys: { tenant_id: "why", operation_id: "why" }) }.to raise_error(configuration_error, /\[:operation_id\] are set by the core/)
    end

    describe "the viewer" do
      it "requires viewer:, or anonymous: with a reason and cap_key:" do
        expect { install(viewer: nil) }.to raise_error(configuration_error, /viewer: is required/)
        expect { install(viewer: nil, anonymous: "", cap_key: ->(_c) { "ip" }) }.to raise_error(configuration_error, /anonymous: must be a non-empty String/)
        expect { install(viewer: nil, anonymous: "public scores") }.to raise_error(configuration_error, /anonymous: needs cap_key:/)
        expect { install(anonymous: "public scores", cap_key: ->(_c) { "ip" }) }.to raise_error(configuration_error, /give viewer: or anonymous:, not both/)
      end

      it "refuses a viewer without dump: and load: callables, unknown keys or sets: that are not Symbols" do
        viewer = controls::Viewer.example(directory)

        expect { install(viewer: viewer.except(:dump)) }.to raise_error(configuration_error, /dump: must be a callable/)
        expect { install(viewer: viewer.merge(load: "load")) }.to raise_error(configuration_error, /load: must be a callable/)
        expect { install(viewer: viewer.merge(sets: ["current_user"])) }.to raise_error(configuration_error, /sets: must be an Array/)
        expect { install(viewer: viewer.merge(set: [])) }.to raise_error(configuration_error, /unknown keys \[:set\]/)
      end

      it "with a viewer, refuses a transport that is not viewer bound; anonymous takes any" do
        loose = controls::Transport.example(capabilities: controls::Capabilities.example(viewer_bound: false))

        expect { install(transport: loose) }.to raise_error(configuration_error, /is not viewer_bound/)
        expect(install(transport: loose, viewer: nil, anonymous: "public scores", context_keys: { tenant_id: "x", current_user_id: "x" },
                       cap_key: ->(context) { context[:ip] }).subscriptions.settings.viewer).to be_anonymous
      end
    end

    describe "the subscription fields" do
      it "refuses a scope key a delivery cannot restore" do
        expect { install(context_keys: {}) }.to raise_error(configuration_error, /Subscription.messagePosted is scoped by context\[:tenant_id\]/)
        viewer = controls::Viewer.example(directory).merge(sets: [:current_user])

        expect { install(viewer: viewer) }.to raise_error(configuration_error, /Subscription.inboxChanged is scoped by context\[:current_user_id\]/)
      end

      it "refuses a Subscription class that overrides topic_for" do
        resolver = Class.new(GraphQL::Schema::Subscription) do
          graphql_name "Custom"
          type String, null: true
          def self.topic_for(arguments:, field:, scope:) = "everything"
        end

        expect { install_with_field { field :custom, resolver: resolver } }.to raise_error(configuration_error, /overrides topic_for/)
        plain = Class.new(GraphQL::Schema::Subscription) { graphql_name "Plain"; type String, null: true }
        expect(install_with_field { field :plain, resolver: plain }.subscriptions).to be_a(described_class)
      end

      it "refuses loads: and prepare: arguments, and input objects with their own prepare, at any depth" do
        expect { install_with_field { field(:a, String) { argument :thing_id, GraphQL::Types::ID, loads: GraphQL::Types::String } } }
          .to raise_error(configuration_error, /loads: argument Subscription.a.thingId/)
        expect { install_with_field { field(:b, String) { argument :n, Integer, prepare: ->(value, _context) { value * 2 } } } }
          .to raise_error(configuration_error, /prepare: argument Subscription.b.n/)

        nested = Class.new(GraphQL::Schema::InputObject) do
          graphql_name "Nested"
          argument :n, Integer, prepare: ->(value, _context) { value + 1 }
        end
        outer = Class.new(GraphQL::Schema::InputObject) do
          graphql_name "Outer"
          argument :nested, nested
        end
        expect { install_with_field { field(:c, String) { argument :outer, outer } } }.to raise_error(configuration_error, /prepare: argument Nested.n/)

        preparing = Class.new(GraphQL::Schema::InputObject) do
          graphql_name "Preparing"
          argument :n, Integer
          def prepare = n
        end
        expect { install_with_field { field(:d, String) { argument :p, preparing } } }.to raise_error(configuration_error, /input object Preparing with its own prepare/)
      end
    end
  end

  it "answers false to broadcastable? and true to validate_update?, whatever it is asked" do
    core = install.subscriptions

    expect(core.broadcastable?("subscription { messagePosted(roomId: 5) { id } }")).to be(false)
    expect(core.validate_update?(query: "x", context: {}, root_value: nil, subscription_topic: "t", operation_name: nil, variables: {})).to be(true)
  end

  it "builds ids of 32 random urlsafe bytes, never the same twice" do
    ids = Array.new(50) { install.subscriptions.build_id }

    expect(ids).to all(match(/\A[A-Za-z0-9_-]{43}\z/))
    expect(ids.uniq.size).to eq(50)
  end
end
