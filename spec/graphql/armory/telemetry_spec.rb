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

    it "is refused at boot when ActiveSupport::Notifications is not available" do
      sink = Class.new { def self.available? = false; def self.call(*) = nil }

      expect { armory::Telemetry.new(sinks: [sink]) }.to raise_error(armory::Telemetry::ConfigurationError, /not available/)
    end
  end
end
