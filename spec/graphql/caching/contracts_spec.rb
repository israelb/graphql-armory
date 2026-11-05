# frozen_string_literal: true

require "spec_helper"

RSpec.describe "GraphQL::Armory::Caching contracts" do
  let(:caching) { GraphQL::Armory::Caching }
  let(:hex) { "a" * 64 }
  let(:other_hex) { "b" * 64 }

  describe "values" do
    it "builds a frozen cacheable Policy and a refused one" do
      policy = caching::Policy.cacheable(ttl: 60, scope: :public, tags: %w[pricing catalog pricing])
      refused = caching::Policy.refused(:undeclared_field)

      expect(policy).to be_frozen
      expect(policy).to be_cacheable
      expect(policy.tags).to eq(%w[catalog pricing])
      expect(refused).not_to be_cacheable
      expect(refused.reason).to eq(:undeclared_field)
    end

    it "refuses a cacheable Policy without a TTL or scope, and a refused one without a reason" do
      expect { caching::Policy.cacheable(ttl: 0, scope: :public) }.to raise_error(ArgumentError)
      expect { caching::Policy.cacheable(ttl: 60, scope: :everyone) }.to raise_error(ArgumentError)
      expect { caching::Policy.refused("errors") }.to raise_error(ArgumentError)
    end

    it "keeps a Key's digest out of inspect" do
      key = caching::Key.new(digest: hex, scope: :viewer, viewer_tag: other_hex)

      expect(key).to be_frozen
      expect(key.inspect).not_to include(hex)
      expect { caching::Key.new(digest: "nothex", scope: :public) }.to raise_error(ArgumentError)
      expect { caching::Key.new(digest: hex, scope: :public, viewer_tag: other_hex) }.to raise_error(ArgumentError)
    end

    it "round-trips an Entry through JSON, frozen all the way down" do
      entry = caching::Entry.new(key: hex, data: { "products" => [{ "name" => "Lamp" }] }, stored_at: 5_000, ttl: 60,
                                 scope: :public, seq: 3, epoch: "e1", tags: [other_hex], cost: 4)
      parsed = caching::Entry.parse(entry.to_json_string)

      expect(parsed.data).to eq(entry.data)
      expect([parsed.key, parsed.stored_at, parsed.ttl, parsed.scope, parsed.seq, parsed.epoch, parsed.tags, parsed.cost])
        .to eq([hex, 5_000, 60, :public, 3, "e1", [other_hex], 4])
      expect(parsed.data["products"].first["name"]).to be_frozen
      expect(parsed.expires_at).to eq(65_000)
      expect(parsed.expired?(65_000)).to be(true)
      expect(parsed.age(17_500)).to eq(12)
    end

    it "rejects anything that is not an entry of this format as :format" do
      ["not json", "[]", JSON.generate({ "v" => 1 }), JSON.generate({ "v" => 2, "scope" => "public", "k" => "short" }), nil].each do |blob|
        expect { caching::Entry.parse(blob) }.to raise_error(caching::Entry::Rejected) { |error| expect(error.reason).to eq(:format) }
      end
    end

    it "builds Lookups and Decisions only from valid parts" do
      lookup = caching::Lookup.miss(seq: 0, epoch: "e1", now: 1)
      key = caching::Key.new(digest: hex, scope: :public)
      policy = caching::Policy.cacheable(ttl: 60, scope: :public)

      expect(lookup).not_to be_found
      expect(caching::Decision.miss(key, policy, lookup)).to be_miss
      expect(caching::Decision.pass(:mutation)).to be_pass
      expect { caching::Decision.miss(key, caching::Policy.refused(:errors), lookup) }.to raise_error(ArgumentError)
      expect { caching::Decision.hit(nil) }.to raise_error(ArgumentError)
      expect { caching::Lookup.miss(seq: -1, epoch: "e1", now: 1) }.to raise_error(ArgumentError)
    end
  end

  describe "Store::Null" do
    it "caches nothing" do
      store = caching::Store::Null.new

      expect(store.write(hex, "blob", tags: [], ttl: 60, seq: 0, epoch: "null", stored_at: 0)).to be(false)
      expect(store.lookup(hex)).not_to be_found
    end
  end

  describe "Store::Substitute" do
    subject(:store) { caching::Store::Substitute.new(now: 10_000) }

    def write(store, lookup, tags: [], ttl: 60, key: "a" * 64)
      store.write(key, "blob", tags: tags, ttl: ttl, seq: lookup.seq, epoch: lookup.epoch, stored_at: lookup.now)
    end

    it "answers a written blob until its TTL ends, with its tags and their marks" do
      lookup = store.lookup(hex)
      expect(write(store, lookup, tags: [other_hex])).to be(true)

      found = store.lookup(hex)
      expect([found.blob, found.tags, found.marks]).to eq(["blob", [other_hex], {}])
      store.now = 70_000
      expect(store.lookup(hex)).not_to be_found
    end

    it "refuses a write after a purge of one of its tags landed" do
      lookup = store.lookup(hex)
      seq = store.purge([other_hex])

      expect(seq).to eq(lookup.seq + 1)
      expect(write(store, lookup, tags: [other_hex])).to be(false)
      expect(write(store, lookup, tags: ["c" * 64])).to be(true)
    end

    it "answers the marks of an entry purged after it was written" do
      write(store, store.lookup(hex), tags: [other_hex])
      store.purge([other_hex])

      expect(store.lookup(hex).marks).to eq(other_hex => 1)
    end

    it "refuses a write from before purge_all" do
      lookup = store.lookup(hex)
      store.purge_all

      expect(write(store, lookup)).to be(false)
    end

    it "treats a lost meta record as everything purged" do
      lookup = store.lookup(hex)
      store.reset!

      expect(write(store, lookup)).to be(false)
      expect(store.lookup(hex).epoch).not_to eq(lookup.epoch)
    end

    it "refuses a write whose seq is ahead of the store's" do
      store.purge(["c" * 64])
      lookup = store.lookup(hex)
      store.rewind_seq(0)

      expect(write(store, lookup)).to be(false)
    end

    it "refuses a write that is already expired" do
      lookup = store.lookup(hex)
      store.now += 61_000

      expect(write(store, lookup)).to be(false)
    end

    it "records calls, fails when told and answers what it is told" do
      store.lookup(hex)
      store.fail_with(IOError.new("down"), on: :write, times: 1)
      lookup = store.lookup(hex)

      expect { write(store, lookup) }.to raise_error(IOError)
      expect(write(store, lookup)).to be(true)
      store.answer(:purge, 99)
      expect(store.purge([])).to eq(99)
      expect(store.calls.map(&:first)).to eq(%i[lookup lookup write write purge])
    end
  end

  describe "Recorder" do
    it "Null reports the whole context uncovered" do
      expect(caching::Recorder::Null.new.uncovered([:locale])).to eq([:all])
    end

    it "Substitute reports uncovered reads, ignores reads of keys the query wrote first, and forbids writes to read or covered keys" do
      recorder = caching::Recorder::Substitute.new
      recorder.read(:locale)
      recorder.read(:flags)
      recorder.write(:passed_down)
      recorder.read(:passed_down)
      recorder.write(:flags)
      recorder.write(:tenant)
      recorder.neutral { recorder.read(:request_id) }

      expect(recorder.uncovered([:locale])).to eq([:flags])
      expect(recorder.forbidden_writes([:tenant])).to eq(%i[flags tenant])
      recorder.read_all
      expect(recorder.uncovered([])).to include(:all)
    end

    it "Substitute::Context records the reads of a real query's context" do
      schema = Class.new(GraphQL::Schema) do
        query(Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :ping, String, null: false
          def ping = context[:locale]
        end)
        context_class(GraphQL::Armory::Caching::Recorder::Substitute::Context)
      end
      query = GraphQL::Query.new(schema, "{ ping }", context: { locale: "en" })
      query.result

      recorder = caching::RecordKeys.recorder(query.context)
      expect(recorder.read?(:locale)).to be(true)
    end
  end

  describe "Caching.neutral" do
    it "yields on a plain Hash and on nil" do
      expect(caching.neutral({}) { :ran }).to eq(:ran)
      expect(caching.neutral(nil) { :ran }).to eq(:ran)
    end

    it "records nothing inside the block on a recording context" do
      schema = Class.new(GraphQL::Schema) do
        query(Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :ping, String })
        context_class(GraphQL::Armory::Caching::Recorder::Substitute::Context)
      end
      context = GraphQL::Query.new(schema, "{ ping }", context: { request_id: "r1" }).context
      caching.neutral(context) { context[:request_id] }

      expect(caching::RecordKeys.recorder(context).read?(:request_id)).to be(false)
    end
  end

  describe "Digester" do
    it "answers a keyed hex digest, different per process key" do
      first = caching::Digester.new
      second = caching::Digester.new

      expect(first.("viewer:User:7")).to match(/\A\h{64}\z/)
      expect(first.("viewer:User:7")).to eq(first.("viewer:User:7"))
      expect(first.("viewer:User:7")).not_to eq(second.("viewer:User:7"))
    end

    it "builds from an encoder's mac" do
      encoder = Object.new
      def encoder.mac(bytes, purpose:) = OpenSSL::HMAC.digest("SHA256", purpose, bytes)

      expect(caching::Digester.build(encoder: encoder).("x")).to eq(OpenSSL::HMAC.hexdigest("SHA256", "cache-digest", "x"))
      expect { caching::Digester.build(encoder: Object.new) }.to raise_error(caching::ConfigurationError)
    end
  end

  describe "nulls and substitutes" do
    it "refuses everything when nothing is wired" do
      expect(caching::Walk::Null.new.(nil)).not_to be_cacheable
      expect(caching::Keyer::Null.new.(nil, nil)).not_to be_cacheable
      expect(caching::Charge::Null.new.(nil, 3)).to be_nil
    end

    it "Walk, Keyer and Codec Substitutes answer what they are told" do
      policy = caching::Policy.cacheable(ttl: 60, scope: :public)
      key = caching::Key.new(digest: hex, scope: :public)
      walk = caching::Walk::Substitute.new(policy)
      keyer = caching::Keyer::Substitute.new(key)
      codec = caching::Codec::Substitute.new
      entry = caching::Entry.new(key: hex, data: {}, stored_at: 0, ttl: 60, scope: :public, seq: 0, epoch: "e", tags: [])

      expect(walk.(:query)).to eq(policy)
      expect(keyer.(:query, policy)).to eq(key)
      expect(keyer.calls).to eq([[:query, policy]])
      expect(codec.decode(codec.encode(entry, hex), hex).key).to eq(hex)
      expect { codec.decode(codec.encode(entry, hex), other_hex) }.to raise_error(caching::Entry::Rejected) { |error| expect(error.reason).to eq(:key) }
      codec.reject_with(:decrypt)
      expect { codec.decode("x", hex) }.to raise_error(caching::Entry::Rejected) { |error| expect(error.reason).to eq(:decrypt) }
    end

    it "Charge::Substitute and Gate::Substitute answer what they are told and record what they saw" do
      charge = caching::Charge::Substitute.new
      charge.refuse_with(:over_budget)
      gate = caching::Gate::Substitute.new
      gate.decide(caching::Decision.pass(:mutation))

      expect(charge.(:query, 3)).to eq(:over_budget)
      expect(charge.calls).to eq([[:query, 3]])
      expect(gate.(%i[a b], engine: :interpreter).map(&:reason)).to eq(%i[mutation unconfigured])
      expect(gate.seen).to eq([[%i[a b], :interpreter]])
      expect(gate.store(:a, nil, nil)).to eq(:stored)
    end
  end

  describe "Controls" do
    it "builds a schema whose persisted catalog runs on the interpreter" do
      schema = caching::Controls::Schema.example
      result = schema.execute(context: caching::Controls::Context.example(operation: "catalog"))

      expect(result.to_h["data"]["products"].first).to eq("name" => "Lamp", "price" => { "amount" => 1200, "currency" => "EUR" })
    end

    it "runs the per-viewer operation through Authorization", if: ArmoryEngine.supported? do
      schema = caching::Controls::Schema.example
      result = schema.execute_next(context: caching::Controls::Context.example(operation: "invoices"))

      expect(result.to_h["data"]["invoices"].map { |invoice| invoice["number"] }).to eq(%w[A-1 A-2])
    end

    it "installs Caching with the real gate when given its options" do
      schema = caching::Controls::Schema.example(caching: { store: caching::Controls::Store.example, release: "test" })

      expect(schema.armory_caching.gate).to be_a(caching::Gate)
    end
  end
end

RSpec.describe "GraphQL::Armory::Caching shared contracts for parallel units" do
  let(:caching) { GraphQL::Armory::Caching }

  it "builds tags with a prefix per kind and a JSON-encoded viewer" do
    expect(caching::Tags.custom("pricing")).to eq("tag:pricing")
    expect(caching::Tags.type("Invoice")).to eq("type:Invoice")
    expect(caching::Tags.viewer("User", 7)).to eq('viewer:["User",7]')
    expect(caching::Tags.viewer("User", 7)).not_to eq(caching::Tags.viewer("AdminUser", 7))
    expect(caching::Tags.viewer("User", "7")).not_to eq(caching::Tags.viewer("User", 7))
    expect { caching::Tags.viewer("User", nil) }.to raise_error(ArgumentError)
    expect { caching::Tags.custom("") }.to raise_error(ArgumentError)
  end

  it "wraps a context class once, and a wrapper not again" do
    klass = Class.new(GraphQL::Query::Context)
    wrapper = caching::Recorder::Context.wrap(klass)

    expect(wrapper.superclass).to be(klass)
    expect(caching::Recorder::Context.wrap(klass)).to be(wrapper)
    expect(caching::Recorder::Context.wrap(wrapper)).to be(wrapper)
  end

  it "marks queries the guard built" do
    schema = Class.new(GraphQL::Schema) { query(Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :ping, String }) }
    context = GraphQL::Query.new(schema, "{ ping }").context

    expect(caching::RecordKeys.guard_built?(context)).to be(false)
    caching::RecordKeys.guard_built!(context)
    expect(caching::RecordKeys.guard_built?(context)).to be(true)
    expect(caching::RecordKeys.guard_built?({})).to be(false)
  end
end

RSpec.describe "GraphQL::Armory::Caching values on every supported Ruby" do
  it "uses no Data classes (Ruby 3.1 has none) and freezes every value" do
    caching = GraphQL::Armory::Caching
    sources = Dir[File.expand_path("../../../lib/graphql/armory/caching/**/*.rb", __dir__)].map { |file| File.read(file) }

    expect(sources.grep(/\bData\.define\b/)).to be_empty
    expect(caching::Policy.refused(:x)).to be_frozen
    expect(caching::Lookup.miss(seq: 0, epoch: "e", now: 0)).to be_frozen
    expect(caching::Decision.pass(:x)).to be_frozen
    expect { caching::Decision.pass(:x).reason = :y }.to raise_error(FrozenError)
  end
end

RSpec.describe GraphQL::Armory::Caching::RecordKeys do
  it "reads without leaving empty namespaces on a query that has none" do
    schema = Class.new(GraphQL::Schema) { query(Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :ping, String }) }
    context = GraphQL::Query.new(schema, "{ ping }").context
    keys = described_class

    expect([keys.recorder(context), keys.persisted?(context), keys.viewer_dependent?(context), keys.rescued?(context),
            keys.guard_built?(context), keys.hit_result(context), keys.record(context)]).to eq([nil, false, false, false, false, nil, nil])
    expect(%i[armory armory_cache graphql_armory].map { |name| context.namespace?(name) }).to eq([false, false, false])
  end
end

RSpec.describe GraphQL::Armory::Caching::Digester do
  it "fails at build, not on the first request, when the encoder cannot digest" do
    encoder = Object.new
    def encoder.mac(_bytes, purpose:) = raise(GraphQL::Armory::Caching::ConfigurationError, "cannot digest")

    expect { described_class.build(encoder: encoder) }.to raise_error(GraphQL::Armory::Caching::ConfigurationError, /cannot digest/)
  end
end
