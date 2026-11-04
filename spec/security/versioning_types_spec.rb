# frozen_string_literal: true

# Types declared with `lifecycle added:, removed:` exist only in the versions they live in: a client of another version
# cannot select them, spread fragments on them, use them as variable types, introspect them or see them in that version's
# SDL, and every field or argument that uses them is gone with them.
RSpec.describe "use GraphQL::Armory::Versioning: types" do
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:controls) { versioning::Controls }
  let(:base) { versioning::Base }
  let(:old) { "2024-06-01" }
  let(:new) { "2025-01-01" }

  def run(schema, query_string, version, root: nil, variables: {})
    execute_query(schema, query_string, root_value: root, variables: variables, context: { armory_version: version }).to_h
  end

  def messages(result) = Array(result["errors"]).map { |error| error["message"] }

  def schema_over(query_type, visibility, mutation: nil, extra: [])
    plugin = controls::Schema::PLUGINS.fetch(visibility)
    labels = controls::Versions::LABELS
    retired = controls::Versions::RETIRED
    Class.new(ArmoryEngine.base_schema) do
      query(query_type)
      mutation(mutation) if mutation
      extra_types(*extra) unless extra.empty?
      use plugin
      use GraphQL::Armory::Versioning, versions: labels, retired: retired, default: :latest
      def self.resolve_type(_abstract, object, _context) = object.fetch(:type)
    end
  end

  # Base classes with `Base`, as an app writes them.
  def bases
    mod = base
    argument = Class.new(GraphQL::Schema::Argument) { include mod }
    field = Class.new(GraphQL::Schema::Field) { include mod; argument_class(argument) }
    object = Class.new(GraphQL::Schema::Object) { include mod; field_class(field) }
    interface = Module.new do
      include GraphQL::Schema::Interface
      include mod
      field_class(field)
    end
    {
      argument: argument, field: field, object: object, interface: interface,
      input: Class.new(GraphQL::Schema::InputObject) { include mod; argument_class(argument) },
      enum: Class.new(GraphQL::Schema::Enum) { include mod },
      union: Class.new(GraphQL::Schema::Union) { include mod },
      scalar: Class.new(GraphQL::Schema::Scalar) { include mod },
      mutation: Class.new(GraphQL::Schema::RelayClassicMutation) { include mod; argument_class(argument); field_class(field); object_class(object); input_object_class(Class.new(GraphQL::Schema::InputObject) { include mod; argument_class(argument) }) }
    }
  end

  def type_names(schema, version)
    run(schema, "{ __schema { types { name } } }", version).dig("data", "__schema", "types").map { |type| type["name"] }
  end

  # Contract (object, from 2025-01-01), Legacy (object, removed in 2025-01-01), Archivable (interface, from 2025-01-01)
  # implemented by Invoice, Doc (union of Invoice and Contract, from 2025-01-01), Level (enum, removed in 2025-01-01),
  # Range (input object, from 2025-01-01), Cents (scalar, removed in 2025-01-01).
  def catalog(b = bases)
    archivable = Module.new do
      include b[:interface]
      graphql_name "Archivable"
      lifecycle added: "2025-01-01"
      field :archived, GraphQL::Types::Boolean, null: false
    end
    invoice = Class.new(b[:object]) do
      graphql_name "Invoice"
      implements archivable
      field :number, String, null: false
    end
    contract = Class.new(b[:object]) { graphql_name "Contract"; lifecycle added: "2025-01-01"; field :party, String, null: false }
    legacy = Class.new(b[:object]) { graphql_name "Legacy"; lifecycle removed: "2025-01-01"; field :code, String, null: false }
    doc = Class.new(b[:union]) { graphql_name "Doc"; lifecycle added: "2025-01-01"; possible_types invoice, contract }
    level = Class.new(b[:enum]) { graphql_name "Level"; lifecycle removed: "2025-01-01"; value "LOW" }
    range = Class.new(b[:input]) { graphql_name "Range"; lifecycle added: "2025-01-01"; argument :from, Integer, required: false }
    cents = Class.new(b[:scalar]) { graphql_name "Cents"; lifecycle removed: "2025-01-01" }
    query = Class.new(b[:object]) do
      graphql_name "Query"
      field :invoice, invoice, null: false
      field :contract, contract, null: true
      field :legacy, legacy, null: true
      field :docs, [doc], null: false
      field :archived, [archivable], null: false
      field :level, level, null: true
      field :price, cents, null: true
      field :count, Integer, null: false do
        argument :range, range, required: false
      end
    end
    { query: query, invoice: invoice, contract: contract, legacy: legacy, doc: doc, archivable: archivable, level: level, range: range, cents: cents }
  end

  def root
    Class.new do
      define_method(:invoice) { { type: nil, number: "A-1", archived: false }.then { |h| Struct.new(*h.keys).new(*h.values) } }
      define_method(:contract) { Struct.new(:party).new("ACME") }
      define_method(:legacy) { Struct.new(:code).new("L") }
      define_method(:docs) { [] }
      define_method(:archived) { [] }
      define_method(:level) { "LOW" }
      define_method(:price) { 5 }
      define_method(:count) { |range: nil| range ? range[:from] || 0 : -1 }
    end.new
  end

  %i[warden visibility].each do |visibility|
    context "with #{visibility}" do
      let(:types) { catalog }
      let(:schema) { schema_over(types[:query], visibility) }

      it "lists, looks up and prints each type only in the versions it lives in" do
        expect(type_names(schema, old) & %w[Contract Legacy Doc Archivable Level Range Cents]).to match_array(%w[Legacy Level Cents])
        expect(type_names(schema, new) & %w[Contract Legacy Doc Archivable Level Range Cents]).to match_array(%w[Contract Doc Archivable Range])
        expect(run(schema, '{ __type(name: "Contract") { name } }', old)).to eq("data" => { "__type" => nil })
        expect(run(schema, '{ __type(name: "Legacy") { name } }', new)).to eq("data" => { "__type" => nil })

        older = schema.to_definition(context: { armory_version: old })
        newer = schema.to_definition(context: { armory_version: new })
        expect(%w[Contract Legacy Doc Archivable Level Range Cents].map { |name| [older, newer].map { |sdl| sdl.match?(/^(?:type|enum|union|interface|input|scalar) #{name}\b/) } }).to eq(
          [[false, true], [true, false], [false, true], [false, true], [true, false], [false, true], [true, false]]
        )
      end

      it "hides every field and argument that uses a type outside the version" do
        older = %w[contract docs archived count(range:)].map do |selection|
          query = selection == "count(range:)" ? "{ count(range: { from: 1 }) }" : "{ #{selection} { __typename } }"
          messages(run(schema, query, old, root: root)).first.to_s
        end
        newer = run(schema, "{ legacy { code } level price }", new, root: root)

        expect(older).to eq(
          ["Field 'contract' doesn't exist on type 'Query'", "Field 'docs' doesn't exist on type 'Query'",
           "Field 'archived' doesn't exist on type 'Query'", "Field 'count' doesn't accept argument 'range'"]
        )
        expect(messages(newer)).to include("Field 'legacy' doesn't exist on type 'Query'", "Field 'level' doesn't exist on type 'Query'",
                                           "Field 'price' doesn't exist on type 'Query'")
        expect(run(schema, "{ legacy { code } level price }", old, root: root)).to eq("data" => { "legacy" => { "code" => "L" }, "level" => "LOW", "price" => 5 })
        expect(run(schema, "{ count(range: { from: 3 }) }", new, root: root)).to eq("data" => { "count" => 3 })
      end

      it "refuses fragments and variables typed with a type outside the version" do
        fragment = run(schema, "{ invoice { ... on Archivable { archived } } }", old, root: root)
        variable = run(schema, "query($r: Range) { count(range: $r) }", old, root: root, variables: { "r" => { "from" => 1 } })

        expect([fragment.key?("data"), variable.key?("data")]).to eq([false, false])
        expect(messages(fragment).join).not_to include("Did you mean")
      end

      it "does not list an interface outside the version among an object's interfaces" do
        query = '{ __type(name: "Invoice") { interfaces { name } } }'

        expect(run(schema, query, old).dig("data", "__type", "interfaces")).to eq([])
        expect(run(schema, query, new).dig("data", "__type", "interfaces")).to eq([{ "name" => "Archivable" }])
      end

      it "keeps a type's lifecycle on its subclasses, never on an interface's implementers" do
        b = bases
        parent = Class.new(b[:object]) { graphql_name "Parent"; lifecycle added: "2025-01-01"; field :x, Integer, null: false }
        child = Class.new(parent) { graphql_name "Child" }
        invoice = types[:invoice]
        query = Class.new(b[:object]) { graphql_name "Query"; field :child, child, null: true; field :invoice, invoice, null: false }
        schema = schema_over(query, visibility)

        expect(type_names(schema, old)).not_to include("Child")
        expect(type_names(schema, old)).to include("Invoice")
        expect(type_names(schema, new)).to include("Child", "Invoice", "Archivable")
      end

      it "refuses a subclass visible in a version where its versioned parent is not" do
        b = bases
        parent = Class.new(b[:object]) { graphql_name "Parent"; lifecycle added: "2025-01-01"; field :x, Integer, null: false }
        child = Class.new(parent) { graphql_name "Child"; lifecycle added: "2024-06-01" }
        query = Class.new(b[:object]) { graphql_name "Query"; field :child, child, null: true }

        expect { type_names(schema_over(query, visibility), old) }.to raise_error(versioning::ConfigurationError, /Child: lives in 2024-06-01 but its parent Parent does not/)
      end

      it "hides a mutation outside the version with its generated input and payload types" do
        b = bases
        create = Class.new(b[:mutation]) do
          graphql_name "CreateContract"
          lifecycle added: "2025-01-01"
          argument :party, String, required: true
          field :party, String, null: true
        end
        mutation = Class.new(b[:object]) { graphql_name "Mutation"; field :create_contract, mutation: create }
        schema = schema_over(types[:query], visibility, mutation: mutation)

        older = type_names(schema, old)
        expect([older.include?("CreateContractInput"), older.include?("CreateContractPayload")]).to eq([false, false])
        expect(run(schema, '{ __type(name: "CreateContractPayload") { name } }', old)).to eq("data" => { "__type" => nil })
        expect(type_names(schema, new)).to include("CreateContractInput", "CreateContractPayload")
      end

      it "hides an argument that loads a type outside the version" do
        b = bases
        contract = types[:contract]
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :sign, String, null: true do
            argument :contract_id, GraphQL::Types::ID, required: true, loads: contract
          end
          field :contract, contract, null: true
        end
        schema = schema_over(query, visibility)
        schema.define_singleton_method(:object_from_id) { |_id, _context| { party: "ACME" } }

        expect(messages(run(schema, '{ sign(contractId: "1") }', old))).to eq(["Field 'sign' doesn't accept argument 'contractId'"])
      end

      it "refuses a default value that names an input field whose type is outside the version" do
        b = bases
        range = types[:range]
        filter = Class.new(b[:input]) { graphql_name "Filter"; argument :range, range, required: false }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :count, Integer, null: true do
            argument :filter, filter, required: false, default_value: { range: { from: 1 } }
          end
        end

        expect { run(schema_over(query, visibility), '{ __type(name: "Query") { fields { args { defaultValue } } } }', old) }
          .to raise_error(versioning::ConfigurationError, /count\.filter: its default_value names Filter\.range, not in 2024-06-01/)
      end

      it "refuses lifecycles on memberships, versioned root types and versioned extra types" do
        b = bases
        archivable = types[:archivable]
        contract = types[:contract]

        expect { Class.new(b[:object]) { graphql_name "X"; implements archivable, added: "2025-01-01" } }
          .to raise_error(versioning::ConfigurationError, /X: .*implements.*not supported yet/)
        expect { Class.new(b[:union]) { graphql_name "U"; possible_types contract, removed: "2025-01-01" } }
          .to raise_error(versioning::ConfigurationError, /U: .*possible_types.*not supported yet/)

        versioned_root = Class.new(b[:object]) { graphql_name "Query"; lifecycle added: "2024-06-01"; field :x, Integer, null: true }
        expect { run(schema_over(versioned_root, visibility), "{ __typename }", new) }.to raise_error(versioning::ConfigurationError, /Query: .*root type/)
        expect { run(schema_over(types[:query], visibility, extra: [contract]), "{ __typename }", new) }
          .to raise_error(versioning::ConfigurationError, /Contract: .*extra_types/)
      end

      it "fails the response when resolve_type answers a type outside the version (documented limit)" do
        b = bases
        contract = types[:contract]
        invoice = types[:invoice]
        mixed = Class.new(b[:union]) { graphql_name "Mixed"; possible_types invoice, contract }
        query = Class.new(b[:object]) { graphql_name "Query"; field :mixed, mixed, null: true }
        schema = schema_over(query, visibility)
        data = Class.new { define_method(:mixed) { { type: contract, party: "ACME" } } }.new

        expect { run(schema, "{ mixed { __typename } }", old, root: data) }.to raise_error(GraphQL::UnresolvedTypeError)
        expect(run(schema, "{ mixed { __typename } }", new, root: data)).to eq("data" => { "mixed" => { "__typename" => "Contract" } })
      end
    end
  end

  describe "Versioning.types" do
    let(:types) { catalog }

    %i[warden visibility].each do |visibility|
      it "answers a version's schema to tooling, with #{visibility}, and records no signal" do
        signals = []
        sink = ->(signal, data) { signals << [signal, data] }
        query_type = types[:query]
        plugin = controls::Schema::PLUGINS.fetch(visibility)
        labels = controls::Versions::LABELS
        retired = controls::Versions::RETIRED
        schema = Class.new(ArmoryEngine.base_schema) do
          query(query_type)
          use plugin
          use GraphQL::Armory::Versioning, versions: labels, retired: retired, default: :latest, sinks: [sink]
          def self.resolve_type(_abstract, object, _context) = object.fetch(:type)
        end
        older = versioning.types(schema, "2024-06-01")
        newer = versioning.types(schema, "2025-01-01")

        expect([older.type("Contract"), older.type("Legacy")&.graphql_name, newer.type("Contract")&.graphql_name]).to eq([nil, "Legacy", "Contract"])
        expect(older.fields(types[:query]).map(&:graphql_name)).not_to include("contract", "docs")
        expect(older.fields(types[:contract])).to eq([])
        expect(older.interfaces(types[:invoice])).to eq([])
        expect(newer.interfaces(types[:invoice]).map(&:graphql_name)).to eq(%w[Archivable])
        expect(newer.possible_types(types[:doc]).map(&:graphql_name)).to match_array(%w[Invoice Contract])
        expect(signals).to eq([])
        expect { versioning.types(schema, "2024-01-15") }.to raise_error(versioning::RefusedVersionError)
      end
    end
  end
end
