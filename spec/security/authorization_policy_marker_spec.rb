# frozen_string_literal: true

# Authorization marks a query whose answer a policy or ability decided: `namespace(:armory)[:viewer_dependent]`, read
# through `Caching::RecordKeys`. Response caching never stores such a run as a shared (`:public`) answer, so a user the
# policy refuses never gets another user's cached data. The mark is set where the adapter is actually consulted
# (`Authorize#decide` and `Scope#call`), never by a declared bypass (`authorize :none`), which consults nothing.
RSpec.describe "Authorization: the policy marker" do
  let(:record_keys) { GraphQL::Armory::Caching::RecordKeys }
  let(:signals) { [] }

  PolicyMarkerItem = Struct.new(:number, :internal_notes, :export_notes)
  PolicyMarkerRoot = Struct.new(:item, :items, :invoice, :invoices, keyword_init: true) do
    def invoice_by_ref(invoice:)
      invoice
    end
  end

  # `Item` is a bypassed type whose fields are covered by its bypass, with one field rule (`internalNotes`) and, when
  # asked, one `visible_when:` field. `Invoice` is checked with `read` and looked up through the scope.
  def schema_for(adapter, visible_when: false)
    armory = GraphQL::Armory::Authorization
    sink = ->(signal, data) { signals << [signal, data] }
    base_field = Class.new(GraphQL::Schema::Field) { include armory::Base }
    base = Class.new(GraphQL::Schema::Object) do
      include armory::Base
      field_class base_field
    end

    item = Class.new(base) do
      graphql_name "Item"
      authorize :none, reason: "test: a type nothing checks", covers_fields: true, model: Invoice
      field :number, String, null: false
      field :internal_notes, String, authorize: :manage
      field :export_notes, String, visible_when: :export if visible_when
    end

    invoice = Class.new(base) do
      graphql_name "Invoice"
      authorize :read, model: Invoice
      field :number, String, null: false
    end

    memory_invoice = Class.new(base) do
      graphql_name "MemoryInvoice"
      authorize :read, model: Invoice, scope: :in_memory
      field :number, String, null: false
    end

    query = Class.new(base) do
      graphql_name "Query"
      authorize :none, reason: "root type"
      field :item, item, authorize: :none, reason: "test root field"
      field :items, [item], null: false, authorize: :none, reason: "test root field"
      field :invoice, invoice, authorize: :none, reason: "test root field"
      field :invoices, [invoice], null: false, authorize: :none, reason: "test root field"
      field :invoice_by_id, invoice, authorize: :none, reason: "looked up through the scope", find_by: :id do
        argument :id, "GraphQL::Types::ID"
      end
      field :memory_invoice_by_id, memory_invoice, authorize: :none, reason: "found, then checked", find_by: :id do
        argument :id, "GraphQL::Types::ID"
      end
      field :invoice_by_ref, invoice, authorize: :none, reason: "loaded through the scope" do
        argument :invoice_id, "GraphQL::Types::ID", loads: invoice
      end
    end

    Class.new(ArmoryEngine.base_schema) do
      query query
      use armory, adapter: adapter, sinks: [sink]
    end
  end

  def root
    PolicyMarkerRoot.new(
      item: PolicyMarkerItem.new("I-1", "notes", "export"),
      items: [PolicyMarkerItem.new("I-1", "notes", "export"), PolicyMarkerItem.new("I-2", "notes", "export")],
      invoice: Invoice.new(number: "A-1"),
      invoices: [Invoice.new(number: "A-1"), Invoice.new(number: "A-2")]
    )
  end

  def run(schema, query_string, variables: {})
    execute_query(schema, query_string, variables: variables, root_value: root)
  end

  def marked?(result)
    record_keys.viewer_dependent?(result.context)
  end

  def actions(adapter)
    adapter.asked.map { |_actor, _subject, rule| rule.action }
  end

  def run_all(schema, queries)
    ArmoryEngine.next? ? schema.multiplex_next(queries) : schema.multiplex(queries)
  end

  let(:adapter) { GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: true) }

  describe "a consulted policy marks the query" do
    it "for a type rule" do
      result = run(schema_for(adapter), "{ invoice { number } }")

      expect([result.to_h, marked?(result), actions(adapter)]).to eq([{ "data" => { "invoice" => { "number" => "A-1" } } }, true, [:read]])
    end

    it "for a field rule on a bypassed type" do
      result = run(schema_for(adapter), "{ item { number internalNotes } }")

      expect([result.to_h, marked?(result), actions(adapter)]).to eq([{ "data" => { "item" => { "number" => "I-1", "internalNotes" => "notes" } } }, true, [:manage]])
    end

    it "for a scoped list, even when the scope leaves nothing to check one by one" do
      empty = GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: true, scoped: ->(_items) { [] })
      result = run(schema_for(empty), "{ invoices { number } }")

      expect([result.to_h, marked?(result), empty.scoped_for.size, empty.asked]).to eq([{ "data" => { "invoices" => [] } }, true, 1, []])
    end

    it "for a find_by: lookup, even for an id that matches nothing" do
      result = run(schema_for(adapter), 'query($id: ID!) { invoiceById(id: $id) { number } }', variables: { "id" => "999999" })

      expect([result.to_h, marked?(result), adapter.scoped_for.size, adapter.asked]).to eq([{ "data" => { "invoiceById" => nil } }, true, 1, []])
    end

    it "for a loads: argument, even for an id that matches nothing" do
      result = run(schema_for(adapter), 'query($id: ID!) { invoiceByRef(invoiceId: $id) { number } }', variables: { "id" => "999999" })

      expect([result.to_h, marked?(result), adapter.scoped_for.size, adapter.asked]).to eq([{ "data" => { "invoiceByRef" => nil } }, true, 1, []])
    end

    it "for a record an in-memory scope found, which is then checked" do
      found = Invoice.create!(account: Account.create!(name: "A"), number: "A-1")
      result = run(schema_for(adapter), 'query($id: ID!) { memoryInvoiceById(id: $id) { number } }', variables: { "id" => found.id.to_s })

      expect([result.to_h, marked?(result), actions(adapter).uniq, adapter.scoped_for]).to eq([{ "data" => { "memoryInvoiceById" => { "number" => "A-1" } } }, true, [:read], []])
    end

    it "for visible_when:" do
      result = run(schema_for(adapter, visible_when: true), "{ item { exportNotes } }")

      expect([result.to_h, marked?(result), actions(adapter).uniq]).to eq([{ "data" => { "item" => { "exportNotes" => "export" } } }, true, [:export]])
    end

    it "for a denial too: the refused answer depends on the viewer as much as the allowed one" do
      refusing = GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: false)
      result = run(schema_for(refusing), "{ invoice { number } }")

      expect([result.to_h, marked?(result)]).to eq([{ "data" => { "invoice" => nil } }, true])
    end
  end

  describe "a declared bypass consults nothing and marks nothing" do
    it "for an object of a type declared authorize :none" do
      result = run(schema_for(adapter), "{ item { number } }")

      expect([result.to_h, marked?(result), adapter.asked, adapter.scoped_for]).to eq([{ "data" => { "item" => { "number" => "I-1" } } }, false, [], []])
      expect(signals).to include([:bypassed, { type: "PolicyMarkerItem", reason: "test: a type nothing checks" }])
    end

    it "for a list of a type declared authorize :none" do
      result = run(schema_for(adapter), "{ items { number } }")

      expect([result.to_h, marked?(result), adapter.asked, adapter.scoped_for]).to eq([{ "data" => { "items" => [{ "number" => "I-1" }, { "number" => "I-2" }] } }, false, [], []])
      # The list's own bypass (Scope#call) ran: its signal names no type.
      expect(signals).to include([:bypassed, { reason: "test: a type nothing checks" }])
    end
  end

  it "marks each query of a multiplex on its own" do
    schema = schema_for(adapter)
    results = run_all(schema, [{ query: "{ item { number } }", root_value: root }, { query: "{ invoice { number } }", root_value: root }])

    expect(results.map { |result| marked?(result) }).to eq([false, true])
  end

  it "keeps the mark out of the context values a client can send" do
    result = execute_query(schema_for(adapter), "{ item { number } }", context: { viewer_dependent: true }, root_value: root)

    expect(marked?(result)).to be(false)
  end
end
