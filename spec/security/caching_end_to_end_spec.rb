# frozen_string_literal: true

require "spec_helper"

# Response caching through `use`, end to end: each example is a way one request's answer could reach another request
# it does not belong to, or a request the other modules refuse could be served from the store. Outcomes are read from
# responses, `Store::Substitute#calls`, the schema's sink and `context[:response_cache]`, never from mocks.
RSpec.describe "Response caching end to end: what is never stored or served" do
  let(:caching) { GraphQL::Armory::Caching }
  let(:store) { caching::Controls::Store.example }
  let(:recorded) { [] }
  let(:sink) { ->(signal, data) { recorded << [signal, data] } }

  def bases = caching::Controls::AppSchema::Bases.example

  # `Controls::AppSchema` with this file's store, sink and `viewer: :current_user`, `caching:` merged over them.
  def build(documents, caching: {}, **options, &fields)
    settings = { store: store, release: "r1", viewer: :current_user, sinks: [sink] }.merge(caching)
    self.caching::Controls::AppSchema.example(documents, caching: settings, **options, &fields)
  end

  def viewer(id = 7, admin: false) = caching::Controls::Viewer.example(id: id, admin: admin)

  def run(schema, operation, query: nil, viewer: self.viewer, **options)
    context = { operation_id: operation, current_user: viewer }.compact.merge(options.delete(:context) || {})
    execute_query(schema, query, context: context, **options)
  end

  def multiplex(schema, queries)
    ArmoryEngine.next? ? schema.multiplex_next(queries) : schema.multiplex(queries)
  end

  def record(result) = result.context[:response_cache]
  def signals(name) = recorded.select { |signal, _| signal == name }.map(&:last)
  def lookups = store.calls.count { |operation, *| operation == :lookup }
  def writes = store.calls.count { |operation, *| operation == :write }

  # A field `name` resolved by `block` on the type instance, on both engines.
  def self.resolved(name, &block)
    proc do |options|
      field name, String, null: true, **options
      define_method(name, &block)
    end
  end

  describe "a context key the cache key does not hold" do
    it "is not stored when a resolver reads it (:context_read, naming the key), and the next request runs again" do
      schema = build({ "op" => "query Op { greeting }" }, &self.class.resolved(:greeting) { "hello #{context[:locale]}" })
      first = run(schema, "op", context: { locale: "en" })
      second = run(schema, "op", context: { locale: "fr" })

      expect(second["data"]).to eq("greeting" => "hello fr")
      expect(record(first)).to include(status: :skipped, reason: :context_read)
      expect(signals(:cache_skipped)).to include({ reason: :context_read, key: :locale })
      expect([writes, signals(:cache_hit)]).to eq([0, []])
    end

    it "is not stored when it is absent: reading a key the request did not send is still an input" do
      schema = build({ "op" => "query Op { greeting }" }, &self.class.resolved(:greeting) { context[:flags] ? "beta" : "stable" })
      result = run(schema, "op")

      expect(result["data"]).to eq("greeting" => "stable")
      expect(signals(:cache_skipped)).to eq([{ reason: :context_read, key: :flags }])
      expect(writes).to eq(0)
    end

    { "context.to_h" => ->(context) { context.to_h.size.to_s },
      "context.namespace(nil)" => ->(context) { context.namespace(nil).class.name },
      "context.scoped_context" => ->(context) { context.scoped_context.merged_context.size.to_s } }.each do |reader, read|
      it "is not stored when a resolver reads the whole context with #{reader}" do
        schema = build({ "op" => "query Op { greeting }" }, &self.class.resolved(:greeting) { read.(context) })
        result = run(schema, "op")

        expect(result["errors"]).to be_nil
        expect(record(result)).to include(status: :skipped, reason: :context_read)
        expect(writes).to eq(0)
      end
    end

    it "is not stored when an app visible? reads it while the query is validated, before any resolver runs" do
      schema = build({ "op" => "query Op { greeting }" }) do |options|
        field :greeting, String, null: true, **options do
          define_singleton_method(:visible?) { |context| super(context) && !context[:beta] }
        end
        define_method(:greeting) { "hello" }
      end
      result = run(schema, "op")

      expect(result["data"]).to eq("greeting" => "hello")
      expect(signals(:cache_skipped)).to eq([{ reason: :context_read, key: :beta }])
      expect(writes).to eq(0)
    end

    it "is not stored when a scalar reads it while coercing a variable" do
      tenant_name = Class.new(GraphQL::Schema::Scalar) do
        graphql_name "TenantName"
        define_singleton_method(:coerce_input) { |value, context| "#{context[:tenant]}/#{value}" }
        define_singleton_method(:coerce_result) { |value, _context| value }
      end
      schema = build({ "op" => "query Op($name: TenantName!) { echo(name: $name) }" }) do |options|
        field :echo, String, null: true, **options do
          argument :name, tenant_name
        end
        define_method(:echo) { |name:| name }
      end
      result = run(schema, "op", variables: { "name" => "lamp" }, context: { tenant: "acme" })

      expect(result["data"]).to eq("echo" => "acme/lamp")
      expect(signals(:cache_skipped)).to eq([{ reason: :context_read, key: :tenant }])
      expect(writes).to eq(0)
    end

    it "is held by a vary: callable only for the input the callable reads: a resolver reading the context instead is not stored" do
      schema = build({ "op" => "query Op { greeting }" }, caching: { vary: { locale: -> { Thread.current[:armory_e2e_locale] } } },
                     &self.class.resolved(:greeting) { "hello #{context[:locale]}" })
      result = run(schema, "op", context: { locale: "en" })

      expect(signals(:cache_skipped)).to eq([{ reason: :context_read, key: :locale }])
      expect([result["data"], writes]).to eq([{ "greeting" => "hello en" }, 0])
    end
  end

  describe "a context key written during the run" do
    it "is not stored when a resolver writes a key the cache key covers (:context_written)" do
      schema = build({ "op" => "query Op { greeting }" }, caching: { vary: { locale: :locale } }) do |options|
        field :greeting, String, null: true, **options
        define_method(:greeting) do
          context[:locale] = "fr"
          "hello"
        end
      end
      result = run(schema, "op", context: { locale: "en" })

      expect(result["data"]).to eq("greeting" => "hello")
      expect(signals(:cache_skipped)).to eq([{ reason: :context_written, key: :locale }])
      expect(writes).to eq(0)
    end

    it "stores neither query of a multiplex sharing one context Hash when one writes a key the other read" do
      document = "query Reader { greeting } query Writer { relabel }"
      schema = build({ "both" => document }, caching: { vary: { locale: :locale } }) do |options|
        field :greeting, String, null: true, **options
        field :relabel, String, null: true, **options
        define_method(:greeting) { "hello #{context[:locale]}" }
        define_method(:relabel) do
          context[:locale] = "fr"
          "done"
        end
      end
      shared = { operation_id: "both", current_user: viewer, locale: "en" }
      results = multiplex(schema, [{ context: shared, operation_name: "Reader" }, { context: shared, operation_name: "Writer" }])

      expect(results.map { |result| result["errors"] }).to eq([nil, nil])
      expect(results.map { |result| record(result)&.slice(:status, :reason) }).to all(eq(status: :skipped, reason: :context_written))
      expect(writes).to eq(0)
    end
  end

  describe "the actor an adapter reads" do
    it "is not stored when Pundit reads current_user and the viewer key is current_account" do
      world = Dummy::World.build
      invoice = Class.new(bases[:object]) do
        graphql_name "Invoice"
        authorize :read, model: Invoice
        cache_fields ttl: 30
        field :number, String, null: false
      end
      schema = build({ "op" => "query Op { invoice { number } }" }, adapter: :pundit, caching: { viewer: :current_account }) do |options|
        field :invoice, invoice, null: true, cache: { ttl: 30, scope: :viewer }, **options
        define_method(:invoice) { Invoice.find_by!(number: "A-1") }
      end
      result = run(schema, "op", viewer: world.alice, context: { current_account: world.account_a })

      expect(result["data"]).to eq("invoice" => { "number" => "A-1" })
      expect(signals(:cache_skipped)).to eq([{ reason: :context_read, key: :current_user }])
      expect(writes).to eq(0)
    end

    it "is never looked up when CanCan's current_ability is in the context" do
      schema = build({ "op" => "query Op { greeting }" }, &self.class.resolved(:greeting) { "hello" })
      result = run(schema, "op", context: { current_ability: Object.new })

      expect(result["data"]).to eq("greeting" => "hello")
      expect(record(result)).to include(status: :skipped, reason: :current_ability)
      expect(store.calls).to eq([])
    end
  end

  describe "the viewer" do
    let(:schema) { caching::Controls::Schema.example(caching: { store: store, release: "r1", viewer: :current_user, sinks: [sink] }) }

    it "raises when viewer_id: answers nil, and serves nothing" do
      schema = caching::Controls::Schema.example(caching: { store: store, release: "r1", viewer: :current_user, viewer_id: ->(_user) {} })

      expect { run(schema, "invoices") }.to raise_error(caching::ConfigurationError)
      expect(store.calls).to eq([])
    end

    it "never shares a :viewer entry between User 7 and AdminUser 7" do
      run(schema, "invoices", viewer: viewer(7))
      other = run(schema, "invoices", viewer: viewer(7, admin: true))

      expect(record(other)).to include(status: :stored)
      expect(signals(:cache_hit)).to eq([])
      expect(writes).to eq(2)
    end

    it "never looks up an anonymous request under anonymous: :uncacheable" do
      result = run(schema, "invoices", viewer: nil)

      expect(result["data"]["invoices"]).not_to be_empty
      expect(record(result)).to include(status: :skipped, reason: :anonymous)
      expect(store.calls).to eq([])
    end

    it "shares one entry between anonymous requests under anonymous: :shared, apart from every principal" do
      shared = caching::Controls::Schema.example(caching: { store: store, release: "r1", viewer: :current_user, anonymous: :shared,
                                                            anonymous_reason: "the same for every anonymous visitor", sinks: [sink] })
      run(shared, "invoices", viewer: nil)
      second = run(shared, "invoices", viewer: nil)
      principal = run(shared, "invoices", viewer: viewer(7))

      expect([record(second)[:status], record(principal)[:status]]).to eq(%i[hit stored])
      expect(writes).to eq(2)
    end
  end

  describe "PersistedQueries decides first" do
    let(:schema) { caching::Controls::Schema.example(caching: { store: store, release: "r1", viewer: :current_user, sinks: [sink] }) }

    before { run(schema, "names") }

    it "refuses, and never serves, a raw query holding the document of a cached operation" do
      result = run(schema, nil, query: caching::Controls::Operations.document("names"))

      expect(result["data"]).to be_nil
      expect(result["errors"]).not_to be_empty
      expect(lookups).to eq(1)
    end

    it "never looks up a raw query allowed with armory_allow_raw_query, even with the text of a cached operation" do
      raw = run(schema, nil, query: caching::Controls::Operations.document("names"), context: { armory_allow_raw_query: true })

      expect(raw["data"]["products"]).not_to be_empty
      expect(record(raw)).to include(status: :skipped, reason: :not_persisted)
      expect(lookups).to eq(1)
    end

    it "never looks up a raw query allowed with armory_allow_raw_query beside a cached operation's id" do
      raw = run(schema, "names", query: "query Names { products { name stockLevel } }", context: { armory_allow_raw_query: true })

      expect(raw["data"]).to be_nil
      expect(lookups).to eq(1)
    end

    it "refuses an unknown id and never looks it up" do
      result = run(schema, "unknown")

      expect(result["errors"]).not_to be_empty
      expect(lookups).to eq(1)
    end
  end

  it "keys a variable the operation does not declare as if it were not sent" do
    schema = caching::Controls::Schema.example(caching: { store: store, release: "r1", sinks: [sink] })
    run(schema, "product", variables: { "name" => "Lamp" })
    flooded = run(schema, "product", variables: { "name" => "Lamp", "extra" => "x" * 64 })

    expect(record(flooded)).to include(status: :hit)
    expect(writes).to eq(1)
  end

  describe "Versioning decides first" do
    def versioned
      build({ "op" => "query Op { greeting }" }, before: proc {
        use GraphQL::Armory::Versioning, versions: %w[2024-01-15 2024-06-01 2025-01-01], retired: %w[2024-01-15], default: :latest
      }, &self.class.resolved(:greeting) { "hello" })
    end

    it "keys the same document apart on two versions" do
      schema = versioned
      run(schema, "op", context: { armory_version: "2024-06-01" })
      other = run(schema, "op", context: { armory_version: "2025-01-01" })

      expect(record(other)).to include(status: :stored)
      expect([signals(:cache_hit), writes]).to eq([[], 2])
    end

    it "never looks up a retired version" do
      result = run(versioned, "op", context: { armory_version: "2024-01-15" })

      expect(result["errors"]).not_to be_empty
      expect(lookups).to eq(0)
    end

    it "never looks up a request for the full schema (armory_full_schema)" do
      result = run(versioned, "op", context: { armory_full_schema: true })

      expect(record(result)).to include(status: :skipped, reason: :full_schema)
      expect(store.calls).to eq([])
    end
  end

  it "does not serve a request with a stricter max_complexity the entry a looser one stored" do
    schema = caching::Controls::Schema.example(caching: { store: store, release: "r1", sinks: [sink] })
    # Through multiplex: execute_next takes no max_complexity:, a query of a multiplex does on both engines.
    loose, strict = [100, 1].map do |limit|
      multiplex(schema, [{ context: caching::Controls::Context.example(operation: "names"), max_complexity: limit }]).first
    end

    expect(record(loose)).to include(status: :stored)

    expect(strict["data"]).to be_nil
    expect(strict["errors"].first["message"]).to include("complexity")
    expect(signals(:cache_hit)).to eq([])
  end

  describe "requests that are never looked up nor stored" do
    let(:schema) { caching::Controls::Schema.example(caching: { store: store, release: "r1", viewer: :current_user, sinks: [sink] }) }

    before { run(schema, "names") }

    # validate: false and root_value: leave the query unmarked by the guard (:built_query): only an unmarked query may
    # carry them, and an unmarked query is never answered from the store.
    { "a mutation" => [{}, :mutation, "touch"],
      "validate: false" => [{ validate: false }, :built_query, "names"],
      "root_value:" => [{ root_value: Object.new }, :built_query, "names"],
      "an operation_name the document does not hold" => [{ operation_name: "Missing" }, nil, "names"] }.each do |name, (options, reason, operation)|
      it "#{name}#{" (#{reason.inspect})" if reason}" do
        recorded.clear
        result = run(schema, operation, **options)

        expect(record(result)&.dig(:status)).not_to eq(:hit)
        expect(signals(:cache_skipped).map { |data| data[:reason] }).to eq([reason]) if reason
        expect([lookups, writes, signals(:cache_hit)]).to eq([1, 1, []])
      end
    end

    it "every query of a multiplex holding a mutation" do
      results = multiplex(schema, [{ context: caching::Controls::Context.example(operation: "names") },
                                   { context: caching::Controls::Context.example(operation: "touch") }])

      expect(results.map { |result| record(result)[:reason] }).to eq(%i[multiplex_mutation mutation])
      expect([lookups, writes]).to eq([1, 1])
    end
  end

  describe "an answer that is not the whole truth" do
    it "is not stored with errors" do
      schema = build({ "op" => "query Op { greeting }" }, &self.class.resolved(:greeting) { raise GraphQL::ExecutionError, "nope" })
      result = run(schema, "op")

      expect(result["errors"]).not_to be_empty
      expect([record(result)[:reason], writes]).to eq([:errors, 0])
    end

    it "is not stored when a rescue_from handler answered" do
      schema = build({ "op" => "query Op { greeting }" }, after: proc { rescue_from(ArgumentError) { |_error, *_rest| nil } },
                     &self.class.resolved(:greeting) { raise ArgumentError, "boom" })
      result = run(schema, "op")

      expect(result["data"]).to eq("greeting" => nil)
      expect([record(result)[:reason], writes]).to eq([:rescued, 0])
    end

    it "is not stored when a resolver adds a response extension" do
      schema = build({ "op" => "query Op { greeting }" }) do |options|
        field :greeting, String, null: true, **options
        define_method(:greeting) do
          context.response_extensions["trace"] = "abc"
          "hello"
        end
      end
      result = run(schema, "op")

      expect(result["extensions"]).to eq("trace" => "abc")
      expect([record(result)[:reason], writes]).to eq([:extensions, 0])
    end

    it "is not stored when a resolver returns a raw value the store cannot hold as JSON" do
      schema = build({ "op" => "query Op { greeting }" }, &self.class.resolved(:greeting) { raw_value(:lamp) })
      result = run(schema, "op")

      expect([record(result)[:reason], writes]).to eq([:non_json_data, 0])
    end

    it "is stored for the viewer a policy denied in :null mode, and served to that viewer only" do
      denied = GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: false)
      schema = build({ "op" => "query Op { secret }" }, adapter: denied) do |options|
        field :secret, String, null: true, authorize: :manage, cache: { ttl: 30, scope: :viewer }, **options
        define_method(:secret) { "secret" }
      end
      run(schema, "op")
      again = run(schema, "op")
      other = run(schema, "op", viewer: viewer(8))

      expect(again["data"]).to eq("secret" => nil)
      expect([record(again)[:status], record(other)[:status]]).to eq(%i[hit stored])
    end
  end

  describe "a purge" do
    it "made during the run refuses the run's write" do
      holder = {}
      schema = build({ "op" => "query Op { greeting }" }) do |options|
        field :greeting, String, null: true, **options
        define_method(:greeting) do
          GraphQL::Armory::Caching.purge(holder[:schema], all: true)
          "hello"
        end
      end
      holder[:schema] = schema
      result = run(schema, "op")
      again = run(schema, "op")

      expect(record(result)).to include(status: :skipped, reason: :write_refused)
      expect(record(again)).not_to include(status: :hit)
    end

    it "of the whole store, by losing its meta record, makes every older entry a miss" do
      schema = caching::Controls::Schema.example(caching: { store: store, release: "r1", sinks: [sink] })
      run(schema, "names")
      store.reset!
      again = run(schema, "names")

      expect(record(again)).to include(status: :stored)
      expect(signals(:cache_entry_rejected)).to eq([{ reason: :epoch }])
    end

    it "is not undone by a run that ends more than max_ttl after its lookup" do
      clock = store
      schema = build({ "op" => "query Op { greeting }" }, caching: { max_ttl: 60 }) do |options|
        field :greeting, String, null: true, **options
        define_method(:greeting) do
          clock.now += 61_000
          "hello"
        end
      end
      result = run(schema, "op")

      expect([record(result)[:reason], writes]).to eq([:run_too_long, 0])
    end
  end

  it "rejects an entry moved under another viewer's key, and runs the query for that viewer" do
    schema = caching::Controls::Schema.example(caching: { store: store, release: "r1", viewer: :current_user, sinks: [sink] })
    run(schema, "invoices", viewer: viewer(7))
    seven = store.blobs.values.first
    run(schema, "invoices", viewer: viewer(8))
    eight = (store.blobs.keys - [store.blobs.key(seven)]).first
    store.poison(eight, seven)
    moved = run(schema, "invoices", viewer: viewer(8))

    expect(record(moved)).to include(status: :stored)
    expect(signals(:cache_entry_rejected)).to eq([{ reason: :key }])
  end

  describe "a store that fails" do
    let(:errors) { [] }
    let(:schema) do
      caching::Controls::Schema.example(caching: { store: store, release: "r1", sinks: [sink], on_store_error: ->(error, _query) { errors << error.class } })
    end

    it "on lookup runs the query, reports it and calls on_store_error" do
      store.fail_with(IOError, on: :lookup)
      result = run(schema, "names")

      expect(result["data"]["products"]).not_to be_empty
      expect(signals(:cache_store_failed)).to eq([{ operation: :lookup, error: "IOError" }])
      expect(errors).to eq([IOError])
    end

    it "on write keeps the query's answer, reports it and calls on_store_error" do
      store.fail_with(IOError, on: :write)
      result = run(schema, "names")

      expect(result["data"]["products"]).not_to be_empty
      expect(signals(:cache_store_failed)).to eq([{ operation: :write, error: "IOError" }])
      expect(errors).to eq([IOError])
    end
  end

  describe "rate limiting" do
    let(:limits) { GraphQL::Armory::RateLimits }
    let(:points_store) { limits::MemoryStore.new }

    def limited(limit: 100, extensions: false)
      bucket = points_store
      caching::Controls::Schema.example(caching: { store: store, release: "r1", sinks: [sink] }).tap do |schema|
        schema.use(limits::Points, store: bucket, limit: limit, window: 60, soft: false, extensions: extensions,
                                   key: ->(query) { "user:#{query.context[:current_user].id}" })
      end
    end

    it "charges a hit the cost its run recorded" do
      schema = limited
      miss = run(schema, "catalog")
      hit = run(schema, "catalog")

      expect(record(hit)).to include(status: :hit)
      expect(hit.context[:rate_limit_points][:cost]).to eq(miss.context[:rate_limit_points][:cost])
      expect(hit.context[:rate_limit_points][:remaining]).to eq(100 - (2 * miss.context[:rate_limit_points][:cost]))
    end

    it "refuses a hit with RATE_LIMITED, and nothing from the cache, for a client over budget" do
      schema = limited(limit: 10)
      cost = run(schema, "catalog").context[:rate_limit_points][:cost]
      (10 / cost).times { run(schema, "catalog") }
      refused = run(schema, "catalog")

      expect(refused["data"]).to be_nil
      expect(refused["errors"].first.dig("extensions", "code")).to eq("RATE_LIMITED")
    end

    it "stores each query of a multiplex with its own cost, even when they share one context Hash, and charges a hit that cost" do
      bucket = points_store
      document = "query Cheap { greeting } query Dear { greeting other: greeting third: greeting }"
      schema = build({ "both" => document }, before: proc {
        use GraphQL::Armory::RateLimits::Points, store: bucket, limit: 100, soft: false, key: ->(_query) { "user:7" }
      }, &self.class.resolved(:greeting) { "hello" })
      shared = { operation_id: "both", current_user: viewer }
      ran = multiplex(schema, [{ context: shared, operation_name: "Cheap" }, { context: shared, operation_name: "Dear" }])
      hits = %w[Cheap Dear].map { |name| multiplex(schema, [{ context: { operation_id: "both", current_user: viewer }, operation_name: name }]).first }

      expect(ran.map { |result| record(result)[:status] }).to eq(%i[stored stored])
      expect(hits.map { |result| record(result)[:status] }).to eq(%i[hit hit])
      expect(hits.map { |result| result.context[:rate_limit_points][:cost] }).to eq([1, 3])
    end

    it "is not stored when a resolver reads the key the limiter reads neutrally" do
      bucket = points_store
      schema = build({ "op" => "query Op { greeting }" }, before: proc {
        use GraphQL::Armory::RateLimits::Points, store: bucket, limit: 100, soft: false, key: ->(query) { "user:#{query.context[:current_user].id}" }
      }, &self.class.resolved(:greeting) { "hello #{context[:current_user].id}" })
      result = run(schema, "op")

      expect(result["data"]).to eq("greeting" => "hello 7")
      expect(signals(:cache_skipped)).to eq([{ reason: :context_read, key: :current_user }])
    end

    it "never shows A's rateLimit extension in B's hit" do
      schema = limited(extensions: true)
      first = run(schema, "catalog", viewer: viewer(7))
      run(schema, "catalog", viewer: viewer(7))
      other = run(schema, "catalog", viewer: viewer(8))

      expect(record(other)).to include(status: :hit)
      expect(other["extensions"]["rateLimit"]).to eq(first["extensions"]["rateLimit"])
      expect(other.context[:rate_limit_points][:key]).to eq("user:8")
    end
  end

  it "never puts a variable, an operation id, a viewer, a tag or a document in a signal" do
    schema = caching::Controls::Schema.example(caching: { store: store, release: "r1", viewer: :current_user, sinks: [sink] })
    run(schema, "product", variables: { "name" => "Lamp" }, viewer: viewer(4242))
    run(schema, "product", variables: { "name" => "Lamp" }, viewer: viewer(4242))
    run(schema, "invoices", viewer: viewer(4242))
    run(schema, "stock", viewer: viewer(4242))
    caching.purge(schema, tag: "pricing")
    caching.purge(schema, viewer: viewer(4242))
    seen = recorded.select { |signal, _| signal.to_s.start_with?("cache_") }.map { |_, data| data.except(:context).inspect }.join(" ")

    expect(recorded.map(&:first)).to include(:cache_stored, :cache_hit, :cache_skipped, :cache_purged)
    %w[Lamp 4242 product invoices stock pricing Product query].each { |secret| expect(seen).not_to include(secret) }
  end

  describe "with a RedisStore" do
    let(:redis) { Redis.new(url: ENV.fetch("REDIS_URL")) }
    let(:prefix) { "graphql-armory-test:cache-e2e:#{SecureRandom.hex(8)}:" }

    before do
      require "redis"
      require "securerandom"
      skip "REDIS_URL is not set (docker compose and CI set it)" if ENV["REDIS_URL"].to_s.empty? && ENV["CI"].to_s.empty?
    end

    after do
      keys = ENV["REDIS_URL"].to_s.empty? ? [] : redis.keys("#{prefix}*")
      redis.del(*keys) unless keys.empty?
    end

    # Values chosen so a base64url or hex string cannot hold them by chance.
    it "keeps no viewer id, tag, variable or operation name in clear in the keyspace or the values" do
      encoder = Class.new(GraphQL::Armory::Encoder) { key("k" * 32) }
      redis_store = caching::RedisStore.build(redis: redis, prefix: prefix, max_ttl: 3600)
      schema = caching::Controls::Schema.example(caching: { store: redis_store, encoder: encoder, release: "r1", viewer: :current_user, sinks: [sink] })
      principal = caching::Controls::Viewer.example(id: "viewer-zq")
      run(schema, "product", variables: { "name" => "Zephyr-Quokka" }, viewer: principal)
      run(schema, "invoices", viewer: principal)
      run(schema, "catalog", viewer: principal)
      caching.purge(schema, tag: "pricing")
      caching.purge(schema, viewer: principal)

      keys = redis.keys("#{prefix}*")
      values = keys.flat_map { |key| redis.type(key) == "hash" ? redis.hgetall(key).to_a.flatten : [redis.get(key)] }
      everything = (keys.map { |key| key.delete_prefix(prefix) } + values).join(" ")

      expect(signals(:cache_stored).size).to eq(3)
      %w[viewer-zq Zephyr Quokka pricing catalog Product Invoices Catalog].each { |secret| expect(everything).not_to include(secret) }
    end
  end
end
