# frozen_string_literal: true

# Clients see their budget on every response, not only when they are refused: the points limiter can add it to
# the response's "extensions", and `Points.headers` turns it into HTTP headers.
RSpec.describe "the points budget in responses" do
  let(:store) { GraphQL::Armory::RateLimits::Store::Substitute.new }
  let(:root) { GraphQL::Armory::RateLimits::Controls::Root.example }

  def schema_for(**options)
    query = GraphQL::Armory::RateLimits::Controls::Query.example
    store = self.store
    Class.new(ArmoryEngine.base_schema) do
      query query
      use GraphQL::Armory::RateLimits::Points, store: store, **{ limit: 100, window: 60, soft: false }.merge(options)
    end
  end

  def run(schema, query = "{ report }", key: "user:1")
    execute_query(schema, query, context: { rate_limit_key: key }, root_value: root)
  end

  describe "extensions: true" do
    it "adds what the query cost and what remains to every response" do
      result = run(schema_for(extensions: true))

      expect(result.to_h).to eq(
        "data" => { "report" => "big" },
        "extensions" => { "rateLimit" => { "cost" => 40, "limit" => 100, "remaining" => 60, "resetIn" => 24 } }
      )
    end

    it "adds it to a refused response too" do
      schema = schema_for(extensions: true)
      2.times { run(schema) }

      expect(run(schema).to_h["extensions"]).to eq("rateLimit" => { "cost" => 40, "limit" => 100, "remaining" => 20, "resetIn" => 48 })
    end

    it "says nothing for a client with no limit" do
      expect(run(schema_for(extensions: true, limit: ->(_key, _query) { nil })).to_h).not_to have_key("extensions")
    end

    it "is off by default, leaving responses as they were" do
      expect(run(schema_for).to_h).to eq("data" => { "report" => "big" })
    end

    it "refuses an extensions: that is not true or false" do
      expect { schema_for(extensions: "yes") }.to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, /extensions/)
    end
  end

  describe "Points.headers" do
    let(:headers) { GraphQL::Armory::RateLimits::Points.method(:headers) }

    it "turns the budget into rate limit headers" do
      expect(headers.call(run(schema_for))).to eq(
        "RateLimit-Limit" => "100", "RateLimit-Remaining" => "60", "RateLimit-Reset" => "24"
      )
    end

    it "answers each query's own budget when the queries of a multiplex share one context hash" do
      schema = schema_for
      shared = { rate_limit_key: "user:1" }
      queries = [{ query: "{ report }", context: shared, root_value: root }, { query: "{ cheap }", context: shared, root_value: root }]
      results = ArmoryEngine.next? ? schema.multiplex_next(queries) : schema.multiplex(queries)

      expect(results.map { |result| headers.call(result)["RateLimit-Remaining"] }).to eq(%w[60 59])
    end

    it "answers no headers, and keeps no stale record, when the store fails" do
      schema = schema_for(on_store_error: ->(_error, _query) {})
      shared = { rate_limit_key: "user:1" }
      execute_query(schema, "{ cheap }", context: shared, root_value: root)
      store.fail_with(IOError.new("down"))

      result = execute_query(schema, "{ cheap }", context: shared, root_value: root)

      expect([headers.call(result), result.context[:rate_limit_points]]).to eq([{}, nil])
    end

    it "answers no headers when the query was not limited or the limiter is not installed" do
      unlimited = run(schema_for(limit: ->(_key, _query) { nil }))
      plain = execute_query(Class.new(ArmoryEngine.base_schema) { query(Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :cheap, String }) }, "{ cheap }", root_value: root)

      expect([headers.call(unlimited), headers.call(plain)]).to eq([{}, {}])
    end
  end
end
