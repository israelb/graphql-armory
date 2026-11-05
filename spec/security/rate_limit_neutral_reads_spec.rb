# frozen_string_literal: true

require "graphql/armory/caching/charge"

# The response cache refuses to store an answer that depended on a context key its cache key does not hold. A limiter
# reads the context to name and limit the client, and that does not change the answer: a `:public` answer is the same
# whoever is charged for it. So every limiter reads its key, limit and exemption through `Caching.neutral`, and its
# own record is not a write of the query. A resolver that reads the same keys is still recorded.
#
# The schemas here use `Recorder::Substitute::Context`, a context class that records what the query reads and writes.
RSpec.describe "Rate limits: neutral context reads" do
  let(:limits) { GraphQL::Armory::RateLimits }
  let(:recorder_context) { GraphQL::Armory::Caching::Recorder::Substitute::Context }
  let(:store) { limits::Store::Substitute.new }
  let(:root) { limits::Controls::Root.example([]) }
  # Read by a key: or a limit: callable, never by the schema's fields.
  let(:inputs) { %i[rate_limit_key current_user plan] }
  let(:key) { ->(query) { query.context[:current_user] } }
  let(:limit) { ->(_key, query) { query.context.fetch(:plan, nil) == "free" ? 100 : 1_000 } }

  # A Query type whose `who` resolver reads context[:current_user] and `budget` reads the limiter's own record.
  def query_type
    # Execution::Next resolves fields on the object unless a field opts in to the type's instance method.
    legacy = ArmoryEngine.supported? ? { resolve_legacy_instance_method: true } : {}
    Class.new(limits::Controls::Query.example) do
      graphql_name "Query"
      field :who, String, null: true, **legacy
      field :budget, Integer, null: true, **legacy

      def who = context[:current_user]
      def budget = context[:rate_limit_points]&.fetch(:remaining)
    end
  end

  def schema_with(*uses)
    context_class = recorder_context
    query_type = self.query_type
    Class.new(ArmoryEngine.base_schema) do
      query query_type
      context_class context_class
      uses.each { |limiter, options| use limiter, **options }
    end
  end

  def context
    { rate_limit_key: "user:1", current_user: "user:1", plan: "free" }
  end

  def run(schema, document = "{ report }")
    execute_query(schema, document, root_value: root, context: context)
  end

  def recorder(result_or_query)
    GraphQL::Armory::Caching::RecordKeys.recorder(result_or_query.context)
  end

  # [the limiters' inputs it recorded as read, the limiters' records it recorded as written]
  def recorded(result_or_query)
    recorder = recorder(result_or_query)
    [recorder.reads.uniq & inputs, recorder.writes.map(&:first).uniq & own_records]
  end

  def own_records
    [limits::Points::CONTEXT_KEY, limits::Time::CONTEXT_KEY, limits::Concurrency::CONTEXT_KEY]
  end

  def hard(**options)
    { store: store, limit: limit, soft: false, key: key }.merge(options)
  end

  it "records nothing a Points limiter reads to name and limit the client, nor its record" do
    expect(recorded(run(schema_with([limits::Points, hard(extensions: true)])))).to eq([[], []])
  end

  it "records nothing the default key reader reads" do
    expect(recorded(run(schema_with([limits::Points, { store: store, limit: 100, soft: false }])))).to eq([[], []])
  end

  it "records nothing a Time or a Concurrency limiter reads, nor their records" do
    schema = schema_with([limits::Time, hard(extensions: true)], [limits::Concurrency, hard(store: limits::Store::Substitute.new)])

    expect(recorded(run(schema))).to eq([[], []])
  end

  it "records nothing a limiter reads for several keys" do
    several = ->(query) { [query.context[:current_user], "ip:#{query.context[:plan]}"] }
    schema = schema_with([limits::Points, hard(key: several)], [limits::Time, hard(key: several, store: limits::Store::Substitute.new)],
                         [limits::Concurrency, hard(key: several, store: limits::Store::Substitute.new)])

    expect(recorded(run(schema))).to eq([[], []])
  end

  it "records nothing the limiters read to charge an invalid query" do
    schema = schema_with([limits::Points, hard], [limits::Time, hard(store: limits::Store::Substitute.new)])

    result = run(schema, "{ nope }")

    expect(result.context[:rate_limit_points]).to include(invalid: true)
    expect(recorded(result)).to eq([[], []])
  end

  it "records nothing a limiter reads to decide whether a client is exempt" do
    schema = schema_with
    query = GraphQL::Query.new(schema, "{ report }", context: context)
    exempt = [limits::Points, limits::Time, limits::Concurrency].map { |limiter| limiter.build(**hard).exempt?(query) }

    expect([exempt, recorded(query)]).to eq([[false, false, false], [[], []]])
  end

  it "records nothing a hit's charge reads or writes" do
    schema = schema_with([limits::Points, hard])
    query = GraphQL::Query.new(schema, "{ report }", root_value: root, context: context)

    GraphQL::Armory::Caching::Charge.build(schema).(query, 40)

    expect(query.context[:rate_limit_points]).to include(cost: 40)
    expect(recorded(query)).to eq([[], []])
  end

  it "still records a resolver that reads the same key" do
    result = run(schema_with([limits::Points, hard]), "{ who }")

    expect([result.to_h["data"], recorded(result).first]).to eq([{ "who" => "user:1" }, [:current_user]])
  end

  it "records a resolver that reads the limiter's record, which is an input it did not write" do
    recorder = recorder(run(schema_with([limits::Points, hard]), "{ budget }"))

    expect([recorder.read?(:rate_limit_points), recorder.writes.map(&:first) & own_records]).to eq([true, []])
    expect(recorder.uncovered([])).to include(:rate_limit_points)
  end

  it "changes nothing for a query without a recorder" do
    query_type = self.query_type
    store = self.store
    limit = self.limit
    key = self.key
    schema = Class.new(ArmoryEngine.base_schema) do
      query query_type
      use GraphQL::Armory::RateLimits::Points, store: store, limit: limit, key: key, soft: false
    end

    expect(run(schema).context[:rate_limit_points]).to include(key: "user:1", limit: 100, remaining: 60)
  end
end
