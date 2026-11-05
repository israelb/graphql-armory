# frozen_string_literal: true

require "graphql/armory/versioning/rspec"

# Versioning's audit, first part: before production, every refusal a query of a served version would hit, and every
# member a served version lists outside its lifecycle. If a client of V reaches a member outside V, it is never ok.
RSpec.describe "GraphQL::Armory::Versioning::Audit" do
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:controls) { versioning::Controls }
  let(:old) { "2024-06-01" }
  let(:new) { "2025-01-01" }

  def audit(schema) = versioning::Audit.(schema)

  def kinds(report) = report.problems.map { |problem| [problem.kind, problem.path] }.uniq

  def run(schema, query_string, version, root: nil)
    execute_query(schema, query_string, root_value: root, context: { armory_version: version }).to_h
  end

  def record(**values) = Struct.new(*values.keys, keyword_init: true).new(**values)

  def schema_over(query_type, visibility, plugin: true, sinks: [], authorization: false, extra: [], allow: true)
    visibility_plugin = visibility && controls::Schema::PLUGINS.fetch(visibility)
    labels = controls::Versions::LABELS
    retired = controls::Versions::RETIRED
    adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: allow)
    Class.new(ArmoryEngine.base_schema) do
      query(query_type)
      extra_types(*extra) unless extra.empty?
      use visibility_plugin if visibility_plugin
      use GraphQL::Armory::Versioning, versions: labels, retired: retired, default: :latest, sinks: sinks if plugin
      use GraphQL::Armory::Authorization, adapter: adapter if authorization
    end
  end

  def bases(authorization: false)
    mods = [GraphQL::Armory::Versioning::Base]
    mods << GraphQL::Armory::Authorization::Base if authorization
    argument = Class.new(GraphQL::Schema::Argument) { mods.each { |mod| include mod } }
    field = Class.new(GraphQL::Schema::Field) { mods.each { |mod| include mod }; argument_class(argument) }
    object = Class.new(GraphQL::Schema::Object) { mods.each { |mod| include mod }; field_class(field) }
    value = Class.new(GraphQL::Schema::EnumValue) { include GraphQL::Armory::Versioning::Base }
    enum = Class.new(GraphQL::Schema::Enum) { include GraphQL::Armory::Versioning::Base; enum_value_class(value) }
    { argument: argument, field: field, object: object, enum: enum }
  end

  %i[warden visibility].each do |visibility|
    context "with #{visibility}" do
      it "is ok on a consistent schema, and says what it does not check yet" do
        report = audit(controls::Schema.example(visibility: visibility))

        expect(report.ok?).to be(true)
        expect(report.to_s).to include("No problems.").and include("Not checked yet:")
      end

      it "reports every schema-level refusal at once, under Schema" do
        b = bases
        query = Class.new(b[:object]) { graphql_name "Query"; lifecycle added: "2024-06-01"; field :x, String, null: true }
        extra = Class.new(b[:object]) { graphql_name "Extra"; lifecycle added: "2025-01-01"; field :y, String, null: true }
        report = audit(schema_over(query, visibility, extra: [extra]))

        expect(report.problems.select { |problem| problem.kind == :refused && problem.path == "Schema" }.map(&:message))
          .to contain_exactly(a_string_matching(/Query: a root type cannot have a lifecycle/), a_string_matching(/Extra: a type with a lifecycle cannot be in extra_types/))
      end

      it "reports a member's refusal even when Authorization hides it from a query with no user" do
        b = bases(authorization: true)
        status = Class.new(b[:enum]) { graphql_name "Kind"; value "OLD"; value "NEW", added: "2025-01-01" }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          authorize :read, model: ::Struct
          field :pick, String, null: true, visible_when: :export do
            argument :kind, status, required: false, default_value: "NEW"
          end
        end
        report = audit(schema_over(query, visibility, authorization: true, allow: false))

        expect(kinds(report)).to include([:refused, "Query.pick.kind"])
        expect(report.problems.find { |problem| problem.path == "Query.pick.kind" }.message).to match(/default_value names Kind.NEW/)
      end

      it "reports two type twins whose lifecycles overlap, which no query refuses" do
        b = bases
        money_v1 = Class.new(b[:object]) { graphql_name "Money"; lifecycle removed: "2025-01-01"; field :cents, Integer, null: true }
        money_v2 = Class.new(b[:object]) { graphql_name "Money"; lifecycle added: "2024-06-01"; field :amount, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :a, money_v1, null: true
          field :b, money_v2, null: true
        end

        expect(kinds(audit(schema_over(query, visibility)))).to include([:duplicate, "Money"])
      end

      it "reports an enum with no value in a served version" do
        b = bases
        kind = Class.new(b[:enum]) { graphql_name "Kind"; value "A", removed: "2025-01-01" }
        query = Class.new(b[:object]) { graphql_name "Query"; field :kind, kind, null: true }

        expect(kinds(audit(schema_over(query, visibility)))).to include([:empty, "Kind"])
      end

      it "reports, as not checked, a visible? that raises with no user" do
        b = bases
        raising = Class.new(b[:field]) { def visible?(context) = context[:current_user].fetch(:admin) && super }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field_class raising
          field :secret, String, null: true
        end

        expect(kinds(audit(schema_over(query, visibility)))).to include([:unchecked, "Query.secret"])
      end

      it "is never ok when a client of a version gets a member outside its lifecycle" do
        b = bases
        always = Class.new(b[:field]) { def visible?(_context) = true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field_class always
          field :x, String, null: true
          field :legacy, String, null: true, removed: "2025-01-01"
        end
        schema = schema_over(query, visibility)

        expect(run(schema, "{ legacy }", new, root: record(x: nil, legacy: "served"))).to eq("data" => { "legacy" => "served" })
        expect(kinds(audit(schema))).to include([:outside_lifecycle, "Query.legacy"])
      end

      it "reports a label not in versions:, on a member no query asks" do
        b = bases
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :x, String, null: true
          field :y, String, null: true, removed: "2025-13-01"
        end

        expect(kinds(audit(schema_over(query, visibility)))).to include([:undeclared_version, "Query.y"])
      end

      it "records no signal" do
        recorded = []
        audit(schema_over(controls::Query.example, visibility, sinks: [->(signal, _data) { recorded << signal }]))

        expect(recorded).to eq([])
      end
    end
  end

  it "reports a schema with versioned members and no plugin, or no visibility plugin" do
    query = controls::Query.example

    expect(kinds(audit(schema_over(query, :visibility, plugin: false)))).to eq([[:plugin, "Schema"]])
    expect(kinds(audit(schema_over(query, nil)))).to eq([[:visibility, "Schema"]])
  end

  it "fails have_consistent_versions with the report" do
    b = bases
    kind = Class.new(b[:enum]) { graphql_name "Kind"; value "A", removed: "2025-01-01" }
    broken = schema_over(Class.new(b[:object]) { graphql_name "Query"; field :kind, kind, null: true }, :visibility)

    expect(controls::Schema.example).to have_consistent_versions
    expect { expect(broken).to have_consistent_versions }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /Kind \(empty\)/)
  end

  describe "the rake command" do
    around do |example|
      Object.const_set(:ArmoryVersioningAuditSchema, controls::Schema.example)
      example.run
    ensure
      Object.send(:remove_const, :ArmoryVersioningAuditSchema)
    end

    it "prints the report and answers its exit status" do
      out = StringIO.new
      command = versioning::Audit::Command.new(out: out)

      expect(command.("ArmoryVersioningAuditSchema")).to eq(0)
      expect(out.string).to include("No problems.")
      expect(command.("NoSuchSchemaHere")).to eq(1)
      expect(command.("")).to eq(1)
    end
  end
end
