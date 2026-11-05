# frozen_string_literal: true

require "digest"

# PersistedQueries marks the query that runs a stored operation: `namespace(:armory)[:persisted]`, read through
# `Caching::RecordKeys`. Response caching serves and stores answers only for marked queries. The mark lives in a
# namespace the client cannot write, so a raw query, a query allowed raw with `armory_allow_raw_query`, a refused
# request and a query the app built itself are never marked, whatever their context holds.
RSpec.describe "PersistedQueries: the persisted mark" do
  let(:operations) { GraphQL::Armory::PersistedQueries::Controls::Operations }
  let(:invoices) { operations.invoices }
  let(:store) { GraphQL::Armory::PersistedQueries::Manifest.new({ id(invoices) => invoices }) }
  let(:root) { GraphQL::Armory::PersistedQueries::Controls::Root.example }
  let(:record_keys) { GraphQL::Armory::Caching::RecordKeys }

  def schema_for(strict:)
    query = GraphQL::Armory::PersistedQueries::Controls::Query.example
    store = self.store
    Class.new(ArmoryEngine.base_schema) do
      query query
      use GraphQL::Armory::PersistedQueries, store: store, strict: strict
    end
  end

  def id(body)
    Digest::SHA256.hexdigest(body)
  end

  def run(schema, text = nil, **context)
    execute_query(schema, text, context: context, root_value: root)
  end

  def marked?(result)
    record_keys.persisted?(result.context)
  end

  def codes(result)
    Array(result.to_h["errors"]).map { |error| error.dig("extensions", "code") }
  end

  [true, false].each do |strict|
    context "with strict: #{strict}" do
      let(:schema) { schema_for(strict: strict) }

      it "marks the query that runs the stored operation an id names" do
        result = run(schema, operation_id: id(invoices))

        expect([result.to_h, marked?(result)]).to eq([{ "data" => { "invoices" => ["A-1"] } }, true])
      end

      it "marks the stored operation when the client also sends its text" do
        result = run(schema, invoices, operation_id: id(invoices))

        expect([result.to_h, marked?(result)]).to eq([{ "data" => { "invoices" => ["A-1"] } }, true])
      end

      it "does not mark an unknown id" do
        result = run(schema, operation_id: "nope")

        expect([codes(result), marked?(result)]).to eq([["UNKNOWN_OPERATION"], false])
      end

      it "does not mark an id sent with another query" do
        result = run(schema, "{ secret }", operation_id: id(invoices))

        expect([codes(result), marked?(result)]).to eq([["OPERATION_MISMATCH"], false])
      end

      it "does not mark a raw query allowed with armory_allow_raw_query, even with the text of a stored operation" do
        result = run(schema, invoices, armory_allow_raw_query: true)

        expect([result.to_h, marked?(result)]).to eq([{ "data" => { "invoices" => ["A-1"] } }, false])
      end

      it "does not mark a query the app built itself, even with an operation id in its context" do
        query = GraphQL::Query.new(schema, invoices, context: { operation_id: id(invoices), armory_allow_raw_query: true }, root_value: root)
        result = (ArmoryEngine.next? ? GraphQL::Execution::Next.run_all(schema, [query], context: {}) : schema.multiplex([query])).first

        expect([result.to_h, marked?(result)]).to eq([{ "data" => { "invoices" => ["A-1"] } }, false])
      end

      it "does not mark a raw query whose context claims it is persisted" do
        result = run(schema, invoices, armory_allow_raw_query: true, persisted: true)

        expect(marked?(result)).to be(false)
      end
    end
  end

  it "does not mark a raw query that strict mode refuses" do
    result = run(schema_for(strict: true), invoices)

    expect([codes(result), marked?(result)]).to eq([["RAW_QUERY_REFUSED"], false])
  end

  it "does not mark a raw query that runs without strict mode" do
    result = run(schema_for(strict: false), invoices)

    expect([result.to_h, marked?(result)]).to eq([{ "data" => { "invoices" => ["A-1"] } }, false])
  end

  it "marks each query of a multiplex on its own" do
    schema = schema_for(strict: false)
    queries = [{ context: { operation_id: id(invoices) }, root_value: root }, { query: invoices, root_value: root }]
    results = ArmoryEngine.next? ? schema.multiplex_next(queries) : schema.multiplex(queries)

    expect(results.map { |result| [result.to_h, marked?(result)] }).to eq([[{ "data" => { "invoices" => ["A-1"] } }, true], [{ "data" => { "invoices" => ["A-1"] } }, false]])
  end
end
