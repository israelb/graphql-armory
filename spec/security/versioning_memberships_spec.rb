# frozen_string_literal: true

# Memberships declared with `implements X, added:` or `possible_types Y, added:` exist only in the versions they live in:
# a client of another version sees the object as not a member of that interface or union, in introspection, the SDL,
# fragments, the fields the interface brings and `resolve_type`. What graphql-ruby would serve anyway is refused.
RSpec.describe "use GraphQL::Armory::Versioning: memberships" do
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:controls) { versioning::Controls }
  let(:base) { versioning::Base }
  let(:old) { "2024-06-01" }
  let(:new) { "2025-01-01" }

  def run(schema, query_string, version, root: nil)
    execute_query(schema, query_string, root_value: root, context: { armory_version: version }).to_h
  end

  def messages(result) = Array(result["errors"]).map { |error| error["message"] }

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

  # Base classes with `Base`, the membership class set on the base interface and the base union.
  def bases
    mod = base
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
    { membership: membership, field: field, object: object, interface: interface, union: union, argument: argument }
  end

  # Invoice implements Archivable from 2025-01-01; Doc lists Contract from 2025-01-01. Both types live everywhere.
  def build_catalog(b = bases)
    archivable = Module.new { include b[:interface]; graphql_name "Archivable"; field :archived, GraphQL::Types::Boolean, null: true }
    invoice = Class.new(b[:object]) do
      graphql_name "Invoice"
      implements archivable, added: "2025-01-01"
      field :number, String, null: true
    end
    memo = Class.new(b[:object]) { graphql_name "Memo"; implements archivable; field :body, String, null: true }
    contract = Class.new(b[:object]) { graphql_name "Contract"; field :party, String, null: true }
    doc = Class.new(b[:union]) do
      graphql_name "Doc"
      possible_types invoice
      possible_types contract, added: "2025-01-01"
    end
    query = Class.new(b[:object]) do
      graphql_name "Query"
      field :invoice, invoice, null: true
      field :contract, contract, null: true
      field :doc, doc, null: true
      field :archivable, archivable, null: true
      field :memo, memo, null: true
    end
    { archivable: archivable, invoice: invoice, contract: contract, doc: doc, query: query, memo: memo, b: b }
  end

  # Execution::Next calls methods on the objects it resolves, so roots are records, not Hashes.
  def record(**values) = Struct.new(*values.keys, keyword_init: true).new(**values)

  def root(catalog)
    record(
      invoice: record(type: catalog[:invoice], number: "F-1", archived: true),
      contract: record(type: catalog[:contract], party: "ACME"),
      doc: record(type: catalog[:contract], party: "ACME"),
      archivable: record(type: catalog[:invoice], number: "F-1", archived: true)
    )
  end

  %i[warden visibility].each do |visibility|
    context "with #{visibility}" do
      let(:catalog) { build_catalog }
      let(:schema) { schema_over(catalog[:query], visibility) }

      it "lists the membership only in the versions it lives in, in introspection and the SDL" do
        introspect = '{ i: __type(name: "Invoice") { interfaces { name } } a: __type(name: "Archivable") { possibleTypes { name } } ' \
                     'd: __type(name: "Doc") { possibleTypes { name } } }'
        by_version = [old, new].map do |version|
          data = run(schema, introspect, version)["data"]
          [data["i"]["interfaces"], data["a"]["possibleTypes"], data["d"]["possibleTypes"]].map { |list| list.map { |type| type["name"] }.sort }
        end
        sdl = [old, new].map { |version| schema.to_definition(context: { armory_version: version }) }

        expect(by_version).to eq([[[], ["Memo"], ["Invoice"]], [["Archivable"], %w[Invoice Memo], %w[Contract Invoice]]])
        expect(sdl.map { |text| [text.include?("type Invoice implements Archivable"), text.include?("union Doc = Contract | Invoice")] }).to eq([[false, false], [true, true]])
      end

      it "takes the interface's fields off the object outside the membership" do
        selection = "{ invoice { number archived } }"

        expect(messages(run(schema, selection, old, root: root(catalog)))).to eq(["Field 'archived' doesn't exist on type 'Invoice'"])
        expect(run(schema, selection, new, root: root(catalog))).to eq("data" => { "invoice" => { "number" => "F-1", "archived" => true } })
        expect(run(schema, "{ memo { body archived } }", old, root: record(memo: record(body: "m", archived: false)))).to eq("data" => { "memo" => { "body" => "m", "archived" => false } })
      end

      it "applies a fragment on the abstract type only inside the membership" do
        on_interface = "{ invoice { number ... on Archivable { archived } } }"
        on_union = "{ contract { party ... on Doc { __typename } } }"
        results = [old, new].map { |version| [on_interface, on_union].map { |text| run(schema, text, version, root: root(catalog)) } }

        expect(results.first.first.key?("data")).to be(false)
        expect(results.first.last).to eq("data" => { "contract" => { "party" => "ACME" } })
        expect(results.last).to eq([{ "data" => { "invoice" => { "number" => "F-1", "archived" => true } } },
                                    { "data" => { "contract" => { "party" => "ACME", "__typename" => "Contract" } } }])
      end

      it "raises graphql-ruby's UnresolvedTypeError when resolve_type answers a type outside the membership" do
        expect { run(schema, "{ doc { __typename } }", old, root: root(catalog)) }.to raise_error(GraphQL::UnresolvedTypeError)
        expect(messages(run(schema, "{ doc { ... on Contract { party } } }", old, root: root(catalog)))).to eq(["Fragment on Contract can't be spread inside Doc"])
        expect(run(schema, "{ doc { ... on Contract { party } } }", new, root: root(catalog))).to eq("data" => { "doc" => { "party" => "ACME" } })
      end

      it "answers the membership through Versioning.types" do
        views = [old, new].map { |version| versioning.types(schema, version) }

        expect(views.map { |view| [view.interfaces(catalog[:invoice]).map(&:graphql_name), view.possible_types(catalog[:doc]).map(&:graphql_name).sort] })
          .to eq([[[], ["Invoice"]], [["Archivable"], %w[Contract Invoice]]])
      end

      it "refuses an argument that loads an abstract type with a versioned membership" do
        b = catalog[:b]
        archivable = catalog[:archivable]
        invoice = catalog[:invoice]
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :invoice, invoice, null: true
          field :archive, GraphQL::Types::Boolean, null: true do
            argument :item_id, GraphQL::Types::ID, required: true, loads: archivable
          end
        end

        expect { run(schema_over(query, visibility), "{ __typename }", new) }.not_to raise_error
        expect { run(schema_over(query, visibility), '{ archive(itemId: "1") }', old) }
          .to raise_error(versioning::ConfigurationError, /archive.itemId: it loads Archivable, which has a membership with a lifecycle/)
      end

      it "refuses an interface membership whose fields another source of the object also declares" do
        b = catalog[:b]
        named = Module.new { include b[:interface]; graphql_name "Named"; field :title, String, null: true }
        titled = Module.new { include b[:interface]; graphql_name "Titled"; field :title, String, null: true }
        report = Class.new(b[:object]) { graphql_name "Report"; implements named; implements titled, added: "2025-01-01" }
        query = Class.new(b[:object]) { graphql_name "Query"; field :report, report, null: true }

        expect { run(schema_over(query, visibility), "{ report { title } }", old) }
          .to raise_error(versioning::ConfigurationError, /Report: implements Titled with a lifecycle, but Titled.title is also declared by Named/)
      end

      it "refuses a versioned membership that another membership to the same type overrides" do
        b = catalog[:b]
        archivable = catalog[:archivable]
        parent = Class.new(b[:object]) { graphql_name "Parent"; implements archivable }
        child = Class.new(parent) { graphql_name "Child"; implements archivable, added: "2025-01-01" }
        contract = catalog[:contract]
        twice = Class.new(b[:union]) { graphql_name "Twice"; possible_types contract; possible_types contract, added: "2025-01-01" }
        query = Class.new(b[:object]) { graphql_name "Query"; field :child, child, null: true; field :twice, twice, null: true }

        expect { run(schema_over(query, visibility), "{ child { archived } }", old) }
          .to raise_error(versioning::ConfigurationError, /Child: implements Archivable with a lifecycle, but another membership to Archivable/)
        query2 = Class.new(b[:object]) { graphql_name "Query"; field :twice, twice, null: true }
        expect { run(schema_over(query2, visibility), "{ twice { __typename } }", old) }
          .to raise_error(versioning::ConfigurationError, /Twice: lists Contract with a lifecycle, but another membership to Contract/)
      end
    end
  end

  describe "membership keywords" do
    let(:bases_example) { bases }

    it "build the membership with its lifecycle" do
      b = bases_example
      archivable = Module.new { include b[:interface]; graphql_name "Archivable" }
      invoice = Class.new(b[:object]) { graphql_name "Invoice"; implements archivable, added: "2025-01-01" }

      membership = invoice.interface_type_memberships.first
      expect([membership.class, membership.armory_lifecycle.to_h, membership.options]).to eq([b[:membership], { added: "2025-01-01" }, {}])
    end

    it "are refused, before anything is added, where graphql-ruby would ignore them or apply them partly" do
      b = bases_example
      plain = Module.new { include GraphQL::Schema::Interface; graphql_name "Plain" }
      archivable = Module.new { include b[:interface]; graphql_name "Archivable" }
      parent = Module.new { include b[:interface]; graphql_name "Parent" }
      nested = Module.new { include b[:interface]; graphql_name "Nested"; implements parent }
      object = b[:object]
      plain_union = Class.new(GraphQL::Schema::Union) { include GraphQL::Armory::Versioning::Base }
      contract = Class.new(object) { graphql_name "Contract" }
      refused = {
        -> { Class.new(object) { graphql_name "A"; implements archivable, plain, added: "2025-01-01" } } => /A: implements Plain with added: or removed: needs Plain's type_membership_class to include GraphQL::Armory::Versioning::Base/,
        -> { Class.new(object) { graphql_name "B"; implements archivable, "Other", added: "2025-01-01" } } => /B: implements "Other" with added: or removed: needs the interface's module, not a name/,
        -> { Class.new(object) { graphql_name "C"; implements nested, added: "2025-01-01" } } => /C: implements Nested with added: or removed:, but Nested implements other interfaces/,
        -> { Module.new { include b[:interface]; graphql_name "D"; implements archivable, added: "2025-01-01" } } => /D: an interface cannot implement another with added: or removed:/,
        -> { Class.new(plain_union) { graphql_name "E"; possible_types contract, added: "2025-01-01" } } => /E: possible_types with added: or removed: needs E's type_membership_class to include GraphQL::Armory::Versioning::Base/,
        -> { Class.new(b[:union]) { graphql_name "F"; possible_types "Contract", added: "2025-01-01" } } => /F: possible_types "Contract" with added: or removed: needs the object's class, not a name/,
        -> { Class.new(object) { graphql_name "G"; implements archivable, added: "" } } => /G: added: must be a non-empty String/
      }

      refused.each { |definition, message| expect(&definition).to raise_error(versioning::ConfigurationError, message) }
      expect(archivable.interfaces).to eq([])
    end
  end
end
