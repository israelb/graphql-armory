# frozen_string_literal: true

# Clients see their budget on every response, not only when they are refused: the points limiter can add it to
# the response's "extensions", and `Points.headers` turns it into HTTP headers.
RSpec.describe "the points budget in responses" do
  let(:now) { [0.0] }
  let(:store) { GraphQL::Armory::RateLimits::MemoryStore.new(clock: -> { now[0] }) }
  let(:root) { Class.new { def cheap = "ok"; def report = "big" }.new }

  def schema_for(**options)
    query = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :cheap, String, null: false
      field :report, String, null: false, complexity: 40
    end
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

    it "answers no headers when the query was not limited or the limiter is not installed" do
      unlimited = run(schema_for(limit: ->(_key, _query) { nil }))
      plain = execute_query(Class.new(ArmoryEngine.base_schema) { query(Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :cheap, String }) }, "{ cheap }", root_value: root)

      expect([headers.call(unlimited), headers.call(plain)]).to eq([{}, {}])
    end
  end
end
