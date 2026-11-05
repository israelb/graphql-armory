# frozen_string_literal: true

# Independent verifier probes for module 7, Response caching (PR #77), kept as regressions. Probes of documented
# limits are pending with the limit they pin: they fail today, and RSpec reports them the day they pass. One probe
# per `it`, each labelled
# "security" (the feature must change its outcome) or "preservation" (existing behaviour must hold).
require "spec_helper"
require "securerandom"

module VerifierCachingProbes
  C = GraphQL::Armory::Caching
  LEGACY = C::Controls::Schema::NEXT_FIELD_OPTIONS
  User = C::Controls::Viewer::User
  AdminUser = C::Controls::Viewer::AdminUser
  Enc = Class.new(GraphQL::Armory::Encoder) { key("v" * 32) }
  Boom = Class.new(StandardError)

  BaseField = Class.new(GraphQL::Schema::Field) { include GraphQL::Armory::Caching::Base }
  BaseObject = Class.new(GraphQL::Schema::Object) do
    include GraphQL::Armory::Caching::Base
    field_class BaseField
  end

  # A query type whose fields resolve with the given lambdas: { name => [type, ->(object, context) { ... }] }.
  def self.query_type(scope: :public, ttl: 300, tags: [], fields: {}, &extra)
    reason = scope == :public ? { reason: "probe" } : {}
    Class.new(BaseObject) do
      graphql_name "Query"
      cache_fields ttl: ttl, scope: scope, tags: tags, **reason
      fields.each do |name, (type, body)|
        field name, type, null: true, **LEGACY
        define_method(name) { body.call(object, context) }
      end
      class_exec(&extra) if extra
    end
  end

  def self.schema(query_type, ops, caching: {}, name: nil, next_default: false, &extra)
    manifest = GraphQL::Armory::PersistedQueries::Manifest.new(ops, digest: false)
    options = { store: C::MemoryStore.new, release: "probe" }.merge(caching)
    klass = Class.new(GraphQL::Schema) do
      use GraphQL::Execution::Next, **(next_default ? { as_default: true } : {}) if defined?(GraphQL::Execution::Next)
      query(query_type)
      use GraphQL::Armory::PersistedQueries, store: manifest, strict: true
      class_exec(&extra) if extra
      use GraphQL::Armory::Caching, **options
    end
    klass.define_singleton_method(:name) { name } if name
    klass
  end
end

RSpec.describe "Verifier probes: response caching (PR #77)" do
  vcp = VerifierCachingProbes
  c = GraphQL::Armory::Caching

  def run(schema, op, **context)
    execute_query(schema, nil, context: { operation_id: op }.merge(context))
  end

  def status(result) = result.context[:response_cache]&.fetch(:status, nil)
  def reason(result) = result.context[:response_cache]&.fetch(:reason, nil)

  # Runs `op` for A then B and answers B's data. A stores (when the cache lets it), B must get its own answer.
  def a_then_b(schema, op, a, b)
    first = run(schema, op, **a)
    run(schema, op, **a) # a second A request, so a stored entry is certainly there
    [first, run(schema, op, **b)]
  end

  # ---------------------------------------------------------------------------------------------- 1. engine key
  describe "1. WRITTEN_BY_ENGINE and machinery-key exemptions" do
    it "security: a neutral writer cannot carry a viewer's id into a :public answer through :__graphql_execute_next" do
      qt = vcp.query_type(fields: {
        stamp: [String, ->(_o, ctx) { c.neutral(ctx) { ctx[:__graphql_execute_next] = "viewer-#{ctx[:current_user]&.id}" }; "ok" }],
        echo: [String, ->(_o, ctx) { ctx[:__graphql_execute_next].to_s }]
      })
      schema = vcp.schema(qt, { "q" => "query Q { stamp echo }" })
      _, b = a_then_b(schema, "q", { current_user: vcp::User.new(7) }, { current_user: vcp::User.new(8) })
      expect(b["data"]["echo"]).not_to eq("viewer-7")
    end

    it "security: two requests that differ only in context[:visibility_profile] (no named profiles) never share an answer" do
      pending "documented limit: graphql-ruby's own context keys are covered whatever the app stores under them"
      qt = vcp.query_type(fields: { mode: [String, ->(_o, ctx) { ctx[:visibility_profile].to_s }] })
      schema = vcp.schema(qt, { "q" => "query Q { mode }" })
      _, b = a_then_b(schema, "q", { visibility_profile: :alpha }, { visibility_profile: :beta })
      expect(b["data"]["mode"]).to eq("beta")
    end

    it "security: two requests that differ only in an app value under a runtime-metadata key (:current_field) never share an answer" do
      pending "documented limit: graphql-ruby's own context keys are covered whatever the app stores under them"
      qt = vcp.query_type(fields: { mode: [String, ->(_o, ctx) { ctx[:current_field].to_s }] })
      schema = vcp.schema(qt, { "q" => "query Q { mode }" })
      _, b = a_then_b(schema, "q", { current_field: "alpha" }, { current_field: "beta" })
      expect(b["data"]["mode"]).to eq("beta")
    end

    it "preservation: queries of one multiplex sharing a context Hash, with no writes of their own, are stored" do
      qt = vcp.query_type(fields: { a: [String, ->(*) { "a" }], b: [String, ->(*) { "b" }] })
      schema = vcp.schema(qt, { "qa" => "query QA { a }" })
      # One Hash for both queries (PersistedQueries reads operation_id from it, so both run the same operation).
      one = { operation_id: "qa" }
      method_name = ArmoryEngine.next? ? :multiplex_next : :multiplex
      results = schema.public_send(method_name, [{ query: nil, context: one }, { query: nil, context: one }])
      expect(results.map { |result| status(result) }).to eq(%i[stored stored])
    end
  end

  # ---------------------------------------------------------------------------------------------- 2. entry sharing
  describe "2. Entry copy: false" do
    let(:qt) { vcp.query_type(fields: { names: [[String], ->(*) { %w[Lamp Desk] }] }) }

    it "security: mutating one hit's data never changes what the next hit answers" do
      schema = vcp.schema(qt, { "q" => "query Q { names }" })
      run(schema, "q")
      hit1 = run(schema, "q")
      expect(status(hit1)).to eq(:hit)
      begin
        hit1["data"]["names"] << "INJECTED"
        hit1["data"]["extra"] = "INJECTED"
      rescue FrozenError
        nil
      end
      hit2 = run(schema, "q")
      expect(hit2["data"]).to eq("names" => %w[Lamp Desk])
    end

    it "security: the app's later mutation of a stored miss's data never reaches the store" do
      schema = vcp.schema(qt, { "q" => "query Q { names }" })
      miss = run(schema, "q")
      expect(status(miss)).to eq(:stored)
      miss["data"]["names"] << "INJECTED"
      expect(run(schema, "q")["data"]).to eq("names" => %w[Lamp Desk])
    end

    it "preservation: a hit's data can be changed like a run's answer" do
      schema = vcp.schema(qt, { "q" => "query Q { names }" })
      run(schema, "q")
      hit = run(schema, "q")
      expect { hit["data"]["names"] << "x" }.not_to raise_error
    end
  end

  # ---------------------------------------------------------------------------------------------- 3. context_methods
  describe "3. context_methods: enforcement" do
    tenant_type = lambda do |reader|
      vcp.query_type(fields: { tenant: [String, reader] })
    end

    it "security: a method prepended to GraphQL::Query::Context that reads @provided_values does not let one tenant's answer reach another" do
      mod = Module.new { def vcp_tenant_prepended = @provided_values[:tenant] }
      GraphQL::Query::Context.prepend(mod) unless GraphQL::Query::Context.include?(mod)
      schema = vcp.schema(tenant_type.(->(_o, ctx) { ctx.vcp_tenant_prepended }), { "q" => "query Q { tenant }" })
      _, b = a_then_b(schema, "q", { tenant: "acme" }, { tenant: "globex" })
      expect(b["data"]["tenant"]).to eq("globex")
    ensure
      # A module cannot be unprepended: emptying it leaves the class as it was for the rest of the suite.
      mod.send(:remove_method, :vcp_tenant_prepended)
    end

    it "security: a method defined by reopening GraphQL::Query::Context does not let one tenant's answer reach another" do
      GraphQL::Query::Context.class_eval { def vcp_tenant_reopened = @provided_values[:tenant] }
      schema = vcp.schema(tenant_type.(->(_o, ctx) { ctx.vcp_tenant_reopened }), { "q" => "query Q { tenant }" })
      _, b = a_then_b(schema, "q", { tenant: "acme" }, { tenant: "globex" })
      expect(b["data"]["tenant"]).to eq("globex")
    ensure
      GraphQL::Query::Context.send(:remove_method, :vcp_tenant_reopened)
    end

    it "security: the audit does not say ok while a method on GraphQL::Query::Context leaks tenants (matrix invariant)" do
      GraphQL::Query::Context.class_eval { def vcp_tenant_audit = @provided_values[:tenant] }
      schema = vcp.schema(tenant_type.(->(_o, ctx) { ctx.vcp_tenant_audit }), { "q" => "query Q { tenant }" })
      _, b = a_then_b(schema, "q", { tenant: "acme" }, { tenant: "globex" })
      leaked = b["data"]["tenant"] == "acme"
      report = GraphQL::Armory::Caching::Audit.(schema)
      expect(leaked && report.ok?).to be(false)
      expect(report.ok?).to be(false)
    ensure
      GraphQL::Query::Context.send(:remove_method, :vcp_tenant_audit)
    end

    it "security: a public method added to the app's context class after its first query is still refused (:context_method)" do
      app_context = Class.new(GraphQL::Query::Context)
      reader = ->(_o, ctx) { ctx.respond_to?(:vcp_late) ? ctx.vcp_late : "none" }
      qt = vcp.query_type(fields: { tenant: [String, reader], names: [[String], ->(*) { %w[Lamp] }] })
      schema = vcp.schema(qt, { "q" => "query Q { tenant }", "w" => "query W { names }" }) { context_class(app_context) }
      run(schema, "w") # another operation: the class's methods are memoized here, nothing is stored for "q"
      app_context.define_method(:vcp_late) { @provided_values[:tenant] }
      _, b = a_then_b(schema, "q", { tenant: "acme" }, { tenant: "globex" })
      expect(b["data"]["tenant"]).to eq("globex")
    end

    it "security: a private context-class method a resolver calls with send does not let one tenant's answer reach another" do
      pending "documented limit: only public context methods are counted; a private one called with send is not"
      app_context = Class.new(GraphQL::Query::Context) do
        private

        def vcp_private = @provided_values[:tenant]
      end
      schema = vcp.schema(tenant_type.(->(_o, ctx) { ctx.send(:vcp_private) }), { "q" => "query Q { tenant }" }) { context_class(app_context) }
      _, b = a_then_b(schema, "q", { tenant: "acme" }, { tenant: "globex" })
      expect(b["data"]["tenant"]).to eq("globex")
    end

    it "preservation: a context class with method_missing runs uncached (:context_method)" do
      app_context = Class.new(GraphQL::Query::Context) do
        def method_missing(name, *args) = name == :tenant ? @provided_values[:tenant] : super
        def respond_to_missing?(name, include_private = false) = name == :tenant || super
      end
      schema = vcp.schema(tenant_type.(->(_o, ctx) { ctx.tenant }), { "q" => "query Q { tenant }" }) { context_class(app_context) }
      result = run(schema, "q", tenant: "acme")
      expect([status(result), reason(result)]).to eq(%i[skipped context_method])
    end
  end

  # ---------------------------------------------------------------------------------------------- 4. Points
  describe "4. Points on hits" do
    it "security: a child schema with its own Points limiter never gets a free hit from what its parent stored" do
      qt = vcp.query_type(fields: { names: [[String], ->(*) { %w[Lamp] }] })
      parent = vcp.schema(qt, { "q" => "query Q { names }" }, name: "VcpPointsParent")
      store = GraphQL::Armory::RateLimits::MemoryStore.new
      child = Class.new(parent) { use GraphQL::Armory::RateLimits::Points, store: store, limit: 100, soft: false }
      child.define_singleton_method(:name) { "VcpPointsChild" }
      run(parent, "q", rate_limit_key: "client")
      run(parent, "q", rate_limit_key: "client")
      results = Array.new(3) { run(child, "q", rate_limit_key: "client") }
      remaining = results.map { |result| result.context[:rate_limit_points]&.fetch(:remaining, nil) }
      expect(remaining.compact.size).to eq(3)
      expect(remaining).to eq(remaining.sort.reverse)
      expect(remaining.uniq.size).to eq(3)
    end
  end

  # ---------------------------------------------------------------------------------------------- 5. stores
  describe "5. max_ttl and purge marks" do
    it "preservation: a store without max_ttl wrapping a MemoryStore with a shorter one fails open to computing" do
      inner = c::MemoryStore.new(max_ttl: 60)
      wrapper = Class.new do
        define_method(:initialize) { |store| @store = store }
        %i[lookup write purge purge_all].each { |name| define_method(name) { |*args, **kw| @store.public_send(name, *args, **kw) } }
      end
      qt = vcp.query_type(fields: { names: [[String], ->(*) { %w[Lamp] }] })
      schema = vcp.schema(qt, { "q" => "query Q { names }" }, caching: { store: wrapper.new(inner), on_store_error: ->(*) {} })
      result = run(schema, "q")
      expect(result["data"]).to eq("names" => %w[Lamp])
      expect(status(result)).not_to eq(:stored)
    end

    it "security: a hostile Redis writer who deletes a purge mark cannot make a purged entry be served again" do
      pending "documented limit: purge marks live in the store, which can delete them"
      require "redis"
      redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://redis:6379/0"))
      prefix = "vcp:#{SecureRandom.hex(4)}:"
      store = c::RedisStore.build(redis: redis, prefix: prefix)
      counter = { runs: 0 }
      qt = vcp.query_type(tags: ["catalog"], fields: { names: [[String], ->(*) { counter[:runs] += 1; ["v#{counter[:runs]}"] }] })
      schema = vcp.schema(qt, { "q" => "query Q { names }" }, caching: { store: store, encoder: vcp::Enc })
      run(schema, "q")
      expect(status(run(schema, "q"))).to eq(:hit)
      c.purge(schema, tag: "catalog")
      redis.hdel("#{prefix}meta", "m:#{schema.armory_caching.digester.("tag:catalog")}")
      after = run(schema, "q")
      redis.del(*redis.keys("#{prefix}*"))
      expect(status(after)).not_to eq(:hit)
    end
  end

  # ---------------------------------------------------------------------------------------------- 6. unprintable
  describe "6. :schema_unprintable" do
    it "preservation: an app visible? that raises on the full-schema context does not disable caching for the process" do
      pending "documented limit: a schema that fails to print once runs uncached for the life of the process (:schema_unprintable)"
      gadget = Class.new(vcp::BaseObject) do
        graphql_name "Gadget"
        cache_fields ttl: 300, scope: :public, reason: "probe"
        field :name, String, null: false
        def self.visible?(ctx) = ctx[:armory_full_schema] ? raise(vcp::Boom, "no user") : super
      end
      qt = vcp.query_type(fields: { names: [[String], ->(*) { %w[Lamp] }] }) do
        field :gadget, gadget, null: true, **vcp::LEGACY
        define_method(:gadget) { nil }
      end
      schema = vcp.schema(qt, { "q" => "query Q { names }" })
      first = run(schema, "q")
      expect(first["data"]).to eq("names" => %w[Lamp])
      expect([status(first), reason(first)]).to eq([:stored, nil])
    end
  end

  # ---------------------------------------------------------------------------------------------- 7. viewer
  describe "7. viewer" do
    let(:viewer_type) { vcp.query_type(scope: :viewer, ttl: 60, fields: { me: [String, ->(_o, ctx) { ctx[:current_user]&.id.to_s }] }) }

    it "security: a principal swapped mid-run with scoped_set! is not stored under the original viewer's key" do
      qt = vcp.query_type(scope: :viewer, ttl: 60, fields: {
        swap: [String, ->(_o, ctx) { ctx.scoped_set!(:current_user, vcp::User.new(99)); "swapped" }],
        me: [String, ->(_o, ctx) { ctx[:current_user]&.id.to_s }]
      })
      schema = vcp.schema(qt, { "q" => "query Q { swap me }" }, caching: { viewer: :current_user })
      result = run(schema, "q", current_user: vcp::User.new(7))
      expect(status(result)).not_to eq(:stored)
    end

    it "security: a viewer read through fetch and dig in a :viewer run is keyed to that viewer" do
      qt = vcp.query_type(scope: :viewer, ttl: 60, fields: {
        me: [String, ->(_o, ctx) { "#{ctx.fetch(:current_user).id}/#{ctx.dig(:current_user)&.id}" }]
      })
      schema = vcp.schema(qt, { "q" => "query Q { me }" }, caching: { viewer: :current_user })
      a, b = a_then_b(schema, "q", { current_user: vcp::User.new(7) }, { current_user: vcp::User.new(8) })
      expect([status(a), b["data"]["me"]]).to eq([:stored, "8/8"])
    end

  end

  # ---------------------------------------------------------------------------------------------- 8. recorder
  describe "8. recorder read paths in a :public run" do
    # reader => [what B sends, what B must get]
    readers = {
      "fetch" => [->(ctx) { ctx.fetch(:secret).to_s }, { secret: "beta" }, "beta"],
      "fetch with default" => [->(ctx) { ctx.fetch(:secret, "none").to_s }, {}, "none"],
      "fetch with block" => [->(ctx) { ctx.fetch(:secret) { "none" }.to_s }, {}, "none"],
      "dig" => [->(ctx) { ctx.dig(:secret).to_s }, { secret: "beta" }, "beta"],
      "key?" => [->(ctx) { ctx.key?(:secret) ? "yes" : "no" }, {}, "no"],
      "query.context[]" => [->(ctx) { ctx.query.context[:secret].to_s }, { secret: "beta" }, "beta"],
      "namespace(:interpreter)[]" => [->(ctx) { ctx.namespace(:interpreter)[:secret].to_s }, { secret: "beta" }, "beta"],
      "to_h" => [->(ctx) { ctx.to_h[:secret].to_s }, { secret: "beta" }, "beta"],
      "to_hash" => [->(ctx) { ctx.to_hash[:secret].to_s }, { secret: "beta" }, "beta"],
      "namespace(nil)" => [->(ctx) { ctx.namespace(nil)[:secret].to_s }, { secret: "beta" }, "beta"]
    }
    readers.each do |label, (read, b_context, expected)|
      it "security: a read through #{label} keeps one requester's answer from another" do
        qt = vcp.query_type(fields: { secret: [String, ->(_o, ctx) { read.(ctx) }] })
        schema = vcp.schema(qt, { "q" => "query Q { secret }" })
        _, b = a_then_b(schema, "q", { secret: "alpha" }, b_context)
        expect(b["data"]["secret"]).to eq(expected)
      end
    end

    it "security: a trace module reading the context during execute_field keeps the answer out of the store" do
      tracer = Module.new do
        def execute_field(query:, **kwargs)
          query.context[:secret]
          super
        end
      end
      qt = vcp.query_type(fields: { names: [[String], ->(*) { %w[Lamp] }] })
      schema = vcp.schema(qt, { "q" => "query Q { names }" }) { trace_with(tracer) }
      result = run(schema, "q", secret: "x")
      expect(status(result)).not_to eq(:stored) unless ArmoryEngine.next?
      expect(result["data"]).to eq("names" => %w[Lamp])
    end
  end

  # ---------------------------------------------------------------------------------------------- 9. authorization
  describe "9. Authorization in :public runs" do
    it "security: user B (refused by a field rule, :null mode) and user A (allowed) never get each other's answer" do
      auth = GraphQL::Armory::Authorization
      adapter = Class.new(auth::Adapters::Substitute) do
        def actor(context) = context[:current_user]
        def authorized?(actor, _subject, _rule) = actor&.id == 7
      end.new
      field_class = Class.new(GraphQL::Schema::Field) do
        include auth::Base
        include GraphQL::Armory::Caching::Base
      end
      object = Class.new(GraphQL::Schema::Object) do
        include auth::Base
        include GraphQL::Armory::Caching::Base
        field_class field_class
        default_action :read
      end
      product = Class.new(object) do
        graphql_name "Product"
        authorize :none, reason: "public catalog", covers_fields: true
        cache_fields ttl: 300, scope: :public, reason: "probe"
        field :name, String, null: false
        field :cost, Integer, null: true, authorize: :manage
      end
      qt = Class.new(object) do
        graphql_name "Query"
        authorize :none, reason: "root"
        cache_fields ttl: 300, scope: :public, reason: "probe"
        field :products, [product], null: false, authorize: :none, reason: "list", **vcp::LEGACY
        define_method(:products) { [Struct.new(:name, :cost).new("Lamp", 42)] }
      end
      schema = vcp.schema(qt, { "q" => "query Q { products { name cost } }" }) { use auth, adapter: adapter }
      b_first = run(schema, "q", current_user: vcp::User.new(8))
      a = run(schema, "q", current_user: vcp::User.new(7))
      b_again = run(schema, "q", current_user: vcp::User.new(8))
      expect([b_first["data"]["products"][0]["cost"], a["data"]["products"][0]["cost"], b_again["data"]["products"][0]["cost"]]).to eq([nil, 42, nil])
    end
  end

  # ---------------------------------------------------------------------------------------------- 10. persisted
  describe "10. PersistedQueries admission" do
    it "security: a raw query whose context spoofs the armory namespace is never looked up" do
      qt = vcp.query_type(fields: { names: [[String], ->(*) { %w[Lamp] }] })
      schema = vcp.schema(qt, { "q" => "query Q { names }" })
      run(schema, "q")
      raw = execute_query(schema, "query Q { names }", context: { armory_allow_raw_query: true, armory: { persisted: true }, armory_cache: { guard_built: true } })
      expect([status(raw), reason(raw)]).to eq(%i[skipped not_persisted])
    end

    it "security: a manifest changed between deploys under the same release never serves the old document's answer" do
      store = c::MemoryStore.new
      qt = vcp.query_type(fields: { names: [[String], ->(*) { %w[Lamp] }], count: [Integer, ->(*) { 1 }] })
      one = vcp.schema(qt, { "q" => "query Q { names }" }, name: "VcpDeploy", caching: { store: store, encoder: vcp::Enc, release: "same" })
      two = vcp.schema(qt, { "q" => "query Q { count }" }, name: "VcpDeploy", caching: { store: store, encoder: vcp::Enc, release: "same" })
      run(one, "q")
      run(one, "q")
      expect(run(two, "q")["data"]).to eq("count" => 1)
    end
  end

  # ---------------------------------------------------------------------------------------------- 11. key completeness
  describe "11. key completeness" do
    let(:deep_type) do
      inner = Class.new(vcp::BaseObject) do
        graphql_name "Inner"
        cache_fields ttl: 300, scope: :public, reason: "probe"
        field :name, String, null: false, **vcp::LEGACY
        field :inner, self, null: true, **vcp::LEGACY
        def name = "n"
        def inner = nil
      end
      vcp.query_type(fields: {}) do
        field :root, inner, null: true, **vcp::LEGACY
        define_method(:root) { Object.new }
      end
    end

    it "security: a request with a stricter max_depth never gets the entry a looser request stored" do
      schema = vcp.schema(deep_type, { "q" => "query Q { root { inner { name } } }" })
      method_name = ArmoryEngine.next? ? :multiplex_next : :multiplex
      2.times { schema.public_send(method_name, [{ query: nil, context: { operation_id: "q" } }]) }
      strict = schema.public_send(method_name, [{ query: nil, context: { operation_id: "q" }, max_depth: 1 }]).first
      expect(status(strict)).not_to eq(:hit)
      expect(strict.to_h.key?("errors")).to be(true)
    end

    it "security: a value read from an undeclared variable (query.provided_variables) is not served to another request" do
      pending "documented limit: reads of the query's raw variables outside the context are not seen"
      qt = vcp.query_type(fields: { echo: [String, ->(_o, ctx) { ctx.query.provided_variables["locale"].to_s }] })
      schema = vcp.schema(qt, { "q" => "query Q { echo }" })
      run_with = ->(locale) { execute_query(schema, nil, variables: { "locale" => locale }, context: { operation_id: "q" }) }
      run_with.("en")
      run_with.("en")
      expect(run_with.("fr")["data"]["echo"]).to eq("fr")
    end

    it "security: vary: keys a String and a Symbol, and an absent key and a nil one, apart" do
      qt = vcp.query_type(fields: { locale: [String, ->(_o, ctx) { ctx.key?(:locale) ? ctx[:locale].inspect : "absent" }] })
      schema = vcp.schema(qt, { "q" => "query Q { locale }" }, caching: { vary: { locale: :locale } })
      answers = [{ locale: "en" }, { locale: :en }, {}, { locale: nil }].map do |context|
        run(schema, "q", **context)
        run(schema, "q", **context)["data"]["locale"]
      end
      expect(answers).to eq(['"en"', ":en", "absent", "nil"])
    end

    it "security: the engine is in the key (an interpreter entry is never a Next hit)" do
      skip "Execution::Next is not available" unless ArmoryEngine.supported?
      qt = vcp.query_type(fields: { names: [[String], ->(*) { %w[Lamp] }] })
      schema = vcp.schema(qt, { "q" => "query Q { names }" })
      2.times { schema.execute(context: { operation_id: "q" }) }
      expect(status(schema.execute_next(context: { operation_id: "q" }))).to eq(:stored)
    end

    it "security: two named visibility profiles never share an answer" do
      skip "named visibility profiles need graphql 2.5+" unless defined?(GraphQL::Schema::Visibility)
      qt = vcp.query_type(fields: { mode: [String, ->(_o, ctx) { ctx[:visibility_profile].to_s }] })
      schema = vcp.schema(qt, { "q" => "query Q { mode }" }) { use GraphQL::Schema::Visibility, profiles: { alpha: {}, beta: {} } }
      _, b = a_then_b(schema, "q", { visibility_profile: :alpha }, { visibility_profile: :beta })
      expect(b["data"]["mode"]).to eq("beta")
    end
  end

  # ---------------------------------------------------------------------------------------------- 12. purge
  describe "12. purge" do
    let(:types) do
      iface = Module.new do
        include GraphQL::Schema::Interface
        include GraphQL::Armory::Caching::Base
        graphql_name "Item"
        field_class vcp::BaseField
        cache_fields ttl: 300, scope: :public, reason: "probe"
        field :name, String, null: false
      end
      product = Class.new(vcp::BaseObject) do
        graphql_name "Product"
        implements iface
        cache_fields ttl: 300, scope: :public, reason: "probe"
        field :name, String, null: false
      end
      gadget = Class.new(vcp::BaseObject) do
        graphql_name "Gadget"
        implements iface
        cache_fields ttl: 300, scope: :public, reason: "probe"
        field :name, String, null: false
      end
      union = Class.new(GraphQL::Schema::Union) do
        graphql_name "Thing"
        possible_types product, gadget
      end
      record = Struct.new(:name, :kind)
      resolve = ->(_type, obj, _ctx) { obj.kind == :gadget ? gadget : product }
      iface.define_singleton_method(:resolve_type) { |obj, ctx| resolve.(nil, obj, ctx) }
      union.define_singleton_method(:resolve_type) { |obj, ctx| resolve.(nil, obj, ctx) }
      qt = vcp.query_type(fields: {}) do
        field :items, [iface], null: false, **vcp::LEGACY
        field :things, [union], null: false, **vcp::LEGACY
        define_method(:items) { [record.new("Lamp", :product)] }
        define_method(:things) { [record.new("Lamp", :product)] }
      end
      { qt: qt, product: product, gadget: gadget }
    end

    %w[items things].each do |root|
      it "security: purge(type:) of a possible type reaches an answer selected through #{root == "items" ? "an interface" : "a union"} field" do
        doc = root == "items" ? "query Q { items { name } }" : "query Q { things { ... on Product { name } ... on Gadget { name } } }"
        t = types
        schema = vcp.schema(t[:qt], { "q" => doc }) do
          orphan_types(t[:product], t[:gadget])
          define_singleton_method(:resolve_type) { |_type, obj, _ctx| obj.kind == :gadget ? t[:gadget] : t[:product] }
        end
        run(schema, "q")
        expect(status(run(schema, "q"))).to eq(:hit)
        c.purge(schema, type: types[:gadget])
        expect(status(run(schema, "q"))).not_to eq(:hit)
      end
    end

    it "security: purge(viewer: :anonymous) reaches the shared anonymous entries, and purge(viewer: user) does not" do
      qt = vcp.query_type(scope: :viewer, ttl: 60, fields: { me: [String, ->(_o, ctx) { ctx[:current_user]&.id.to_s }] })
      schema = vcp.schema(qt, { "q" => "query Q { me }" }, caching: { viewer: :current_user, anonymous: :shared, anonymous_reason: "probe" })
      run(schema, "q")
      expect(status(run(schema, "q"))).to eq(:hit)
      c.purge(schema, viewer: vcp::User.new(7))
      expect(status(run(schema, "q"))).to eq(:hit)
      c.purge(schema, viewer: :anonymous)
      expect(status(run(schema, "q"))).not_to eq(:hit)
    end

    it "preservation: a purge whose store fails once raises PurgeError, and the retry purges" do
      store = c::Store::Substitute.new
      qt = vcp.query_type(tags: ["catalog"], fields: { names: [[String], ->(*) { %w[Lamp] }] })
      schema = vcp.schema(qt, { "q" => "query Q { names }" }, caching: { store: store })
      run(schema, "q")
      expect(status(run(schema, "q"))).to eq(:hit)
      store.fail_with(RuntimeError.new("down"), on: :purge, times: 1)
      expect { c.purge(schema, tag: "catalog") }.to raise_error(c::PurgeError)
      c.purge(schema, tag: "catalog")
      expect(status(run(schema, "q"))).not_to eq(:hit)
    end
  end

  # ---------------------------------------------------------------------------------------------- 14. entry points
  describe "14. entry points" do
    let(:qt) { vcp.query_type(fields: { names: [[String], ->(*) { %w[Lamp] }] }) }

    it "security: a query the app built with query_class and hands to multiplex is never answered from the store" do
      schema = vcp.schema(qt, { "q" => "query Q { names }" })
      run(schema, "q")
      run(schema, "q")
      built = schema.query_class.new(schema, nil, context: { operation_id: "q" })
      method_name = ArmoryEngine.next? ? :multiplex_next : :multiplex
      result = schema.public_send(method_name, [built]).first
      expect(status(result)).not_to eq(:hit)
    end

    it "security: a rescue_from registered on a child schema after its parent's use is wrapped, so a rescued run is not stored" do
      parent = vcp.schema(vcp.query_type(fields: { names: [[String], ->(_o, ctx) { raise vcp::Boom if ctx[:fail]; %w[Lamp] }] }), { "q" => "query Q { names }" })
      child = Class.new(parent) { rescue_from(vcp::Boom) { nil } }
      result = run(child, "q", fail: true)
      expect(status(result)).not_to eq(:stored)
      expect(status(run(child, "q"))).not_to eq(:hit)
    end

    it "preservation: owners of the hooked methods are the plugin's (method(name).owner)" do
      schema = vcp.schema(qt, { "q" => "query Q { names }" })
      guard = c::Integration::Guard
      owners = %i[multiplex context_class query_class rescue_from].to_h { |name| [name, schema.method(name).owner] }
      context = schema.context_class.new(query: schema.query_class.new(schema, "{ names }", context: { armory_allow_raw_query: true }), values: {})
      context_owners = %i[[] fetch dig key? to_h namespace].to_h { |name| [name, context.method(name).owner] }
      expect(owners.values).to all(eq(guard))
      expect(context_owners.values.uniq.size).to eq(1)
      expect(c::Recorder::Context.wrapper?(context_owners.values.first)).to be(true)
    end
  end

  # ---------------------------------------------------------------------------------------------- 16. fail open
  describe "16. a store-time failure" do
    it "security (availability): data the store cannot encode (invalid UTF-8) is answered uncached instead of raising" do
      bad = (+"\xFF\xFE").force_encoding(Encoding::UTF_8)
      qt = vcp.query_type(fields: { name: [String, ->(*) { bad }] })
      schema = vcp.schema(qt, { "q" => "query Q { name }" })
      result = nil
      expect { result = run(schema, "q") }.not_to raise_error
      expect(result.to_h.key?("data")).to be(true)
    end
  end
end
