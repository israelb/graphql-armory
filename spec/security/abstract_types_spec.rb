# frozen_string_literal: true

# Interfaces and unions are never authorized themselves: every path ends at a concrete type, which is.
# What an abstract type adds is its fields (declared once, resolved on many types) and its lists.
RSpec.describe "Authorization of interfaces and unions" do
  let(:world) { Dummy::World.build }
  let(:note_class) { Struct.new(:number) }

  def schema_for(adapter, declare_number: false, bypassed_implementer: false)
    armory = GraphQL::Armory::Authorization
    base_field = Class.new(GraphQL::Schema::Field) { include armory::Base }
    base_object = Class.new(GraphQL::Schema::Object) do
      include armory::Base
      field_class base_field
      default_action :read
    end
    document = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Document"
      field_class base_field
      field :number, String, null: false, **(declare_number ? { authorize: :none, reason: "numbers are public" } : {})
    end
    invoice = Class.new(base_object) do
      graphql_name "Invoice"
      implements document
    end
    account = Class.new(base_object) do
      graphql_name "Account"
      field :name, String, null: false
    end
    # Bypassed: it checks nothing itself, so the interface field must say why it may be read.
    public_note = Class.new(base_object) do
      graphql_name "PublicNote"
      authorize :none, reason: "anyone may read public notes"
      implements document if bypassed_implementer
    end
    searchable = Class.new(GraphQL::Schema::Union) do
      graphql_name "Searchable"
      possible_types invoice, account
    end
    types = { invoice => Invoice, account => Account, public_note => note_class }
    query = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root type; each field declares its own rule"
      field :results, [searchable, { null: true }], authorize: :none, reason: "test", null: false, hash_key: :records
      field :result, searchable, authorize: :none, reason: "test", hash_key: :first
      field :documents, [document, { null: true }], authorize: :none, reason: "test", null: false, hash_key: :records
      field :note, public_note, authorize: :none, reason: "test", hash_key: :note
    end
    Class.new(ArmoryEngine.base_schema) do
      query query
      orphan_types invoice, account, public_note
      use armory, adapter: adapter
      define_singleton_method(:resolve_type) do |_abstract, obj, _ctx|
        types.find { |_type, model| obj.is_a?(model) }.first
      end
    end
  end

  %i[pundit cancan].each do |adapter|
    context "with #{adapter}" do
      let(:schema) { schema_for(adapter) }
      let(:bypass_schema) { schema_for(adapter, bypassed_implementer: true) }

      def run(query, user, records: [])
        execute_query(schema, query, context: { current_user: user }, root_value: { records: records, first: records.first, note: note_class.new("N-0") })
      end

      it "returns only the user's own objects from a list of a union" do
        records = [world.a1, world.b1, world.account_a, world.account_b]
        result = run("{ results { __typename ... on Invoice { number } ... on Account { name } } }", world.alice, records: records)

        expect(result["data"]["results"]).to eq([{ "__typename" => "Invoice", "number" => "A-1" }, nil, { "__typename" => "Account", "name" => "A" }, nil])
        expect(result["errors"]).to be_nil
      end

      it "answers a foreign object behind a union field with null" do
        result = run("{ result { ... on Invoice { number } } }", world.alice, records: [world.b1])

        expect(result).to eq("data" => { "result" => nil })
      end

      it "returns only the user's own objects from a list of an interface" do
        result = run("{ documents { number } }", world.alice, records: [world.a1, world.b1])

        expect(result["data"]["documents"]).to eq([{ "number" => "A-1" }, nil])
      end

      it "denies an interface field with no rule when an implementer is bypassed, instead of covering it" do
        result = execute_query(bypass_schema, "{ note { number } }", context: { current_user: world.alice }, root_value: { records: [], note: note_class.new("N-0") })

        expect(result.to_h.to_s).not_to include("N-0")
      end

      it "reports that interface field in the audit" do
        problems = GraphQL::Armory::Authorization::Audit.build(bypass_schema).call(bypass_schema).problems

        expect(problems.map { |p| [p.kind, p.path] }).to include([:field_without_rule, "Document.number"])
      end

      it "reads the interface field once it declares its rule" do
        schema = schema_for(adapter, declare_number: true, bypassed_implementer: true)
        result = execute_query(schema, "{ note { number } }", context: { current_user: world.alice }, root_value: { records: [], note: note_class.new("N-0") })
        problems = GraphQL::Armory::Authorization::Audit.build(schema).call(schema).problems

        expect([result["data"], problems.map(&:path)]).to eq([{ "note" => { "number" => "N-0" } }, []])
      end
    end
  end

  describe "the audit of interface fields" do
    # A bypassed type implementing `interfaces`; `number_rule` is the kwargs of the interface field.
    def audit_of(number_rule: {}, nested: false, node: false)
      armory = GraphQL::Armory::Authorization
      base_field = Class.new(GraphQL::Schema::Field) { include armory::Base }
      base_object = Class.new(GraphQL::Schema::Object) do
        include armory::Base
        field_class base_field
        default_action :read
      end
      numbered = Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Numbered"
        field_class base_field
        field :number, String, null: false, **number_rule
      end
      document = Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Document"
        field_class base_field
        if nested
          implements numbered
        else
          field :number, String, null: false, **number_rule
        end
      end
      public_note = Class.new(base_object) do
        graphql_name "PublicNote"
        authorize :none, reason: "anyone may read public notes"
        implements document
        implements GraphQL::Types::Relay::Node if node
      end
      query = Class.new(base_object) do
        graphql_name "Query"
        authorize :none, reason: "root type"
        field :note, public_note, authorize: :none, reason: "test"
      end
      schema = Class.new(GraphQL::Schema) do
        query query
        use armory, adapter: :pundit
        define_singleton_method(:resolve_type) { |*| public_note }
      end
      GraphQL::Armory::Authorization::Audit.build(schema).call(schema).problems
    end

    it "reports an undeclared field once, on the interface, not again on each implementer" do
      expect(audit_of.map { |p| [p.kind, p.path] }).to eq([[:field_without_rule, "Document.number"]])
    end

    it "reports a field inherited from a nested interface once, where it is declared" do
      expect(audit_of(nested: true).map { |p| [p.kind, p.path] }).to eq([[:field_without_rule, "Numbered.number"]])
    end

    it "reports `authorize: true` on an interface field, which is always denied" do
      problems = audit_of(number_rule: { authorize: true }).map { |p| [p.kind, p.path, p.message] }

      expect(problems).to match([[:field_without_rule, "Document.number", /authorize: true/]])
    end

    it "reports an interface field that is never checked because its field class lacks Base, like Relay's Node.id" do
      problems = audit_of(number_rule: { authorize: :none, reason: "public" }, node: true).map { |p| [p.kind, p.path, p.message] }

      expect(problems).to match([[:unprotected, "Node.id", /not checked/]])
    end
  end

  it "refuses a rule on an interface or a union, which would look protective and protect nothing" do
    armory = GraphQL::Armory::Authorization
    expect { Class.new(GraphQL::Schema::Union) { include armory::Base } }
      .to raise_error(ArgumentError, /possible types/)
    expect { Module.new { include GraphQL::Schema::Interface; include armory::Base } }
      .to raise_error(ArgumentError, /possible types/)
  end
end
