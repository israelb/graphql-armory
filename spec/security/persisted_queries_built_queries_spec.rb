# frozen_string_literal: true

require "digest"

# A query the app builds itself never passes through the plugin's query class, so strict mode must refuse it elsewhere.
RSpec.describe "Persisted queries: queries built by hand" do
  let(:persisted) { GraphQL::Armory::PersistedQueries }
  let(:invoices) { persisted::Controls::Operations.invoices }
  let(:store) { persisted::Manifest.new({ Digest::SHA256.hexdigest(invoices) => invoices }) }
  let(:resolved) { [] }
  let(:root) { persisted::Controls::Root.example(resolved) }
  let(:seen) { [] }

  def schema_for(strict: true)
    query_type = persisted::Controls::Query.example
    manifest = store
    sinks = [->(signal, data) { seen << [signal, data] }]
    Class.new(ArmoryEngine.base_schema) do
      query query_type
      use GraphQL::Armory::PersistedQueries, store: manifest, strict: strict, sinks: sinks
    end
  end

  def built(schema, **context)
    GraphQL::Query.new(schema, "{ secret }", context: context, root_value: root)
  end

  def run_all(schema, queries)
    if ArmoryEngine.next?
      GraphQL::Execution::Next.run_all(schema, queries, context: {})
    else
      GraphQL::Execution::Interpreter.run_all(schema, queries, context: {})
    end
  end

  it "refuses one in strict mode, with the same message and code" do
    schema = schema_for
    result = run_all(schema, [built(schema)]).first.to_h

    expect(result).not_to have_key("data")
    expect(result["errors"].first).to include("message" => persisted::RAW_QUERY_REFUSED, "extensions" => { "code" => "RAW_QUERY_REFUSED" })
    expect(resolved).to eq([])
    expect(seen).to eq([[:operation_refused, { reason: :raw_query }]])
  end

  it "refuses every one of a multiplex, and runs what came through the plugin" do
    schema = schema_for
    results = run_all(schema, [built(schema), schema.query_class.new(schema, nil, context: { operation_id: Digest::SHA256.hexdigest(invoices) }, root_value: root)])

    expect(results.first.to_h).not_to have_key("data")
    expect(results.last.to_h["data"]).to eq("invoices" => ["A-1"])
    expect(resolved).to eq([:invoices])
  end

  it "does not honour an operation id on one: it runs its own text" do
    schema = schema_for
    result = run_all(schema, [built(schema, operation_id: Digest::SHA256.hexdigest(invoices))]).first.to_h

    expect(result).not_to have_key("data")
  end

  it "raises on one that skips static validation: the next engine would ignore a refusal" do
    schema = schema_for
    query = GraphQL::Query.new(schema, "{ secret }", validate: false, root_value: root)

    expect { run_all(schema, [query]) }.to raise_error(persisted::ConfigurationError, /validate: false/)
    expect(resolved).to eq([])
    expect(seen).to eq([[:operation_refused, { reason: :raw_query }]])
  end

  it "runs one that skips static validation when the context allows raw queries" do
    schema = schema_for
    query = GraphQL::Query.new(schema, "{ secret }", validate: false, context: { armory_allow_raw_query: true }, root_value: root)

    expect(run_all(schema, [query]).first.to_h["data"]).to eq("secret" => "s3cr3t")
  end

  it "refuses a raw query through the plugin that skips static validation" do
    result = execute_query(schema_for, "{ secret }", validate: false, root_value: root).to_h

    expect(result).not_to have_key("data")
    expect(resolved).to eq([])
  end

  it "runs one when the context allows raw queries, and records it" do
    schema = schema_for
    result = run_all(schema, [built(schema, armory_allow_raw_query: true)]).first.to_h

    expect(result["data"]).to eq("secret" => "s3cr3t")
    expect(seen).to eq([[:raw_query_allowed, {}]])
  end

  it "runs one when not strict, and records it" do
    schema = schema_for(strict: false)
    result = run_all(schema, [built(schema)]).first.to_h

    expect(result["data"]).to eq("secret" => "s3cr3t")
    expect(seen).to eq([[:raw_query_run, {}]])
  end

  it "records a query through the plugin once" do
    schema = schema_for(strict: false)
    execute_query(schema, "{ secret }", root_value: root)

    expect(seen).to eq([[:raw_query_run, {}]])
  end
end
