# frozen_string_literal: true

# Twins: two definitions of one field, argument or enum value name on one owner, with disjoint lifecycles, so a member
# can change shape across versions. Each version sees exactly one; two that a version would both see are refused.
RSpec.describe "use GraphQL::Armory::Versioning: twins" do
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:controls) { versioning::Controls }
  let(:old) { "2024-06-01" }
  let(:new) { "2025-01-01" }

  def run(schema, query_string, version, root: nil, variables: {})
    execute_query(schema, query_string, root_value: root, variables: variables, context: { armory_version: version }).to_h
  end

  def messages(result) = Array(result["errors"]).map { |error| error["message"] }

  # Execution::Next calls methods on the objects it resolves, so roots are records, not Hashes.
  def record(**values) = Struct.new(*values.keys, keyword_init: true).new(**values)

  def schema_over(query_type, visibility, subscription: nil)
    plugin = controls::Schema::PLUGINS.fetch(visibility)
    labels = controls::Versions::LABELS
    retired = controls::Versions::RETIRED
    adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new
    Class.new(ArmoryEngine.base_schema) do
      query(query_type)
      subscription(subscription) if subscription
      use plugin
      use GraphQL::Armory::Versioning, versions: labels, retired: retired, default: :latest
      use GraphQL::Armory::Authorization, adapter: adapter
    end
  end

  def bases
    mods = [GraphQL::Armory::Versioning::Base, GraphQL::Armory::Authorization::Base]
    argument = Class.new(GraphQL::Schema::Argument) { mods.each { |mod| include mod } }
    field = Class.new(GraphQL::Schema::Field) { mods.each { |mod| include mod }; argument_class(argument) }
    object = Class.new(GraphQL::Schema::Object) { mods.each { |mod| include mod }; field_class(field) }
    interface = Module.new do
      include GraphQL::Schema::Interface
      include GraphQL::Armory::Versioning::Base
      field_class(field)
    end
    input = Class.new(GraphQL::Schema::InputObject) { mods.each { |mod| include mod }; argument_class(argument) }
    value = Class.new(GraphQL::Schema::EnumValue) { include GraphQL::Armory::Versioning::Base }
    enum = Class.new(GraphQL::Schema::Enum) { include GraphQL::Armory::Versioning::Base; enum_value_class(value) }
    { argument: argument, field: field, object: object, interface: interface, input: input, enum: enum }
  end

  # Invoice.total is an Int up to 2025-01-01 and a String from it; Query.invoices(first:) takes an Int, then a String;
  # Status.VOID changes its description.
  def build_catalog(b = bases)
    status = Class.new(b[:enum]) do
      graphql_name "Status"
      value "VOID", "Cancelled.", value: :void, removed: "2025-01-01"
      value "VOID", "Voided by the issuer.", value: :void, value_method: false, added: "2025-01-01"
    end
    invoice = Class.new(b[:object]) do
      graphql_name "Invoice"
      authorize :none, reason: "test data", covers_fields: true
      field :total, Integer, null: true, method: :total_cents, removed: "2025-01-01"
      field :total, String, null: true, method: :total_text, added: "2025-01-01"
      field :status, status, null: true
    end
    query = Class.new(b[:object]) do
      graphql_name "Query"
      authorize :none, reason: "test data", covers_fields: true
      field :invoices, [invoice], null: true do
        argument :first, Integer, required: false, removed: "2025-01-01"
        argument :first, String, required: false, added: "2025-01-01"
      end
    end
    { invoice: invoice, query: query, status: status, b: b }
  end

  def root(_catalog)
    invoice = record(total_cents: 1200, total_text: "12.00 EUR", status: :void)
    Class.new { define_method(:invoices) { |first: nil| [invoice] } }.new
  end

  %i[warden visibility].each do |visibility|
    context "with #{visibility}" do
      let(:catalog) { build_catalog }
      let(:schema) { schema_over(catalog[:query], visibility) }

      it "serves each version its own definition of a field, an argument and an enum value" do
        introspect = '{ i: __type(name: "Invoice") { fields { name type { name } } } ' \
                     'q: __type(name: "Query") { fields { name args { name type { name } } } } ' \
                     's: __type(name: "Status") { enumValues { name description } } }'
        shapes = [old, new].map do |version|
          data = run(schema, introspect, version)["data"]
          [data["i"]["fields"].find { |field| field["name"] == "total" }["type"]["name"],
           data["q"]["fields"].first["args"].map { |arg| arg["type"]["name"] },
           data["s"]["enumValues"].map { |value| value["description"] }]
        end

        expect(shapes).to eq([["Int", ["Int"], ["Cancelled."]], ["String", ["String"], ["Voided by the issuer."]]])
      end

      it "resolves and validates each version against its own definition, in the SDL too" do
        query = "{ invoices(first: 1) { total status } }"
        text = '{ invoices(first: "1") { total status } }'

        expect(execute(old, query)).to eq("data" => { "invoices" => [{ "total" => 1200, "status" => "VOID" }] })
        expect(execute(new, text)).to eq("data" => { "invoices" => [{ "total" => "12.00 EUR", "status" => "VOID" }] })
        # graphql 2.4 with json 3.1 cannot print a literal in its own validation error.
        if ArmoryJsonPrinting.prints_strings?
          expect([messages(execute(old, text)).size, messages(execute(new, query)).size]).to eq([1, 1])
        end
        expect([old, new].map { |version| schema.to_definition(context: { armory_version: version })[/total: \w+/] }).to eq(["total: Int", "total: String"])
      end

      it "refuses two definitions that one version would both see, or an unversioned one beside a versioned one" do
        b = catalog[:b]
        overlapping = Class.new(b[:object]) do
          graphql_name "Query"
          field :total, Integer, null: true, removed: "2025-01-01"
          field :total, String, null: true
        end
        enum = Class.new(b[:enum]) { graphql_name "Kind"; value "A", added: "2024-06-01"; value "A", value_method: false, removed: "2025-01-01" }
        with_enum = Class.new(b[:object]) { graphql_name "Query"; authorize :none, reason: "test data", covers_fields: true; field :kind, enum, null: true }

        expect { run(schema_over(overlapping, visibility), "{ total }", old) }
          .to raise_error(versioning::ConfigurationError, /Query\.total: is defined more than once for 2024-06-01/)
        expect { run(schema_over(with_enum, visibility), '{ __type(name: "Kind") { enumValues { name } } }', old) }
          .to raise_error(versioning::ConfigurationError, /Kind\.A: is defined more than once for 2024-06-01/)
      end

      it "refuses argument twins under a subscription field, which graphql-ruby's trigger reads with no version" do
        b = catalog[:b]
        filter = Class.new(b[:input]) do
          graphql_name "Filter"
          argument :since, Integer, required: false, removed: "2025-01-01"
          argument :since, String, required: false, added: "2025-01-01"
        end
        subscription = Class.new(b[:object]) do
          graphql_name "Subscription"
          authorize :none, reason: "test data", covers_fields: true
          field :invoice_changed, String, null: true do
            argument :filter, filter, required: false
          end
        end

        expect { run(schema_over(catalog[:query], visibility, subscription: subscription), "{ __typename }", new) }
          .to raise_error(versioning::ConfigurationError, /Subscription\.invoiceChanged\.filter: Filter\.since has two definitions/)
      end

      it "keeps an interface with field twins working beside a versioned membership" do
        b = catalog[:b]
        membership = Class.new(GraphQL::Schema::TypeMembership) { include GraphQL::Armory::Versioning::Base }
        priced = Module.new do
          include b[:interface]
          graphql_name "Priced"
          type_membership_class(membership)
          field :price, Integer, null: true, removed: "2025-01-01"
          field :price, String, null: true, added: "2025-01-01"
        end
        named = Module.new { include b[:interface]; graphql_name "Named"; field :name, String, null: true }
        item = Class.new(b[:object]) do
          graphql_name "Item"
          authorize :none, reason: "test data", covers_fields: true
          implements named
          implements priced, added: "2025-01-01"
        end
        query = Class.new(b[:object]) do
          graphql_name "Query"
          authorize :none, reason: "test data", covers_fields: true
          field :item, item, null: true
        end
        root = record(item: record(name: "pen", price: "1.00"))

        expect(run(schema_over(query, visibility), "{ item { name price } }", new, root: root)).to eq("data" => { "item" => { "name" => "pen", "price" => "1.00" } })
      end

      it "is one member for Authorization's audit, and two overlapping definitions are still reported" do
        b = catalog[:b]
        invoice = catalog[:invoice]
        overlapping = Class.new(b[:object]) do
          graphql_name "Query"
          authorize :none, reason: "test data", covers_fields: true
          field :invoices, [invoice], null: true
          field :total, Integer, null: true, removed: "2025-01-01"
          field :total, String, null: true, added: "2024-06-01"
        end
        twins_report = GraphQL::Armory::Authorization::Audit.(schema_over(catalog[:query], visibility))
        overlap_report = GraphQL::Armory::Authorization::Audit.(schema_over(overlapping, visibility))

        expect(twins_report.problems.select { |problem| problem.kind == :ignored_rule }.map(&:path)).to eq([])
        expect(overlap_report.problems.select { |problem| problem.kind == :ignored_rule }.map(&:path).uniq).to eq(["Query.total"])
      end

      def execute(version, text) = run(schema, text, version, root: root(catalog))
    end
  end
end
