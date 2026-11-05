# frozen_string_literal: true

require "spec_helper"
require "graphql/armory/caching/gate"

# What the gate never does: look up a query that must not be served from the store, serve an entry that fails a
# check, serve anything when the store fails, or put a key, viewer, variable, operation or tag in a signal.
RSpec.describe "GraphQL::Armory::Caching::Gate security" do
  let(:caching) { GraphQL::Armory::Caching }
  let(:schema) { caching::Controls::Schema.example.tap { |built| built.context_class(caching::Recorder::Substitute::Context) } }
  let(:store) { caching::Controls::Store.example }
  let(:telemetry) { GraphQL::Armory::Telemetry::Substitute.new }
  let(:digester) { caching::Digester.new }
  let(:codec) { caching::Codec::Substitute.new }
  let(:charge) { caching::Charge::Substitute.new }
  let(:policy) { caching::Policy.cacheable(ttl: 60, scope: :public, tags: [caching::Tags.custom("catalog"), caching::Tags.type("Product")]) }
  let(:key) { caching::Key.new(digest: "a" * 64, scope: :public) }
  let(:walk) { caching::Walk::Substitute.new(policy) }
  let(:keyer) { caching::Keyer::Substitute.new(key) }
  let(:data) { { "products" => [{ "name" => "Lamp" }] } }
  let(:store_errors) { [] }
  let(:gate) do
    caching::Gate.new(store: store, walk: walk, keyer: keyer, codec: codec, charge: charge, telemetry: telemetry, digester: digester,
                      on_store_error: ->(error, query) { store_errors << [error.class, query] })
  end

  def build(operation: "names", context: nil, mark: true, persisted: true, query_class: schema.query_class, **options)
    context ||= caching::Controls::Context.example(operation: operation)
    query = query_class.new(schema, nil, context: context, **options)
    caching::RecordKeys.guard_built!(query.context) if mark
    caching::RecordKeys.persisted!(query.context) if persisted
    query
  end

  # A query on a document of its own, built without PersistedQueries and marked as if it had been admitted.
  def raw(document)
    query = GraphQL::Query.new(schema, document, context: caching::Controls::Context.example)
    caching::RecordKeys.guard_built!(query.context)
    caching::RecordKeys.persisted!(query.context)
    query
  end

  def decide(*queries)
    gate.(queries, engine: :interpreter)
  end

  def signals(name)
    telemetry.recorded.select { |signal, _| signal == name }.map(&:last)
  end

  def fill
    query = build
    decision = decide(query).first
    expect(gate.store(query, decision, GraphQL::Query::Result.new(query: query, values: { "data" => data }))).to eq(:stored)
    store.calls.clear
    telemetry.recorded.clear
  end

  describe "admission: these queries are never looked up" do
    def never_looked_up(query, reason, *others)
      decisions = decide(query, *others)

      expect(decisions.first).to be_pass
      expect(decisions.first.reason).to eq(reason)
      expect(store.calls).to be_empty
      expect(walk.calls).to be_empty
      expect(signals(:cache_skipped).first).to eq(reason: reason)
      expect(caching::RecordKeys.hit_result(query.context)).to be_nil
    end

    it "a query the guard did not build (:built_query)" do
      never_looked_up(build(mark: false), :built_query)
    end

    it "an app-built Query::Partial (:built_query)" do
      skip "no Query::Partial in this graphql" unless defined?(GraphQL::Query::Partial)

      full = build
      partial = GraphQL::Query::Partial.new(path: ["products"], object: nil, query: full)

      expect(decide(partial).first.reason).to eq(:built_query)
    end

    it "a mutation (:mutation)" do
      never_looked_up(build(operation: "touch"), :mutation)
    end

    it "every query of a call that holds a mutation (:multiplex_mutation)" do
      decisions = decide(build, build(operation: "touch"), build(operation: "catalog"))

      expect(decisions.map(&:reason)).to eq(%i[multiplex_mutation mutation multiplex_mutation])
      expect(store.calls).to be_empty
    end

    it "a mutation the app built itself still sends every query of the call through" do
      app_built = build(operation: "touch", mark: false)

      expect(decide(build, app_built).map(&:reason)).to eq(%i[multiplex_mutation built_query])
      expect(store.calls).to be_empty
    end

    it "a subscription (:subscription)" do
      never_looked_up(raw("subscription Ticks { touch }"), :subscription)
    end

    it "a query PersistedQueries refused (:refused)" do
      never_looked_up(build(context: { operation_id: "nope" }), :refused)
    end

    it "a query with an app-supplied static_validator (:refused)" do
      validator = GraphQL::StaticValidation::Validator.new(schema: schema)

      never_looked_up(build(static_validator: validator), :refused)
    end

    it "a query with root_value: or validate: false (:options)" do
      never_looked_up(build(root_value: Object.new), :options)
      never_looked_up(build(validate: false), :options)
    end

    it "a query whose visibility profile the app turned off (:options)" do
      skip "no Schema::Visibility in this graphql" unless defined?(GraphQL::Schema::Visibility)

      schema.use(GraphQL::Schema::Visibility)
      expect(decide(build).first).to be_miss
      store.calls.clear
      walk.calls.clear
      telemetry.recorded.clear

      never_looked_up(build(use_visibility_profile: false), :options)
    end

    it "a query PersistedQueries did not mark persisted, even with an operation_id in its context (:not_persisted)" do
      never_looked_up(build(persisted: false), :not_persisted)
    end

    it "a context holding armory_full_schema (:full_schema), even when false" do
      never_looked_up(build(context: caching::Controls::Context.example(operation: "names", armory_full_schema: true)), :full_schema)
      store.calls.clear
      telemetry.recorded.clear
      never_looked_up(build(context: caching::Controls::Context.example(operation: "names").merge(armory_full_schema: false)), :full_schema)
    end

    it "a context holding current_ability (:current_ability)" do
      never_looked_up(build(context: caching::Controls::Context.example(operation: "names", current_ability: Object.new)), :current_ability)
    end

    it "checks armory_full_schema and current_ability without recording them as the run's reads" do
      query = build
      decide(query)

      expect(caching::RecordKeys.recorder(query.context).reads).not_to include(:armory_full_schema, :current_ability)
    end
  end

  describe "an entry that fails a check is never served: the query runs and its answer may replace it" do
    def rejected(reason)
      query = build
      decision = decide(query).first

      expect(decision).to be_miss
      expect(caching::RecordKeys.hit_result(query.context)).to be_nil
      expect(signals(:cache_entry_rejected)).to eq([{ reason: reason }])
      expect(charge.calls).to be_empty
      decision
    end

    before { fill }

    it "expired at the lookup's clock (:expired)" do
      entry = caching::Entry.parse(store.blobs.fetch(key.digest))
      store.poison(key.digest, caching::Entry.new(key: key.digest, data: data, stored_at: store.now - 61_000, ttl: 60, scope: :public,
                                                  seq: entry.seq, epoch: entry.epoch, tags: entry.tags).to_json_string, tags: entry.tags)

      rejected(:expired)
    end

    it "stored under another epoch: the store lost its meta record (:epoch)" do
      store.reset!

      rejected(:epoch)
    end

    it "stored at a seq the store no longer reached: a replica that lost increments (:epoch)" do
      store.purge_all
      store.purge(["f" * 64])
      store.purge(["f" * 64])
      query = build
      decision = decide(query).first
      expect(decision).to be_miss
      gate.store(query, decision, GraphQL::Query::Result.new(query: query, values: { "data" => data }))
      store.rewind_seq(0)
      telemetry.recorded.clear

      rejected(:epoch)
    end

    it "carrying a tag purged after it was stored (:purged)" do
      store.purge([digester.(caching::Tags.type("Product"))])

      rejected(:purged)
    end

    it "whose companion tag list in the store differs from its sealed one (:tags)" do
      blob = store.blobs.fetch(key.digest)
      store.poison(key.digest, blob, tags: [digester.(caching::Tags.custom("catalog"))])

      rejected(:tags)
    end

    it "moved under another key (:key)" do
      blob = store.blobs.fetch(key.digest)
      other = caching::Key.new(digest: "c" * 64, scope: :public)
      store.poison(other.digest, blob, tags: caching::Entry.parse(blob).tags)
      keyer.answer(other)

      rejected(:key)
    end

    it "that the codec cannot open (:decrypt)" do
      codec.reject_with(:decrypt)

      rejected(:decrypt)
    end

    it "that is not an entry at all (:format)" do
      store.poison(key.digest, "\x00not json")

      rejected(:format)
    end

    it "with no recorded cost while a Points limiter is installed: a hit would be free (:cost_unknown)" do
      gate_with_points = caching::Gate.new(store: store, walk: walk, keyer: keyer, codec: codec, charge: charge, telemetry: telemetry,
                                           digester: digester, recorded_cost: ->(_query) { 3 })
      query = build

      expect(gate_with_points.([query], engine: :interpreter).first).to be_miss
      expect(signals(:cache_entry_rejected)).to eq([{ reason: :cost_unknown }])
      expect(charge.calls).to be_empty
    end
  end

  describe "a store that fails opens to computing, never to serving" do
    it "runs the query uncached when the lookup raises, and reports the operation and the error class only" do
      store.fail_with(IOError.new("redis://user:secret@cache"), on: :lookup)
      query = build
      decision = decide(query).first

      expect(decision).to be_pass
      expect(decision.reason).to eq(:store_failed)
      expect(store_errors).to eq([[IOError, query]])
      expect(signals(:cache_store_failed)).to eq([{ operation: :lookup, error: "IOError" }])
      expect(query.context[:response_cache]).to include(status: :skipped, reason: :store_failed)
    end

    it "answers :store_failed when the write raises, and the query's answer stands" do
      store.fail_with(IOError.new("secret"), on: :write)
      query = build
      decision = decide(query).first

      expect(gate.store(query, decision, GraphQL::Query::Result.new(query: query, values: { "data" => data }))).to eq(:store_failed)
      expect(store_errors).to eq([[IOError, query]])
      expect(signals(:cache_store_failed)).to eq([{ operation: :write, error: "IOError" }])
    end

    it "keeps going when on_store_error itself raises" do
      store.fail_with(IOError.new("down"), on: :lookup)
      failing = caching::Gate.new(store: store, walk: walk, keyer: keyer, codec: codec, telemetry: telemetry, digester: digester,
                                  on_store_error: ->(_error, _query) { raise "handler broke" })

      expect { expect(failing.([build], engine: :interpreter).first.reason).to eq(:store_failed) }.to output(/RuntimeError/).to_stderr
    end

    it "treats a lookup answer that is not a Lookup as a store failure" do
      store.answer(:lookup, { "blob" => "forged" })

      expect(decide(build).first.reason).to eq(:store_failed)
      expect(signals(:cache_store_failed)).to eq([{ operation: :lookup, error: "TypeError" }])
    end
  end

  describe "a shared answer" do
    it "is not stored from a :public run that consulted a policy, so a refused user never gets it" do
      query = build
      decision = decide(query).first
      caching::RecordKeys.viewer_dependent!(query.context)

      expect(gate.store(query, decision, GraphQL::Query::Result.new(query: query, values: { "data" => data }))).to eq(:policy_consulted)
      expect(store.blobs).to be_empty
      expect(decide(build).first).to be_miss
    end

    it "is not stored from a :public run that read the viewer, even when the viewer key is configured" do
      cache = caching::Gate.new(store: store, walk: walk, keyer: keyer, codec: codec, telemetry: telemetry, digester: digester, viewer_key: :current_user)
      query = build
      decision = cache.([query], engine: :interpreter).first
      query.context[:current_user]

      expect(cache.store(query, decision, GraphQL::Query::Result.new(query: query, values: { "data" => data }))).to eq(:context_read)
    end

    it "is never served to a query that was refused before running, even when its key holds an entry" do
      fill
      refused = build(context: { operation_id: "nope" })

      expect(decide(refused).first.reason).to eq(:refused)
      expect(store.calls).to be_empty
    end
  end

  describe "signals" do
    it "never carry a key digest, a viewer, a variable, an operation id or name, or a tag value" do
      store.fail_with(IOError.new("x"), on: :lookup, times: 1)
      context = caching::Controls::Context.example(operation: "product", locale: "secret-locale").merge(request_id: "rid-123")
      queries = [build(context: context, variables: { "name" => "SecretLamp" }), build(operation: "catalog")]
      decide(*queries)
      decision = decide(queries[1]).first
      gate.store(queries[1], decision, GraphQL::Query::Result.new(query: queries[1], values: { "data" => data }))
      decide(build(operation: "catalog"))
      queries[1].context[:locale]
      decide(build(persisted: false))
      store.reset!
      decide(build)

      dumped = [telemetry.recorded, queries.map { |query| query.context[:response_cache] }].inspect
      forbidden = [key.digest, "User", "7", "SecretLamp", "product", "Product", "catalog", "Catalog", "secret-locale", "rid-123",
                   *policy.tags, *policy.tags.map { |tag| digester.(tag) }]
      forbidden.each { |value| expect(dumped).not_to include(value) }
      expect(telemetry.recorded.map(&:first)).to include(:cache_store_failed, :cache_stored, :cache_hit, :cache_skipped, :cache_entry_rejected)
    end
  end
end
