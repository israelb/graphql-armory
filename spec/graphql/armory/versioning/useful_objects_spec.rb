# frozen_string_literal: true

# The versioning module's objects on their own: inert `new`, validating `build`, one actuator, Substitutes and Controls.
RSpec.describe "GraphQL::Armory::Versioning objects" do
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:versions) { versioning::Controls::Versions.example }

  def build(**settings)
    versioning::Gate.build(versions: %w[2024-01-15 2024-06-01 2025-01-01], default: :latest, **settings)
  end

  describe "Gate" do
    it "refuses every request when built with new: nothing is wired" do
      gate = versioning::Gate.new
      decisions = [{}, { armory_version: nil }, { armory_version: "2024-06-01" }, { armory_version: 1 }].map { |context| gate.(context) }

      expect(decisions.map { |decision| [decision.refused?, decision.code] }).to eq(
        [[true, "MISSING_API_VERSION"], [true, "MISSING_API_VERSION"], [true, "UNKNOWN_API_VERSION"], [true, "UNKNOWN_API_VERSION"]]
      )
    end

    it "decides from context[:armory_version] and records one signal per call, never the client's value" do
      telemetry = GraphQL::Armory::Telemetry::Substitute.new
      gate = versioning::Gate.new(versions: versions, default: versioning::Default::Latest.new, telemetry: telemetry)
      contexts = [{ armory_version: "2024-06-01" }, {}, { armory_version: "2024-01-15" }, { armory_version: "nope" }]

      decisions = contexts.map { |context| gate.(context) }

      expect(decisions.map { |decision| [decision.outcome, decision.version&.label, decision.reason] }).to eq(
        [[:served, "2024-06-01", nil], [:defaulted, "2025-01-01", nil], [:refused, "2024-01-15", :retired], [:refused, nil, :unknown]]
      )
      expect(telemetry.recorded).to eq(
        [[:version_served, { version: "2024-06-01" }], [:version_defaulted, { version: "2025-01-01" }],
         [:version_refused, { reason: :retired }], [:version_refused, { reason: :unknown }]]
      )
      expect(telemetry.contexts).to eq(contexts)
    end

    it "resolves a label without recording anything" do
      telemetry = GraphQL::Armory::Telemetry::Substitute.new
      gate = versioning::Gate.new(versions: versions, default: versioning::Default::Refuse.new, telemetry: telemetry)

      decisions = ["2025-01-01", nil, "2024-01-15"].map { |label| gate.resolve(label) }

      expect([decisions.map { |decision| [decision.outcome, decision.code] }, telemetry.recorded]).to eq(
        [[[:served, nil], [:refused, "MISSING_API_VERSION"], [:refused, "RETIRED_API_VERSION"]], []]
      )
    end

    it "builds the three default policies" do
      latest, pinned, refuse = [:latest, "2024-06-01", :refuse].map { |default| build(retired: %w[2024-01-15], default: default).resolve(nil) }

      expect([latest.version.label, pinned.version.label, refuse.code]).to eq(["2025-01-01", "2024-06-01", "MISSING_API_VERSION"])
      expect([latest.outcome, pinned.outcome]).to eq(%i[defaulted defaulted])
    end

    it "accepts any opaque labels, ordered by position" do
      gate = versioning::Gate.build(versions: %w[v10 v9 beta], default: "v9")

      expect([gate.versions.map(&:label), gate.resolve(nil).version.index, gate.versions.latest.label]).to eq([%w[v10 v9 beta], 1, "beta"])
    end

    it "refuses every invalid setting" do
      invalid = {
        { versions: "2024-06-01" } => /versions: must be an Array/,
        { versions: [] } => /versions: must name at least one version/,
        { versions: ["2024-06-01", ""] } => /non-empty String/,
        { versions: ["2024-06-01", :"2025-01-01"] } => /non-empty String/,
        { versions: %w[2024-06-01 2024-06-01] } => /"2024-06-01" is listed twice/,
        { versions: %w[2025-01-01 2024-06-01] } => /ascending/,
        { retired: "2024-01-15" } => /retired: must be an Array/,
        { retired: %w[2024-06-01] } => /retired: must be the oldest versions/,
        { retired: %w[2024-01-15 2024-06-01 2025-01-01] } => /leaves no version to serve/,
        { default: :oldest } => /default: must be :latest, :refuse or a served label/,
        { default: "2026-01-01" } => /default: "2026-01-01" is not in versions:/,
        { retired: %w[2024-01-15], default: "2024-01-15" } => /default: "2024-01-15" is retired/,
        { default: versioning::Gate::UNSET } => /default: is required/,
      }

      invalid.each do |settings, message|
        expect { build(**settings) }.to raise_error(versioning::ConfigurationError, message)
      end
      expect { build(sinks: :log) }.to raise_error(GraphQL::Armory::Telemetry::ConfigurationError)
    end

    it "has a Substitute that answers the decision it is told and records what it saw" do
      gate = versioning::Gate::Substitute.new
      served = versioning::Decision.served(versions.fetch("2024-06-01"))

      first = gate.({ armory_version: "x" })
      gate.answer(served)
      second = gate.resolve("2024-06-01")

      expect([first.code, second, gate.contexts, gate.labels]).to eq(["MISSING_API_VERSION", served, [{ armory_version: "x" }], ["2024-06-01"]])
    end
  end

  describe "Versions and Version" do
    it "answers labels, positions and what is served" do
      expect([versions.index("2024-06-01"), versions.index("nope"), versions.size, versions.latest.label]).to eq([1, nil, 3, "2025-01-01"])
      expect([versions.served?("2024-06-01"), versions.served?("2024-01-15"), versions.retired?("2024-01-15"), versions.retired?("nope")]).to eq([true, false, true, false])
      expect([versions.each_served.map(&:label), versions.map(&:label)]).to eq([%w[2024-06-01 2025-01-01], %w[2024-01-15 2024-06-01 2025-01-01]])
      expect { versions.fetch("nope") }.to raise_error(versioning::UnknownVersionError)
      expect([versions.frozen?, versions.latest.frozen?]).to eq([true, true])
    end

    it "compares versions with each other and with a label, and refuses a label it does not declare" do
      older = versions.fetch("2024-06-01")
      newer = versions.fetch("2025-01-01")

      expect([older < newer, older < "2025-01-01", older == "2024-06-01", newer >= "2024-06-01", older.retired?, older.to_s]).to eq([true, true, true, true, false, "2024-06-01"])
      expect { older < "2024-6-01" }.to raise_error(versioning::UnknownVersionError)
    end

    it "has a Null that knows no version" do
      null = versioning::Versions::Null.new

      expect([null.index("2024-06-01"), null.served?("2024-06-01"), null.retired?("2024-06-01"), null.size, null.to_a]).to eq([nil, false, false, 0, []])
      expect { null.latest }.to raise_error(versioning::UnknownVersionError)
      expect { null.fetch("2024-06-01") }.to raise_error(versioning::UnknownVersionError)
    end
  end

  describe "Lifecycle" do
    it "covers the versions in [added, removed)" do
      lifecycles = [{}, { added: "2024-06-01" }, { removed: "2025-01-01" }, { added: "2024-06-01", removed: "2025-01-01" }].map { |options| versioning::Lifecycle.build(**options) }
      covered = lifecycles.map { |lifecycle| versions.map { |version| lifecycle.covers?(version) } }

      expect(covered).to eq([[true, true, true], [false, true, true], [true, true, false], [false, true, false]])
      expect(lifecycles.first).to equal(versioning::Lifecycle::EVERYWHERE)
    end

    it "covers the latest version, with no list at hand, when nothing removed the member" do
      expect([versioning::Lifecycle.build(added: "2025-01-01"), versioning::Lifecycle.build(removed: "2025-01-01")].map { |lifecycle| lifecycle.covers?(versioning::Version::LATEST) }).to eq([true, false])
    end

    it "checks the shape of its labels when built and their order every time it is asked" do
      expect { versioning::Lifecycle.build(added: "") }.to raise_error(versioning::ConfigurationError, /added: must be a non-empty String/)
      expect { versioning::Lifecycle.build(removed: 1) }.to raise_error(versioning::ConfigurationError, /removed: must be a non-empty String/)
      expect { versioning::Lifecycle.build(added: "2024-06-01", removed: "2024-06-01") }.to raise_error(versioning::ConfigurationError, /removed: must be a later version/)
      expect { versioning::Lifecycle.build(added: "2023-01-01").covers?(versions.latest) }.to raise_error(versioning::ConfigurationError, /added: "2023-01-01" is not in versions:/)
      expect { versioning::Lifecycle.build(added: "2025-01-01", removed: "2024-06-01").covers?(versions.latest) }.to raise_error(versioning::ConfigurationError, /comes before/)
      expect([versioning::Lifecycle.build(added: "2024-06-01").to_h, versioning::Lifecycle.build(added: "2024-06-01").frozen?]).to eq([{ added: "2024-06-01" }, true])
    end
  end

  describe "Base" do
    it "goes only in a field class in this version" do
      expect { Class.new(GraphQL::Schema::Object) { include GraphQL::Armory::Versioning::Base } }.to raise_error(ArgumentError, /field class/)
    end
  end

  describe "Versioning.version" do
    it "needs a query's context" do
      [{}, GraphQL::Query::NullContext.instance].each do |context|
        expect { versioning.version(context) }.to raise_error(versioning::ConfigurationError, /query's context/)
      end
    end
  end
end
