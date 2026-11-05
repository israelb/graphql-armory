# frozen_string_literal: true

require "spec_helper"
require "graphql/armory/subscriptions"

# A subscription delivery is server work a trigger caused, not a request of the subscriber: charging it to the
# subscriber's key would let whoever causes triggers drain another user's budget. So every limiter skips a query
# carrying the delivery mark, which lives in a namespace of the query's context that no request can write. A client
# request with the same context keys is still charged.
RSpec.describe "rate limits on subscription deliveries" do
  limits = GraphQL::Armory::RateLimits

  let(:subscriptions) { GraphQL::Armory::Subscriptions }
  let(:store) { limits::Store::Substitute.new }
  let(:clock) { limits::Clock::Substitute.new }
  let(:resolved) { [] }
  let(:root) { limits::Controls::Root.example(resolved) }
  let(:query_type) do
    Class.new(limits::Controls::Query.example) do
      field :guarded, String, null: false, method: :cheap, complexity: ->(_context, _arguments, _child) { raise GraphQL::ExecutionError, "lambda says no" }
    end
  end
  # What a client could put in its context to pass for a delivery: none of it is the mark.
  let(:lookalike) { { subscription_delivery: true, armory: { subscription_delivery: true }, __armory_delivery: true } }

  define_method(:schema_with) do |&setup|
    query = query_type
    Class.new(ArmoryEngine.base_schema) do
      query query
      class_exec(&setup)
    end
  end

  def run(schema, query)
    (ArmoryEngine.next? ? schema.multiplex_next([query]) : schema.multiplex([query])).first
  end

  # A delivery as the core builds it: the query, then the mark, then the run. It carries the subscriber's
  # rate_limit_key (a stored context key could hold it), which would be charged without the mark.
  def deliver(schema, document = "{ report }", **context)
    query = schema.query_class.new(schema, document, context: { rate_limit_key: "user:1", **context }, root_value: root)
    subscriptions.delivery!(query.context, "subscription-1")
    run(schema, query)
  end

  def request(schema, document = "{ report }", **context)
    run(schema, schema.query_class.new(schema, document, context: { rate_limit_key: "user:1", **lookalike, **context }, root_value: root))
  end

  def codes(result)
    Array(result.to_h["errors"]).map { |error| error.dig("extensions", "code") }
  end

  describe "Subscriptions.delivery?" do
    it "is true only for a context marked by delivery!, never for a context a request built" do
      schema = schema_with { nil }
      marked = schema.query_class.new(schema, "{ cheap }", context: {})
      subscriptions.delivery!(marked.context, "subscription-1")
      plain = schema.query_class.new(schema, "{ cheap }", context: lookalike)

      expect(subscriptions.delivery?(marked.context)).to be(true)
      expect(subscriptions.delivery?(plain.context)).to be(false)
      expect([subscriptions.delivery?(lookalike), subscriptions.delivery?(nil), subscriptions.delivery?(GraphQL::Query::NullContext.instance)]).to eq([false, false, false])
    end
  end

  describe "Points" do
    let(:schema) do
      store = self.store
      schema_with { use limits::Points, store: store, limit: 100, soft: false }
    end

    it "does not charge a delivery" do
      result = deliver(schema)

      expect(result.to_h).to eq("data" => { "report" => "big" })
      expect(store.calls).to be_empty
    end

    it "runs a delivery that carries no rate_limit_key at all" do
      query = schema.query_class.new(schema, "{ cheap }", context: {}, root_value: root)
      subscriptions.delivery!(query.context, "subscription-1")

      expect(run(schema, query).to_h).to eq("data" => { "cheap" => "ok" })
      expect(store.calls).to be_empty
    end

    it "still charges a client request with the same context keys" do
      expect(request(schema).to_h).to eq("data" => { "report" => "big" })
      expect(store.calls.map(&:first)).to eq([:take])
    end
  end

  describe "Time" do
    let(:schema) do
      store = self.store
      clock = self.clock
      schema_with { use limits::Time, store: store, clock: clock, limit: 1_000, soft: false }
    end

    it "does not charge a delivery" do
      expect(deliver(schema).to_h).to eq("data" => { "report" => "big" })
      expect(store.calls).to be_empty
    end

    it "still charges a client request with the same context keys" do
      request(schema)

      expect(store.calls.map(&:first)).to include(:take)
    end
  end

  describe "Concurrency" do
    let(:schema) do
      store = self.store
      schema_with { use limits::Concurrency, store: store, limit: 2, soft: false }
    end

    it "takes no slot for a delivery" do
      expect(deliver(schema).to_h).to eq("data" => { "report" => "big" })
      expect(store.calls).to be_empty
    end

    it "still takes a slot for a client request with the same context keys" do
      request(schema)

      expect(store.calls.map(&:first)).to eq(%i[acquire release])
    end
  end

  describe "invalid queries" do
    let(:schema) do
      store = self.store
      schema_with { use limits::Points, store: store, limit: 100, soft: false, invalid_cost: 7 }
    end

    it "does not charge an invalid delivery" do
      result = deliver(schema, "{ nothing }")

      expect(result.to_h["errors"]).not_to be_empty
      expect(store.calls).to be_empty
    end

    it "still charges an invalid client request with the same context keys" do
      request(schema, "{ nothing }")

      expect(store.calls.map { |call| [call.first, call.last[:cost]] }).to eq([[:take, 7]])
    end
  end

  describe "Settings.exempt? (what AnalysisGuard asks a limiter that could not answer)" do
    let(:schema) do
      store = self.store
      schema_with { use limits::Points, store: store, limit: 100, soft: false }
    end

    it "answers true for a delivery, so a raise during its analysis leaves it uncharged and unrefused" do
      query = schema.query_class.new(schema, "{ guarded }", context: {}, root_value: root)
      subscriptions.delivery!(query.context, "subscription-1")

      expect(limits::Settings.exempt?(limits::Settings.key_reader(nil), 100, query)).to be(true)
      expect(codes(run(schema, query))).not_to include("RATE_LIMIT_NOT_CHARGED")
      expect(store.calls).to be_empty
    end

    it "answers false for a client request with the same context keys, which is still refused when uncharged" do
      query = schema.query_class.new(schema, "{ guarded }", context: { rate_limit_key: "user:1", **lookalike }, root_value: root)

      expect(limits::Settings.exempt?(limits::Settings.key_reader(nil), 100, query)).to be(false)
      expect(codes(run(schema, schema.query_class.new(schema, "{ guarded }", context: { rate_limit_key: "user:1", **lookalike }, root_value: root))))
        .to include("RATE_LIMIT_NOT_CHARGED")
    end
  end

  it "keeps the analyzers: a delivery over max_complexity is still refused" do
    store = self.store
    schema = schema_with do
      max_complexity 10
      use limits::Points, store: store, limit: 100, soft: false
    end

    result = deliver(schema)

    expect(result.to_h["data"]).to be_nil
    expect(result.to_h["errors"].first["message"]).to include("exceeds max complexity")
    expect(store.calls).to be_empty
  end
end
