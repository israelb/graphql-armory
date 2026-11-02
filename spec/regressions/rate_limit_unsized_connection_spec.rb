# frozen_string_literal: true

# graphql-ruby's install template sets no page size, so a connection asked for with no `first:` cannot be scored.
RSpec.describe "Rate limits: a connection with no page size" do
  let(:limits) { GraphQL::Armory::RateLimits }
  let(:store) { limits::Store::Substitute.new }
  let(:resolved) { [] }
  let(:root) do
    seen = resolved
    Class.new { define_method(:items) { seen << :items; %w[a b] } }.new
  end

  def schema_with(**options)
    query_type = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :items, GraphQL::Types::String.connection_type, null: false
    end
    Class.new(ArmoryEngine.base_schema) do
      query query_type
      use GraphQL::Armory::RateLimits::Points, **options
    end
  end

  def run(schema, document)
    execute_query(schema, document, root_value: root, context: { rate_limit_key: "user:1" })
  end

  [true, false].each do |soft|
    context "with soft: #{soft}" do
      let(:schema) { schema_with(store: store, limit: 100, soft: soft) }

      it "refuses the query with an error for the client, and never runs it" do
        response = run(schema, "{ items { nodes } }").to_h

        expect(response["errors"].map { |error| error["message"] }).to eq(["This connection needs first: or last:"])
        expect(response["data"]).to be_nil
        expect(resolved).to be_empty
      end

      it "charges nothing and leaves no record" do
        result = run(schema, "{ items { nodes } }")

        expect(store.calls).to be_empty
        expect(result.context[:rate_limit_points]).to be_nil
      end

      it "still runs the same connection with first:" do
        response = run(schema, "{ items(first: 1) { nodes } }").to_h

        expect(response.dig("data", "items", "nodes")).to eq(["a"])
        expect(store.calls.size).to eq(1)
      end
    end
  end

  it "uses the page size when the schema sets one" do
    sized = schema_with(store: store, limit: 100, soft: false)
    sized.default_max_page_size(5)

    expect(run(sized, "{ items { nodes } }").to_h.dig("data", "items", "nodes")).to eq(%w[a b])
  end

  it "leaves a schema with max_complexity to graphql-ruby, whose own analyzer raises (documented limit)" do
    limited = schema_with(store: store, limit: 100, soft: false)
    limited.max_complexity(1_000)

    expect { run(limited, "{ items { nodes } }") }.to raise_error(GraphQL::Error, /calculate complexity/)
  end

  context "with a later analyzer that raises an ExecutionError" do
    let(:raising) { Class.new(GraphQL::Analysis::Analyzer) { def result = raise(GraphQL::ExecutionError, "no") } }

    it "keeps the refusal of an unsized connection" do
      schema = schema_with(store: store, limit: 100, soft: false)
      schema.query_analyzer(raising)

      response = run(schema, "{ items { nodes } }").to_h
      expect(response["errors"].map { |error| error["message"] }).to eq(["This connection needs first: or last:"])
      expect(resolved).to be_empty
    end

    it "keeps a rate limit refusal" do
      schema = schema_with(store: store, limit: 1, soft: false)
      schema.query_analyzer(raising)

      response = run(schema, "{ items(first: 5) { nodes } }").to_h
      expect(response["errors"].first["extensions"]["code"]).to eq("RATE_LIMITED")
      expect(resolved).to be_empty
    end

    it "leaves a query that nothing refused as graphql-ruby leaves it" do
      schema = schema_with(store: store, limit: 100, soft: false)
      schema.query_analyzer(raising)

      expect(run(schema, "{ items(first: 1) { nodes } }").to_h.dig("data", "items", "nodes")).to eq(["a"])
    end
  end

  it "does not reuse the record of an earlier query on the same context hash" do
    schema = schema_with(store: store, limit: 100, soft: false)
    shared = { rate_limit_key: "user:1" }
    execute_query(schema, "{ items(first: 1) { nodes } }", root_value: root, context: shared)

    expect(execute_query(schema, "{ items { nodes } }", root_value: root, context: shared).context[:rate_limit_points]).to be_nil
  end

  it "does not hide any other error while scoring" do
    query_type = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :items, GraphQL::Types::String, null: false, complexity: ->(_context, _arguments, _child) { raise GraphQL::Error, "a bug in your complexity" }
    end
    broken = Class.new(ArmoryEngine.base_schema) do
      query query_type
      use GraphQL::Armory::RateLimits::Points, store: GraphQL::Armory::RateLimits::Store::Substitute.new, limit: 100, soft: false
    end

    expect { run(broken, "{ items }") }.to raise_error(GraphQL::Error, "a bug in your complexity")
  end
end
