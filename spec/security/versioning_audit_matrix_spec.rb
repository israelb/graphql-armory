# frozen_string_literal: true

# Versioning's audit against what a client of a version really gets. Each row builds a schema with one hazard, shows it
# with a real request of the version, and expects the audit to report that kind at that path; the schema without the
# hazard is ok. Hazards that change nothing a client relies on are information: listed, but `ok?` stays true.
RSpec.describe "GraphQL::Armory::Versioning::Audit against a request" do
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:controls) { versioning::Controls }
  let(:old) { "2024-06-01" }
  let(:new) { "2025-01-01" }

  def audit(schema) = versioning::Audit.(schema)

  def found(report, kind) = report.problems.select { |problem| problem.kind == kind }

  def paths(report, kind) = found(report, kind).map(&:path)

  def run(schema, query_string, version, root: nil)
    execute_query(schema, query_string, root_value: root, context: { armory_version: version }).to_h
  end

  def record(**values) = Struct.new(*values.keys, keyword_init: true).new(**values)

  def schema_over(query_type, visibility)
    plugin = controls::Schema::PLUGINS.fetch(visibility)
    labels = controls::Versions::LABELS
    retired = controls::Versions::RETIRED
    Class.new(ArmoryEngine.base_schema) do
      query(query_type)
      use plugin
      use GraphQL::Armory::Versioning, versions: labels, retired: retired, default: :latest
      def self.resolve_type(_abstract, object, _context) = object.type
    end
  end

  def bases
    mod = versioning::Base
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
    union = Class.new(GraphQL::Schema::Union) { include mod; type_membership_class(membership) }
    value = Class.new(GraphQL::Schema::EnumValue) { include mod }
    enum = Class.new(GraphQL::Schema::Enum) { include mod; enum_value_class(value) }
    { argument: argument, field: field, object: object, input: input, interface: interface, union: union, enum: enum }
  end

  %i[warden visibility].each do |visibility|
    context "with #{visibility}" do
      describe ":implicit" do
        it "reports a required argument hidden by its input type: the field runs without it" do
          b = bases
          filter = Class.new(b[:input]) { graphql_name "Filter"; lifecycle added: "2025-01-01"; argument :q, String, required: false }
          query = Class.new(b[:object]) do
            graphql_name "Query"
            field :find, String, null: true do
              argument :filter, filter, required: true
            end
          end
          schema = schema_over(query, visibility)

          expect(run(schema, "{ find }", old, root: record(find: "ran"))).to eq("data" => { "find" => "ran" })
          report = audit(schema)
          expect(paths(report, :implicit)).to eq(["Query.find.filter"])
          expect(found(report, :implicit).first.message).to match(/required.*2024-06-01.*Filter.*without it/)
          expect(report.ok?).to be(false)
        end

        it "reports a required loads: argument hidden by the loaded type" do
          b = bases
          contract = Class.new(b[:object]) { graphql_name "Contract"; lifecycle added: "2025-01-01"; field :party, String, null: true }
          query = Class.new(b[:object]) do
            graphql_name "Query"
            field :contract, contract, null: true
            field :sign, String, null: true do
              argument :contract_id, GraphQL::Types::ID, required: true, loads: contract
            end
          end
          schema = schema_over(query, visibility)

          expect(run(schema, "{ sign }", old, root: record(sign: "ran", contract: nil))).to eq("data" => { "sign" => "ran" })
          report = audit(schema)
          expect(found(report, :implicit).reject(&:information?).map(&:path)).to eq(["Query.sign.contractId"])
          expect(report.ok?).to be(false)
        end

        it "lists an optional member hidden by its type as information, and stays ok" do
          b = bases
          contract = Class.new(b[:object]) { graphql_name "Contract"; lifecycle added: "2025-01-01"; field :party, String, null: true }
          query = Class.new(b[:object]) do
            graphql_name "Query"
            field :name, String, null: true
            field :contract, contract, null: true
          end
          schema = schema_over(query, visibility)

          expect(run(schema, '{ __type(name: "Query") { fields { name } } }', old)).to eq("data" => { "__type" => { "fields" => [{ "name" => "name" }] } })
          report = audit(schema)
          expect(paths(report, :implicit)).to eq(["Query.contract"])
          expect(found(report, :implicit).first.information?).to be(true)
          expect(report.ok?).to be(true)
          expect(report.to_s).to include("Information:").and include("Query.contract (implicit)")
        end
      end

      describe ":empty and :orphan_interface" do
        it "reports an object with no field in a version" do
          b = bases
          thing = Class.new(b[:object]) { graphql_name "Thing"; field :a, String, null: true, added: "2025-01-01" }
          query = Class.new(b[:object]) { graphql_name "Query"; field :thing, thing, null: true }
          schema = schema_over(query, visibility)

          expect(run(schema, '{ __type(name: "Thing") { fields { name } } }', old)).to eq("data" => { "__type" => { "fields" => [] } })
          report = audit(schema)
          expect(paths(report, :empty)).to eq(["Thing"])
          expect(report.ok?).to be(false)
        end

        it "reports an input object with no input field in a version" do
          b = bases
          filter = Class.new(b[:input]) { graphql_name "Filter"; argument :q, String, required: false, added: "2025-01-01" }
          query = Class.new(b[:object]) do
            graphql_name "Query"
            field :find, String, null: true do
              argument :filter, filter, required: false
            end
          end

          expect(paths(audit(schema_over(query, visibility)), :empty)).to eq(["Filter"])
        end

        it "does not report a type that declares it has no fields" do
          b = bases
          marker = Class.new(b[:object]) { graphql_name "Marker"; has_no_fields(true) }
          query = Class.new(b[:object]) { graphql_name "Query"; field :marker, marker, null: true }

          expect(paths(audit(schema_over(query, visibility)), :empty)).to eq([])
        end

        it "reports an interface with no implementer in a version" do
          b = bases
          named = Module.new { include b[:interface]; graphql_name "Named"; field :name, String, null: true }
          person = Class.new(b[:object]) { graphql_name "Person"; implements named, added: "2025-01-01"; field :age, Integer, null: true }
          query = Class.new(b[:object]) do
            graphql_name "Query"
            field :named, named, null: true
            field :person, person, null: true
          end
          schema = schema_over(query, visibility)

          seen = run(schema, '{ __type(name: "Named") { possibleTypes { name } } }', old)
          expected = visibility == :visibility ? { "__type" => { "possibleTypes" => [] } } : { "__type" => nil }
          expect(seen).to eq("data" => expected)
          report = audit(schema)
          expect(paths(report, :orphan_interface)).to eq(["Named"])
          expect(report.ok?).to be(false)
        end

        it "reports a union with no member in a version" do
          b = bases
          contract = Class.new(b[:object]) { graphql_name "Contract"; field :party, String, null: true }
          doc = Class.new(b[:union]) { graphql_name "Doc"; possible_types contract, added: "2025-01-01" }
          query = Class.new(b[:object]) do
            graphql_name "Query"
            field :doc, doc, null: true
            field :contract, contract, null: true
          end
          schema = schema_over(query, visibility)

          seen = run(schema, '{ __type(name: "Doc") { possibleTypes { name } } }', old)
          expected = visibility == :visibility ? { "__type" => { "possibleTypes" => [] } } : { "__type" => nil }
          expect(seen).to eq("data" => expected)
          expect(paths(audit(schema), :empty)).to eq(["Doc"])
        end
      end

      describe ":fallback" do
        it "reports an object's field hidden in a version while its interface's lives there" do
          b = bases
          totaled = Module.new { include b[:interface]; graphql_name "Totaled"; field :id, GraphQL::Types::ID, null: true; field :total, Integer, null: true }
          invoice = Class.new(b[:object]) { graphql_name "Invoice"; implements totaled; field :total, Integer, null: true, removed: "2025-01-01" }
          query = Class.new(b[:object]) { graphql_name "Query"; field :invoice, invoice, null: true }
          schema = schema_over(query, visibility)

          if visibility == :warden
            # The Warden serves Totaled's definition where Invoice's own is removed.
            expect(run(schema, "{ invoice { total } }", new, root: record(invoice: record(total: 7)))).to eq("data" => { "invoice" => { "total" => 7 } })
          else
            # Schema::Visibility drops the name: Invoice no longer has a field its interface declares.
            fields = ->(name) { run(schema, %({ __type(name: "#{name}") { fields { name } } }), new).dig("data", "__type", "fields").map { |field| field["name"] } }
            expect([fields.("Totaled"), fields.("Invoice")]).to eq([%w[id total], %w[id]])
          end
          report = audit(schema)
          expect(paths(report, :fallback)).to eq(["Invoice.total"])
          message = visibility == :warden ? /2025-01-01.*serves Totaled's definition/ : /Invoice no longer has total in 2025-01-01, which Totaled declares/
          expect(found(report, :fallback).first.message).to match(message)
          expect(report.ok?).to be(false)
        end

        it "reports an argument an object's field drops in a version while its interface's field takes it" do
          b = bases
          searchable = Module.new do
            include b[:interface]
            graphql_name "Searchable"
            field :search, String, null: true do
              argument :term, String, required: false
              argument :page, Integer, required: false
            end
          end
          catalog = Class.new(b[:object]) do
            graphql_name "Catalog"
            implements searchable
            field :search, String, null: true do
              argument :term, String, required: false
              argument :page, Integer, required: false, removed: "2025-01-01"
            end
          end
          query = Class.new(b[:object]) { graphql_name "Query"; field :catalog, catalog, null: true }
          schema = schema_over(query, visibility)

          arguments = lambda do |name|
            fields = run(schema, %({ __type(name: "#{name}") { fields { args { name } } } }), new).dig("data", "__type", "fields")
            fields.first["args"].map { |argument| argument["name"] }
          end
          expect([arguments.("Searchable"), arguments.("Catalog")]).to eq([%w[term page], %w[term]])
          report = audit(schema)
          expect(paths(report, :fallback)).to eq(["Catalog.search.page"])
          expect(found(report, :fallback).first.message).to match(/2025-01-01.*Searchable\.search takes it/)
          expect(report.ok?).to be(false)
        end
      end

      it "is ok on the same shapes once each member follows its type" do
        b = bases
        filter = Class.new(b[:input]) { graphql_name "Filter"; lifecycle added: "2025-01-01"; argument :q, String, required: false }
        named = Module.new { include b[:interface]; graphql_name "Named"; lifecycle added: "2025-01-01"; field :name, String, null: true }
        person = Class.new(b[:object]) { graphql_name "Person"; implements named, added: "2025-01-01"; field :age, Integer, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :find, String, null: true, added: "2025-01-01" do
            argument :filter, filter, required: true
          end
          field :named, named, null: true, added: "2025-01-01"
          field :person, person, null: true
        end
        report = audit(schema_over(query, visibility))

        expect(report.problems).to eq([])
        expect(report.ok?).to be(true)
      end
    end
  end
end
