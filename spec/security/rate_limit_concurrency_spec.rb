# frozen_string_literal: true

# `use GraphQL::Armory::RateLimits::Concurrency` lets each client run at most N operations at the same time. A
# client already at its limit is refused before any field resolves; every slot is released when its operation
# ends, even when it raises.
RSpec.describe "use GraphQL::Armory::RateLimits::Concurrency" do
  let(:store) { GraphQL::Armory::RateLimits::Store::Substitute.new }
  let(:resolved) { [] }
  let(:root) { GraphQL::Armory::RateLimits::Controls::Root.example(resolved) }

  def schema_for(**options)
    query = GraphQL::Armory::RateLimits::Controls::Query.example
    store = self.store
    Class.new(ArmoryEngine.base_schema) do
      query query
      use GraphQL::Armory::RateLimits::Concurrency, store: store, **{ limit: 2, soft: false }.merge(options)
    end
  end

  def run(schema, query = "{ cheap }", key: "user:1", **context)
    context = context.merge(rate_limit_key: key) if key
    result = execute_query(schema, query, context: context, root_value: root)
    [result.to_h, result.context[:rate_limit_concurrency]]
  end

  # An operation of the same client still running elsewhere.
  def occupy(key = "user:1") = store.occupy(key)

  def active(key = "user:1") = store.held(key)

  it "runs an operation under the limit, records it, and releases its slot when it ends" do
    occupy
    response, info = run(schema_for)

    expect(response).to eq("data" => { "cheap" => "ok" })
    expect(info).to eq(key: "user:1", limit: 2, active: 2, soft: false, limited: false)
    expect(active).to eq(1)
  end

  it "refuses an operation when the client is at its limit, running nothing" do
    2.times { occupy }
    response, info = run(schema_for)

    expect([response.key?("data"), resolved, info[:limited]]).to eq([false, [], true])
    expect(response["errors"].first).to include(
      "message" => "Too many operations at the same time: 2 are already running for this client (limit 2). Retry when one finishes.",
      "extensions" => { "code" => "RATE_LIMITED", "limit" => 2, "active" => 2 }
    )
    expect(active).to eq(2)
  end

  it "runs again once a running operation finishes" do
    tokens = 2.times.map { occupy }
    store.release("user:1", token: tokens.first)

    expect(run(schema_for).first).to eq("data" => { "cheap" => "ok" })
  end

  it "releases the slot when the operation raises" do
    schema = schema_for(limit: 1)

    expect { run(schema, "{ broken }") }.to raise_error(IOError)
    expect(active).to eq(0)
  end

  it "releases the slot of an operation another analyzer refused" do
    schema = schema_for(limit: 1)
    schema.max_depth(1)

    run(schema, "{ __schema { types { name } } }")

    expect(active).to eq(0)
  end

  it "frees slots left by a crashed process once they are stale" do
    occupy
    occupy
    store.now = 61.0

    expect(run(schema_for).last).to include(active: 1, limited: false)
  end

  it "keeps separate slots per client" do
    2.times { occupy("user:1") }

    expect(run(schema_for, key: "user:2").last).to include(active: 1, limited: false)
  end

  it "holds a slot per query of a multiplex while they run, and releases them all" do
    schema = schema_for(limit: 1)
    results = schema.multiplex([{ query: "{ cheap }", context: { rate_limit_key: "user:1" }, root_value: root }] * 2)

    expect(results.map { |result| result.to_h.key?("errors") }).to eq([false, true])
    expect(active).to eq(0)
  end

  it "releases every slot when the queries of a multiplex share one context hash, as batched requests do" do
    schema = schema_for(limit: 2)
    context = { rate_limit_key: "user:1" }
    queries = [{ query: "{ cheap }", context: context, root_value: root }] * 2
    ArmoryEngine.next? ? schema.multiplex_next(queries) : schema.multiplex(queries)

    expect(active).to eq(0)
  end

  it "refuses to take a slot for a query that brings its own trace, since it could never release it" do
    expect { run(schema_for(limit: 1), trace: GraphQL::Tracing::Trace.new) }
      .to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, /trace/)
    expect(active).to eq(0)
  end

  it "releases every slot of a multiplex even when the hook raises on one release" do
    store.fail_with(IOError.new("flaky"), on: :release, times: 1)
    schema = schema_for(limit: 5, on_store_error: ->(error, _query) { raise error })
    queries = 3.times.map { { query: "{ cheap }", context: { rate_limit_key: "user:1" }, root_value: root } }

    expect { ArmoryEngine.next? ? schema.multiplex_next(queries) : schema.multiplex(queries) }.to raise_error(IOError, "flaky")
    expect(active).to eq(1)
  end

  describe "soft mode, the default" do
    it "runs operations over the limit and records them as limited" do
      query = schema_for.query
      store = self.store
      schema = Class.new(ArmoryEngine.base_schema) do
        query query
        use GraphQL::Armory::RateLimits::Concurrency, store: store, limit: 1
      end
      occupy

      response, info = run(schema)

      expect([response, info[:soft], info[:limited]]).to eq([{ "data" => { "cheap" => "ok" } }, true, true])
      expect(active).to eq(1)
    end
  end

  it "takes a limit per key, and nil for no limit" do
    schema = schema_for(limit: ->(key, _query) { key == "admin" ? nil : 1 })
    2.times { occupy("admin") }

    expect(run(schema, key: "admin").last).to include(limit: nil, active: nil, limited: false)
  end

  it "raises when the context has no key" do
    expect { run(schema_for, key: nil) }.to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, /rate_limit_key/)
  end

  describe "when the store fails" do
    before { store.fail_with(IOError.new("connection refused"), on: :acquire) }

    it "lets the operation run and reports the error to the hook" do
      seen = []
      schema = schema_for(on_store_error: ->(error, _query) { seen << error.message })

      expect([run(schema).first, seen]).to eq([{ "data" => { "cheap" => "ok" } }, ["connection refused"]])
    end

    it "raises on an answer that is not [true or false, Integer]" do
      store.recover
      [[0, 1], nil, [true, "1"]].each do |answer|
        store.answer(:acquire, answer)

        expect { run(schema_for) }.to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, /store/)
      end
    end
  end

  describe "what it refuses at boot" do
    def refused(pattern, &block)
      expect(&block).to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, pattern)
    end

    it "refuses a bad limit, stale_after, soft or store" do
      refused(/limit/) { schema_for(limit: 0) }
      refused(/limit/) { schema_for(limit: nil) }
      refused(/stale_after/) { schema_for(stale_after: 0) }
      refused(/stale_after/) { schema_for(stale_after: Float::INFINITY) }
      refused(/soft/) { schema_for(soft: nil) }
      refused(/store/) { schema_for(store: Object.new) }
      refused(/store/) { schema_for(store: Class.new { def acquire(_key, token:, limit:, ttl:, force:) = [true, 1] }.new) }
      refused(/store/) do
        schema_for(store: Class.new { def acquire(token:, limit:, ttl:, force:) = [true, 1]; def release(_key, token:) = nil }.new)
      end
    end
  end
end
