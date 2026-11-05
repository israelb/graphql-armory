# frozen_string_literal: true

require "spec_helper"

# Every way a request reaches graphql-ruby goes through the caching guard once, whatever the other plugins and the order of
# their `use` lines; a `rescue_from` handler is always seen. Design 4.1, 4.2 step 0, 8.4, attack list items 3, 4, 10, 11.
RSpec.describe "GraphQL::Armory::Caching entry points" do
  let(:armory) { GraphQL::Armory }
  let(:caching) { GraphQL::Armory::Caching }
  let(:store) { caching::Controls::Store.example }
  let(:gate) { caching::Gate::Substitute.new }
  let(:miss) do
    caching::Decision.miss(caching::Key.new(digest: "b" * 64, scope: :public), caching::Policy.cacheable(ttl: 60, scope: :public),
                           caching::Lookup.miss(seq: 0, epoch: "e", now: 0))
  end

  def context(operation = "names") = caching::Controls::Context.example(operation: operation)

  describe "with PersistedQueries, Versioning, RateLimits and Authorization, in every use order" do
    plugins = %i[persisted_queries versioning rate_limits authorization caching]

    let(:query_type) { caching::Controls::Schema.example.query }

    def schema_in(order, gate)
      armory = GraphQL::Armory
      lines = {
        persisted_queries: -> { use armory::PersistedQueries, store: armory::Caching::Controls::Operations.manifest, strict: true },
        versioning: -> { use armory::Versioning, versions: %w[2025-01-01 2025-06-01], default: :latest },
        rate_limits: -> { use armory::RateLimits::Points, store: armory::RateLimits::MemoryStore.new, limit: 10_000, key: ->(_query) { "client" } },
        authorization: -> { use armory::Authorization, adapter: armory::Authorization::Adapters::Substitute.new(allow: true) },
        caching: -> { use armory::Caching, store: armory::Caching::Controls::Store.example, release: "r1", gate: gate }
      }
      query_type = self.query_type
      Class.new(GraphQL::Schema) do
        use GraphQL::Execution::Next if defined?(GraphQL::Execution::Next)
        query(query_type)
        order.each { |plugin| instance_exec(&lines.fetch(plugin)) }
      end
    end

    it "keeps the guard on multiplex, multiplex_next, context_class and rescue_from, and every module's query class" do
      guards = [caching::Integration::Guard, armory::PersistedQueries::Guard, armory::Versioning::Integration::Guard]

      plugins.permutation.each do |order|
        gate = caching::Gate::Substitute.new
        schema = schema_in(order, gate)
        owners = %i[multiplex context_class rescue_from].to_h { |name| [name, schema.method(name).owner] }
        owners[:multiplex_next] = schema.method(:multiplex_next).owner if defined?(GraphQL::Execution::Next)

        expect(owners.values.uniq).to eq([caching::Integration::Guard]), "use order #{order.inspect}: #{owners.inspect}"
        expect(guards).to include(schema.method(:query_class).owner)
        expect(schema.query_class).to include(caching::Integration::Query, armory::PersistedQueries::Lookup, armory::Versioning::Integration::Lookup)
        expect(schema.context_class).to include(caching::Recorder::Context::Wrapped)

        result = schema.execute(context: context("names"))
        expect(result.to_h["data"]["products"].map { |product| product["name"] }).to eq(%w[Lamp Desk]), "use order #{order.inspect}: #{result.to_h}"
        expect(gate.seen.size).to eq(1), "use order #{order.inspect}"
      end
    end

    it "lets PersistedQueries and Versioning decide while the query is built, before the gate sees it, in every use order" do
      plugins.permutation.each do |order|
        gate = caching::Gate::Substitute.new
        schema = schema_in(order, gate)
        schema.execute(context: context("unknown"))
        schema.execute(context: context("names").merge(armory_version: "1999-01-01"))
        schema.execute("{ products { name } }", context: context(nil))

        refused = gate.seen.map { |queries, _engine| queries.first.static_validator }
        expect(refused).to all(be_a(GraphQL::StaticValidation::Validator)), "use order #{order.inspect}"
        expect(refused.map { |validator| validator.class.name }).to eq([armory::PersistedQueries::Refusal.name, armory::Versioning::Integration::Refusal.name,
                                                                         armory::PersistedQueries::Refusal.name]), "use order #{order.inspect}"
      end
    end
  end

  describe "the request funnel" do
    let(:schema) { caching::Controls::Schema.example(caching: { store: store, release: "r1", gate: gate }) }

    it "sees execute, multiplex and a child schema's multiplex once each" do
      schema.execute(context: context)
      schema.multiplex([{ context: context }, { context: context("catalog") }])
      Class.new(schema).multiplex([{ context: context }])

      expect(gate.seen.map { |queries, engine| [queries.size, engine] }).to eq([[1, :interpreter], [2, :interpreter], [1, :interpreter]])
    end

    it "sees execute_next and multiplex_next once each, labelled :next", if: ArmoryEngine.supported? do
      schema.execute_next(context: context)
      schema.multiplex_next([{ context: context }, { context: context("catalog") }])

      expect(gate.seen.map { |queries, engine| [queries.size, engine] }).to eq([[1, :next], [2, :next]])
    end

    it "sees a Next-default schema's execute, multiplex and multiplex_next once each", if: ArmoryEngine.supported? do
      next_schema = caching::Controls::Schema.example(next_default: true, caching: { store: store, release: "r1", gate: gate })
      next_schema.execute(context: context)
      next_schema.multiplex([{ context: context }])
      next_schema.multiplex_next([{ context: context }])

      expect(gate.seen.map(&:last)).to eq(%i[next next next])
    end

    it "never looks up nor stores a query the app runs with query.result: it skips the funnel and runs uncached" do
      gate.decide(miss)
      query = schema.query_class.new(schema, nil, context: context)
      result = query.result

      expect(result.to_h["data"]["products"].size).to eq(2)
      expect(gate.seen).to eq([])
      expect(gate.stored).to eq([])
    end
  end

  describe "rescue_from" do
    def schema_raising(gate)
      error = Class.new(StandardError)
      legacy = caching::Controls::Schema::NEXT_FIELD_OPTIONS
      query = Class.new(GraphQL::Schema::Object) do
        graphql_name "Query"
        field :boom, String, **legacy
        field :fine, String, **legacy
        define_method(:boom) { raise error, "boom" }
        define_method(:fine) { "fine" }
      end
      manifest = armory::PersistedQueries::Manifest.new({ "boom" => "query Boom { boom }", "fine" => "query Fine { fine }" }, digest: false)
      caching_options = { store: store, release: "r1", gate: gate }
      schema = Class.new(GraphQL::Schema) do
        use GraphQL::Execution::Next if defined?(GraphQL::Execution::Next)
        query(query)
        use GraphQL::Armory::PersistedQueries, store: manifest, strict: true
        use GraphQL::Armory::Caching, **caching_options
      end
      [schema, error]
    end

    it "flags a run a handler answered, calling the handler with graphql-ruby's arguments" do
      gate.decide(miss, miss)
      schema, error = schema_raising(gate)
      calls = []
      schema.rescue_from(error) do |*arguments|
        calls << arguments
        nil
      end

      rescued = execute_query(schema, nil, context: { operation_id: "boom" })
      fine = execute_query(schema, nil, context: { operation_id: "fine" })

      expect(rescued.to_h["data"]).to eq("boom" => nil)
      expect(fine.to_h["data"]).to eq("fine" => "fine")
      expect(calls.size).to eq(1)
      expect(calls.first.size).to eq(5)
      expect(calls.first[0]).to be_a(error)
      expect(calls.first[3]).to be_a(GraphQL::Query::Context)
      expect(gate.stored.map { |query, _decision, _result| caching::RecordKeys.rescued?(query.context) }).to eq([true, false])
      expect(schema.method(:rescue_from).owner).to eq(caching::Integration::Guard)
    end

    it "refuses use after a rescue_from on the schema or a parent: that handler could not be wrapped" do
      parent = Class.new(GraphQL::Schema) { rescue_from(IOError) { nil } }

      expect { parent.use(caching, store: store, release: "r1", gate: gate) }.to raise_error(caching::ConfigurationError, /above `rescue_from`/)
      expect { Class.new(parent).use(caching, store: store, release: "r1", gate: gate) }.to raise_error(caching::ConfigurationError, /above `rescue_from`/)
    end

    it "refuses the request when a parent registers a handler after a child's use" do
      parent = Class.new(GraphQL::Schema)
      query = Class.new(GraphQL::Schema::Object) do
        graphql_name "Query"
        field :fine, String
        define_method(:fine) { "fine" }
      end
      manifest = armory::PersistedQueries::Manifest.new({ "fine" => "query Fine { fine }" }, digest: false)
      child = Class.new(parent) do
        query(query)
        use GraphQL::Armory::PersistedQueries, store: manifest, strict: true
      end
      child.use(caching, store: store, release: "r1", gate: gate)
      parent.rescue_from(IOError) { nil }

      expect { child.execute(context: { operation_id: "fine" }) }.to raise_error(caching::ConfigurationError, /rescue_from/)
      expect(gate.seen).to eq([])
    end
  end
end
