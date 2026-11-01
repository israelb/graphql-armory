# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "graphql/armory/authorization/rspec"

# Adopting the gem on a schema with hundreds of problems: the build fails only on new ones, and nothing is hidden.
RSpec.describe GraphQL::Armory::Authorization::Audit::Baseline do
  let(:audit) { GraphQL::Armory::Authorization::Audit }
  let(:error) { GraphQL::Armory::Authorization::ConfigurationError }
  let(:old_problem) { audit::Report::Problem.new(:no_rule, "Invoice", "has no rule and no default_action, so it is denied") }
  let(:new_problem) { audit::Report::Problem.new(:no_rule, "Payment", "has no rule and no default_action, so it is denied") }

  def report(*problems) = audit::Report.new(problems: problems, bypasses: [])

  def in_tmp
    Dir.mktmpdir { |dir| yield File.join(dir, "baseline.json") }
  end

  it "accepts nothing when nothing was wired" do
    result = described_class.new.(report(old_problem))

    expect(result.passes?).to be(false)
    expect(result.new_problems).to eq([old_problem])
  end

  it "passes with only accepted problems, and lists them" do
    result = described_class.from(report(old_problem)).(report(old_problem))

    expect(result.passes?).to be(true)
    expect(result.accepted).to eq([old_problem])
    expect(result.to_s).to include("1 accepted", "Invoice (no_rule)")
  end

  it "fails on a new problem and names it" do
    result = described_class.from(report(old_problem)).(report(old_problem, new_problem))

    expect(result.passes?).to be(false)
    expect(result.new_problems).to eq([new_problem])
    expect(result.to_s).to include("1 new", "Payment (no_rule)")
  end

  it "treats a problem whose message changed as new: it is not the problem someone accepted" do
    other = audit::Report::Problem.new(:no_rule, "Invoice", "another reason")

    expect(described_class.from(report(old_problem)).(report(other)).new_problems).to eq([other])
  end

  it "fails on an accepted problem that is gone: left there, it could come back unseen" do
    result = described_class.from(report(old_problem)).(report)

    expect(result.passes?).to be(false)
    expect(result.gone.map(&:path)).to eq(["Invoice"])
    expect(result.to_s).to include("no longer found", "Invoice")
  end

  it "never turns the audit's own answer into ok" do
    schema_report = report(old_problem)
    result = described_class.from(schema_report).(schema_report)

    expect(schema_report.ok?).to be(false)
    expect(result.report.ok?).to be(false)
    expect(result).not_to respond_to(:ok?)
  end

  it "refuses to accept a schema that never installed the plugin" do
    missing = audit::Report::Problem.new(:plugin, "Schema", "never installed the plugin")

    expect { described_class.from(report(missing)) }.to raise_error(error, /plugin/)
    in_tmp do |path|
      File.write(path, JSON.generate("version" => 1, "problems" => [{ "kind" => "plugin", "path" => "Schema", "message" => "x" }]))
      expect { described_class.load(path) }.to raise_error(error, /plugin/)
    end
  end

  describe ".load" do
    it "raises on what it cannot read, so a typo never passes" do
      in_tmp do |path|
        expect { described_class.load(path) }.to raise_error(error, /cannot be read/)
        File.write(path, "{ not json")
        expect { described_class.load(path) }.to raise_error(error, /not valid JSON/)
        [[], { "version" => 2, "problems" => [] }, { "version" => 1 }, { "version" => 1, "problems" => [{ "kind" => "no_rule" }] }, { "version" => 1, "problems" => [1] }].each do |data|
          File.write(path, JSON.generate(data))
          expect { described_class.load(path) }.to raise_error(error, /baseline/)
        end
      end
    end

    it "reads what write wrote" do
      in_tmp do |path|
        described_class.write(report(old_problem), path)

        expect(described_class.load(path).(report(old_problem)).passes?).to be(true)
      end
    end
  end

  describe ".write" do
    it "writes one sorted entry per line of review, with the message" do
      in_tmp do |path|
        described_class.write(report(new_problem, old_problem), path)

        expect(JSON.parse(File.read(path))["problems"].map { |entry| entry["path"] }).to eq(%w[Invoice Payment])
        expect(File.read(path)).to include("so it is denied", "\n")
      end
    end

    it "only ever removes from a file that exists: accepting a new problem is a visible, manual edit" do
      in_tmp do |path|
        described_class.write(report(old_problem, new_problem), path)
        third = audit::Report::Problem.new(:no_rule, "Refund", "has no rule")

        described_class.write(report(old_problem, third), path)

        expect(JSON.parse(File.read(path))["problems"].map { |entry| entry["path"] }).to eq(["Invoice"])
      end
    end
  end

  describe "on a real schema" do
    let(:schema) do
      invoice = Class.new(GraphQL::Schema::Object) do
        include GraphQL::Armory::Authorization::Base
        graphql_name "Invoice"
        field :number, String, null: false
      end
      query_type = Class.new(GraphQL::Schema::Object) do
        include GraphQL::Armory::Authorization::Base
        graphql_name "Query"
        authorize :none, reason: "public root"
        field :invoice, invoice, null: true
      end
      adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new
      Class.new(ArmoryEngine.base_schema) do
        query query_type
        use GraphQL::Armory::Authorization, adapter: adapter
      end
    end

    it "matches the audit's own problems from one run to the next" do
      first = audit.(schema)

      expect(first.ok?).to be(false)
      expect(described_class.from(first).(audit.(schema)).passes?).to be(true)
    end

    it "takes a baseline in the RSpec matcher, and still fails on the audit alone" do
      in_tmp do |path|
        described_class.write(audit.(schema), path)

        expect(schema).to be_fully_authorized(baseline: path)
        expect(schema).not_to be_fully_authorized
      end
    end

    describe GraphQL::Armory::Authorization::Audit::Command do
      let(:out) { StringIO.new }
      let(:command) { described_class.new(out: out) }

      before { Object.const_set(:ArmoryBaselineSpecSchema, schema) }
      after { Object.send(:remove_const, :ArmoryBaselineSpecSchema) }

      it "exits 1 with no baseline, as before" do
        expect(command.("ArmoryBaselineSpecSchema")).to eq(1)
      end

      it "writes a baseline, then passes with it and says how many it accepts" do
        in_tmp do |path|
          expect(command.write_baseline("ArmoryBaselineSpecSchema", path)).to eq(0)
          expect(out.string).to include(path)
          expect(command.("ArmoryBaselineSpecSchema", path)).to eq(0)
          expect(out.string).to include("accepted")
        end
      end

      it "exits 1 when the baseline cannot be read, and never runs without it" do
        in_tmp do |path|
          expect(command.("ArmoryBaselineSpecSchema", path)).to eq(1)
          expect(out.string).to include("cannot be read")
        end
      end
    end
  end
end
