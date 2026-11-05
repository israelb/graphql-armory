# frozen_string_literal: true

require "spec_helper"

RSpec.describe "GraphQL::Armory::Caching integration" do
  let(:caching) { GraphQL::Armory::Caching }
  let(:store) { caching::Controls::Store.example }
  let(:entry_data) { { "products" => [{ "name" => "Cached" }] } }
  let(:entry) { caching::Entry.new(key: "a" * 64, data: entry_data, stored_at: 0, ttl: 60, scope: :public, seq: 0, epoch: "e", tags: []) }
  let(:hit) { caching::Decision.hit(entry) }
  let(:miss) do
    caching::Decision.miss(caching::Key.new(digest: "b" * 64, scope: :public), caching::Policy.cacheable(ttl: 60, scope: :public),
                           caching::Lookup.miss(seq: 0, epoch: "e", now: 0))
  end

  # The real gate sets the hit's Result for every `Decision.hit` (`RecordKeys.hit_result!`); U0's Gate::Substitute
  # answers the decision only, so this one adds that line, as the gate does for a hit it answered.
  let(:gate) { caching::Gate::Substitute.new }

  def schema_with(gate: self.gate, **options)
    caching::Controls::Schema.example(caching: { store: store, release: "r1", gate: gate, **options })
  end

  def context(operation = "names", **extra)
    caching::Controls::Context.example(operation: operation, **extra)
  end

  # The engine this run tests: `multiplex` on the interpreter, `multiplex_next` on Execution::Next.
  def run_multiplex(schema, queries)
    ArmoryEngine.next? ? schema.multiplex_next(queries) : schema.multiplex(queries)
  end

  def engine = ArmoryEngine.next? ? :next : :interpreter

  describe "use" do
    def install(**options)
      schema = Class.new(GraphQL::Schema)
      schema.use(caching, **options)
      schema
    end

    let(:valid) { { store: store, release: "r1", gate: caching::Gate::Substitute.new } }

    it "keeps the settings on the schema and its children, with the defaults of the docs" do
      schema = install(**valid)
      settings = schema.armory_caching

      expect(settings.store).to equal(store)
      expect([settings.release, settings.viewer, settings.anonymous, settings.max_ttl, settings.max_viewer_ttl, settings.max_entry_bytes, settings.extensions])
        .to eq(["r1", nil, :uncacheable, 3600, 300, 262_144, false])
      expect(settings.digester).to be_a(caching::Digester)
      expect(settings.viewer_id.(caching::Controls::Viewer.example(id: 9))).to eq(9)
      expect(settings).to be_frozen
      expect(Class.new(schema).armory_caching).to equal(settings)
    end

    it "takes every documented option" do
      settings = install(**valid, viewer: :current_user, viewer_id: ->(user) { "u#{user.id}" }, anonymous: :shared, anonymous_reason: "a public landing page",
                                  vary: { locale: :locale, tenant: -> { "t1" } }, max_ttl: 600, max_viewer_ttl: 120, max_entry_bytes: 1024,
                                  neutral_keys: { request_id: "logging only" }, context_methods: { tenant: "reads only the tenant key, which vary: holds" },
                                  own_checks: { GraphQL::Schema::Object => { visible?: "the base class answers true" } },
                                  extensions: true, sinks: [->(_signal, _data) {}], on_sink_error: ->(_error, _signal) {}, on_store_error: ->(_error) {}).armory_caching

      expect([settings.viewer, settings.anonymous, settings.anonymous_reason, settings.max_ttl, settings.max_viewer_ttl, settings.max_entry_bytes])
        .to eq([:current_user, :shared, "a public landing page", 600, 120, 1024])
      expect(settings.vary.keys).to eq(%i[locale tenant])
      expect(settings.neutral_keys).to eq(request_id: "logging only")
      expect(settings.context_methods.keys).to eq([:tenant])
      expect(settings.own_checks).to eq(GraphQL::Schema::Object => { visible?: "the base class answers true" })
      expect(settings.viewer_id.(caching::Controls::Viewer.example(id: 9))).to eq("u9")
    end

    # Each invalid value, refused at boot with Caching::ConfigurationError.
    {
      "no store" => [{ store: nil }, /store: is required/],
      "Store::Null" => [{ store: GraphQL::Armory::Caching::Store::Null.new }, /stores nothing/],
      "a store without the store methods" => [{ store: {} }, /lookup, write, purge and purge_all/],
      "Encoder::Null" => [{ encoder: GraphQL::Armory::Encoder::Null }, /does not encrypt/],
      "Encoder::Legacy" => [{ encoder: GraphQL::Armory::Encoder::Legacy }, /does not encrypt/],
      "an encoder that cannot seal" => [{ encoder: Object.new }, /encoder: must seal/],
      "no release" => [{ release: nil }, /release:/],
      "an empty release" => [{ release: "  " }, /release:/],
      "a release that is not a String" => [{ release: 42 }, /release:/],
      "a viewer that is not a context key" => [{ viewer: 1 }, /viewer:/],
      "an empty viewer key" => [{ viewer: "" }, /viewer:/],
      "a viewer_id that cannot be called" => [{ viewer: :current_user, viewer_id: "id" }, /viewer_id:/],
      "a viewer_id without a viewer" => [{ viewer_id: ->(user) { user.id } }, /viewer_id: needs viewer:/],
      "an unknown anonymous mode" => [{ viewer: :current_user, anonymous: :everyone }, /anonymous:/],
      "anonymous: :shared without a reason" => [{ viewer: :current_user, anonymous: :shared }, /anonymous_reason:/],
      "anonymous: :shared with an empty reason" => [{ viewer: :current_user, anonymous: :shared, anonymous_reason: " " }, /anonymous_reason:/],
      "anonymous: :shared without a viewer" => [{ anonymous: :shared, anonymous_reason: "landing page" }, /needs viewer:/],
      "a reason for anonymous: :uncacheable" => [{ viewer: :current_user, anonymous_reason: "landing page" }, /anonymous_reason: goes with anonymous: :shared/],
      "vary: that is not a Hash" => [{ vary: [:locale] }, /vary:/],
      "a vary name that is not a Symbol or String" => [{ vary: { 1 => :locale } }, /vary:/],
      "a vary value that is neither a key nor a callable" => [{ vary: { locale: 1 } }, /vary:/],
      "a vary callable taking an argument" => [{ vary: { tenant: ->(context) { context[:tenant] } } }, /takes no arguments/],
      "two vary names that print alike" => [{ vary: { locale: :locale, "locale" => :lang } }, /vary:.*twice/],
      "max_ttl: 0" => [{ max_ttl: 0 }, /max_ttl:/],
      "max_ttl: a String" => [{ max_ttl: "60" }, /max_ttl:/],
      "max_ttl: a Float" => [{ max_ttl: 1.5 }, /max_ttl:/],
      "max_viewer_ttl: over 300" => [{ max_viewer_ttl: 301 }, /max_viewer_ttl:.*300/],
      "max_viewer_ttl: 0" => [{ max_viewer_ttl: 0 }, /max_viewer_ttl:/],
      "max_entry_bytes: 0" => [{ max_entry_bytes: 0 }, /max_entry_bytes:/],
      "neutral_keys: that is not a Hash" => [{ neutral_keys: [:request_id] }, /neutral_keys:/],
      "a neutral key without a reason" => [{ neutral_keys: { request_id: nil } }, /neutral_keys:.*reason/],
      "a neutral key with an empty reason" => [{ neutral_keys: { request_id: "" } }, /neutral_keys:.*reason/],
      "the viewer key declared neutral" => [{ viewer: :current_user, neutral_keys: { current_user: "who is logged in" } }, /viewer key/],
      "context_methods: with an empty reason" => [{ context_methods: { tenant: "" } }, /context_methods:.*reason/],
      "a context method name that is not a Symbol or String" => [{ context_methods: { 1 => "reason" } }, /context_methods:/],
      "own_checks: that is not a Hash" => [{ own_checks: [] }, /own_checks:/],
      "an own check on something that is not a class" => [{ own_checks: { "Invoice" => { visible?: "reason" } } }, /own_checks:/],
      "an own check without a reason" => [{ own_checks: { GraphQL::Schema::Object => { visible?: "" } } }, /own_checks:.*reason/],
      "own checks that are not a Hash of methods" => [{ own_checks: { GraphQL::Schema::Object => [:visible?] } }, /own_checks:/],
      "extensions: that is not a boolean" => [{ extensions: "yes" }, /extensions:/],
      "sinks: that is not an Array" => [{ sinks: "log" }, /sinks:/],
      "on_sink_error: that cannot be called" => [{ on_sink_error: 1 }, /on_sink_error:/],
      "on_store_error: that cannot be called" => [{ on_store_error: 1 }, /on_store_error:/],
      "a gate that does not decide" => [{ gate: Object.new }, /gate:/]
    }.each do |description, (options, message)|
      it "refuses #{description} at boot, and installs nothing" do
        schema = Class.new(GraphQL::Schema)

        expect { schema.use(caching, **valid, **options) }.to raise_error(caching::ConfigurationError, message)
        expect(schema.singleton_class.include?(caching::Integration::Guard)).to be(false)
        expect(schema.respond_to?(:armory_caching)).to be(false)
      end
    end

    it "requires an encoder with a RedisStore, found by its class name, subclasses included" do
      redis_store = Class.new(caching::Store::Substitute) { def self.name = "GraphQL::Armory::Caching::RedisStore" }

      expect { install(**valid, store: redis_store.new) }.to raise_error(caching::ConfigurationError, /encoder: is required with RedisStore/)
      expect { install(**valid, store: Class.new(redis_store).new) }.to raise_error(caching::ConfigurationError, /encoder: is required with RedisStore/)
    end

    it "is used once per schema hierarchy" do
      schema = install(**valid)

      expect { schema.use(caching, **valid) }.to raise_error(caching::ConfigurationError, /already uses GraphQL::Armory::Caching/)
      expect { Class.new(schema).use(caching, **valid) }.to raise_error(caching::ConfigurationError, /already uses GraphQL::Armory::Caching/)
    end

    it "wraps the context class set before use and the one set after, once per class" do
      app_context = Class.new(GraphQL::Query::Context) { def tenant = self[:tenant] }
      before = Class.new(GraphQL::Schema) { context_class(app_context) }
      before.use(caching, **valid)
      after = install(**valid)
      after.context_class(app_context)

      [before, after].each do |schema|
        expect(schema.context_class).to include(caching::Recorder::Context::Wrapped)
        expect(schema.context_class).to be < app_context
      end
      expect(before.context_class).to equal(after.context_class)
      expect(install(**valid).context_class).to include(caching::Recorder::Context::Wrapped)
    end

    it "wraps the query class set before use and the one set after, once per class" do
      app_query = Class.new(GraphQL::Query)
      before = Class.new(GraphQL::Schema) { query_class(app_query) }
      before.use(caching, **valid)
      after = install(**valid)
      after.query_class(app_query)

      [before, after].each { |schema| expect(schema.query_class).to include(caching::Integration::Query) }
      expect(before.query_class).to equal(after.query_class)
      after.query_class(after.query_class)
      expect(after.query_class).to equal(before.query_class)
    end
  end

  describe "a request" do
    it "hands every query of the call, in order, to the gate, labelled with the engine" do
      schema = schema_with
      run_multiplex(schema, [{ context: context("names") }, { context: context("catalog") }])

      queries, seen_engine = gate.seen.first
      expect(gate.seen.size).to eq(1)
      expect(seen_engine).to eq(engine)
      expect(queries.map { |query| query.context[:operation_id] }).to eq(%w[names catalog])
      expect(queries).to all(satisfy { |query| caching::RecordKeys.guard_built?(query.context) })
    end

    it "answers hits from the gate, runs misses and passes together, and keeps the order" do
      gate.decide(hit, miss, caching::Decision.pass(:mutation), hit)
      schema = schema_with
      results = run_multiplex(schema, [{ context: context("names") }, { context: context("catalog") }, { context: context("names") }, { context: context("product") }])

      expect(results.map { |result| result.to_h["data"]&.keys }).to eq([["products"], ["products"], ["products"], ["products"]])
      expect(results[0].to_h["data"]).to eq(entry_data)
      expect(results[3].to_h["data"]).to eq(entry_data)
      expect(results[1].to_h["data"]["products"].first["price"]).to eq("amount" => 1200, "currency" => "EUR")
      expect(results[2].to_h["data"]["products"].map { |product| product["name"] }).to eq(%w[Lamp Desk])

      queries = gate.seen.first.first
      expect(queries[1].multiplex).to equal(queries[2].multiplex)
      expect(queries[1].multiplex).not_to be_nil
      expect([queries[0].multiplex, queries[3].multiplex]).to eq([nil, nil])
      expect(gate.stored.map { |query, decision, result| [query, decision, result] }).to eq([[queries[1], miss, results[1]]])
    end

    it "runs nothing when every query is a hit" do
      gate.decide(hit, hit)
      results = run_multiplex(schema_with, [{ context: context("names") }, { context: context("catalog") }])

      expect(results.map { |result| result.to_h["data"] }).to eq([entry_data, entry_data])
      expect(gate.seen.first.first.map(&:multiplex)).to eq([nil, nil])
      expect(gate.stored).to eq([])
    end

    it "runs a hit uncached when the gate did not set its Result, and never stores it" do
      plain = Class.new(caching::Gate::Substitute) do
        def call(queries, engine:)
          super.tap { queries.each { |query| GraphQL::Armory::Caching::RecordKeys.hit_result!(query.context, nil) } }
        end
      end.new
      plain.decide(hit)
      result = run_multiplex(schema_with(gate: plain), [{ context: context("names") }]).first

      expect(result.to_h["data"]["products"].map { |product| product["name"] }).to eq(%w[Lamp Desk])
      expect(plain.stored).to eq([])
    end

    it "passes an app-built query through as it is, unmarked, and never answers it from a hit" do
      gate.decide(hit)
      schema = schema_with
      built = schema.query_class.new(schema, nil, context: context("names"))
      result = run_multiplex(schema, [built]).first

      expect(gate.seen.first.first.first).to equal(built)
      expect(caching::RecordKeys.guard_built?(built.context)).to be(false)
      expect(result.to_h["data"]["products"].map { |product| product["name"] }).to eq(%w[Lamp Desk])
    end

    # The gate cannot read these back from the query, so a query built with them never carries the guard's mark.
    {
      "warden:" => ->(schema) { { warden: GraphQL::Schema::Warden::NullWarden.new(context: nil, schema: schema) } },
      "static_validator:" => ->(schema) { { static_validator: GraphQL::StaticValidation::Validator.new(schema: schema) } },
      "root_value:" => ->(_schema) { { root_value: Object.new } },
      "use_visibility_profile:" => ->(schema) { { use_visibility_profile: schema.use_visibility_profile? } },
      "validate: false" => ->(_schema) { { validate: false } }
    }.each do |option, options_for|
      it "leaves a query built with #{option} unmarked, so a hit never answers it" do
        if option == "use_visibility_profile:" && GraphQL::Query.instance_method(:initialize).parameters.none? { |_, name| name == :use_visibility_profile }
          skip "graphql #{GraphQL::VERSION} has no use_visibility_profile:"
        end
        gate.decide(hit)
        schema = schema_with
        result = run_multiplex(schema, [{ context: context("names"), **options_for.(schema) }]).first

        expect(caching::RecordKeys.guard_built?(gate.seen.first.first.first.context)).to be(false)
        expect(result.to_h["data"]["products"].map { |product| product["name"] }).to eq(%w[Lamp Desk])
      end
    end

    it "marks a query whose options carry those keys as nil, as execute_next sends them" do
      run_multiplex(schema_with, [{ context: context("names"), warden: nil, root_value: nil, static_validator: nil, validate: true }])

      expect(caching::RecordKeys.guard_built?(gate.seen.first.first.first.context)).to be(true)
    end

    it "answers the hit again from query.result, running nothing" do
      gate.decide(hit)
      result = run_multiplex(schema_with, [{ context: context("names") }]).first
      query = gate.seen.first.first.first

      expect(query.result).to equal(result)
      expect(query.result.to_h["data"]).to eq(entry_data)
      expect(query.executed?).to be(false)
      expect(query.multiplex).to be_nil
    end

    it "answers query.result from the run once the query ran" do
      result = run_multiplex(schema_with, [{ context: context("names") }]).first
      query = gate.seen.first.first.first

      expect(query.executed?).to be(true)
      expect(query.result).to equal(result)
    end

    it "keeps no trace from before the multiplex: once it runs, the query traces with the multiplex" do
      schema = schema_with
      query = schema.query_class.new(schema, "{ products { name } }", context: context(nil, armory_allow_raw_query: true))
      early = query.current_trace

      expect(query.current_trace).not_to equal(early)
      run_multiplex(schema, [query])
      expect(query.multiplex).not_to be_nil
      expect(query.current_trace).to equal(query.multiplex.current_trace)
    end

    it "answers the context's own trace before the multiplex, unmemoized" do
      schema = schema_with
      trace = schema.new_trace
      query = schema.query_class.new(schema, nil, context: context("names", trace: trace))

      expect(query.current_trace).to equal(trace)
    end

    it "labels execute :interpreter and execute_next :next" do
      schema = schema_with
      schema.execute(context: context("names"))
      schema.execute_next(context: context("names")) if ArmoryEngine.supported?

      expect(gate.seen.map(&:last)).to eq(ArmoryEngine.supported? ? %i[interpreter next] : %i[interpreter])
    end

    it "runs the gate once on a Next-default schema, labelled :next, for execute and multiplex", if: ArmoryEngine.supported? do
      schema = caching::Controls::Schema.example(next_default: true, caching: { store: store, release: "r1", gate: gate })
      schema.execute(context: context("names"))
      schema.multiplex([{ context: context("names") }])

      expect(gate.seen.map(&:last)).to eq(%i[next next])
    end

    it "runs the gate once for a child schema, with the parent's settings" do
      child = Class.new(schema_with)
      child.multiplex([{ context: context("names") }])
      child.execute(context: context("names"))

      expect(gate.seen.map(&:last)).to eq(%i[interpreter interpreter])
    end

    it "runs the gate once for the child of a Next-default schema, on the engine graphql-ruby picks", if: ArmoryEngine.supported? do
      child = Class.new(caching::Controls::Schema.example(next_default: true, caching: { store: store, release: "r1", gate: gate }))
      child.multiplex([{ context: context("names") }])
      child.execute(context: context("names"))

      expect(gate.seen.map(&:last)).to eq(%i[interpreter next])
    end

    it "refuses the first request when PersistedQueries is not installed, not the use" do
      query = Class.new(GraphQL::Schema::Object) do
        graphql_name "Query"
        field :ping, String, null: false
        define_method(:ping) { "pong" }
      end
      schema = Class.new(GraphQL::Schema) { query(query) }
      schema.use(caching, store: store, release: "r1", gate: gate)

      expect { schema.execute("{ ping }") }.to raise_error(caching::ConfigurationError, /PersistedQueries/)
      expect(gate.seen).to eq([])
    end

    it "has no multiplex_next on a schema without Execution::Next" do
      schema = Class.new(GraphQL::Schema)
      schema.use(caching, store: store, release: "r1", gate: gate)

      expect { schema.multiplex_next([]) }.to raise_error(NoMethodError, /multiplex_next/)
    end
  end

  describe "purge" do
    let(:telemetry) { caching::Telemetry::Substitute.new }
    let(:digester) { caching::Digester.new }
    let(:purge) { caching::Purge.new(store: store, digester: digester, telemetry: telemetry) }

    it "purges a custom tag, a type, a principal and the anonymous answers by the digests of their tags" do
      purge.(tag: "pricing")
      purge.(type: Class.new(GraphQL::Schema::Object) { graphql_name "Invoice" })
      purge.(viewer: caching::Controls::Viewer.example(id: 7))
      purge.(viewer: caching::Controls::Viewer.example(id: 7, admin: true))
      purge.(viewer: :anonymous)

      tags = [caching::Tags.custom("pricing"), caching::Tags.type("Invoice"), caching::Tags.viewer(caching::Controls::Viewer::User.name, 7),
              caching::Tags.viewer(caching::Controls::Viewer::AdminUser.name, 7), caching::Tags::ANONYMOUS]
      expect(store.calls.map { |operation, _, arguments| [operation, arguments[:tags]] }).to eq(tags.map { |tag| [:purge, [digester.(tag)]] })
      expect(telemetry.recorded).to eq([[:cache_purged, { kind: :tag }], [:cache_purged, { kind: :type, type: "Invoice" }],
                                        [:cache_purged, { kind: :viewer }], [:cache_purged, { kind: :viewer }], [:cache_purged, { kind: :viewer }]])
    end

    it "purges everything by replacing the epoch" do
      epoch = store.epoch
      purge.(all: true)

      expect(store.calls.map(&:first)).to eq(%i[purge_all])
      expect(store.epoch).not_to eq(epoch)
      expect(telemetry.recorded).to eq([[:cache_purged, { kind: :all }]])
    end

    it "takes exactly one of all:, viewer:, tag: and type:" do
      [{}, { all: false }, { all: true, tag: "pricing" }, { tag: "pricing", viewer: :anonymous }].each do |arguments|
        expect { purge.(**arguments) }.to raise_error(ArgumentError, /exactly one/)
      end
      expect { purge.(all: "yes") }.to raise_error(ArgumentError, /all:/)
      expect { purge.(type: "Invoice") }.to raise_error(ArgumentError, /type:/)
      expect { purge.(viewer: :everyone) }.to raise_error(ArgumentError, /viewer:/)
      expect(store.calls).to eq([])
    end

    it "derives a principal's id with viewer_id: and refuses one it cannot identify" do
      by_email = caching::Purge.new(store: store, digester: digester, viewer_id: ->(user) { user.id.to_s }, telemetry: telemetry)
      by_email.(viewer: caching::Controls::Viewer.example(id: 7))

      expect(store.calls.last[2][:tags]).to eq([digester.(caching::Tags.viewer(caching::Controls::Viewer::User.name, "7"))])
      expect { caching::Purge.new(store: store, viewer_id: ->(_user) {}).(viewer: caching::Controls::Viewer.example) }
        .to raise_error(caching::ConfigurationError, /viewer_id:/)
      expect { purge.(viewer: Struct.new(:id).new(7)) }.to raise_error(caching::ConfigurationError, /anonymous class/)
    end

    it "raises PurgeError when the store fails, reporting the error class and never the tag" do
      store.fail_with(IOError.new("redis://user:secret@host"), on: :purge)

      expect { purge.(tag: "pricing") }.to raise_error(caching::PurgeError) { |error| expect(error.message).not_to include("secret", "pricing") }
      expect(telemetry.recorded).to eq([[:cache_store_failed, { operation: :purge, error: "IOError" }]])
    end

    it "raises PurgeError when purge_all fails" do
      store.fail_with(IOError.new, on: :purge_all)

      expect { purge.(all: true) }.to raise_error(caching::PurgeError)
    end

    it "is inert when new: it purges nothing anywhere" do
      expect(caching::Purge.new.(all: true)).to be_nil
    end

    it "purges through the installed store and digester from Caching.purge, signals going to the sinks" do
      signals = []
      schema = schema_with(sinks: [->(signal, data) { signals << [signal, data] }])
      caching.purge(schema, tag: "pricing")

      expect(store.calls).to eq([[:purge, nil, { tags: [schema.armory_caching.digester.(caching::Tags.custom("pricing"))] }]])
      expect(signals).to eq([[:cache_purged, { kind: :tag }]])
      expect { caching.purge(Class.new(GraphQL::Schema), all: true) }.to raise_error(caching::ConfigurationError, /does not use GraphQL::Armory::Caching/)
    end
  end
end
