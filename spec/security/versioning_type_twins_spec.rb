# frozen_string_literal: true

# Type twins: two type classes with one `graphql_name` and disjoint lifecycles, each returned by its own field twin, so a
# type can change shape across versions. graphql-ruby serves the one each version sees; what would serve the wrong one
# is refused, and Authorization's audit judges each twin.
RSpec.describe "use GraphQL::Armory::Versioning: type twins" do
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:controls) { versioning::Controls }
  let(:old) { "2024-06-01" }
  let(:new) { "2025-01-01" }

  def run(schema, query_string, version, root: nil)
    execute_query(schema, query_string, root_value: root, context: { armory_version: version }).to_h
  end

  def messages(result) = Array(result["errors"]).map { |error| error["message"] }

  # Execution::Next calls methods on the objects it resolves, so roots are records, not Hashes.
  def record(**values) = Struct.new(*values.keys, keyword_init: true).new(**values)

  def schema_over(query_type, visibility, authorization: false)
    plugin = controls::Schema::PLUGINS.fetch(visibility)
    labels = controls::Versions::LABELS
    retired = controls::Versions::RETIRED
    adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new
    Class.new(ArmoryEngine.base_schema) do
      query(query_type)
      use plugin
      use GraphQL::Armory::Versioning, versions: labels, retired: retired, default: :latest
      use GraphQL::Armory::Authorization, adapter: adapter if authorization
      def self.resolve_type(_abstract, object, _context) = object.type
    end
  end

  def bases
    mod = GraphQL::Armory::Versioning::Base
    membership = Class.new(GraphQL::Schema::TypeMembership) { include mod }
    argument = Class.new(GraphQL::Schema::Argument) { include mod }
    field = Class.new(GraphQL::Schema::Field) { include mod; argument_class(argument) }
    object = Class.new(GraphQL::Schema::Object) { include mod; field_class(field) }
    input = Class.new(GraphQL::Schema::InputObject) { include mod; argument_class(argument) }
    interface = Module.new do
      include GraphQL::Schema::Interface
      include mod
      field_class(field)
      type_membership_class(membership)
    end
    { argument: argument, field: field, object: object, input: input, interface: interface }
  end

  # Money is { cents: Int } up to 2025-01-01 and { amount: String, currency: String } from it; Invoice.total returns each.
  def build_catalog(b = bases)
    money_v1 = Class.new(b[:object]) do
      graphql_name "Money"
      lifecycle removed: "2025-01-01"
      field :cents, Integer, null: true
    end
    money_v2 = Class.new(b[:object]) do
      graphql_name "Money"
      lifecycle added: "2025-01-01"
      field :amount, String, null: true
      field :currency, String, null: true
    end
    invoice = Class.new(b[:object]) do
      graphql_name "Invoice"
      field :total, money_v1, null: true, removed: "2025-01-01"
      field :total, money_v2, null: true, added: "2025-01-01"
    end
    query = Class.new(b[:object]) { graphql_name "Query"; field :invoice, invoice, null: true }
    { money_v1: money_v1, money_v2: money_v2, invoice: invoice, query: query, b: b }
  end

  def root
    record(invoice: record(total: record(cents: 1200, amount: "12.00", currency: "EUR")))
  end

  %i[warden visibility].each do |visibility|
    context "with #{visibility}" do
      let(:catalog) { build_catalog }
      let(:schema) { schema_over(catalog[:query], visibility) }

      it "serves each version its own type twin, in introspection, queries and the SDL" do
        introspect = '{ __type(name: "Money") { fields { name } } }'
        shapes = [old, new].map { |version| run(schema, introspect, version)["data"]["__type"]["fields"].map { |field| field["name"] } }
        sdl = [old, new].map { |version| schema.to_definition(context: { armory_version: version })[/type Money \{([^}]*)\}/, 1].split("
").map(&:strip).reject(&:empty?) }

        expect(shapes).to eq([["cents"], %w[amount currency]])
        expect(sdl).to eq([["cents: Int"], ["amount: String", "currency: String"]])
        expect(run(schema, "{ invoice { total { cents } } }", old, root: root)).to eq("data" => { "invoice" => { "total" => { "cents" => 1200 } } })
        expect(run(schema, "{ invoice { total { amount currency } } }", new, root: root))
          .to eq("data" => { "invoice" => { "total" => { "amount" => "12.00", "currency" => "EUR" } } })
        expect(messages(run(schema, "{ invoice { total { cents } } }", new, root: root))).to eq(["Field 'cents' doesn't exist on type 'Money'"])
      end

      it "refuses a late-bound field, argument or interface whose name has twins" do
        b = catalog[:b]
        invoice = catalog[:invoice]
        status_v1 = Class.new(b[:input]) { graphql_name "Range"; lifecycle removed: "2025-01-01"; argument :from, Integer, required: false }
        status_v2 = Class.new(b[:input]) { graphql_name "Range"; lifecycle added: "2025-01-01"; argument :from, String, required: false }
        by_field = Class.new(b[:object]) do
          graphql_name "Query"
          field :invoice, invoice, null: true
          field :price, GraphQL::Schema::LateBoundType.new("Money"), null: true
        end
        by_argument = Class.new(b[:object]) do
          graphql_name "Query"
          field :search, String, null: true do
            argument :range, GraphQL::Schema::LateBoundType.new("Range"), required: false
          end
          field :old_search, String, null: true, removed: "2025-01-01" do
            argument :range, status_v1, required: false
          end
          field :new_search, String, null: true, added: "2025-01-01" do
            argument :range, status_v2, required: false
          end
        end
        named_v1 = Module.new { include b[:interface]; graphql_name "Named"; lifecycle removed: "2025-01-01"; field :name, String, null: true }
        named_v2 = Module.new { include b[:interface]; graphql_name "Named"; lifecycle added: "2025-01-01"; field :name, String, null: false }
        person = Class.new(b[:object]) { graphql_name "Person"; implements GraphQL::Schema::LateBoundType.new("Named"); field :name, String, null: true }
        by_interface = Class.new(b[:object]) do
          graphql_name "Query"
          field :person, person, null: true
          field :old_named, named_v1, null: true, removed: "2025-01-01"
          field :new_named, named_v2, null: true, added: "2025-01-01"
        end

        [old, new].each do |version|
          expect { run(schema_over(by_field, visibility), "{ __typename }", version) }
            .to raise_error(versioning::ConfigurationError, /Query\.price: names Money by name, and Money has more than one definition/)
          expect { run(schema_over(by_argument, visibility), "{ __typename }", version) }
            .to raise_error(versioning::ConfigurationError, /Query\.search\.range: names Range by name, and Range has more than one definition/)
          expect { run(schema_over(by_interface, visibility), "{ __typename }", version) }
            .to raise_error(versioning::ConfigurationError, /Person: names Named by name, and Named has more than one definition/)
        end
      end

      it "keeps a late-bound name without twins working" do
        b = catalog[:b]
        invoice = catalog[:invoice]
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :invoice, invoice, null: true
          field :other, GraphQL::Schema::LateBoundType.new("Invoice"), null: true
        end

        expect(run(schema_over(query, visibility), "{ other { __typename } }", new, root: record(other: record(total: nil))))
          .to eq("data" => { "other" => { "__typename" => "Invoice" } })
      end

      it "is judged twin by twin by Authorization's audit" do
        authorized = GraphQL::Armory::Authorization::Base
        mod = GraphQL::Armory::Versioning::Base
        argument_base = Class.new(GraphQL::Schema::Argument) { [mod, authorized].each { |m| include m } }
        field_base = Class.new(GraphQL::Schema::Field) { [mod, authorized].each { |m| include m }; argument_class(argument_base) }
        object = Class.new(GraphQL::Schema::Object) { [mod, authorized].each { |m| include m }; field_class(field_base) }
        money_v1 = Class.new(object) do
          graphql_name "Money"
          lifecycle removed: "2025-01-01"
          authorize :none, reason: "test data", covers_fields: true
          field :cents, Integer, null: true
        end
        money_v2 = Class.new(object) { graphql_name "Money"; lifecycle added: "2025-01-01"; field :amount, String, null: true }
        query = Class.new(object) do
          graphql_name "Query"
          authorize :none, reason: "test data", covers_fields: true
          field :total, money_v1, null: true, removed: "2025-01-01"
          field :total, money_v2, null: true, added: "2025-01-01"
        end
        report = GraphQL::Armory::Authorization::Audit.(schema_over(query, visibility, authorization: true))

        expect(report.problems.select { |problem| problem.kind == :no_rule }.map(&:path)).to eq(["Money"])
        expect(report.problems.map(&:kind)).not_to include(:ignored_rule)
      end
    end
  end

  # Warden's `schema.types` keeps one twin per name, the one the latest version sees, and nil when none does: the walk
  # that refuses abstract loads follows the definitions instead.
  context "with warden" do
    it "refuses an abstract load on a twin the latest version does not see" do
      b = bases
      archivable = Module.new { include b[:interface]; graphql_name "Archivable"; field :archived, GraphQL::Types::Boolean, null: true }
      item = Class.new(b[:object]) { graphql_name "Item"; implements archivable, added: "2025-01-01"; field :name, String, null: true }
      plain = Class.new(GraphQL::Schema::Object) { field_class(Class.new(GraphQL::Schema::Field)) }
      money_v1 = Class.new(plain) do
        extend GraphQL::Armory::Versioning::Integration::Type
        graphql_name "Money"
        lifecycle removed: "2025-01-01"
        field :convert, Integer, null: true do
          argument :item_id, GraphQL::Types::ID, required: true, loads: archivable
        end
      end
      money_v2 = Class.new(b[:object]) { graphql_name "Money"; lifecycle added: "2025-01-01"; field :amount, String, null: true }
      gone = Class.new(b[:object]) { graphql_name "Gone"; lifecycle removed: "2024-06-01"; field :id, String, null: true }
      gone_too = Class.new(b[:object]) { graphql_name "Gone"; lifecycle added: "2024-06-01", removed: "2025-01-01"; field :id, String, null: true }
      query = Class.new(b[:object]) do
        graphql_name "Query"
        field :item, item, null: true
        field :total, money_v1, null: true, removed: "2025-01-01"
        field :total, money_v2, null: true, added: "2025-01-01"
        field :gone, gone, null: true, removed: "2024-06-01"
        field :gone, gone_too, null: true, added: "2024-06-01", removed: "2025-01-01"
      end
      schema = schema_over(query, :warden)

      [old, new].each do |version|
        expect { run(schema, "{ __typename }", version) }
          .to raise_error(versioning::ConfigurationError, /Money\.convert\.itemId: it loads Archivable, which has a membership with a lifecycle/)
      end
    end
  end

  # PayloadReuse reads a late-bound return by name: with twins it must not pick one and miss the other.
  it "reports a payload reused through a late-bound name that has twins" do
    armory = GraphQL::Armory::Authorization
    field_class = Class.new(GraphQL::Schema::Field) { include armory::Base }
    object = Class.new(GraphQL::Schema::Object) { include armory::Base; field_class(field_class) }
    payload_base = Class.new(object) { authorize :none, reason: "the mutation's rule covers its payload", covers_fields: true }
    mutation = Class.new(GraphQL::Schema::RelayClassicMutation) do
      include armory::Base
      field_class field_class
      object_class payload_base
      graphql_name "Move"
      authorize :move
      field :done, String, null: true
    end
    payload = mutation.payload_type
    plain = Class.new(GraphQL::Schema::Object) { graphql_name payload.graphql_name; field :done, String, null: true }
    holder = Class.new(GraphQL::Schema::Object) { graphql_name "Holder"; field :last, GraphQL::Schema::LateBoundType.new(payload.graphql_name), null: true }
    findings = armory::Audit::Findings.new

    armory::Audit::PayloadReuse.([payload, holder, plain], findings)

    expect(findings.report.problems.map { |problem| [problem.kind, problem.path] }).to eq([[:payload_outside_mutation, "Holder.last"]])
  end
end
