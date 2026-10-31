# frozen_string_literal: true

RSpec.describe GraphQL::Armory::Authorization::Audit do
  let(:authorization) { GraphQL::Armory::Authorization }
  let(:clean) { IntegrationSchema.build(flawed: false) }
  let(:flawed) { IntegrationSchema.build }

  def found(report, kind, path)
    report.problems.find { |problem| problem.kind == kind && problem.path == path }
  end

  describe "a schema where everything is covered" do
    let(:report) { described_class.(clean) }

    it "has no problems" do
      expect(report.problems.map(&:to_s)).to eq([])
      expect(report).to be_ok
    end

    it "lists every declared bypass with its reason" do
      expect(report.bypasses.map { |bypass| [bypass.path, bypass.reason] }).to include(
        ["Invoice.id", "ids are public"],
        ["Query", "root type; each field declares its own rule"],
        ["Query.ping", "health check"]
      )
    end

    it "leaves out the Relay edge and page info types that add nothing" do
      paths = (report.problems.map(&:path) + report.bypasses.map(&:path)).join(" ")

      expect(paths).not_to match(/Edge|PageInfo/)
    end

    it "lists the connection that adds a field" do
      expect(report.bypasses.map(&:path)).to include("InvoiceConnection")
    end
  end

  describe "a schema with gaps" do
    let(:report) { described_class.(flawed) }

    it "is not ok" do
      expect(report).not_to be_ok
    end

    it "reports a type whose base class never included the integration" do
      expect(found(report, :unprotected, "Forgotten").message).to match(/open/)
    end

    it "reports a type whose policy does not exist" do
      expect(found(report, :adapter, "Ghost").message).to eq("GhostPolicy not found")
    end

    it "reports a field with no rule on a bypassed type" do
      expect(found(report, :field_without_rule, "Query.no_rule").message).to match(/denied/)
    end

    it "reports a loads: that skips the scope" do
      expect(found(report, :unscoped_load, "Query.invoice_unscoped(invoice_id)")).not_to be_nil
    end

    it "does not report what is covered" do
      expect(report.problems.map(&:path)).not_to include("Invoice", "Invoice.number", "Query.ping", "AdminInvoice")
    end
  end

  describe "a type with no rule and no default action" do
    it "is reported, because it is denied" do
      report = described_class.(IntegrationSchema.build(type_action: nil, flawed: false))

      expect(found(report, :no_rule, "Invoice").message).to match(/denied/)
    end
  end

  describe "a policy that does not define the declared action" do
    it "is reported once for the type, not once per field" do
      base_field = Class.new(GraphQL::Schema::Field) { include GraphQL::Armory::Authorization::Base }
      note_type = Class.new(GraphQL::Schema::Object) do
        include GraphQL::Armory::Authorization::Base
        field_class base_field
        graphql_name "Note"
        authorize :manage
        field :body, String, null: false
      end
      schema = Class.new(ArmoryEngine.base_schema) do
        query(Class.new(GraphQL::Schema::Object) do
          include GraphQL::Armory::Authorization::Base
          field_class base_field
          graphql_name "Query"
          authorize :none, reason: "root"
          field :note, note_type, null: false, authorize: :none, reason: "root"
        end)
        use GraphQL::Armory::Authorization, adapter: :pundit
      end

      problems = described_class.(schema).problems.select { |problem| problem.path == "Note" }

      expect(problems.map(&:message)).to eq(["NotePolicy#manage? is not defined", "NotePolicy::Scope is not defined"])
    end
  end

  describe "a schema that never installed the plugin" do
    it "is reported, and everything is unverifiable" do
      report = described_class.(IntegrationSchema.build(plugin: false, flawed: false))

      expect(found(report, :plugin, "Schema").message).to match(/use GraphQL::Armory::Authorization/)
    end
  end

  describe "with nothing configured" do
    it "fails closed: no adapter, nothing is covered" do
      report = described_class.new.(clean)

      expect(report).not_to be_ok
      expect(report.problems.map(&:message)).to include("no adapter is configured: everything is denied")
    end
  end

  describe "the report" do
    it "reads as text with the problems first and the bypasses after" do
      text = described_class.(flawed).to_s

      expect(text).to match(/\A\d+ problems?:/)
      expect(text).to include("Forgotten (unprotected)", "Query.no_rule (field_without_rule)", "declared bypasses")
    end

    it "says so when there is nothing to fix" do
      expect(described_class.(clean).to_s).to start_with("No problems")
    end
  end

  describe "Substitute" do
    it "answers the report it was given" do
      report = authorization::Audit::Report.new(problems: [], bypasses: [])

      expect(described_class::Substitute.new(report).(clean)).to equal(report)
    end
  end
end
