# frozen_string_literal: true

require "spec_helper"

# The whole response cache through `use`, on the Controls schema: what a request stores, what the next one is served,
# and what a purge removes. Telemetry is read from the schema's sink, never from mocks.
RSpec.describe "GraphQL::Armory::Caching end to end" do
  let(:caching) { GraphQL::Armory::Caching }
  let(:store) { caching::Controls::Store.example }
  let(:recorded) { [] }
  let(:sink) { ->(signal, data) { recorded << [signal, data] } }
  let(:options) { { store: store, release: "r1", viewer: :current_user, sinks: [sink] } }

  def schema(**extra)
    @schema ||= caching::Controls::Schema.example(caching: options.merge(extra))
  end

  def run(operation, engine: :execute, **context)
    schema.public_send(engine, context: caching::Controls::Context.example(operation: operation, **context)).to_h
  end

  def signals(name) = recorded.select { |signal, _| signal == name }.map(&:last)

  it "stores a public answer on the first request and serves it on the second, unchanged" do
    first = run("names")
    second = run("names", viewer: caching::Controls::Viewer.example(id: 8))

    expect(first["data"]["products"]).not_to be_empty
    expect(second).to eq(first)
    expect(signals(:cache_stored).size).to eq(1)
    expect(signals(:cache_hit).size).to eq(1)
  end

  it "serves a :viewer answer to its viewer only" do
    run("invoices")
    run("invoices")
    run("invoices", viewer: caching::Controls::Viewer.example(id: 8))

    expect(signals(:cache_hit).size).to eq(1)
    expect(signals(:cache_stored).size).to eq(2)
  end

  it "stops serving an answer once its tag is purged" do
    run("catalog")
    caching.purge(schema, tag: "pricing")
    run("catalog")

    expect(signals(:cache_hit)).to be_empty
    expect(signals(:cache_purged).size).to eq(1)
  end

  it "keys the engine: an answer stored by the interpreter is not served on Next", if: ArmoryEngine.supported? do
    run("names")
    run("names", engine: :execute_next)

    expect(signals(:cache_hit)).to be_empty
    expect(signals(:cache_stored).size).to eq(2)
  end

  describe "with resolvers of the app's own" do
    # `Controls::AppSchema` with this file's options, `caching:` merged over them.
    def app(documents, caching: {}, **options, &fields)
      self.caching::Controls::AppSchema.example(documents, caching: self.options.merge(caching), **options, &fields)
    end

    # On the engine the suite runs.
    def request(schema, operation, **context)
      execute_query(schema, nil, context: { operation_id: operation, current_user: caching::Controls::Viewer.example }.merge(context))
    end

    def status(result) = result.context[:response_cache][:status]

    def multiplex(schema, queries)
      ArmoryEngine.next? ? schema.multiplex_next(queries) : schema.multiplex(queries)
    end

    it "keys a vary: context key: the same locale is served, another one runs and is stored apart" do
      schema = app({ "op" => "query Op { greeting }" }, caching: { vary: { locale: :locale } }) do |options|
        field :greeting, String, null: true, **options
        define_method(:greeting) { "hello #{context[:locale]}" }
      end
      results = [request(schema, "op", locale: "en"), request(schema, "op", locale: "en"), request(schema, "op", locale: "fr")]

      expect(results.map { |result| result["data"]["greeting"] }).to eq(["hello en", "hello en", "hello fr"])
      expect(results.map { |result| status(result) }).to eq(%i[stored hit stored])
    end

    it "keys a vary: callable that reads no context, such as a thread-local locale" do
      schema = app({ "op" => "query Op { greeting }" }, caching: { vary: { locale: -> { Thread.current[:armory_e2e_locale] } } }) do |options|
        field :greeting, String, null: true, **options
        define_method(:greeting) { "hello #{Thread.current[:armory_e2e_locale]}" }
      end
      results = %w[en en fr].map do |locale|
        Thread.current[:armory_e2e_locale] = locale
        request(schema, "op")
      ensure
        Thread.current[:armory_e2e_locale] = nil
      end

      expect(results.map { |result| result["data"]["greeting"] }).to eq(["hello en", "hello en", "hello fr"])
      expect(results.map { |result| status(result) }).to eq(%i[stored hit stored])
    end

    it "stores a run that passes a value down with scoped_set! and reads it below" do
      legacy = caching::Controls::Schema::NEXT_FIELD_OPTIONS
      label = Class.new(caching::Controls::AppSchema::Bases.example.fetch(:object)) do
        graphql_name "Label"
        authorize :none, reason: "public test data", covers_fields: true
        cache_fields ttl: 60, scope: :public, reason: "the same for everyone"
        field :text, String, null: true, **legacy
        define_method(:text) { "#{context[:prefix]} lamp" }
      end
      schema = app({ "op" => "query Op { label { text } }" }) do |options|
        field :label, label, null: true, **options
        define_method(:label) do
          context.scoped_set!(:prefix, "shiny")
          {}
        end
      end
      first = request(schema, "op")
      second = request(schema, "op")

      expect(second["data"]).to eq("label" => { "text" => "shiny lamp" })
      expect([status(first), status(second)]).to eq(%i[stored hit])
    end

    it "stores a :public answer while a Points limiter reads the viewer to name the client" do
      bucket = GraphQL::Armory::RateLimits::MemoryStore.new
      schema = app({ "op" => "query Op { greeting }" }, before: proc {
        use GraphQL::Armory::RateLimits::Points, store: bucket, limit: 100, soft: false, key: ->(query) { "user:#{query.context[:current_user].id}" }
      }) do |options|
        field :greeting, String, null: true, **options
        define_method(:greeting) { "hello" }
      end
      first = request(schema, "op")
      second = request(schema, "op", current_user: caching::Controls::Viewer.example(id: 8))

      expect([status(first), status(second)]).to eq(%i[stored hit])
      expect(second.context[:rate_limit_points]).to include(key: "user:8")
    end

    it "answers a hit and a miss of one multiplex in order, and query.result of the hit runs and charges nothing more" do
      bucket = GraphQL::Armory::RateLimits::MemoryStore.new
      schema = caching::Controls::Schema.example(caching: options).tap do |built|
        built.use(GraphQL::Armory::RateLimits::Points, store: bucket, limit: 100, soft: false, key: ->(_query) { "user:7" })
      end
      request(schema, "names")
      results = multiplex(schema, [{ context: caching::Controls::Context.example(operation: "catalog") },
                                   { context: caching::Controls::Context.example(operation: "names") }])
      hit = results.last
      charged = hit.context[:rate_limit_points]
      again = hit.query.result
      later = request(schema, "names").context[:rate_limit_points]

      expect(results.map { |result| status(result) }).to eq(%i[stored hit])
      expect(results.first["data"]["products"].first.keys).to eq(%w[name price])
      expect(again.to_h).to eq(hit.to_h)
      expect(hit.query.executed?).to be(false)
      # The miss beside the hit is charged after the hit's record was written; query.result charged nothing.
      expect(later[:remaining]).to eq(charged[:remaining] - results.first.context[:rate_limit_points][:cost] - charged[:cost])
    end

    it "lets an app visible? reach the dataloader during the walk, and gives resolvers the multiplex's" do
      seen = []
      schema = app({ "op" => "query Op { greeting }" }) do |options|
        field :greeting, String, null: true, **options do
          define_singleton_method(:visible?) do |context|
            seen << [:visible, context.dataloader]
            super(context)
          end
        end
        define_method(:greeting) do
          seen << [:resolver, context.dataloader]
          "hello"
        end
      end
      result = request(schema, "op")
      in_resolver = seen.select { |where, _| where == :resolver }.map(&:last)

      expect(result["data"]).to eq("greeting" => "hello")
      expect(seen.map(&:first)).to include(:visible)
      expect(in_resolver.size).to eq(1)
      # Execution::Next binds no Multiplex to the query: its resolvers get the context's own dataloader.
      expect(in_resolver.first).to equal(result.query.multiplex.dataloader) unless ArmoryEngine.next?
    end
  end
end
