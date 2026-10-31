# frozen_string_literal: true

require "active_support/notifications"

# One Telemetry for every module: it hands each signal the gem records to the sinks the app gave, and the
# Notifications sink turns them into ActiveSupport::Notifications events.
RSpec.describe GraphQL::Armory::Telemetry do
  let(:armory) { GraphQL::Armory }

  it "is the telemetry authorization has always used" do
    expect(armory::Authorization::Telemetry).to equal(armory::Telemetry)
  end

  it "does nothing without sinks, and hands every signal to every sink in order" do
    seen = []
    telemetry = armory::Telemetry.build(sinks: [->(signal, data) { seen << [:a, signal, data] }, ->(signal, data) { seen << [:b, signal, data] }])

    expect(armory::Telemetry.new.record(:denied)).to be_nil
    telemetry.record(:denied, type: "Invoice")

    expect(seen).to eq([[:a, :denied, { type: "Invoice" }], [:b, :denied, { type: "Invoice" }]])
  end

  it "refuses at boot sinks that are not an Array of callables" do
    ["log", [nil], [:log], Object.new].each do |sinks|
      expect { armory::Telemetry.new(sinks: sinks) }.to raise_error(armory::Telemetry::ConfigurationError, /sinks/)
    end
  end

  it "never quotes a sink in the boot error: a metrics client holds its API key" do
    client = Class.new { def initialize = @api_key = "sk_live_SECRET123"; def call(*) = nil }.new
    credentials = [{ url: "https://user:hunter2@metrics" }]

    [client, credentials, [credentials.first]].each do |sinks|
      expect { armory::Telemetry.new(sinks: sinks) }.to raise_error(armory::Telemetry::ConfigurationError) { |error|
        expect(error.message).not_to match(/SECRET|hunter2|api_key/)
      }
    end
  end

  it "gives every sink the same frozen data, so one sink cannot change what the next sees" do
    type = +"Invoice"
    seen = []
    mutator = ->(_signal, data) { data[:reason] = :tampered }
    reader = ->(_signal, data) { seen << data }

    raised = []
    armory::Telemetry.new(sinks: [mutator], on_sink_error: ->(error, _signal) { raised << error.class }).record(:id_refused, reason: :invalid)
    expect(raised).to eq([FrozenError])
    armory::Telemetry.new(sinks: [reader]).record(:id_refused, reason: :invalid, type: type)
    type << "!"

    expect([seen.first, seen.first.frozen?, seen.first[:type].frozen?]).to eq([{ reason: :invalid, type: "Invoice" }, true, true])
  end

  it "refuses bad sinks in use GraphQL::Armory::Authorization at boot, not at the first query" do
    expect { Class.new(GraphQL::Schema) { use GraphQL::Armory::Authorization, adapter: :pundit, sinks: "log" } }
      .to raise_error(armory::Telemetry::ConfigurationError, /sinks/)
  end

  describe "Substitute" do
    it "fails when told, until it recovers" do
      telemetry = armory::Telemetry::Substitute.new
      telemetry.fail_with(IOError.new("metrics down"))

      expect { telemetry.record(:denied) }.to raise_error(IOError, "metrics down")
      telemetry.recover
      telemetry.record(:denied)
      expect(telemetry.recorded).to eq([[:denied, {}]])
    end

    it "keeps what was recorded" do
      telemetry = armory::Telemetry::Substitute.new
      telemetry.record(:id_refused, reason: :invalid)

      expect([telemetry.recorded, telemetry.recorded?(:id_refused), telemetry.recorded?(:id_resolved)])
        .to eq([[[:id_refused, { reason: :invalid }]], true, false])
    end
  end

  describe "Notifications" do
    it "instruments each signal as '<signal>.graphql_armory' with its data" do
      events = []
      subscription = ActiveSupport::Notifications.subscribe(/\.graphql_armory\z/) { |name, _s, _f, _id, payload| events << [name, payload] }
      armory::Telemetry.build(sinks: [armory::Telemetry::Notifications]).record(:operation_refused, reason: :unknown_operation)
      ActiveSupport::Notifications.unsubscribe(subscription)

      expect(events).to eq([["operation_refused.graphql_armory", { reason: :unknown_operation }]])
    end

    it "keeps what a subscriber does to its payload away from the other sinks" do
      other = []
      subscription = ActiveSupport::Notifications.subscribe("id_refused.graphql_armory") { |*, payload| payload[:extra] = 1 }
      telemetry = armory::Telemetry.build(sinks: [armory::Telemetry::Notifications, ->(_signal, data) { other << data }])
      telemetry.record(:id_refused, reason: :invalid)
      ActiveSupport::Notifications.unsubscribe(subscription)

      expect(other).to eq([{ reason: :invalid }])
    end

    it "is refused at boot when ActiveSupport::Notifications is not available" do
      sink = Class.new { def self.available? = false; def self.call(*) = nil }

      expect { armory::Telemetry.new(sinks: [sink]) }.to raise_error(armory::Telemetry::ConfigurationError, /not available/)
    end
  end
end
