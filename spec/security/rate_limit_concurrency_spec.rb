# frozen_string_literal: true

# `use GraphQL::Armory::RateLimits::Concurrency` lets each client run at most N operations at the same time. A
# client already at its limit is refused before any field resolves; every slot is released when its operation
# ends, even when it raises.
RSpec.describe "use GraphQL::Armory::RateLimits::Concurrency" do
  let(:now) { [0.0] }
  let(:store) { GraphQL::Armory::RateLimits::MemoryStore.new(clock: -> { now[0] }) }
  let(:resolved) { [] }
  let(:root) do
    log = resolved
    Class.new do
      define_method(:cheap) { log << :cheap; "ok" }
      define_method(:broken) { raise IOError, "disk on fire" }
    end.new
  end

  def schema_for(**options)
    query = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :cheap, String, null: false
      field :broken, String, null: false
    end
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
  def occupy(key = "user:1", token: "elsewhere-#{rand}")
    store.acquire(key, token: token, limit: 1_000, ttl: 60, force: true)
    token
  end

  def active(key = "user:1")
    store.acquire(key, token: "probe", limit: 1_000, ttl: 60, force: false).last.tap { store.release(key, token: "probe") } - 1
  end

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
    now[0] = 61.0

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
    let(:broken) do
      Class.new do
        def acquire(_key, token:, limit:, ttl:, force:) = raise(IOError, "connection refused")
        def release(_key, token:) = nil
      end.new
    end

    it "lets the operation run and reports the error to the hook" do
      seen = []
      schema = schema_for(store: broken, on_store_error: ->(error, _query) { seen << error.message })

      expect([run(schema).first, seen]).to eq([{ "data" => { "cheap" => "ok" } }, ["connection refused"]])
    end

    it "raises on an answer that is not [true or false, Integer]" do
      [[0, 1], nil, [true, "1"]].each do |answer|
        store = Class.new do
          define_method(:acquire) { |_key, token:, limit:, ttl:, force:| answer }
          define_method(:release) { |_key, token:| nil }
        end.new

        expect { run(schema_for(store: store)) }.to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, /store/)
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
    end
  end
end
