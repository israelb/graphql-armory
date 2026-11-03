# frozen_string_literal: true

# Probes of the verification of issue #38 (the eight surfaces of `observe:` the PR #35 verification did not run), kept as
# regressions. Item 4 (the real graphql:install generator) is left out: loading rails/generators defines Rails without
# Rails.env, which breaks Schema::Visibility on graphql 2.4 for the rest of the process.
# Each `it` is labelled [security] or [preservation] and names its item.

require "securerandom"
require "tmpdir"
require "fileutils"
require "digest"

ProbeDoc = Struct.new(:id, :secret, :account_id) unless defined?(ProbeDoc)

# Answers by who asks: only the actors in `allowed` get a clear yes. Scopes nothing.
class ProbeAdapter
  def initialize(allowed: [:admin])
    @allowed = allowed
  end

  def actor(context) = context[:user]
  def authorized?(actor, _subject, _rule) = @allowed.include?(actor)
  def scope(_actor, items, _rule) = items
  def check(_type, _rule) = []
end

# Root values answer the root fields themselves, so both engines resolve them the same way.
class KeysetRoot
  def invoices = GraphQL::Armory::Keyset.build(Invoice.order(:id), plain_cursors: true)
end

class GenRoot
  def doc = $probe_doc
  def raising = $probe_doc
  def test_field = "Hello World!"
end

class CombinedRoot
  def invoices = Invoice.all
  def invoice_by_ref(invoice:) = invoice
end

# A minimal per-subscriber backend: every subscriber gets its own update, run with its own saved context.
class ProbeSubscriptions < GraphQL::Subscriptions
  attr_reader :deliveries, :queries

  def initialize(**rest)
    super
    @queries = {}
    @topics = Hash.new { |h, k| h[k] = [] }
    @deliveries = Hash.new { |h, k| h[k] = [] }
  end

  def write_subscription(query, events)
    id = query.context[:subscription_id] = build_id
    @queries[id] = query
    events.each { |event| @topics[event.topic] << id }
  end

  def read_subscription(id)
    query = @queries[id]
    return nil unless query

    { query_string: query.query_string, operation_name: query.operation_name, variables: query.provided_variables,
      context: { user: query.context[:user] } }
  end

  def execute_all(event, object)
    @topics[event.topic].each { |id| execute(id, event, object) }
  end

  def deliver(id, result)
    @deliveries[id] << result.to_h
  end

  def delete_subscription(id)
    @queries.delete(id)
  end
end

RSpec.describe "issue #38 probes: observe:" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:config_error) { armory::ConfigurationError }
  let(:signals) { [] }
  let(:sink) { ->(signal, data) { signals << [signal, data] } }
  let(:record) { ProbeDoc.new("1", "SECRET", 1) }
  let(:root) { Struct.new(:invoice, :thing, :doc).new(record, record, record) }
  let(:ran) { [] }

  let(:base_field) do
    plugin = armory
    Class.new(GraphQL::Schema::Field) { include plugin::Base }
  end
  let(:base_object) do
    plugin = armory
    field = base_field
    Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class field
    end
  end

  def resolver_counting(ran)
    Class.new(GraphQL::Schema::Resolver) do
      type String, null: true
      define_method(:resolve) { ran << :body; "RESOLVER RAN" }
    end
  end

  def root_query(type, extra: nil)
    Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :invoice, type, null: true, authorize: :none, reason: "x"
      class_eval(&extra) if extra
    end
  end

  def schema_with(query_type, adapter: ProbeAdapter.new, sinks: [sink], visibility: false, extra: nil)
    plugin = armory
    Class.new(ArmoryEngine.base_schema) do
      query query_type
      use GraphQL::Schema::Visibility, dynamic: true if visibility
      use plugin, adapter: adapter, sinks: sinks
      class_eval(&extra) if extra
    end
  end

  def run(schema, document, **context)
    execute_query(schema, document, root_value: root, context: context).to_h
  end

  def kinds = signals.map(&:first)

  # ---------------------------------------------------------------- item 1
  describe "item 1: a child that shadows its parent's resolver field" do
    def shapes(child_touch_options: {})
      r = resolver_counting(ran)
      parent = Class.new(base_object) do
        graphql_name "Parent"
        authorize :read, model: Object
        field :touch, resolver: r
      end
      opts = child_touch_options
      child = Class.new(parent) do
        graphql_name "Invoice"
        authorize :read, model: Object, observe: "rollout"
        field :touch, String, null: true, hash_key: :secret, **opts
        field :secret, String
      end
      [parent, child]
    end

    it "[security] item 1: r never runs through the child, by field, alias or fragment, for a refused user; data observed" do
      _parent, child = shapes
      response = run(schema_with(root_query(child)), "{ invoice { touch t2: touch ... on Invoice { touch } ...F } } fragment F on Invoice { touch secret }", user: :bob)

      expect(ran).to be_empty
      expect(response.to_s).not_to include("RESOLVER RAN")
      expect(response["errors"]).to be_nil
      expect(kinds).to include(:observed)
    end

    it "[security] item 1: r never runs through an interface the child implements" do
      r = resolver_counting(ran)
      iface = Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Touchable"
        field :touch, String, null: true
      end
      parent = Class.new(base_object) do
        graphql_name "Parent"
        authorize :read, model: Object
        field :touch, resolver: r
      end
      child = Class.new(parent) do
        graphql_name "Invoice"
        implements iface
        authorize :read, model: Object, observe: "rollout"
        field :touch, String, null: true, hash_key: :secret
      end
      query_type = root_query(child, extra: proc { field :thing, iface, null: true, authorize: :none, reason: "x" })
      schema = schema_with(query_type, extra: proc { define_singleton_method(:resolve_type) { |_a, _o, _c| child } })
      response = run(schema, "{ thing { touch ... on Invoice { touch } } }", user: :bob)

      expect(ran).to be_empty
      expect(response["errors"]).to be_nil
      expect(kinds).to include(:observed)
    end

    it "[security] item 1: r never runs when the override is hidden from the refused user (legacy Warden fallback)" do
      _parent, child = shapes(child_touch_options: { authorize: :manage, visible_when: :export })
      response = begin
        run(schema_with(root_query(child)), "{ invoice { touch secret } }", user: :bob)
      rescue GraphQL::Armory::Authorization::ConfigurationError => error
        { "raised" => error.message }
      end

      expect(ran).to be_empty, "r ran for a refused user; response: #{response.inspect}; signals: #{kinds.inspect}"
      expect(response["raised"]).to include("Invoice cannot be observed")
    end

    it "[security] item 1: r never runs when the override is hidden from the refused user (Schema::Visibility)" do
      _parent, child = shapes(child_touch_options: { authorize: :manage, visible_when: :export })
      response = run(schema_with(root_query(child), visibility: true), "{ invoice { touch secret } }", user: :bob)

      expect(ran).to be_empty, "r ran for a refused user; response: #{response.inspect}"
    end

    it "[security] item 1: the audit of the hidden-override shape is not ok, and says what it says" do
      _parent, child = shapes(child_touch_options: { authorize: :manage, visible_when: :export })
      report = armory::Audit.(schema_with(root_query(child)))
      observed = report.problems.select { |problem| problem.kind == :observed }
      $stdout.puts "[item 1 hidden override] audit observed: #{observed.map { |p| [p.path, p.message] }.inspect}"

      expect(report.ok?).to be(false)
      expect(observed.map(&:path)).to include("Invoice")
    end

    it "[security] item 1: the audit reports the child as :observed" do
      _parent, child = shapes
      report = armory::Audit.(schema_with(root_query(child)))
      observed = report.problems.select { |problem| problem.kind == :observed }

      expect(report.ok?).to be(false)
      expect(observed.map(&:path)).to include("Invoice")
    end

    it "[preservation] item 1: the parent's resolver still runs for an allowed user on the parent, not for a refused one" do
      parent, child = shapes
      query_type = root_query(child, extra: proc { field :doc, parent, null: true, authorize: :none, reason: "x" })
      schema = schema_with(query_type)

      allowed = run(schema, "{ doc { touch } }", user: :admin)
      expect(allowed.dig("data", "doc", "touch")).to eq("RESOLVER RAN")
      ran.clear
      refused = run(schema, "{ doc { touch } }", user: :bob)
      expect(refused.dig("data", "doc")).to be_nil
      expect(ran).to be_empty
    end
  end

  # ---------------------------------------------------------------- item 2
  describe "item 2: subscription delivery" do
    def subscription_schema
      sub = Class.new(GraphQL::Schema::Subscription)
      doc = Class.new(base_object) do
        graphql_name "Doc"
        authorize :read, model: Object, observe: "rollout"
        field :secret, String
      end
      sub.class_eval do
        graphql_name "DocChanged"
        type doc, null: true
        define_method(:subscribe) { object.doc }
      end
      subscription_type = Class.new(base_object) do
        graphql_name "Subscription"
        authorize :none, reason: "root", covers_fields: true
        field :doc_changed, subscription: sub
      end
      query_type = root_query(doc)
      schema_with(query_type, extra: proc {
        subscription subscription_type
        use ProbeSubscriptions
      })
    end

    def subscribe(schema, user)
      result = execute_query(schema, "subscription { docChanged { secret } }", root_value: root, context: { user: user })
      [result.to_h, result.context[:subscription_id]]
    end

    it "[security] item 2: an update does not serve the observed type to a refused subscriber" do
      schema = subscription_schema
      initial, id = subscribe(schema, :bob)
      expect(initial.dig("data", "docChanged")).to be_nil
      expect(id).not_to be_nil, "no subscription was written: #{initial.inspect}"
      signals.clear

      schema.subscriptions.trigger(:doc_changed, {}, ProbeDoc.new("2", "UPDATED SECRET", 1))
      delivered = schema.subscriptions.deliveries[id]

      expect(delivered.size).to eq(1)
      expect(delivered.first.dig("data", "docChanged")).to be_nil
      expect(delivered.to_s).not_to include("UPDATED SECRET")
      expect(kinds).not_to include(:observed)
    end

    it "[preservation] item 2: an allowed subscriber still gets the update" do
      schema = subscription_schema
      initial, id = subscribe(schema, :admin)
      expect(initial.dig("data", "docChanged", "secret")).to eq("SECRET")

      schema.subscriptions.trigger(:doc_changed, {}, ProbeDoc.new("2", "UPDATED SECRET", 1))
      expect(schema.subscriptions.deliveries[id].map { |r| r.dig("data", "docChanged", "secret") }).to eq(["UPDATED SECRET"])
    end
  end

  # ---------------------------------------------------------------- item 3
  describe "item 3: keyset connections" do
    let(:world) { Dummy::World.build }

    def keyset_schema(action: :manage)
      act = action
      doc = Class.new(base_object) do
        graphql_name "Invoice"
        authorize act, model: Invoice, observe: "rollout"
        field :number, String, null: false
      end
      query_type = Class.new(base_object) do
        graphql_name "Query"
        authorize :none, reason: "root", covers_fields: true
        field :invoices, doc.connection_type, null: false, authorize: :none, reason: "scoped"
      end
      plugin = armory
      sink = self.sink
      Class.new(ArmoryEngine.base_schema) do
        query query_type
        use plugin, adapter: :pundit, sinks: [sink]
      end
    end

    let(:doc) do
      <<~GRAPHQL
        query($first: Int, $after: String, $last: Int, $before: String) {
          invoices(first: $first, after: $after, last: $last, before: $before) {
            nodes { number }
            edges { cursor node { number } }
            pageInfo { hasNextPage hasPreviousPage endCursor startCursor }
          }
        }
      GRAPHQL
    end

    def page(schema, user, **variables)
      execute_query(schema, doc, variables: variables.transform_keys(&:to_s), root_value: KeysetRoot.new, context: { current_user: user }).to_h
    end

    def numbers(result)
      (result.dig("data", "invoices", "nodes") || []).map { |n| n["number"] } +
        (result.dig("data", "invoices", "edges") || []).map { |e| e.dig("node", "number") }
    end

    it "[security] item 3: rows still go through the scope on every page, forged cursors included, while the rule is observed" do
      schema = keyset_schema
      w = world
      first = page(schema, w.bob, first: 1)
      expect(first["errors"]).to be_nil
      expect(numbers(first).uniq).to eq(["B-1"])
      expect(first.dig("data", "invoices", "pageInfo", "hasNextPage")).to be(false)
      expect(kinds).to include(:observed) # bob is refused :manage on his own row: observed, served
      expect(kinds).to include(:scoped)

      second = page(schema, w.bob, first: 5, after: first.dig("data", "invoices", "pageInfo", "endCursor"))
      expect(numbers(second)).to be_empty

      alice_cursors = page(schema, w.alice, first: 5).dig("data", "invoices", "edges").map { |e| e["cursor"] }
      forged = page(schema, w.bob, first: 5, after: alice_cursors.first)
      expect(numbers(forged).uniq).to eq(["B-1"])
      backward = page(schema, w.bob, last: 5, before: page(schema, w.bob, first: 1).dig("data", "invoices", "pageInfo", "endCursor"))
      expect(numbers(backward)).to be_empty
      last = page(schema, w.bob, last: 5)
      expect(numbers(last).uniq).to eq(["B-1"])
    end

    it "[preservation] item 3: an allowed user pages their own rows through the keyset" do
      schema = keyset_schema(action: :read)
      first = page(schema, world.alice, first: 1)
      second = page(schema, world.alice, first: 1, after: first.dig("data", "invoices", "pageInfo", "endCursor"))

      expect([numbers(first).uniq, numbers(second).uniq]).to eq([["A-1"], ["A-2"]])
      expect(kinds).not_to include(:observed)
    end
  end

  # ---------------------------------------------------------------- item 5
  describe "item 5: Telemetry::Notifications with real ActiveSupport" do
    def observed_doc
      Class.new(base_object) do
        graphql_name "Invoice"
        authorize :read, model: Object, observe: "rollout of docs"
        field :secret, String
      end
    end

    it "[security] item 5: the subscriber receives type, action and reason of the observed read" do
      events = []
      subscriber = ActiveSupport::Notifications.subscribe("observed.graphql_armory") { |*args| events << args.last }
      begin
        schema = schema_with(root_query(observed_doc), sinks: [GraphQL::Armory::Telemetry::Notifications])
        response = run(schema, "{ invoice { secret } }", user: :bob)

        expect(response.dig("data", "invoice", "secret")).to eq("SECRET")
        expect(events.size).to eq(1)
        expect(events.first).to include(type: "ProbeDoc", action: :read, reason: "rollout of docs")
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end
    end

    it "[security] item 5: an allowed read sends no observed event, and the denied/allowed events carry no record data" do
      events = []
      subscriber = ActiveSupport::Notifications.subscribe(/graphql_armory\z/) { |name, *, payload| events << [name, payload] }
      begin
        schema = schema_with(root_query(observed_doc), sinks: [GraphQL::Armory::Telemetry::Notifications])
        run(schema, "{ invoice { secret } }", user: :admin)

        expect(events.map(&:first)).not_to include("observed.graphql_armory")
        expect(events.to_s).not_to include("SECRET")
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end
    end

    it "[preservation] item 5: with no subscriber the data is served (documented limit)" do
      schema = schema_with(root_query(observed_doc), sinks: [GraphQL::Armory::Telemetry::Notifications])
      response = run(schema, "{ invoice { secret } }", user: :bob)

      expect(response.dig("data", "invoice", "secret")).to eq("SECRET")
    end
  end

  # ---------------------------------------------------------------- item 6
  describe "item 6: threads" do
    it "[security] item 6: no signal or answer crosses between concurrent queries of an allowed and a refused user" do
      lock = Mutex.new
      tagged = []
      tagging_sink = ->(signal, data, ctx) { lock.synchronize { tagged << [ctx[:user], signal, data[:reason]] } }
      type = Class.new(base_object) do
        graphql_name "Invoice"
        authorize :read, model: Object, observe: "rollout"
        field :secret, String
        field :other, String, method: :secret, authorize: :manage
        field :notes, String, method: :secret, authorize: :manage, observe: "notes rollout"
      end
      schema = schema_with(root_query(type), sinks: [tagging_sink])
      shared_root = root # the same record object for every query: a shared memo would leak by identity
      answers = Queue.new
      threads = %i[admin bob admin bob].map do |user|
        Thread.new do
          150.times do
            r = execute_query(schema, "{ invoice { secret other notes } }", root_value: shared_root, context: { user: user }).to_h
            answers << [user, r.dig("data", "invoice")]
          end
        end
      end
      threads.each(&:join)

      results = []
      results << answers.pop until answers.empty?
      bad_answers = results.reject do |user, data|
        user == :admin ? data == { "secret" => "SECRET", "other" => "SECRET", "notes" => "SECRET" } : data == { "secret" => "SECRET", "other" => nil, "notes" => "SECRET" }
      end
      admin_bad = tagged.select { |user, signal, _| user == :admin && %i[observed denied].include?(signal) }
      bob_bad = tagged.select { |user, signal, _| user == :bob && signal == :allowed }

      expect(results.size).to eq(600)
      expect(bad_answers).to be_empty
      expect(admin_bad).to be_empty
      expect(bob_bad).to be_empty
      expect(tagged.count { |user, signal, _| user == :bob && signal == :observed }).to eq(300 * 2)
    end

    it "[preservation] item 6: the memo lives in each query's context" do
      type = Class.new(base_object) do
        graphql_name "Invoice"
        authorize :read, model: Object, observe: "rollout"
        field :secret, String
      end
      schema = schema_with(root_query(type))
      first = execute_query(schema, "{ invoice { secret } }", root_value: root, context: { user: :bob })
      second = execute_query(schema, "{ invoice { secret } }", root_value: root, context: { user: :admin })

      expect(first.context.namespace(:armory)[:memo]).not_to be_nil
      expect(first.context.namespace(:armory)[:memo]).not_to equal(second.context.namespace(:armory)[:memo])
      expect(kinds - [:bypassed]).to eq(%i[observed allowed])
    end
  end

  # ---------------------------------------------------------------- item 7
  describe "item 7: Schema::Visibility, dynamic: true" do
    let(:hiding_field) do
      plugin = armory
      Class.new(GraphQL::Schema::Field) do
        include plugin::Base
        def visible?(context) = super && !context[:hide]
      end
    end

    def unobservable_type
      r = resolver_counting(ran)
      hiding = hiding_field
      Class.new(base_object) do
        graphql_name "Invoice"
        authorize :read, model: Object, observe: "rollout"
        field :secret, String
        field_class hiding
        field :touch, resolver: r
      end
    end

    [true, false].each do |visibility|
      label = visibility ? "Visibility dynamic" : "legacy Warden"

      it "[security] item 7 (#{label}): a type that cannot be observed still raises and runs no resolver" do
        schema = schema_with(root_query(unobservable_type), visibility: visibility)

        expect { run(schema, "{ invoice { touch } }", user: :bob) }.to raise_error(config_error, /cannot be observed/)
        expect { run(schema, "{ invoice { secret } }", user: :admin) }.to raise_error(config_error, /cannot be observed/)
        expect(ran).to be_empty
      end

      it "[security] item 7 (#{label}): still raises and runs nothing when the resolver field is hidden from that user" do
        schema = schema_with(root_query(unobservable_type), visibility: visibility)
        outcome = begin
          response = run(schema, "{ invoice { secret } }", user: :bob, hide: true)
          "served: #{response.inspect}"
        rescue StandardError => e
          "raised #{e.class}: #{e.message}"
        end

        $stdout.puts "[item 7 #{label}] hidden resolver field -> #{outcome}"
        expect(ran).to be_empty
        expect(outcome).to start_with("raised GraphQL::Armory::Authorization::ConfigurationError")
        hidden = run(schema, "{ invoice { touch } }", user: :bob, hide: true) rescue $!
        expect(ran).to be_empty
        $stdout.puts "[item 7 #{label}] querying the hidden field -> #{hidden.is_a?(Exception) ? "#{hidden.class}: #{hidden.message}" : hidden.inspect}"
      end

      it "[preservation] item 7 (#{label}): an observable type is still served and recorded" do
        type = Class.new(base_object) do
          graphql_name "Invoice"
          authorize :read, model: Object, observe: "rollout"
          field :secret, String
        end
        response = run(schema_with(root_query(type), visibility: visibility), "{ invoice { secret } }", user: :bob)

        expect(response.dig("data", "invoice", "secret")).to eq("SECRET")
        expect(kinds).to include(:observed)
      end
    end
  end

  # ---------------------------------------------------------------- item 8
  describe "item 8: IDs, rate limits and persisted queries together" do
    let(:world) { Dummy::World.build }
    let(:encoder) { GraphQL::Armory::IDs::Controls::Encoder.example }
    let(:rate_store) { GraphQL::Armory::RateLimits::MemoryStore.new }
    let(:ops) do
      {
        invoices: "{ invoices { number } }",
        node: "query($id: ID!) { node(id: $id) { ... on Invoice { number } } }",
        by_ref: "query($id: ID!) { invoiceByRef(invoiceId: $id) { number } }"
      }
    end

    def combined_schema
      armory_mod = GraphQL::Armory
      base_argument = Class.new(GraphQL::Schema::Argument) { include armory_mod::Authorization::Base }
      base_field = Class.new(GraphQL::Schema::Field) do
        include armory_mod::Authorization::Base
        argument_class base_argument
      end
      base_object = Class.new(GraphQL::Schema::Object) do
        include armory_mod::Authorization::Base
        field_class base_field
      end
      invoice = Class.new(base_object) do
        graphql_name "Invoice"
        authorize :manage, model: Invoice, observe: "rollout"
        implements GraphQL::Types::Relay::Node
        field :number, String, null: false
      end
      node_lookup = Class.new(GraphQL::Schema::Resolver) do
        include armory_mod::Authorization::Base
        authorize :none, reason: "looks the node up by its encrypted ID"
        type GraphQL::Types::Relay::Node, null: true
        argument :id, GraphQL::Types::ID
        def resolve(id:) = context.schema.object_from_id(id, context)
      end
      query = Class.new(base_object) do
        graphql_name "Query"
        authorize :none, reason: "root type"
        field :node, resolver: node_lookup
        field :invoice_by_ref, invoice, authorize: :none, reason: "loads through the scope" do
          argument :invoice_id, GraphQL::Types::ID, loads: invoice
        end
        field :invoices, [invoice], null: false, authorize: :none, reason: "scoped"
      end
      manifest = GraphQL::Armory::PersistedQueries::Manifest.new(ops.values.to_h { |body| [Digest::SHA256.hexdigest(body), body] })
      sink = self.sink
      enc = encoder
      store = rate_store
      Class.new(ArmoryEngine.base_schema) do
        query query
        orphan_types invoice
        use armory_mod::Authorization, adapter: :pundit, sinks: [sink]
        use armory_mod::IDs, encoder: enc
        use armory_mod::PersistedQueries, store: manifest, strict: true
        use armory_mod::RateLimits::Points, store: store, limit: 6, window: 60, soft: false
        define_singleton_method(:resolve_type) { |_abstract, obj, _ctx| obj.is_a?(Invoice) ? invoice : nil }
      end
    end

    def op(schema, name, user, variables: {}, key: SecureRandom.hex, **extra)
      execute_query(schema, nil, variables: variables, root_value: CombinedRoot.new, context: { operation_id: Digest::SHA256.hexdigest(ops.fetch(name)), current_user: user, rate_limit_key: key }.merge(extra)).to_h
    end

    def gid(schema, record) = schema.id_from_object(record, schema.get_type("Invoice"), {})

    it "[security] item 8: strict persisted queries refuse a raw query on an observed type, running nothing" do
      schema = combined_schema
      response = execute_query(schema, "{ invoices { number } }", root_value: CombinedRoot.new, context: { current_user: world.bob, rate_limit_key: "k" }).to_h

      expect(response.key?("data")).to be(false)
      expect(response.to_s).to include("Only persisted operations are allowed")
      expect(kinds).not_to include(:observed)
    end

    it "[security] item 8: an observed read does not skip the rate limit" do
      schema = combined_schema
      w = world
      responses = Array.new(5) { op(schema, :invoices, w.bob, key: "user:bob") }
      codes = responses.map { |r| Array(r["errors"]).map { |e| e.dig("extensions", "code") } }

      expect(responses.first.dig("data", "invoices")).to eq([{ "number" => "B-1" }])
      expect(codes.flatten).to include("RATE_LIMITED")
      limited = responses.select { |r| Array(r["errors"]).any? { |e| e.dig("extensions", "code") == "RATE_LIMITED" } }
      expect(limited.map { |r| r.key?("data") }.uniq).to eq([false])
      $stdout.puts "[item 8] rate-limit codes per request: #{codes.inspect}"
    end

    it "[security] item 8: an encrypted id of another account's row answers nil through node and loads:, while the rule is observed" do
      schema = combined_schema
      w = world
      foreign = gid(schema, w.a1)
      own = gid(schema, w.b1)

      expect(op(schema, :node, w.bob, variables: { "id" => foreign }).dig("data", "node")).to be_nil
      expect(op(schema, :by_ref, w.bob, variables: { "id" => foreign }).dig("data", "invoiceByRef")).to be_nil
      expect(op(schema, :node, w.bob, variables: { "id" => own }).dig("data", "node", "number")).to eq("B-1")
      expect(op(schema, :node, w.bob, variables: { "id" => "garbage" }).dig("data", "node")).to be_nil
      expect(signals.select { |s, _| s == :observed }.size).to eq(1) # only bob's own B-1, refused :manage, observed
    end

    it "[preservation] item 8: an admin reads through the combined schema with no :observed" do
      schema = combined_schema
      response = op(schema, :invoices, world.carol)

      expect(response.dig("data", "invoices")).to eq([{ "number" => "A-1" }, { "number" => "A-2" }])
      expect(kinds).not_to include(:observed)
    end
  end
end
