# frozen_string_literal: true

require "digest"

# `use GraphQL::Armory::PersistedQueries, store:` runs the operation a request names by id. An id the store does
# not hold, or a query that does not match its id, runs nothing. In strict mode a raw query runs only for a
# request the app explicitly allows (staff, development).
RSpec.describe "use GraphQL::Armory::PersistedQueries" do
  let(:invoices) { GraphQL::Armory::PersistedQueries::Controls::Operations.invoices }
  let(:greeting) { GraphQL::Armory::PersistedQueries::Controls::Operations.greeting }
  let(:store) do
    GraphQL::Armory::PersistedQueries::Manifest.new(
      { Digest::SHA256.hexdigest(invoices) => invoices, Digest::SHA256.hexdigest(greeting) => greeting }
    )
  end
  let(:resolved) { [] }
  # The root object answers the fields, so both engines resolve them the same way.
  let(:root) { GraphQL::Armory::PersistedQueries::Controls::Root.example(resolved) }

  def schema_for(**options)
    query = GraphQL::Armory::PersistedQueries::Controls::Query.example
    store = options.fetch(:store, self.store)
    Class.new(ArmoryEngine.base_schema) do
      query query
      use GraphQL::Armory::PersistedQueries, store: store, **options.except(:store)
    end
  end

  def run(schema, query = nil, **context)
    execute_query(schema, query, context: context, root_value: root).to_h
  end

  def id(body)
    Digest::SHA256.hexdigest(body)
  end

  def messages(result)
    Array(result["errors"]).map { |error| error["message"] }
  end

  it "runs the stored operation an id names" do
    expect(run(schema_for, operation_id: id(invoices))).to eq("data" => { "invoices" => ["A-1"] })
  end

  it "runs a stored operation with variables" do
    result = execute_query(schema_for, nil, context: { operation_id: id(greeting) }, variables: { "name" => "Ada" }, root_value: root).to_h

    expect(result).to eq("data" => { "greeting" => "Hello Ada" })
  end

  it "refuses an id the store does not hold, running nothing" do
    result = run(schema_for, operation_id: "unknown")

    expect([messages(result), result.key?("data"), resolved]).to eq([["Unknown operation id"], false, []])
  end

  it "refuses an id that is not a String, running nothing" do
    [123, [id(invoices)], { "id" => id(invoices) }].each do |operation_id|
      expect(messages(run(schema_for, operation_id: operation_id))).to eq(["Unknown operation id"])
    end
    expect(resolved).to eq([])
  end

  it "runs an id sent with its own query, as Apollo's clients do" do
    expect(run(schema_for, invoices, operation_id: id(invoices))).to eq("data" => { "invoices" => ["A-1"] })
  end

  it "runs an id sent with an empty query, as a GET request with `query=` does" do
    expect(run(schema_for, "", operation_id: id(invoices))).to eq("data" => { "invoices" => ["A-1"] })
  end

  it "refuses an id sent with another query, running neither" do
    result = run(schema_for, "{ secret }", operation_id: id(invoices))

    expect([messages(result), resolved]).to eq([["The operation id and the query do not match"], []])
  end

  it "runs raw queries as usual when strict mode is off" do
    expect(run(schema_for, "{ secret }")).to eq("data" => { "secret" => "s3cr3t" })
  end

  describe "strict mode" do
    let(:schema) { schema_for(strict: true) }

    it "refuses a raw query, running nothing and validating nothing" do
      result = run(schema, "{ secret }")
      invalid = run(schema, "{ fieldThatDoesNotExist }")

      expect([messages(result), messages(invalid), resolved]).to eq(
        [["Only persisted operations are allowed: send an operation id"]] * 2 + [[]]
      )
    end

    it "refuses a raw query even when the app executes without validation" do
      result = execute_query(schema, "{ secret }", validate: false, root_value: root).to_h

      expect([messages(result), resolved]).to eq([["Only persisted operations are allowed: send an operation id"], []])
    end

    it "keeps a query class the schema already had" do
      custom = Class.new(GraphQL::Query)
      store = self.store
      schema = Class.new(ArmoryEngine.base_schema) do
        query_class custom
        use GraphQL::Armory::PersistedQueries, store: store
      end

      expect(schema.query_class.ancestors).to include(custom)
    end

    it "stays in force when a query class is set after use, or by a child schema" do
      schema.query_class(Class.new(GraphQL::Query))
      child = Class.new(schema) { query_class Class.new(GraphQL::Query) }

      [schema, child].each do |each_schema|
        expect(messages(run(each_schema, "{ secret }"))).to eq(["Only persisted operations are allowed: send an operation id"])
      end
      expect(resolved).to eq([])
    end

    it "leaves Schema.validate reporting errors" do
      expect(schema.validate("{ fieldThatDoesNotExist }").map(&:message)).to eq(
        ["Field 'fieldThatDoesNotExist' doesn't exist on type 'Query'"]
      )
    end

    it "runs stored operations" do
      expect(run(schema, operation_id: id(invoices))).to eq("data" => { "invoices" => ["A-1"] })
    end

    it "runs a raw query for a request the app allows" do
      expect(run(schema, "{ secret }", armory_allow_raw_query: true)).to eq("data" => { "secret" => "s3cr3t" })
    end

    it "takes only true as the allowance" do
      ["true", 1, :yes].each do |allowance|
        expect(messages(run(schema, "{ secret }", armory_allow_raw_query: allowance))).to eq(
          ["Only persisted operations are allowed: send an operation id"]
        )
      end
    end

    it "leaves schema printing working" do
      expect(schema.to_definition).to include("greeting(name: String!): String!")
    end
  end

  describe "what it refuses at boot" do
    def refused(pattern, &block)
      expect(&block).to raise_error(GraphQL::Armory::PersistedQueries::ConfigurationError, pattern)
    end

    it "refuses a store that cannot fetch operations, or a plain Hash" do
      refused(/store/) { schema_for(store: nil) }
      refused(/store/) { schema_for(store: { id(invoices) => invoices }) }
    end

    it "refuses a second use, here or in a child schema, rather than replacing the first" do
      store = self.store
      schema = schema_for(strict: true)

      refused(/already uses/) { schema.use(GraphQL::Armory::PersistedQueries, store: store) }
      refused(/already uses/) { Class.new(schema) { use GraphQL::Armory::PersistedQueries, store: store } }
    end

    it "refuses a strict: that is not true or false" do
      refused(/strict/) { schema_for(strict: "yes") }
    end
  end

  describe ".operation_id" do
    let(:operation_id) { GraphQL::Armory::PersistedQueries.method(:operation_id) }

    it "reads the id from the places clients send it" do
      expect([
        operation_id.call({ "operationId" => "a" }),
        operation_id.call({ "extensions" => { "operationId" => "b" } }),
        operation_id.call({ "extensions" => { "persistedQuery" => { "version" => 1, "sha256Hash" => "c" } } }),
        operation_id.call({ "extensions" => '{"persistedQuery":{"sha256Hash":"d"}}' })
      ]).to eq(%w[a b c d])
    end

    it "answers nil when there is no usable id" do
      [
        {}, nil, "operationId=a", { "operationId" => 1 }, { "operationId" => "" }, { "extensions" => "not json" },
        { "extensions" => ["a"] }, { "extensions" => { "persistedQuery" => "c" } }
      ].each do |params|
        expect(operation_id.call(params)).to be_nil
      end
    end
  end
end
