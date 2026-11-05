# frozen_string_literal: true

require "spec_helper"
require "graphql/armory/caching/gate"

# The per-request flow of the response cache (docs/response-caching.md "What is cached and when"), against the
# Substitutes: what the gate decides for each query, what it stores after a miss ran, and what it reports.
RSpec.describe "GraphQL::Armory::Caching::Gate" do
  let(:caching) { GraphQL::Armory::Caching }
  let(:schema) { caching::Controls::Schema.example.tap { |built| built.context_class(caching::Recorder::Substitute::Context) } }
  let(:store) { caching::Controls::Store.example }
  let(:telemetry) { GraphQL::Armory::Telemetry::Substitute.new }
  let(:digester) { caching::Digester.new }
  let(:codec) { caching::Codec::Substitute.new }
  let(:charge) { caching::Charge::Substitute.new }
  let(:public_policy) { caching::Policy.cacheable(ttl: 60, scope: :public, tags: [caching::Tags.custom("catalog"), caching::Tags.type("Product")]) }
  let(:viewer_policy) { caching::Policy.cacheable(ttl: 30, scope: :viewer, tags: [caching::Tags.type("Invoice")]) }
  let(:public_key) { caching::Key.new(digest: "a" * 64, scope: :public) }
  let(:viewer_tag) { digester.(caching::Tags.viewer("User", 7)) }
  let(:viewer_key) { caching::Key.new(digest: "b" * 64, scope: :viewer, viewer_tag: viewer_tag) }
  let(:walk) { caching::Walk::Substitute.new(public_policy) }
  let(:keyer) { caching::Keyer::Substitute.new(public_key) }
  let(:data) { { "products" => [{ "name" => "Lamp" }, { "name" => "Desk" }] } }

  def gate(**settings)
    caching::Gate.new(store: store, walk: walk, keyer: keyer, codec: codec, charge: charge, telemetry: telemetry, digester: digester, **settings)
  end

  # A query as the guard builds it: through the schema's query_class, marked guard-built and persisted.
  def build(operation: "names", persisted: true, **options)
    context = options.delete(:context) || caching::Controls::Context.example(operation: operation)
    # Through `schema.query_class`, PersistedQueries would look up the operation_id and mark the query persisted.
    query = (persisted ? schema.query_class : GraphQL::Query).new(schema, nil, context: context, **options)
    caching::RecordKeys.guard_built!(query.context)
    caching::RecordKeys.persisted!(query.context) if persisted
    query
  end

  def result_for(query, values = { "data" => data })
    GraphQL::Query::Result.new(query: query, values: values)
  end

  def signals(name)
    telemetry.recorded.select { |signal, _| signal == name }.map(&:last)
  end

  def operations
    store.calls.map(&:first)
  end

  # Runs one miss through the gate and stores `values` as its result; answers the store's verdict.
  def fill(cache, values = { "data" => data }, **build_options)
    query = build(**build_options)
    decision = cache.([query], engine: :interpreter).first
    expect(decision).to be_miss
    cache.store(query, decision, result_for(query, values))
  end

  describe "Gate.new" do
    it "is inert: every query runs uncached and the store is never touched" do
      inert = caching::Gate.new(telemetry: telemetry)
      query = build
      decision = inert.([query], engine: :interpreter).first

      expect(decision).to be_pass
      expect(decision.reason).to eq(:unconfigured)
      expect(inert.store(query, decision, result_for(query))).to eq(:unconfigured)
      expect(caching::RecordKeys.hit_result(query.context)).to be_nil
    end

    it "refuses an engine other than :interpreter or :next" do
      expect { gate.([build], engine: :legacy) }.to raise_error(ArgumentError, /engine/)
    end

    it "refuses settings that would let anything through unchecked" do
      expect { caching::Gate.new(max_ttl: 0) }.to raise_error(caching::ConfigurationError, /max_ttl/)
      expect { caching::Gate.new(max_viewer_ttl: "300") }.to raise_error(caching::ConfigurationError, /max_viewer_ttl/)
      expect { caching::Gate.new(max_entry_bytes: -1) }.to raise_error(caching::ConfigurationError, /max_entry_bytes/)
      expect { caching::Gate.new(vary_keys: [1]) }.to raise_error(caching::ConfigurationError, /vary_keys/)
      expect { caching::Gate.new(recorded_cost: 5) }.to raise_error(caching::ConfigurationError, /recorded_cost/)
      expect { caching::Gate.new(on_store_error: "log") }.to raise_error(caching::ConfigurationError, /on_store_error/)
    end

    it "builds from the checked use options, with the installer's digester" do
      built = caching::Gate.build(schema, store: caching::MemoryStore.new, digester: digester, telemetry: telemetry, release: "r1",
                                          own_checks: {}, sinks: [])

      expect(built).to be_a(caching::Gate)
      expect(built.instance_variable_get(:@digester)).to equal(digester)
    end

    it "refuses a max_ttl longer than the store keeps purge marks" do
      expect do
        caching::Gate.build(schema, store: caching::MemoryStore.new(max_ttl: 60), digester: digester, telemetry: telemetry, release: "r1", max_ttl: 3600)
      end.to raise_error(caching::ConfigurationError, /max_ttl: 3600 exceeds the store's max_ttl: 60/)
    end
  end

  describe "the app's context class" do
    let(:app_context) do
      Class.new(caching::Recorder::Substitute::Context) do
        def tenant = @provided_values[:tenant]
      end
    end

    it "runs uncached (:context_method) when it adds a public method not declared in context_methods:" do
      schema.context_class(app_context)

      expect(gate.([build], engine: :interpreter).first.reason).to eq(:context_method)
      expect(store.calls).to be_empty
      expect(signals(:cache_skipped).map { |data| data[:reason] }).to eq([:context_method])
    end

    it "is looked up when every added method is declared with a reason" do
      schema.context_class(app_context)

      expect(gate(context_methods: { tenant: "reads the request's tenant, which vary: holds" }).([build], engine: :interpreter).first).to be_miss
    end
  end

  describe "the Points cost, per query" do
    it "stores a miss without a cost when the charge reports no limiter for the query" do
      unlimited = Class.new(caching::Charge::Substitute) { def limited?(_query = nil) = false }.new

      expect(fill(gate(charge: unlimited, recorded_cost: ->(_query) {}))).to eq(:stored)
    end

    it "refuses a miss without a cost when the charge reports a limiter for the query" do
      limited = Class.new(caching::Charge::Substitute) { def limited?(_query = nil) = true }.new

      expect(fill(gate(charge: limited, recorded_cost: ->(_query) {}))).to eq(:cost_unknown)
      expect(operations).not_to include(:write)
    end
  end

  describe "deciding" do
    it "answers one decision per query, in the order given" do
      queries = [build(operation: "names"), build(operation: "names", persisted: false), build(operation: "catalog")]
      decisions = gate.(queries, engine: :interpreter)

      expect(decisions.map(&:kind)).to eq(%i[miss pass miss])
      expect(decisions[1].reason).to eq(:not_persisted)
    end

    it "looks the key up once and answers a miss with the key, the policy and the lookup" do
      query = build
      decision = gate.([query], engine: :interpreter).first

      expect(store.calls).to eq([[:lookup, public_key.digest, {}]])
      expect(decision.key).to eq(public_key)
      expect(decision.policy).to eq(public_policy)
      expect(decision.lookup.now).to eq(store.now)
      expect(walk.calls).to eq([[query]])
    end

    it "hands the engine to a keyer that takes it" do
      gate.([build], engine: :next)

      expect(keyer.calls.last.last).to eq(engine: :next)
    end

    it "passes a query through with the walk's reason when the walk refuses it" do
      walk.answer(caching::Policy.refused(:undeclared_field))
      decision = gate.([build], engine: :interpreter).first

      expect(decision.reason).to eq(:undeclared_field)
      expect(operations).to be_empty
    end

    it "passes a query through with the keyer's reason when the keyer refuses it" do
      keyer.answer(caching::Policy.refused(:anonymous))
      decision = gate.([build], engine: :interpreter).first

      expect(decision.reason).to eq(:anonymous)
      expect(operations).to be_empty
    end

    it "passes a query through when the key's scope is not the policy's" do
      keyer.answer(viewer_key)
      decision = gate.([build], engine: :interpreter).first

      expect(decision.reason).to eq(:key_scope)
      expect(operations).to be_empty
    end
  end

  describe "storing a miss" do
    it "writes the sealed entry under the key digest with digested tags, the lookup's seq, epoch and clock" do
      query = build
      decision = gate.([query], engine: :interpreter).first
      verdict = gate.store(query, decision, result_for(query))

      expect(verdict).to eq(:stored)
      write = store.calls.find { |operation, _, _| operation == :write }
      expected_tags = public_policy.tags.map { |tag| digester.(tag) }.sort
      expect(write[1]).to eq(public_key.digest)
      expect(write[2]).to eq(tags: expected_tags, ttl: 60, seq: decision.lookup.seq, epoch: decision.lookup.epoch, stored_at: decision.lookup.now)
      entry = caching::Entry.parse(store.blobs.fetch(public_key.digest))
      expect([entry.key, entry.data, entry.scope, entry.ttl, entry.cost]).to eq([public_key.digest, data, :public, 60, nil])
      expect(codec.calls).to include([:encode, public_key.digest])
    end

    it "adds the viewer tag of a :viewer key to the entry's tags" do
      walk.answer(viewer_policy)
      keyer.answer(viewer_key)

      expect(fill(gate(viewer_key: :current_user))).to eq(:stored)
      write = store.calls.find { |operation, _, _| operation == :write }
      expect(write[2][:tags]).to contain_exactly(digester.(caching::Tags.type("Invoice")), viewer_tag)
    end

    it "caps the TTL at max_ttl, and a :viewer TTL at max_viewer_ttl" do
      walk.answer(caching::Policy.cacheable(ttl: 7200, scope: :public))
      expect(fill(gate(max_ttl: 600))).to eq(:stored)
      expect(store.calls.last[2][:ttl]).to eq(600)

      walk.answer(caching::Policy.cacheable(ttl: 1000, scope: :viewer))
      keyer.answer(viewer_key)
      expect(fill(gate(viewer_key: :current_user, max_viewer_ttl: 120))).to eq(:stored)
      expect(store.calls.last[2][:ttl]).to eq(120)
    end

    it "records the run's cost in the entry when a Points limiter is installed" do
      expect(fill(gate(recorded_cost: ->(_query) { 7 }))).to eq(:stored)

      expect(caching::Entry.parse(store.blobs.fetch(public_key.digest)).cost).to eq(7)
    end

    it "reports :stored with its scope and TTL, and writes the controller's record" do
      query = build
      cache = gate
      cache.store(query, cache.([query], engine: :interpreter).first, result_for(query))

      expect(signals(:cache_stored)).to eq([{ scope: :public, ttl: 60 }])
      expect(query.context[:response_cache]).to eq(status: :stored, reason: nil, scope: :public, ttl: 60, age: nil)
      expect(caching::RecordKeys.record(query.context)).to eq(query.context[:response_cache])
    end

    it "does not record its own write of the controller's record as a context write" do
      query = build
      cache = gate
      cache.store(query, cache.([query], engine: :interpreter).first, result_for(query))

      expect(caching::RecordKeys.recorder(query.context).writes.map(&:first)).not_to include(:response_cache)
    end

    it "answers the decision's reason, and writes nothing, for a pass or a hit" do
      query = build(persisted: false)
      decision = gate.([query], engine: :interpreter).first

      expect(gate.store(query, decision, result_for(query))).to eq(:not_persisted)
      expect(operations).not_to include(:write)
    end
  end

  describe "store-time checks" do
    def refused(values = { "data" => data }, cache: gate, **build_options)
      verdict = fill(cache, values, **build_options)
      expect(operations).not_to include(:write)
      verdict
    end

    it "skips a response with errors (:errors)" do
      expect(refused({ "data" => data, "errors" => [{ "message" => "boom" }] })).to eq(:errors)
      expect(signals(:cache_skipped)).to eq([{ reason: :errors }])
    end

    it "skips a response whose data is nil or not a Hash (:no_data)" do
      expect(refused({ "data" => nil })).to eq(:no_data)
    end

    it "skips data that is not JSON-native (:non_json_data)" do
      [{ "a" => :sym }, { "a" => Time.at(0) }, { "a" => Float::NAN }, { "a" => Float::INFINITY }, { "a" => { b: 1 } }, { "a" => [Object.new] }].each do |bad|
        store.calls.clear
        expect(refused({ "data" => bad })).to eq(:non_json_data)
      end
    end

    it "stores JSON-native data of every kind" do
      native = { "s" => "x", "i" => 1, "f" => 1.5, "t" => true, "n" => nil, "a" => [1, { "b" => false }] }

      expect(fill(gate, { "data" => native })).to eq(:stored)
    end

    it "skips a response with extensions other than the limiters' rateLimit (:extensions)" do
      expect(refused({ "data" => data, "extensions" => { "rateLimit" => { "cost" => 1 }, "trace" => {} } })).to eq(:extensions)
    end

    it "stores a response whose only extension is rateLimit, and never stores the extension" do
      expect(fill(gate, { "data" => data, "extensions" => { "rateLimit" => { "remaining" => 9 } } })).to eq(:stored)

      expect(store.blobs.fetch(public_key.digest)).not_to include("rateLimit")
    end

    it "skips a run in which a rescue_from handler answered (:rescued)" do
      query = build
      decision = gate.([query], engine: :interpreter).first
      caching::RecordKeys.rescued!(query.context)

      expect(gate.store(query, decision, result_for(query))).to eq(:rescued)
      expect(operations).not_to include(:write)
    end

    it "skips a run that read an uncovered context key (:context_read), naming the key" do
      query = build
      decision = gate.([query], engine: :interpreter).first
      query.context[:locale]

      expect(gate.store(query, decision, result_for(query))).to eq(:context_read)
      expect(signals(:cache_skipped)).to eq([{ reason: :context_read, key: :locale }])
    end

    it "skips a run that read the whole context (:context_read without a key name)" do
      query = build
      decision = gate.([query], engine: :interpreter).first
      caching::RecordKeys.recorder(query.context).read_all

      expect(gate.store(query, decision, result_for(query))).to eq(:context_read)
      expect(signals(:cache_skipped)).to eq([{ reason: :context_read }])
    end

    it "skips a run without a recorder: nothing it read can be checked" do
      plain = caching::Controls::Schema.example
      query = plain.query_class.new(plain, nil, context: caching::Controls::Context.example(operation: "names"))
      caching::RecordKeys.guard_built!(query.context)
      caching::RecordKeys.persisted!(query.context)
      decision = gate.([query], engine: :interpreter).first

      expect(gate.store(query, decision, result_for(query))).to eq(:context_read)
    end

    it "skips a run that wrote a key it had read (:context_written), naming the key" do
      query = build
      decision = gate.([query], engine: :interpreter).first
      query.context[:request_id]
      query.context[:request_id] = "changed"

      expect(gate(neutral_keys: { request_id: "logging only" }).store(query, decision, result_for(query))).to eq(:context_written)
      expect(signals(:cache_skipped)).to eq([{ reason: :context_written, key: :request_id }])
    end

    it "skips a run that wrote a covered key (:context_written)" do
      query = build
      cache = gate(vary_keys: [:locale])
      decision = cache.([query], engine: :interpreter).first
      query.context[:locale] = "fr"

      expect(cache.store(query, decision, result_for(query))).to eq(:context_written)
    end

    it "stores a run that read a key it wrote first" do
      query = build
      decision = gate.([query], engine: :interpreter).first
      query.context[:passed_down] = 1
      query.context[:passed_down]

      expect(gate.store(query, decision, result_for(query))).to eq(:stored)
    end

    it "covers the viewer key for a :viewer key only" do
      walk.answer(viewer_policy)
      keyer.answer(viewer_key)
      query = build
      cache = gate(viewer_key: :current_user)
      decision = cache.([query], engine: :interpreter).first
      query.context[:current_user]
      expect(cache.store(query, decision, result_for(query))).to eq(:stored)

      walk.answer(public_policy)
      keyer.answer(public_key)
      query = build
      decision = cache.([query], engine: :interpreter).first
      query.context[:current_user]
      expect(cache.store(query, decision, result_for(query))).to eq(:context_read)
    end

    it "covers the vary: context keys, the neutral keys, graphql-ruby's machinery keys and the keys whose absence was checked" do
      query = build
      cache = gate(vary_keys: [:locale], neutral_keys: { request_id: "logging only" })
      decision = cache.([query], engine: :interpreter).first
      [:locale, :request_id, :current_path, :trace, :dataloader, :visibility_profile, :__graphql_execute_next, :armory_full_schema, :current_ability].each { |key| query.context[key] }

      expect(cache.store(query, decision, result_for(query))).to eq(:stored)
    end

    it "skips a :public run in which a policy was consulted (:policy_consulted)" do
      query = build
      decision = gate.([query], engine: :interpreter).first
      caching::RecordKeys.viewer_dependent!(query.context)

      expect(gate.store(query, decision, result_for(query))).to eq(:policy_consulted)
    end

    it "stores a :viewer run in which a policy was consulted" do
      walk.answer(viewer_policy)
      keyer.answer(viewer_key)
      query = build
      cache = gate(viewer_key: :current_user)
      decision = cache.([query], engine: :interpreter).first
      caching::RecordKeys.viewer_dependent!(query.context)

      expect(cache.store(query, decision, result_for(query))).to eq(:stored)
    end

    it "skips a run with no recorded cost when a Points limiter is installed (:cost_unknown)" do
      expect(refused(cache: gate(recorded_cost: ->(_query) {}))).to eq(:cost_unknown)
    end

    it "skips an entry larger than max_entry_bytes (:too_large)" do
      expect(refused({ "data" => { "big" => "x" * 2_000 } }, cache: gate(max_entry_bytes: 1_000))).to eq(:too_large)
    end

    it "skips a run that ended more than max_ttl after its lookup, on the store clock (:run_too_long)" do
      query = build
      cache = gate(max_ttl: 60)
      decision = cache.([query], engine: :interpreter).first
      store.now += 60_001

      expect(cache.store(query, decision, result_for(query))).to eq(:run_too_long)
      expect(operations).not_to include(:write)
    end

    it "skips a write the store refused, as after a purge landed during the run (:write_refused)" do
      query = build
      decision = gate.([query], engine: :interpreter).first
      store.purge([digester.(caching::Tags.custom("catalog"))])

      expect(gate.store(query, decision, result_for(query))).to eq(:write_refused)
      expect(store.blobs).to be_empty
      expect(query.context[:response_cache]).to include(status: :skipped, reason: :write_refused)
    end
  end

  describe "a hit" do
    let(:cache_gate) { gate }

    def hit_query(cache = cache_gate, engine: :interpreter)
      query = build
      [query, cache.([query], engine: engine).first]
    end

    it "answers the cached data as a Result remembered on the query, charges the recorded cost and reports :cache_hit" do
      expect(fill(gate(recorded_cost: ->(_query) { 4 }))).to eq(:stored)
      store.now += 12_000
      query, decision = hit_query(gate(recorded_cost: ->(_query) { 4 }))

      expect(decision).to be_hit
      result = caching::RecordKeys.hit_result(query.context)
      expect(result).to be_a(GraphQL::Query::Result)
      expect(result.query).to equal(query)
      expect(result.to_h).to eq("data" => data)
      expect(charge.calls).to eq([[query, 4]])
      expect(signals(:cache_hit)).to eq([{ scope: :public }])
      expect(query.context[:response_cache]).to eq(status: :hit, reason: nil, scope: :public, ttl: 60, age: 12)
    end

    it "adds the extensions the charge set, and the cache extension when extensions: true" do
      fill(gate)
      query = build
      query.context.response_extensions["rateLimit"] = { "remaining" => 3 }
      gate(extensions: true).([query], engine: :interpreter)

      expect(caching::RecordKeys.hit_result(query.context).to_h)
        .to eq("data" => data, "extensions" => { "rateLimit" => { "remaining" => 3 }, "cache" => { "hit" => true, "age" => 0 } })
    end

    it "answers the limiter's refusal, and nothing from the cache, when the client is over budget" do
      fill(gate)
      refusal = GraphQL::AnalysisError.new("Rate limit exceeded", extensions: { "code" => "RATE_LIMITED" })
      charge.refuse_with(refusal)
      query, decision = hit_query

      expect(decision).to be_hit
      values = caching::RecordKeys.hit_result(query.context).to_h
      expect(values).not_to have_key("data")
      expect(values["errors"].first["extensions"]).to eq("code" => "RATE_LIMITED")
      expect(query.context[:response_cache]).to include(status: :hit, reason: :rate_limited)
    end

    it "answers a refusal the charge gives as a Result or a Hash as it is" do
      fill(gate)
      charge.refuse_with({ "errors" => [{ "message" => "limited" }] })
      query, = hit_query

      expect(caching::RecordKeys.hit_result(query.context).to_h).to eq("errors" => [{ "message" => "limited" }])
    end

    it "answers a hit and the queries around it in the order given" do
      fill(gate)
      queries = [build(persisted: false), build, build(persisted: false)]

      expect(gate.(queries, engine: :interpreter).map(&:kind)).to eq(%i[pass hit pass])
      expect(caching::RecordKeys.hit_result(queries[1].context).to_h).to eq("data" => data)
      expect(caching::RecordKeys.hit_result(queries[0].context)).to be_nil
    end

    it "is not stored again" do
      fill(gate)
      query, decision = hit_query

      expect(gate.store(query, decision, result_for(query))).to eq(:hit)
      expect(operations.count(:write)).to eq(1)
    end
  end
end
