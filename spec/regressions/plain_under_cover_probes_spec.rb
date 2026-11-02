# frozen_string_literal: true

require "spec_helper"
require "json"

# Probes of the audit of plain resolvers under covers_fields. Each compares the audit with what really runs for a refused user.
module PlainCoverProbes
  SECRET = "SECRET"
  Audit = GraphQL::Armory::Authorization::Audit

  class Record
    attr_reader :type_class
    def initialize(type_class = nil) = @type_class = type_class
    def secret = SECRET
    def self.primary_key = "id"
    def total = SECRET
    def open = SECRET
    def y = SECRET
    def x = "safe"
  end

  WRITES = []
  ROOTS = {}
  def self.on(name, &block) = ROOTS[name] = block

  class Root
    def respond_to_missing?(name, priv = false) = ROOTS.key?(name) || super
    def method_missing(name, *args) = ROOTS.key?(name) ? ROOTS[name].call : super
  end

  class Conn < GraphQL::Pagination::ArrayConnection
    def total = SECRET
    def secret = SECRET
  end

  module Const
    Field = Class.new(GraphQL::Schema::Field) { include GraphQL::Armory::Authorization::Base }
    Object = Class.new(GraphQL::Schema::Object) do
      include GraphQL::Armory::Authorization::Base
      field_class Const::Field
    end
    class Invoice < Object
      graphql_name "ConstInvoice"
      authorize :read, model: Record
      field :secret, String, null: true
    end
  end

  Obs = Struct.new(:id, :leak, :wrote, :ok, :problems, :result, :raised, keyword_init: true)

  class Kit
    attr_reader :field, :object, :spec

    def initialize(spec)
      @spec = spec
      fld = Class.new(GraphQL::Schema::Field) { include GraphQL::Armory::Authorization::Base }
      @field = fld
      @object = Class.new(GraphQL::Schema::Object) do
        include GraphQL::Armory::Authorization::Base
        field_class fld
        default_action :read
      end
    end

    def covering(name, parent: object, &block)
      Class.new(parent) do
        graphql_name name
        authorize :none, reason: "public", covers_fields: true
        class_eval(&block) if block
      end
    end

    def bypass(name, parent: object, &block)
      Class.new(parent) do
        graphql_name name
        authorize :none, reason: "bypass"
        class_eval(&block) if block
      end
    end

    def ruled(name, parent: object, &block)
      Class.new(parent) do
        graphql_name name
        authorize :read, model: Record
        field :secret, String, null: true
        class_eval(&block) if block
      end
    end

    def covering_object
      @covering_object ||= begin
        o = Class.new(object)
        o.authorize :none, reason: "payload", covers_fields: true
        o
      end
    end

    # A resolver with no Base.
    def resolver(type = String, null: true, value: SECRET, parent: GraphQL::Schema::Resolver, &block)
      Class.new(parent) do
        self.type(type, null: null) if type
        define_method(:resolve) { WRITES << :resolver; value.respond_to?(:call) ? value.call : value }
        class_eval(&block) if block
      end
    end

    def mutation(name, parent: GraphQL::Schema::Mutation, type_field: true, &block)
      fld = field
      obj = covering_object
      Class.new(parent) do
        graphql_name name
        field_class fld
        object_class obj
        field :secret, String, null: true, hash_key: :secret if type_field
        define_method(:resolve) { WRITES << :mutation; { secret: SECRET } }
        class_eval(&block) if block
      end
    end

    def query(&block)
      covering("Query") do
        field :ping, String, null: true
        def ping = "pong"
        class_eval(&block) if block
      end
    end

    def schema(query: self.query, mutation: nil, subscription: nil, orphans: [], allow: false, sinks: [->(_s, _d) {}], &block)
      s = spec.base_schema
      s.orphan_types(*orphans) unless orphans.empty?
      s.query(query)
      s.mutation(mutation) if mutation
      s.subscription(subscription) if subscription
      s.use GraphQL::Armory::Authorization, adapter: GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: allow), sinks: sinks
      s.define_singleton_method(:resolve_type) { |_t, o, _c| o.type_class }
      s.instance_eval(&block) if block
      s
    end
  end
end

RSpec.describe "Plain resolvers under covers_fields: probes" do
  let(:kit) { PlainCoverProbes::Kit.new(self) }
  rec = PlainCoverProbes::Record

  before { PlainCoverProbes::WRITES.clear; PlainCoverProbes::ROOTS.clear }

  def see(schema, query, root: PlainCoverProbes::Root.new)
    id = RSpec.current_example.description.split(" ").first
    report = PlainCoverProbes::Audit.(schema)
    raised = nil
    result = begin
      execute_query(schema, query, context: { current_user: :refused }, root_value: root).to_h
    rescue StandardError => e
      raised = "#{e.class}: #{e.message[0, 90]}"
      {}
    end
    leak = result.to_json.include?(PlainCoverProbes::SECRET)
    wrote = PlainCoverProbes::WRITES.dup
    kinds = report.problems.map { |p| "#{p.kind}@#{p.path}" }
    puts "OBS|#{id}|leak=#{leak}|wrote=#{wrote.join(",")}|ok=#{report.ok?}|#{kinds.join(";")}|#{raised}|#{result.to_json[0, 150]}"
    PlainCoverProbes::Obs.new(id: id, leak: leak, wrote: wrote, ok: report.ok?, problems: report.problems, result: result, raised: raised)
  end

  # The invariant: if a refused user gets data or a write runs, the audit must not say ok.
  def holds(obs)
    expect(obs.ok && (obs.leak || !obs.wrote.empty?)).to eq(false), "audit ok, leak=#{obs.leak} wrote=#{obs.wrote} #{obs.result}"
  end

  def clean(obs)
    expect(obs.leak).to eq(false)
    expect(obs.problems.map(&:to_s)).to eq([])
  end

  # base
  it "p01 security: scalar resolver under a covering root" do
    r = kit.resolver
    holds see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x }")
  end

  it "p02 security: plain Mutation under a covering mutation root" do
    m = kit.mutation("M")
    root = kit.covering("Mutation") { field :m, mutation: m }
    holds see(kit.schema(mutation: root), "mutation { m { secret } }")
  end

  it "p03 security: plain RelayClassicMutation" do
    m = kit.mutation("M", parent: GraphQL::Schema::RelayClassicMutation)
    root = kit.covering("Mutation") { field :m, mutation: m }
    holds see(kit.schema(mutation: root), "mutation { m(input: {}) { secret } }")
  end

  it "p04 security: plain Subscription" do
    fld = kit.field
    obj = kit.covering_object
    sub = Class.new(GraphQL::Schema::Subscription) do
      graphql_name "S"
      field_class fld
      object_class obj
      field :secret, String, null: true, hash_key: :secret
      define_method(:subscribe) { { secret: PlainCoverProbes::SECRET } }
    end
    root = kit.covering("Subscription") { field :s, subscription: sub }
    subs = Class.new(GraphQL::Subscriptions) { def write_subscription(_q, _e) = nil }
    schema = kit.schema(subscription: root) { use subs }
    holds see(schema, "subscription { s { secret } }")
  end

  it "p05 security: resolver on a plain field class" do
    r = kit.resolver
    plain_object = Class.new(kit.object) { field_class GraphQL::Schema::Field }
    q = kit.covering("Query", parent: plain_object) { field :x, resolver: r }
    holds see(kit.schema(query: q), "{ x }")
  end

  # exemption
  it "p10 security: ruled type with own authorized? that opens" do
    t = kit.ruled("T") { def self.authorized?(_o, _c) = true }
    r = kit.resolver(t, value: -> { rec.new })
    holds see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x { secret } }")
  end

  it "p11 security: observed rule" do
    t = Class.new(kit.object) { graphql_name "T"; authorize :read, model: rec, observe: "rollout"; field :secret, String, null: true }
    r = kit.resolver(t, value: -> { rec.new })
    holds see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x { secret } }")
  end

  it "p12 security: reauthorize_scoped_objects(false)" do
    t = kit.ruled("T") { reauthorize_scoped_objects(false) }
    r = kit.resolver([t], value: -> { [rec.new] })
    holds see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x { secret } }")
  end

  it "p13 security: authorized? brought by an extended module" do
    opener = Module.new { def authorized?(_o, _c) = true }
    t = kit.ruled("T") { extend opener }
    r = kit.resolver(t, value: -> { rec.new })
    holds see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x { secret } }")
  end

  it "p14 security: ruled class with ConnectionBehaviors" do
    node = kit.ruled("Node1")
    t = Class.new(kit.object) do
      graphql_name "TConnection"
      authorize :read, model: rec
      include GraphQL::Types::Relay::ConnectionBehaviors
      edge_type node.edge_type
      field :secret, String, null: true
      def secret = PlainCoverProbes::SECRET
    end
    r = kit.resolver(t, value: -> { PlainCoverProbes::Conn.new([rec.new]) })
    holds see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x { secret } }")
  end

  it "p15 preservation: read answering a ruled type refuses, audit clean" do
    t = kit.ruled("T")
    r = kit.resolver(t, value: -> { rec.new })
    clean see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x { secret } }")
  end

  it "p16 security: read answering a covering subclass of a ruled type" do
    t = kit.ruled("T")
    sub = kit.covering("Sub", parent: t)
    r = kit.resolver(sub, value: -> { rec.new })
    holds see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x { secret } }")
  end

  it "p17 preservation: list of a ruled type refuses each row" do
    t = kit.ruled("T")
    r = kit.resolver([t], value: -> { [rec.new] })
    clean see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x { secret } }")
  end

  it "p18 preservation: non-null ruled type" do
    t = kit.ruled("T")
    r = kit.resolver(t, null: false, value: -> { rec.new })
    clean see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x { secret } }")
  end

  it "p19 preservation: late-bound ruled type" do
    t = kit.ruled("T")
    r = kit.resolver(GraphQL::Schema::LateBoundType.new("T"), value: -> { rec.new })
    obs = see(kit.schema(query: kit.query { field :x, resolver: r }, orphans: [t]), "{ x { secret } }")
    expect(obs.leak).to eq(false)
  end

  it "p20 preservation: string constant ruled type" do
    r = kit.resolver("PlainCoverProbes::Const::Invoice", value: -> { rec.new })
    clean see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x { secret } }")
  end

  it "p21 security: union with a covering member" do
    open = kit.covering("Open") { field :secret, String, null: true }
    u = Class.new(GraphQL::Schema::Union) { graphql_name "U"; possible_types open }
    r = kit.resolver(u, value: -> { rec.new(open) })
    holds see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x { ... on Open { secret } } }")
  end

  it "p22 security: interface with a covering member" do
    i = Module.new { include GraphQL::Schema::Interface; graphql_name "I"; field :secret, String, null: true }
    open = kit.covering("Open") { implements i }
    r = kit.resolver(i, value: -> { rec.new(open) })
    holds see(kit.schema(query: kit.query { field :x, resolver: r }, orphans: [open]), "{ x { secret } }")
  end

  it "p23 preservation: union of ruled members only" do
    t = kit.ruled("T")
    u = Class.new(GraphQL::Schema::Union) { graphql_name "U"; possible_types t }
    r = kit.resolver(u, value: -> { rec.new(t) })
    clean see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x { ... on T { secret } } }")
  end

  it "p24 security: connection of covering nodes" do
    open = kit.covering("Open") { field :secret, String, null: true }
    r = kit.resolver(open.connection_type, value: -> { [rec.new(open)] })
    holds see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x { nodes { secret } } }")
  end

  it "p25 preservation: connection of ruled nodes" do
    t = kit.ruled("T")
    r = kit.resolver(t.connection_type, value: -> { [rec.new] })
    clean see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x { nodes { secret } edges { node { secret } } pageInfo { hasNextPage } } }")
  end

  it "p26 security: template connection with an own field over ruled nodes" do
    t = kit.ruled("T")
    conn = kit.covering("TConnection") do
      include GraphQL::Types::Relay::ConnectionBehaviors
      edge_type t.edge_type
      field :total, String, null: true
      def total = PlainCoverProbes::SECRET
    end
    r = kit.resolver(conn, value: -> { PlainCoverProbes::Conn.new([rec.new]) })
    holds see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x { total } }")
  end

  it "p27 preservation: type declared on the resolver's parent class" do
    t = kit.ruled("T")
    parent = kit.resolver(t, value: -> { rec.new })
    r = Class.new(parent)
    clean see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x { secret } }")
  end

  it "p28 preservation: only __typename on a refused type" do
    t = kit.ruled("T")
    r = kit.resolver(t, value: -> { rec.new })
    obs = see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x { __typename } }")
    expect(obs.result.dig("data", "x")).to eq(nil)
    clean obs
  end

  it "p29 preservation: a public field of a refused type" do
    t = kit.ruled("T") do
      field :open, String, null: true, authorize: :none, reason: "public"
      def open = PlainCoverProbes::SECRET
    end
    r = kit.resolver(t, value: -> { rec.new })
    clean see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x { open } }")
  end

  it "p30 security: plain Resolver on the Mutation root answering a ruled type, the write runs" do
    t = kit.ruled("T")
    r = kit.resolver(t, value: -> { rec.new })
    root = kit.covering("Mutation") { field :create, resolver: r }
    holds see(kit.schema(mutation: root), "mutation { create { secret } }")
  end

  it "p31 security: plain Resolver under mutation: on the Mutation root" do
    t = kit.ruled("T")
    r = kit.resolver(t, value: -> { rec.new })
    root = kit.covering("Mutation") { field :create, mutation: r }
    holds see(kit.schema(mutation: root), "mutation { create { secret } }")
  end

  # inheritance
  it "p40 preservation: resolver subclass of a Base parent with a rule" do
    parent = Class.new(GraphQL::Schema::Resolver) { include GraphQL::Armory::Authorization::Base; type String, null: true; authorize :read, model: rec; def resolve = PlainCoverProbes::SECRET }
    r = Class.new(parent)
    clean see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x }")
  end

  it "p41 preservation: Base subclass of a plain parent" do
    parent = kit.resolver
    r = Class.new(parent) { include GraphQL::Armory::Authorization::Base; authorize :read, model: rec }
    clean see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x }")
  end

  it "p42 preservation: Mutation whose parent has Base and a rule" do
    parent = kit.mutation("Parent") { include GraphQL::Armory::Authorization::Base; authorize :write, model: rec }
    m = Class.new(parent) { graphql_name "Child" }
    root = kit.covering("Mutation") { field :m, mutation: m }
    clean see(kit.schema(mutation: root), "mutation { m { secret } }")
  end

  it "p43 preservation: include Base after the field is defined" do
    r = kit.resolver
    q = kit.query { field :x, resolver: r }
    r.include GraphQL::Armory::Authorization::Base
    r.authorize :read, model: rec
    clean see(kit.schema(query: q), "{ x }")
  end

  it "p44 security: covering parent, bypassed child" do
    r = kit.resolver
    parent = kit.covering("Parent") { field :x, resolver: r }
    child = kit.bypass("Child", parent: parent)
    q = kit.query { field :c, child, null: true; PlainCoverProbes.on(:c) { rec.new } }
    holds see(kit.schema(query: q), "{ c { x } }")
  end

  it "p45 security: bypassed parent, covering child" do
    r = kit.resolver
    parent = kit.bypass("Parent") { field :x, resolver: r }
    child = kit.covering("Child", parent: parent)
    q = kit.query { field :c, child, null: true; PlainCoverProbes.on(:c) { rec.new } }
    holds see(kit.schema(query: q), "{ c { x } }")
  end

  it "p46 security: ruled parent, covering child" do
    r = kit.resolver
    parent = kit.ruled("Parent") { field :x, resolver: r }
    child = kit.covering("Child", parent: parent)
    q = kit.query { field :c, child, null: true; PlainCoverProbes.on(:c) { rec.new } }
    holds see(kit.schema(query: q), "{ c { x } }")
  end

  it "p47 security: parent with no Base, covering child" do
    r = kit.resolver
    fld = kit.field
    parent = Class.new(GraphQL::Schema::Object) { field_class fld; field :x, resolver: r }
    child = Class.new(parent) { include GraphQL::Armory::Authorization::Base; graphql_name "Child"; authorize :none, reason: "r", covers_fields: true }
    q = kit.query { field :c, child, null: true; PlainCoverProbes.on(:c) { rec.new } }
    holds see(kit.schema(query: q), "{ c { x } }")
  end

  it "p48 security: shadowed by a declared child" do
    r = kit.resolver
    parent = kit.covering("Parent") { field :x, resolver: r }
    child = kit.covering("Child", parent: parent) do
      field :x, String, null: true, authorize: :none, reason: "safe", override_reason: "safe"
      def x = "safe"
    end
    q = kit.query { field :c, child, null: true; PlainCoverProbes.on(:c) { rec.new } }
    holds see(kit.schema(query: q), "{ c { x } }")
  end

  xit "p49 preservation: plain resolver with its own authorized? that refuses" do
    r = kit.resolver { def authorized?(**) = false }
    obs = see(kit.schema(query: kit.query { field :x, resolver: r }), "{ x }")
    expect(obs.leak).to eq(false)
    expect(obs.problems.map(&:kind) - %i[own_check]).to eq([])
  end

  # owners
  def ruled_mutation(name, on_denied: :default, &block)
    kit.mutation(name) do
      include GraphQL::Armory::Authorization::Base
      authorize :write, model: PlainCoverProbes::Record, on_denied: on_denied
      class_eval(&block) if block
    end
  end

  it "p50 preservation: ruled mutation, covering payload, resolver in it" do
    r = kit.resolver
    m = ruled_mutation("M") { field :extra, resolver: r }
    root = kit.covering("Mutation") { field :m, mutation: m }
    clean see(kit.schema(mutation: root), "mutation { m { extra } }")
  end

  it "p51 security: public Base mutation with no covers, resolver in payload" do
    r = kit.resolver
    m = kit.mutation("M") { include GraphQL::Armory::Authorization::Base; authorize :none, reason: "public"; field :extra, resolver: r }
    root = kit.covering("Mutation") { field :m, mutation: m }
    holds see(kit.schema(mutation: root), "mutation { m { extra } }")
  end

  it "p52 security: public Base mutation with covers, resolver in payload" do
    r = kit.resolver
    m = kit.mutation("M") { include GraphQL::Armory::Authorization::Base; authorize :none, reason: "public", covers_fields: true; field :extra, resolver: r }
    root = kit.covering("Mutation") { field :m, mutation: m }
    holds see(kit.schema(mutation: root), "mutation { m { extra } }")
  end

  it "p53 security: ruled mutation with on_denied: :errors, resolver in the payload it answers" do
    r = kit.resolver
    err = kit.covering("Err") { field :message, String, null: true, hash_key: :message; field :code, String, null: true, hash_key: :code }
    m = ruled_mutation("M", on_denied: :errors) do
      field :errors, [err], null: true, hash_key: :errors
      field :extra, resolver: r
    end
    root = kit.covering("Mutation") { field :m, mutation: m }
    holds see(kit.schema(mutation: root), "mutation { m { errors { code } extra } }")
  end

  it "p54 security: ruled parent mutation, public child inherits a resolver field" do
    r = kit.resolver
    parent = ruled_mutation("Parent") { field :extra, resolver: r }
    child = Class.new(parent) { graphql_name "Child"; authorize :none, reason: "public", covers_fields: true }
    root = kit.covering("Mutation") { field :c, mutation: child }
    holds see(kit.schema(mutation: root), "mutation { c { extra } }")
  end

  it "p55 security: the same on a plain field class" do
    r = kit.resolver
    parent = ruled_mutation("Parent") { field_class GraphQL::Schema::Field; field :extra, resolver: r }
    child = Class.new(parent) { graphql_name "Child"; authorize :none, reason: "public", covers_fields: true }
    root = kit.covering("Mutation") { field :c, mutation: child }
    holds see(kit.schema(mutation: root), "mutation { c { extra } }")
  end

  it "p56 security: plain mutation whose generated payload covers, resolver in it" do
    r = kit.resolver
    m = kit.mutation("M") { field :extra, resolver: r }
    root = kit.covering("Mutation") { field :m, mutation: m }
    holds see(kit.schema(mutation: root), "mutation { m { extra } }")
  end

  it "p57 security: ruled mutation's payload returned by a query field, resolver in it" do
    r = kit.resolver
    m = ruled_mutation("M") { field :extra, resolver: r }
    payload = m.payload_type
    root = kit.covering("Mutation") { field :m, mutation: m }
    q = kit.query { field :pay, payload, null: true; PlainCoverProbes.on(:pay) { {} } }
    holds see(kit.schema(query: q, mutation: root), "{ pay { extra } }")
  end

  xit "p58 preservation: ruled mutation, shared covering payload_type holds a resolver" do
    r = kit.resolver
    shared = kit.covering("Shared") { field :extra, resolver: r; field :secret, String, null: true }
    m = kit.mutation("M", type_field: false) { include GraphQL::Armory::Authorization::Base; authorize :write, model: rec; payload_type shared }
    root = kit.covering("Mutation") { field :m, mutation: m }
    clean see(kit.schema(mutation: root), "mutation { m { extra } }")
  end

  # interfaces
  def iface(name, field_class: nil, &block)
    fc = field_class || kit.field
    Module.new do
      include GraphQL::Schema::Interface
      graphql_name name
      field_class fc
      class_eval(&block) if block
    end
  end

  it "p60 security: resolver on an interface with covering and bypassed implementers" do
    r = kit.resolver
    i = iface("I") { field :x, resolver: r }
    open = kit.covering("Open") { implements i }
    by = kit.bypass("By") { implements i }
    q = kit.query { field :v, open, null: true; PlainCoverProbes.on(:v) { rec.new }; field :w, by, null: true; PlainCoverProbes.on(:w) { rec.new } }
    holds see(kit.schema(query: q), "{ v { x } w { x } }")
  end

  it "p61 security: covering and ruled implementers, reported once on the interface" do
    r = kit.resolver
    i = iface("I") { field :x, resolver: r }
    open = kit.covering("Open") { implements i }
    t = kit.ruled("T") { implements i }
    q = kit.query { field :v, open, null: true; PlainCoverProbes.on(:v) { rec.new }; field :w, t, null: true; PlainCoverProbes.on(:w) { rec.new } }
    obs = see(kit.schema(query: q), "{ v { x } w { x } }")
    holds obs
    expect(obs.problems.map(&:path)).to eq(["I.x"])
  end

  it "p62 security: interface included by another interface" do
    r = kit.resolver
    inner = iface("Inner") { field :x, resolver: r }
    outer = iface("Outer") { include inner }
    open = kit.covering("Open") { implements outer }
    q = kit.query { field :v, open, null: true; PlainCoverProbes.on(:v) { rec.new } }
    holds see(kit.schema(query: q), "{ v { x } }")
  end

  it "p63 security: interface's field class has no Base" do
    r = kit.resolver
    i = iface("I", field_class: GraphQL::Schema::Field) { field :x, resolver: r }
    open = kit.covering("Open") { implements i }
    q = kit.query { field :v, open, null: true; PlainCoverProbes.on(:v) { rec.new } }
    holds see(kit.schema(query: q), "{ v { x } }")
  end

  it "p64 security: covering implementer only through orphan_types" do
    r = kit.resolver
    i = iface("I") { field :x, resolver: r }
    open = kit.covering("Open") { implements i }
    q = kit.query { field :v, i, null: true; PlainCoverProbes.on(:v) { rec.new(open) } }
    holds see(kit.schema(query: q, orphans: [open]), "{ v { x } }")
  end

  it "p65 preservation: ruled implementers only" do
    r = kit.resolver
    i = iface("I") { field :x, resolver: r }
    t = kit.ruled("T") { implements i }
    q = kit.query { field :v, t, null: true; PlainCoverProbes.on(:v) { rec.new } }
    clean see(kit.schema(query: q), "{ v { x } }")
  end

  it "p66 preservation: interface resolver answering a ruled type" do
    t = kit.ruled("T")
    r = kit.resolver(t, value: -> { rec.new })
    i = iface("I") { field :x, resolver: r }
    open = kit.covering("Open") { implements i }
    q = kit.query { field :v, open, null: true; PlainCoverProbes.on(:v) { rec.new } }
    clean see(kit.schema(query: q), "{ v { x { secret } } }")
  end

  xit "p67 preservation: every implementer shadows the interface's resolver with a method" do
    r = kit.resolver
    i = iface("I") { field :x, resolver: r }
    open = kit.covering("Open") do
      implements i
      field :x, String, null: true, override_reason: "safe"
      def x = "safe"
    end
    q = kit.query { field :v, open, null: true; PlainCoverProbes.on(:v) { rec.new } }
    clean see(kit.schema(query: q), "{ v { x } }")
  end

  # forms
  it "p70 preservation: authorize: true with a plain resolver is denied" do
    r = kit.resolver
    obs = see(kit.schema(query: kit.query { field :x, resolver: r, authorize: true }), "{ x }")
    expect(obs.leak).to eq(false)
    holds obs
  end

  it "p71 preservation: authorize: :read on a type with no model is asked and refused" do
    r = kit.resolver
    obs = see(kit.schema(query: kit.query { field :x, resolver: r, authorize: :read }), "{ x }")
    expect(obs.leak).to eq(false)
    holds obs
  end

  it "p72 security: authorize: false with a plain resolver" do
    r = kit.resolver
    holds see(kit.schema(query: kit.query { field :x, resolver: r, authorize: false }), "{ x }")
  end

  it "p73 preservation: field's own type overrides the resolver's, a ruled one" do
    t = kit.ruled("T")
    r = kit.resolver(String, value: -> { rec.new })
    clean see(kit.schema(query: kit.query { field :x, t, null: true, resolver: r }), "{ x { secret } }")
  end

  it "p68 security: inner interface linked with implements, the guide's other form" do
    r = kit.resolver
    inner = iface("Inner") { field :x, resolver: r }
    outer = iface("Outer") { implements inner }
    open = kit.covering("Open") { implements outer }
    q = kit.query { field :v, open, null: true; PlainCoverProbes.on(:v) { rec.new } }
    holds see(kit.schema(query: q), "{ v { x } }")
  end

  it "p69 security: included inner interface on a plain field class, bypassed implementer" do
    r = kit.resolver
    inner = iface("Inner", field_class: GraphQL::Schema::Field) { field :x, String, null: true; field :y, resolver: r }
    outer = iface("Outer") { include inner }
    by = kit.bypass("By") { implements outer }
    q = kit.query { field :v, by, null: true; PlainCoverProbes.on(:v) { rec.new } }
    holds see(kit.schema(query: q), "{ v { y } }")
  end

  it "p59 security: included inner interface, plain method field with no Base, bypassed implementer (no resolver)" do
    inner = iface("Inner", field_class: GraphQL::Schema::Field) { field :y, String, null: true; def y = PlainCoverProbes::SECRET }
    outer = iface("Outer") { include inner }
    by = kit.bypass("By") { implements outer }
    q = kit.query { field :v, by, null: true; PlainCoverProbes.on(:v) { rec.new } }
    holds see(kit.schema(query: q), "{ v { y } }")
  end

  it "p74 security: resolver_method: combined with resolver:" do
    r = kit.resolver
    q = kit.query do
      field :x, resolver: r, resolver_method: :other
      define_method(:other) { PlainCoverProbes::SECRET }
    end
    holds see(kit.schema(query: q), "{ x }")
  end

  it "p75 preservation: a field block is the documented plain limit" do
    q = kit.query do
      field(:x, String, null: true) { description "plain" }
      PlainCoverProbes.on(:x) { PlainCoverProbes::SECRET }
    end
    obs = see(kit.schema(query: q), "{ x }")
    expect(obs.problems.map(&:to_s)).to eq([])
  end

  it "p76 preservation: HasNodeField and HasNodesField under a covering root" do
    t = kit.ruled("T") { implements GraphQL::Types::Relay::Node }
    q = kit.query { include GraphQL::Types::Relay::HasNodeField; include GraphQL::Types::Relay::HasNodesField; field :t, t, null: true }
    schema = kit.schema(query: q, orphans: [t])
    schema.define_singleton_method(:object_from_id) { |_id, _c| rec.new(t) }
    clean see(schema, %({ node(id: "1") { ... on T { secret } } nodes(ids: ["1"]) { ... on T { secret } } }))
  end

  it "p77 security: custom EntryPoints with a plain resolver" do
    r = kit.resolver
    intro = Module.new
    intro.const_set(:EntryPoints, Class.new(GraphQL::Introspection::EntryPoints) { field :x, resolver: r })
    holds see(kit.schema { introspection intro }, "{ x }")
  end

  it "p78 security: custom DynamicFields with a plain resolver" do
    r = kit.resolver
    intro = Module.new
    intro.const_set(:DynamicFields, Class.new(GraphQL::Introspection::DynamicFields) { field :x, resolver: r })
    holds see(kit.schema { introspection intro }, "{ x }")
  end

  it "p79 security: mutation: under the query root" do
    m = kit.mutation("M")
    holds see(kit.schema(query: kit.query { field :m, mutation: m }), "{ m { secret } }")
  end

  it "p80 security: template connection with an own resolver field" do
    t = kit.ruled("T")
    r = kit.resolver
    conn = kit.covering("TConnection") do
      include GraphQL::Types::Relay::ConnectionBehaviors
      edge_type t.edge_type
      field :total, resolver: r
    end
    q = kit.query { field :c, conn, null: true, connection: false; PlainCoverProbes.on(:c) { GraphQL::Pagination::ArrayConnection.new([]) } }
    holds see(kit.schema(query: q), "{ c { total } }")
  end

  it "p81 security: Relay::BaseConnection subclass with nodes held by a plain resolver" do
    t = kit.ruled("T")
    r = kit.resolver([String], value: -> { [PlainCoverProbes::SECRET] })
    fld = kit.field
    conn = Class.new(GraphQL::Types::Relay::BaseConnection) do
      include GraphQL::Armory::Authorization::Base
      graphql_name "TConnection"
      authorize :none, reason: "r", covers_fields: true
      field_class fld
      edge_type t.edge_type, nodes_field: false
      field :nodes, resolver: r
    end
    q = kit.query { field :c, conn, null: true; PlainCoverProbes.on(:c) { [] } }
    holds see(kit.schema(query: q), "{ c { nodes } }")
  end

  it "p82 security: Relay::BaseEdge subclass with node held by a plain resolver" do
    r = kit.resolver
    fld = kit.field
    edge = Class.new(GraphQL::Types::Relay::BaseEdge) do
      include GraphQL::Armory::Authorization::Base
      graphql_name "TEdge"
      authorize :none, reason: "r", covers_fields: true
      field_class fld
      node_type PlainCoverProbes::Const::Invoice
      field :node, resolver: r
    end
    q = kit.query { field :e, edge, null: true; PlainCoverProbes.on(:e) { {} } }
    holds see(kit.schema(query: q), "{ e { node } }")
  end

  it "p83 security: PageInfo subclass with a plain resolver" do
    r = kit.resolver
    fld = kit.field
    info = Class.new(GraphQL::Types::Relay::PageInfo) do
      include GraphQL::Armory::Authorization::Base
      graphql_name "Info"
      authorize :none, reason: "r", covers_fields: true
      field_class fld
      field :x, resolver: r
    end
    q = kit.query { field :i, info, null: true; PlainCoverProbes.on(:i) { {} } }
    holds see(kit.schema(query: q), "{ i { x } }")
  end

  # baseline
  def baseline_of(schema) = PlainCoverProbes::Audit::Baseline.from(PlainCoverProbes::Audit.(schema))

  it "p90 security: a baseline with one accepted problem fails on another" do
    r = kit.resolver
    accepted = baseline_of(kit.schema(query: kit.query { field :x, resolver: r }))
    k2 = PlainCoverProbes::Kit.new(self)
    r2 = k2.resolver
    result = accepted.(PlainCoverProbes::Audit.(k2.schema(query: k2.query { field :x, resolver: r2; field :y, resolver: r2 })))
    puts "OBS|p90|new=#{result.new_problems.map(&:path)}|passes=#{result.passes?}"
    expect(result.passes?).to eq(false)
  end

  xit "p91 security: swapping the plain resolver for another one" do
    r = kit.resolver
    accepted = baseline_of(kit.schema(query: kit.query { field :x, resolver: r }))
    k2 = PlainCoverProbes::Kit.new(self)
    r2 = k2.resolver(String) { def resolve = "other code, same signature" }
    result = accepted.(PlainCoverProbes::Audit.(k2.schema(query: k2.query { field :x, resolver: r2 })))
    puts "OBS|p91|swap_passes=#{result.passes?}|accepted=#{accepted.entries.size}"
    expect(result.passes?).to eq(false)
  end

  it "p92 preservation: anonymous classes make a usable message" do
    r = kit.resolver
    report = PlainCoverProbes::Audit.(kit.schema(query: kit.query { field :x, resolver: r }))
    puts "OBS|p92|#{report}"
    expect(report.problems.map(&:path)).to eq(["Query.x"])
    expect(report.problems.first.message).not_to match(/#<Class/)
  end

  it "p93 preservation: Reach of the interface's problem names implementers" do
    r = kit.resolver
    i = iface("I") { field :x, resolver: r }
    open = kit.covering("Open") { implements i }
    q = kit.query { field :v, open, null: true; PlainCoverProbes.on(:v) { rec.new } }
    base = baseline_of(kit.schema(query: q))
    puts "OBS|p93|#{base.entries.map(&:to_h)}"
    expect(base.entries.first.covers.join).to include("Open")
  end

  it "p94 security: a new covering implementer grows the accepted problem" do
    r = kit.resolver
    i = iface("I") { field :x, resolver: r }
    open = kit.covering("Open") { implements i }
    q1 = kit.query { field :v, open, null: true; PlainCoverProbes.on(:v) { rec.new } }
    base = baseline_of(kit.schema(query: q1))
    other = kit.covering("Other") { implements i }
    q2 = kit.query { field :v, open, null: true; PlainCoverProbes.on(:v) { rec.new }; field :w, other, null: true; PlainCoverProbes.on(:w) { rec.new } }
    result = base.(PlainCoverProbes::Audit.(kit.schema(query: q2)))
    puts "OBS|p94|passes=#{result.passes?}|grown=#{result.grown.values}"
    expect(result.passes?).to eq(false)
  end

  # templates
  it "p95 security: the shape of graphql-ruby's generators, with owners read" do
    fld = kit.field
    obj = kit.object
    base_resolver = Class.new(GraphQL::Schema::Resolver)
    base_mutation = Class.new(GraphQL::Schema::RelayClassicMutation) { field_class fld; object_class obj }
    base_connection = Class.new(obj) do
      authorize :none, reason: "the field that returns it holds the rule", covers_fields: true
      include GraphQL::Types::Relay::ConnectionBehaviors
    end
    base_edge = Class.new(obj) do
      authorize :none, reason: "edge", covers_fields: true
      include GraphQL::Types::Relay::EdgeBehaviors
    end
    obj.connection_type_class(base_connection)
    obj.edge_type_class(base_edge)
    invoice = kit.ruled("Invoice")
    list = Class.new(base_resolver) { type [invoice], null: true; def resolve = [PlainCoverProbes::Record.new] }
    pub = Class.new(base_resolver) { type String, null: true; def resolve = PlainCoverProbes::SECRET }
    create = Class.new(base_mutation) do
      graphql_name "Create"
      field :secret, String, null: true, hash_key: :secret
      def resolve = (PlainCoverProbes::WRITES << :create; { secret: PlainCoverProbes::SECRET })
    end
    create.payload_type.authorize(:none, reason: "payload", covers_fields: true)
    q = kit.query { field :list, resolver: list; field :pub, resolver: pub; field :page, invoice.connection_type, null: true; PlainCoverProbes.on(:page) { [] } }
    m = kit.covering("Mutation") { field :create, mutation: create }
    obs = see(kit.schema(query: q, mutation: m), "{ list { secret } pub }")
    puts "OBS|p95|conn=#{base_connection.method(:authorized?).owner}|edge=#{base_edge.method(:authorized?).owner}|invoice=#{invoice.method(:authorized?).owner}|resolver=#{pub.instance_method(:authorized?).owner}|mutation=#{create.instance_method(:authorized?).owner}"
    holds obs
    expect(obs.problems.map(&:path)).to include("Query.pub", "Mutation.create")
    expect(obs.problems.map(&:path)).not_to include("Query.list")
  end

  it "p96 preservation: canonical schema with Base everywhere stays clean" do
    t = kit.ruled("T")
    r = Class.new(GraphQL::Schema::Resolver) { include GraphQL::Armory::Authorization::Base; type [t], null: true; authorize :none, reason: "scoped"; def resolve = [PlainCoverProbes::Record.new] }
    q = kit.query { field :l, resolver: r; field :c, t.connection_type, null: true, authorize: :none, reason: "scope"; PlainCoverProbes.on(:c) { [] } }
    obs = see(kit.schema(query: q), "{ l { secret } }")
    expect(obs.leak).to eq(false)
    expect(obs.problems.map(&:path).grep(/\AQuery\./)).to eq([])
  end

  it "p97 preservation: Base mutation with a rule under a covering mutation root" do
    m = ruled_mutation("M")
    root = kit.covering("Mutation") { field :m, mutation: m }
    clean see(kit.schema(mutation: root), "mutation { m { secret } }")
  end
end
