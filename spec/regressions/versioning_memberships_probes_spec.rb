# frozen_string_literal: true

# Probes from the independent verification of increment 2b2 (membership lifecycles), kept as regressions.
# V1 = 2024-06-01 (outside the memberships), V2 = 2025-01-01 (inside).
RSpec.describe "Versioning 2b2 probes: membership lifecycles" do
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:v1) { "2024-06-01" }
  let(:v2) { "2025-01-01" }
  let(:config_error) { GraphQL::Armory::Versioning::ConfigurationError }

  def run(schema, query_string, version, root: nil, variables: {})
    execute_query(schema, query_string, root_value: root, variables: variables, context: { armory_version: version }).to_h
  end

  def messages(result) = Array(result["errors"]).map { |error| error["message"] }

  def record(**values) = Struct.new(*values.keys, keyword_init: true).new(**values)

  def schema_over(query_type, visibility, loader: nil)
    plugin = GraphQL::Armory::Versioning::Controls::Schema::PLUGINS.fetch(visibility)
    labels = GraphQL::Armory::Versioning::Controls::Versions::LABELS
    retired = GraphQL::Armory::Versioning::Controls::Versions::RETIRED
    Class.new(ArmoryEngine.base_schema) do
      query(query_type)
      use plugin
      use GraphQL::Armory::Versioning, versions: labels, retired: retired, default: :latest
      def self.resolve_type(_abstract, object, _context) = object.type
      define_singleton_method(:object_from_id) { |id, _ctx| loader.call(id) } if loader
    end
  end

  def bases
    mod = GraphQL::Armory::Versioning::Base
    membership = Class.new(GraphQL::Schema::TypeMembership) { include mod }
    argument = Class.new(GraphQL::Schema::Argument) { include mod }
    field = Class.new(GraphQL::Schema::Field) { include mod; argument_class(argument) }
    object = Class.new(GraphQL::Schema::Object) { include mod; field_class(field) }
    interface = Module.new do
      include GraphQL::Schema::Interface
      include mod
      field_class(field)
      type_membership_class(membership)
    end
    union = Class.new(GraphQL::Schema::Union) { include mod; type_membership_class(membership) }
    input = Class.new(GraphQL::Schema::InputObject) { include mod; argument_class(argument) }
    { membership: membership, field: field, object: object, interface: interface, union: union, argument: argument, input: input }
  end

  def archivable_of(b, name = "Archivable")
    Module.new { include b[:interface]; graphql_name name; field :archived, GraphQL::Types::Boolean, null: true }
  end

  def interface_names(schema, name, version)
    data = run(schema, %({ __type(name: "#{name}") { interfaces { name } } }), version)["data"]
    data["__type"] && data["__type"]["interfaces"].map { |t| t["name"] }.sort
  end

  def possible_names(schema, name, version)
    data = run(schema, %({ __type(name: "#{name}") { possibleTypes { name } } }), version)["data"]
    data["__type"] && data["__type"]["possibleTypes"].map { |t| t["name"] }.sort
  end

  %i[warden visibility].each do |visibility|
    context "with #{visibility}" do
      # P02
      it "security P02: a subclass of an object with a versioned membership is not a member outside it" do
        b = bases
        archivable = archivable_of(b)
        invoice = Class.new(b[:object]) { graphql_name "Invoice"; implements archivable, added: "2025-01-01"; field :number, String, null: true }
        sub = Class.new(invoice) { graphql_name "SubInvoice" }
        memo = Class.new(b[:object]) { graphql_name "Memo"; implements archivable }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :sub, sub, null: true
          field :memo, memo, null: true
          field :archivable, archivable, null: true
        end
        schema = schema_over(query, visibility)
        root = record(sub: record(number: "S", archived: true, type: sub))

        expect(messages(run(schema, "{ sub { archived } }", v1, root: root))).to eq(["Field 'archived' doesn't exist on type 'SubInvoice'"])
        expect(run(schema, "{ sub { ... on Archivable { archived } } }", v1, root: root)).not_to have_key("data")
        expect(interface_names(schema, "SubInvoice", v1)).to eq([])
        expect(possible_names(schema, "Archivable", v1)).to eq(["Memo"])
        expect(run(schema, "{ sub { archived } }", v2, root: root)).to eq("data" => { "sub" => { "archived" => true } })
      end

      # P03
      it "security P03: a subclass re-implementing the interface without keywords is refused" do
        b = bases
        archivable = archivable_of(b)
        invoice = Class.new(b[:object]) { graphql_name "Invoice"; implements archivable, added: "2025-01-01" }
        sub = Class.new(invoice) { graphql_name "SubInvoice"; implements archivable }
        query = Class.new(b[:object]) { graphql_name "Query"; field :sub, sub, null: true }

        expect { run(schema_over(query, visibility), "{ sub { archived } }", v1, root: record(sub: record(archived: true, type: sub))) }
          .to raise_error(config_error, /SubInvoice: implements Archivable with a lifecycle, but another membership/)
      end

      # P04
      it "security P04: a grandparent's plain membership makes a grandchild's versioned one refused" do
        b = bases
        archivable = archivable_of(b)
        grand = Class.new(b[:object]) { graphql_name "Grand"; implements archivable }
        mid = Class.new(grand) { graphql_name "Mid" }
        leaf = Class.new(mid) { graphql_name "Leaf"; implements archivable, added: "2025-01-01" }
        query = Class.new(b[:object]) { graphql_name "Query"; field :leaf, leaf, null: true }

        expect { run(schema_over(query, visibility), "{ leaf { archived } }", v1, root: record(leaf: record(archived: true, type: leaf))) }
          .to raise_error(config_error, /Leaf: implements Archivable with a lifecycle, but another membership/)
      end

      # P05
      it "security P05: an interface the object implements that includes the versioned one after the fact is refused" do
        b = bases
        archivable = Module.new { include b[:interface]; graphql_name "Archivable"; field :secret, String, null: true }
        folder = Module.new { include b[:interface]; graphql_name "Folder"; field :path, String, null: true }
        note = Class.new(b[:object]) { graphql_name "Note"; implements folder; implements archivable, added: "2025-01-01" }
        folder.implements(archivable)
        query = Class.new(b[:object]) { graphql_name "Query"; field :note, note, null: true }
        root = record(note: record(secret: "V2-ONLY", path: "/", type: note))

        expect { run(schema_over(query, visibility), "{ note { path secret } }", v1, root: root) }
          .to raise_error(config_error, /Note: implements Archivable with a lifecycle, but another membership to Archivable, or to an interface that includes it/)
      end
      # P06
      it "security P06: I1 versioned implementing I2 after the fact: I1 fields hidden in V1, I2 kept" do
        b = bases
        i1 = Module.new { include b[:interface]; graphql_name "I1"; field :one, String, null: true }
        i2 = Module.new { include b[:interface]; graphql_name "I2"; field :two, String, null: true }
        obj = Class.new(b[:object]) { graphql_name "Obj"; implements i1, added: "2025-01-01"; implements i2 }
        i1.implements(i2)
        query = Class.new(b[:object]) { graphql_name "Query"; field :obj, obj, null: true }
        schema = schema_over(query, visibility)
        root = record(obj: record(one: "1", two: "2", type: obj))

        expect(messages(run(schema, "{ obj { one } }", v1, root: root))).to eq(["Field 'one' doesn't exist on type 'Obj'"])
        expect(run(schema, "{ obj { two } }", v1, root: root)).to eq("data" => { "obj" => { "two" => "2" } })
        expect(Array(possible_names(schema, "I1", v1))).not_to include("Obj")
      end

      # P08
      it "security P08: the superclass declaring the interface's field differently is refused" do
        b = bases
        archivable = archivable_of(b)
        parent = Class.new(b[:object]) { graphql_name "Parent"; field :archived, String, null: true }
        child = Class.new(parent) { graphql_name "Child"; implements archivable, added: "2025-01-01" }
        query = Class.new(b[:object]) { graphql_name "Query"; field :child, child, null: true }

        expect { run(schema_over(query, visibility), "{ child { archived } }", v1, root: record(child: record(archived: "x", type: child))) }
          .to raise_error(config_error, /Child: implements Archivable with a lifecycle, but Archivable.archived is also declared by Parent/)
      end

      # P09
      it "preservation P09: a field from a base interface module shared by every interface is not refused and stays in V1" do
        b = bases
        shared = Module.new { include b[:interface]; graphql_name "SharedBase"; field :id, GraphQL::Types::ID, null: true }
        i1 = Module.new { include shared; graphql_name "I1"; field :one, String, null: true }
        i2 = Module.new { include shared; graphql_name "I2"; field :two, String, null: true }
        obj = Class.new(b[:object]) { graphql_name "Obj"; implements i2; implements i1, added: "2025-01-01" }
        query = Class.new(b[:object]) { graphql_name "Query"; field :obj, obj, null: true }
        schema = schema_over(query, visibility)
        root = record(obj: record(id: "7", one: "1", two: "2", type: obj))

        expect(run(schema, "{ obj { id two } }", v1, root: root)).to eq("data" => { "obj" => { "id" => "7", "two" => "2" } })
        expect(run(schema, "{ obj { id one two } }", v2, root: root)).to eq("data" => { "obj" => { "id" => "7", "one" => "1", "two" => "2" } })
      end

      # P10
      it "preservation P10: a field the object redeclares is not refused and stays in V1" do
        b = bases
        named = Module.new { include b[:interface]; graphql_name "Named"; field :title, String, null: true }
        titled = Module.new { include b[:interface]; graphql_name "Titled"; field :title, String, null: true }
        report = Class.new(b[:object]) do
          graphql_name "Report"
          implements named
          implements titled, added: "2025-01-01"
          field :title, String, null: true
        end
        query = Class.new(b[:object]) { graphql_name "Query"; field :report, report, null: true }
        root = record(report: record(title: "t", type: report))

        expect(run(schema_over(query, visibility), "{ report { title } }", v1, root: root)).to eq("data" => { "report" => { "title" => "t" } })
      end

      # P11b
      it "security P11b: the same field from an interface the superclass implements is refused" do
        b = bases
        named = Module.new { include b[:interface]; graphql_name "Named"; field :title, String, null: true, method: :public_title }
        titled = Module.new { include b[:interface]; graphql_name "Titled"; field :title, String, null: true, method: :secret_title }
        parent = Class.new(b[:object]) { graphql_name "Parent"; implements named }
        child = Class.new(parent) { graphql_name "Child"; implements titled, added: "2025-01-01" }
        query = Class.new(b[:object]) { graphql_name "Query"; field :child, child, null: true }
        root = record(child: record(public_title: "pub", secret_title: "SECRET", type: child))

        expect { run(schema_over(query, visibility), "{ child { title } }", v1, root: root) }
          .to raise_error(config_error, /Child: implements Titled with a lifecycle, but Titled.title is also declared by Named/)
      end

      # P12
      it "security P12: an input-object field and a resolver argument that load the interface are refused" do
        b = bases
        archivable = archivable_of(b)
        invoice = Class.new(b[:object]) { graphql_name "Invoice"; implements archivable, added: "2025-01-01"; field :number, String, null: true }
        filter = Class.new(b[:input]) { graphql_name "Filter"; argument :item_id, GraphQL::Types::ID, required: true, loads: archivable }
        arg_class = b[:argument]
        resolver = Class.new(GraphQL::Schema::Resolver) do
          graphql_name "ByResolver"
          argument_class(arg_class)
          type String, null: true
          argument :item_id, GraphQL::Types::ID, required: true, loads: archivable
          def resolve(item:) = item.number
        end
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :invoice, invoice, null: true
          field :by_filter, String, null: true do
            argument :filter, filter, required: true
          end
          field :by_resolver, resolver: resolver
          def by_filter(filter:) = filter[:item].number
        end
        loader = ->(_id) { record(type: invoice, number: "F-1", archived: true) }
        schema = schema_over(query, visibility, loader: loader)

        expect { run(schema, '{ byFilter(filter: { itemId: "1" }) }', v1) }.to raise_error(config_error, /loads Archivable/)
        expect { run(schema, '{ byResolver(itemId: "1") }', v1) }.to raise_error(config_error, /loads Archivable/)
      end

      # P12b
      it "security P12b: a resolver without the Base argument class loading the interface never loads a non-member in V1" do
        b = bases
        archivable = archivable_of(b)
        invoice = Class.new(b[:object]) { graphql_name "Invoice"; implements archivable, added: "2025-01-01"; field :number, String, null: true }
        resolver = Class.new(GraphQL::Schema::Resolver) do
          graphql_name "ByResolver"
          type String, null: true
          argument :item_id, GraphQL::Types::ID, required: true, loads: archivable
          def resolve(item:) = "LOADED #{item.number}"
        end
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :invoice, invoice, null: true
          field :by_resolver, resolver: resolver
        end
        loader = ->(_id) { record(type: invoice, number: "F-1", archived: true) }
        schema = schema_over(query, visibility, loader: loader)

        outcome = begin
          run(schema, '{ byResolver(itemId: "1") }', v1).dig("data", "byResolver")
        rescue config_error, GraphQL::Error => error
          error.class
        end
        expect(outcome).not_to eq("LOADED F-1")
      end

      # P13
      it "security P13: a membership declared after the loads: argument was first asked is still refused" do
        b = bases
        archivable = archivable_of(b)
        memo = Class.new(b[:object]) { graphql_name "Memo"; implements archivable; field :body, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :memo, memo, null: true
          field :archive, String, null: true do
            argument :item_id, GraphQL::Types::ID, required: true, loads: archivable
          end
          def archive(item:) = "LOADED #{item.class}"
        end
        invoice = nil
        loader = ->(_id) { record(type: invoice, number: "F-1", archived: true) }
        schema = schema_over(query, visibility, loader: loader)
        run(schema, "{ __typename }", v2)
        run(schema, '{ archive(itemId: "1") { } }'.sub(" { }", ""), v2) rescue nil
        invoice = Class.new(b[:object]) { graphql_name "Invoice"; implements archivable, added: "2025-01-01"; field :number, String, null: true }
        schema.orphan_types(invoice)

        outcome = begin
          run(schema, '{ archive(itemId: "1") }', v1).dig("data", "archive")
        rescue config_error, GraphQL::Error => error
          error.class
        end
        expect(outcome).not_to match(/LOADED/)
      end

      # P14
      it "security P14: a union subclass with its own versioned member is refused in loads:" do
        b = bases
        contract = Class.new(b[:object]) { graphql_name "Contract"; field :party, String, null: true }
        invoice = Class.new(b[:object]) { graphql_name "Invoice"; field :number, String, null: true }
        doc = Class.new(b[:union]) { graphql_name "Doc"; possible_types invoice }
        sub = Class.new(doc) { graphql_name "SubDoc"; possible_types invoice; possible_types contract, added: "2025-01-01" }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :doc, doc, null: true
          field :pick, String, null: true do
            argument :item_id, GraphQL::Types::ID, required: true, loads: sub
          end
          def pick(item:) = "LOADED"
        end
        loader = ->(_id) { record(type: contract, party: "x") }
        expect { run(schema_over(query, visibility, loader: loader), '{ pick(itemId: "1") }', v1) }.to raise_error(config_error, /loads SubDoc/)
      end

      # P15a
      it "security P15a: type_membership_class set on the child interface only works" do
        b = bases
        plain_base = Module.new { include GraphQL::Schema::Interface; include GraphQL::Armory::Versioning::Base; field_class(b[:field]) }
        membership = b[:membership]
        archivable = Module.new { include plain_base; graphql_name "Archivable"; type_membership_class(membership); field :archived, GraphQL::Types::Boolean, null: true }
        invoice = Class.new(b[:object]) { graphql_name "Invoice"; implements archivable, added: "2025-01-01" }
        query = Class.new(b[:object]) { graphql_name "Query"; field :invoice, invoice, null: true }
        schema = schema_over(query, visibility)
        root = record(invoice: record(archived: true, type: invoice))

        expect(messages(run(schema, "{ invoice { archived } }", v1, root: root))).to eq(["Field 'archived' doesn't exist on type 'Invoice'"])
        expect(run(schema, "{ invoice { archived } }", v2, root: root)).to eq("data" => { "invoice" => { "archived" => true } })
      end

      # P15b
      it "security P15b: replacing type_membership_class after a versioned membership keeps it versioned, and later keywords are refused" do
        b = bases
        archivable = archivable_of(b)
        invoice = Class.new(b[:object]) { graphql_name "Invoice"; implements archivable, added: "2025-01-01" }
        archivable.type_membership_class(GraphQL::Schema::TypeMembership)
        query = Class.new(b[:object]) { graphql_name "Query"; field :invoice, invoice, null: true }
        root = record(invoice: record(archived: true, type: invoice))

        expect(messages(run(schema_over(query, visibility), "{ invoice { archived } }", v1, root: root))).to eq(["Field 'archived' doesn't exist on type 'Invoice'"])
        expect { Class.new(b[:object]) { graphql_name "Other"; implements archivable, added: "2025-01-01" } }.to raise_error(config_error, /type_membership_class/)
      end

      # P15c
      it "security P15c: a parent union's type_membership_class reaches a subclass union, and its versioned member is hidden" do
        b = bases
        contract = Class.new(b[:object]) { graphql_name "Contract"; field :party, String, null: true }
        invoice = Class.new(b[:object]) { graphql_name "Invoice"; field :number, String, null: true }
        sub = Class.new(b[:union]) { graphql_name "SubDoc"; possible_types invoice; possible_types contract, added: "2025-01-01" }
        query = Class.new(b[:object]) { graphql_name "Query"; field :doc, sub, null: true }
        schema = schema_over(query, visibility)

        expect(possible_names(schema, "SubDoc", v1)).to eq(["Invoice"])
        expect(messages(run(schema, "{ doc { ... on Contract { party } } }", v1))).to eq(["Fragment on Contract can't be spread inside SubDoc"])
      end

      # P16
      # P17
      it "security P17: a union listing the same member versioned first, then plain, is refused" do
        b = bases
        contract = Class.new(b[:object]) { graphql_name "Contract"; field :party, String, null: true }
        twice = Class.new(b[:union]) { graphql_name "Twice"; possible_types contract, added: "2025-01-01"; possible_types contract }
        query = Class.new(b[:object]) { graphql_name "Query"; field :twice, twice, null: true }

        expect { run(schema_over(query, visibility), "{ twice { __typename } }", v1) }
          .to raise_error(config_error, /Twice: lists Contract with a lifecycle, but another membership/)
      end

      # P18
      it "security P18: named, nested and aliased fragments and variables do not reach the interface in V1" do
        b = bases
        archivable = archivable_of(b)
        invoice = Class.new(b[:object]) { graphql_name "Invoice"; implements archivable, added: "2025-01-01"; field :number, String, null: true }
        contract = Class.new(b[:object]) { graphql_name "Contract"; field :party, String, null: true }
        doc = Class.new(b[:union]) { graphql_name "Doc"; possible_types invoice, contract }
        memo = Class.new(b[:object]) { graphql_name "Memo"; implements archivable }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :invoice, invoice, null: true
          field :doc, doc, null: true
          field :memo, memo, null: true
        end
        schema = schema_over(query, visibility)
        inv = record(type: invoice, number: "F-1", archived: true)
        root = record(invoice: inv, doc: inv)
        attempts = [
          "fragment F on Archivable { archived } { invoice { ...F } }",
          "{ doc { ... on Invoice { ... on Archivable { archived } } } }",
          "{ doc { ... on Archivable { __typename } } }",
          "{ invoice { a: archived } }",
          'query($x: Boolean!) { invoice { ... on Archivable @include(if: $x) { archived } } }'
        ]
        leaked = attempts.select do |text|
          result = run(schema, text, v1, root: root, variables: { "x" => true })
          result.to_s.include?("archived\"=>true") || result.to_s.include?("\"Invoice\"") && text.include?("Archivable { __typename")
        end
        expect(leaked).to eq([])
        expect(run(schema, attempts.first, v2, root: root)).to eq("data" => { "invoice" => { "archived" => true } })

        unless ArmoryEngine.next?
          results = schema.multiplex([
            { query: "{ invoice { archived } }", root_value: root, context: { armory_version: v1 } },
            { query: "{ invoice { archived } }", root_value: root, context: { armory_version: v2 } },
            { query: "{ invoice { archived } }", root_value: root, context: { armory_version: v1 } }
          ]).map(&:to_h)
          expect(results.map { |r| r.key?("data") && r["data"] ? r["data"] : messages(r) })
            .to eq([["Field 'archived' doesn't exist on type 'Invoice'"], { "invoice" => { "archived" => true } }, ["Field 'archived' doesn't exist on type 'Invoice'"]])
        end
      end

      # P19
      it "security P19: composed with Authorization's Base, the membership still follows its version" do
        b = bases
        vbase = b[:object]
        abase = Class.new(vbase) { include GraphQL::Armory::Authorization::Base; authorize :read, model: Object, visible_when: :read }
        archivable = archivable_of(b)
        invoice = Class.new(abase) { graphql_name "Invoice"; implements archivable, added: "2025-01-01"; field :number, String, null: true }
        memo = Class.new(abase) { graphql_name "Memo"; implements archivable }
        query = Class.new(abase) { graphql_name "Query"; field :invoice, invoice, null: true; field :memo, memo, null: true }
        adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: true, actor: :anyone)
        schema = schema_over(query, visibility)
        schema.use(GraphQL::Armory::Authorization, adapter: adapter)
        root = record(invoice: record(type: invoice, number: "F-1", archived: true))

        expect(invoice.interface_type_memberships.first.method(:visible?).owner).to eq(GraphQL::Armory::Versioning::Integration::Membership)
        expect(messages(run(schema, "{ invoice { archived } }", v1, root: root))).to eq(["Field 'archived' doesn't exist on type 'Invoice'"])
        expect(run(schema, "{ invoice { archived } }", v2, root: root)).to eq("data" => { "invoice" => { "archived" => true } })
      end

      # P20
      it "security P20: a type lifecycle and a membership lifecycle on the same object combine with AND" do
        b = bases
        archivable = archivable_of(b)
        old_invoice = Class.new(b[:object]) { graphql_name "OldInvoice"; lifecycle removed: "2025-01-01"; implements archivable, added: "2025-01-01"; field :number, String, null: true }
        contract = Class.new(b[:object]) { graphql_name "Contract"; lifecycle added: "2025-01-01"; field :party, String, null: true }
        invoice = Class.new(b[:object]) { graphql_name "Invoice"; field :number, String, null: true }
        doc = Class.new(b[:union]) { graphql_name "Doc"; possible_types invoice; possible_types contract, added: "2024-06-01" }
        memo = Class.new(b[:object]) { graphql_name "Memo"; implements archivable }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :old_invoice, old_invoice, null: true
          field :doc, doc, null: true
          field :memo, memo, null: true
          field :contract, contract, null: true
        end
        schema = schema_over(query, visibility)
        root = record(old_invoice: record(type: old_invoice, number: "1", archived: true))

        expect(messages(run(schema, "{ oldInvoice { archived } }", v1, root: root))).to eq(["Field 'archived' doesn't exist on type 'OldInvoice'"])
        expect(possible_names(schema, "Doc", v1)).to eq(["Invoice"])
        expect(possible_names(schema, "Doc", v2)).to eq(%w[Contract Invoice])
        expect(possible_names(schema, "Archivable", v2)).to eq(["Memo"])
      end

      # P21a
      it "security P21a: a conflicting membership added after the first query is refused" do
        b = bases
        archivable = archivable_of(b)
        invoice = Class.new(b[:object]) { graphql_name "Invoice"; implements archivable, added: "2025-01-01" }
        memo = Class.new(b[:object]) { graphql_name "Memo"; implements archivable }
        query = Class.new(b[:object]) { graphql_name "Query"; field :invoice, invoice, null: true; field :memo, memo, null: true }
        schema = schema_over(query, visibility)
        root = record(invoice: record(archived: true, type: invoice))
        run(schema, "{ invoice { __typename } }", v1, root: root)
        invoice.implements(archivable)

        outcome = begin
          run(schema, "{ invoice { archived } }", v1, root: root)
        rescue config_error => error
          :refused
        end
        expect(outcome).not_to eq("data" => { "invoice" => { "archived" => true } })
      end

      # P21b
      it "security P21b: a String membership to the same interface does not make the versioned one live everywhere" do
        b = bases
        archivable = archivable_of(b)
        invoice = Class.new(b[:object]) { graphql_name "Invoice"; implements archivable, added: "2025-01-01"; implements "Archivable" }
        memo = Class.new(b[:object]) { graphql_name "Memo"; implements archivable }
        query = Class.new(b[:object]) { graphql_name "Query"; field :invoice, invoice, null: true; field :memo, memo, null: true }
        root = record(invoice: record(archived: true, type: invoice))

        outcome = begin
          schema = schema_over(query, visibility)
          [run(schema, "{ invoice { archived } }", v1, root: root), interface_names(schema, "Invoice", v1)]
        rescue StandardError => error
          [error.class, error.message[0, 160]]
        end
        expect(outcome.first).not_to eq("data" => { "invoice" => { "archived" => true } })
        expect(outcome.last).not_to eq(["Archivable"])
      end

      # P23
      it "preservation P23: Union.possible_types keeps its reader, with and without a context" do
        b = bases
        contract = Class.new(b[:object]) { graphql_name "Contract"; field :party, String, null: true }
        invoice = Class.new(b[:object]) { graphql_name "Invoice"; field :number, String, null: true }
        doc = Class.new(b[:union]) { graphql_name "Doc"; possible_types invoice; possible_types contract, added: "2025-01-01" }
        query = Class.new(b[:object]) { graphql_name "Query"; field :doc, doc, null: true }
        schema = schema_over(query, visibility)
        q = GraphQL::Query.new(schema, "{ __typename }", context: { armory_version: v1 })

        expect(doc.possible_types.map(&:graphql_name)).to eq(%w[Invoice Contract])
        # Under Schema::Visibility graphql-ruby's class-level reader does not filter (documented limit: context-free lookups).
        expect(doc.possible_types(context: q.context).map(&:graphql_name)).to eq(["Invoice"]) if visibility == :warden
      end

      # P24
      it "security P24: resolve_type answering a non-member of the interface in V1 never serves it" do
        b = bases
        archivable = archivable_of(b)
        invoice = Class.new(b[:object]) { graphql_name "Invoice"; implements archivable, added: "2025-01-01"; field :number, String, null: true }
        memo = Class.new(b[:object]) { graphql_name "Memo"; implements archivable }
        query = Class.new(b[:object]) { graphql_name "Query"; field :archivable, archivable, null: true; field :invoice, invoice, null: true; field :memo, memo, null: true }
        root = record(archivable: record(type: invoice, number: "F-1", archived: true))

        outcome = begin
          run(schema_over(query, visibility), "{ archivable { __typename archived } }", v1, root: root)
        rescue GraphQL::UnresolvedTypeError
          :raised
        end
        expect(outcome).to eq(:raised)
      end

      # P27
      it "security P27: an object class without Base cannot take a versioned membership" do
        b = bases
        plain_object = Class.new(GraphQL::Schema::Object) { field_class(b[:field]) }
        archivable = archivable_of(b)
        parent = Class.new(plain_object) { graphql_name "Parent"; implements archivable }

        expect { Class.new(parent) { graphql_name "Child"; implements archivable, added: "2025-01-01" } }.to raise_error(config_error, /needs an object class and an interface or union that include GraphQL::Armory::Versioning::Base/)
      end
      # P27a
      it "security P27a: an object class without Base cannot take a versioned membership whose interface shares a field" do
        b = bases
        plain_object = Class.new(GraphQL::Schema::Object) { field_class(b[:field]) }
        named = Module.new { include b[:interface]; graphql_name "Named"; field :title, String, null: true, method: :public_title }
        titled = Module.new { include b[:interface]; graphql_name "Titled"; field :title, String, null: true, method: :secret_title }

        expect { Class.new(plain_object) { graphql_name "Report"; implements named; implements titled, added: "2025-01-01" } }.to raise_error(config_error, /needs an object class and an interface or union that include GraphQL::Armory::Versioning::Base/)
      end
      # P27b
      it "security P27b: a union class without Base cannot list a member with a lifecycle" do
        b = bases
        membership = b[:membership]
        contract = Class.new(b[:object]) { graphql_name "Contract"; field :party, String, null: true }

        expect { Class.new(GraphQL::Schema::Union) { graphql_name "Twice"; type_membership_class(membership); possible_types contract, added: "2025-01-01" } }
          .to raise_error(config_error, /needs an object class and an interface or union that include GraphQL::Armory::Versioning::Base/)
      end
      # P27c
      it "security P27c: an interface without Base cannot implement another with added:" do
        b = bases
        archivable = archivable_of(b)

        expect { Module.new { include GraphQL::Schema::Interface; graphql_name "Folder"; implements archivable, added: "2025-01-01" } }
          .to raise_error(config_error, /needs an object class and an interface or union that include GraphQL::Armory::Versioning::Base/)
      end
    end
  end

  # P07
  it "security P07: a refused implements adds nothing to the object, all or nothing" do
    b = bases
    archivable = archivable_of(b)
    parent = Module.new { include b[:interface]; graphql_name "ParentI" }
    nested = Module.new { include b[:interface]; graphql_name "Nested"; implements parent }
    obj = Class.new(b[:object]) { graphql_name "Obj" }

    expect { obj.implements(archivable, nested, added: "2025-01-01") }.to raise_error(GraphQL::Armory::Versioning::ConfigurationError, /Nested implements other interfaces/)
    expect([obj.interface_type_memberships, obj.include?(archivable)]).to eq([[], false])
  end

  # P22 is the run of this whole file on graphql 2.4; this pins the keywords reaching the membership there.
  it "preservation P22: the keywords reach the membership on this graphql version" do
    b = bases
    archivable = archivable_of(b)
    contract = Class.new(b[:object]) { graphql_name "Contract" }
    invoice = Class.new(b[:object]) { graphql_name "Invoice"; implements archivable, removed: "2025-01-01" }
    doc = Class.new(b[:union]) { graphql_name "Doc"; possible_types contract, added: "2025-01-01" }

    expect([invoice.interface_type_memberships.first.armory_lifecycle.to_h, doc.type_memberships.first.armory_lifecycle.to_h])
      .to eq([{ removed: "2025-01-01" }, { added: "2025-01-01" }])
  end
end
