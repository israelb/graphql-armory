# frozen_string_literal: true

# Probes of the verification of PR #57 (RootCheck and the Warden fallback in live_fields), kept as regressions.
# Each probe is labelled [security] or [preservation]. "dump" wrote what a probe saw, to compare the branch with main
# during the verification; here it records nothing, and the preservation probes assert main's behaviour.
require "json"
require "fileutils"
require "securerandom"
require "digest"

class VerifierByAction
  attr_reader :asked

  def initialize(answers = {})
    @answers = answers
    @asked = []
  end

  def actor(context) = context[:user]

  def authorized?(_actor, _subject, rule)
    @asked << rule.action
    @answers.fetch(rule.action, false)
  end

  def scope(_actor, items, _rule) = items
  def check(_type, _rule) = []
end

RSpec.describe "Verifier probes PR #57" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:ran) { [] }
  let(:signals) { [] }
  let(:sink) do
    log = signals
    ->(signal, data) { log << [signal, data[:type], data[:action]] }
  end
  let(:adapter) { VerifierByAction.new(read: false, export: false) }


  def dump(name, value) = [name, value]

  def base_field
    @base_field ||= begin
      plugin = armory
      Class.new(GraphQL::Schema::Field) { include plugin::Base }
    end
  end

  def base_object
    @base_object ||= begin
      plugin = armory
      fc = base_field
      Class.new(GraphQL::Schema::Object) do
        include plugin::Base
        field_class fc
      end
    end
  end

  def resolver(tag = :body)
    log = ran
    Class.new(GraphQL::Schema::Resolver) do
      type String, null: true
      define_method(:resolve) do |**|
        log << tag
        "RAN"
      end
    end
  end

  def resolver_with_prepare
    log = ran
    Class.new(GraphQL::Schema::Resolver) do
      type String, null: true
      argument :x, String, required: false, prepare: ->(value, _ctx) { log << :prepare; value }
      define_method(:resolve) do |**|
        log << :body
        "RAN"
      end
    end
  end

  def resolver_with_loads(target)
    log = ran
    Class.new(GraphQL::Schema::Resolver) do
      type String, null: true
      argument :doc_id, GraphQL::Types::ID, required: false, loads: target
      define_method(:resolve) do |**|
        log << :body
        "RAN"
      end
    end
  end

  def mutation_class
    log = ran
    Class.new(GraphQL::Schema::Mutation) do
      graphql_name "DoIt"
      field :ok, String, null: true
      define_method(:resolve) do |**|
        log << :mutation_body
        { ok: "WROTE" }
      end
    end
  end

  def fine_query(extra: nil)
    Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :ping, String, null: true, authorize: :none, reason: "x", hash_key: :ping
      class_eval(&extra) if extra
    end
  end

  def bad_query(extra: nil)
    r = resolver
    Class.new(base_object) do
      graphql_name "Query"
      authorize :read, model: Object, observe: "rollout"
      field :touch, resolver: r
      field :ping, String, null: true, hash_key: :ping
      class_eval(&extra) if extra
    end
  end

  def bad_mutation
    m = mutation_class
    Class.new(base_object) do
      graphql_name "Mutation"
      authorize :read, model: Object, observe: "rollout"
      field :do_it, mutation: m
    end
  end

  def schema_for(query: nil, mutation: nil, subscription: nil, adapter: self.adapter, handler: false, visibility: nil, sinks: [sink], extra: nil, before: nil)
    plugin = armory
    Class.new(ArmoryEngine.base_schema) do
      class_eval(&before) if before
      query(query) if query
      mutation(mutation) if mutation
      subscription(subscription) if subscription
      use GraphQL::Schema::Visibility, **visibility if visibility
      use plugin, adapter: adapter, sinks: sinks
      rescue_from(StandardError) { |_error| nil } if handler
      class_eval(&extra) if extra
    end
  end

  def run(schema, document, root: { ping: "pong", doc: { secret: "S", ping: "p" }, docs: [] }, **options)
    options[:context] ||= { user: :bob }
    execute_query(schema, document, root_value: root, **options)
  end

  def outcome
    result = yield
    plain = ->(r) { r.is_a?(Array) ? r.map { |x| plain.(x) } : (r.respond_to?(:to_h) ? r.to_h : r) }
    { "result" => plain.(result) }
  rescue StandardError => error
    { "raised" => error.class.name, "message" => error.message[0, 160], "cause" => error.cause&.class&.name }
  end

  def multiplex(schema, queries)
    if ArmoryEngine.next?
      schema.multiplex_next(queries)
    else
      schema.multiplex(queries)
    end
  end

  def nested(type, extra: nil)
    fine_query(extra: proc {
      field :doc, type, null: true, authorize: :none, reason: "x", hash_key: :doc
      class_eval(&extra) if extra
    })
  end

  # A parent with resolver field `touch`, a child that hides its override from :bob.
  def hidden_override_child(r: resolver, child_rule: { observe: "rollout" }, override: { authorize: :manage, visible_when: :export }, name: "Doc", parent_opts: {})
    parent = Class.new(base_object) do
      graphql_name "#{name}Parent"
      authorize :read, model: Object
      field :touch, resolver: r, **parent_opts
    end
    rule = child_rule
    ov = override
    Class.new(parent) do
      graphql_name name
      authorize :read, model: Object, **rule
      field :touch, String, null: true, hash_key: :secret, **ov
      field :secret, String, null: true, hash_key: :secret
      field :ping, String, null: true, hash_key: :ping
    end
  end

  def config_error = armory::ConfigurationError

  # ------------------------------------------------------------------ root operations

  it "[security] S01 an observed mutation root holding a mutation raises ConfigurationError from execute, past rescue_from, no body" do
    [false, true].each do |handler|
      schema = schema_for(query: fine_query, mutation: bad_mutation, handler: handler)
      res = outcome { run(schema, "mutation { doIt { ok } }") }
      dump("S01-handler-#{handler}", res)
      expect(res["raised"]).to eq(config_error.name), res.inspect
      expect(res["message"]).to include("Mutation cannot be observed")
    end
    expect(ran).to eq([])
  end

  it "[security] S02 an observed subscription root holding a subscription field raises from execute, past rescue_from, no subscribe" do
    log = ran
    sub = Class.new(GraphQL::Schema::Subscription) do
      graphql_name "Changed"
      field :value, String, null: true
      define_method(:subscribe) { |**| log << :subscribe; { value: "SUB" } }
      define_method(:update) { |**| log << :update; { value: "UPD" } }
    end
    subscription_root = Class.new(base_object) do
      graphql_name "Subscription"
      authorize :read, model: Object, observe: "rollout"
      field :changed, subscription: sub
    end
    [false, true].each do |handler|
      schema = schema_for(query: fine_query, subscription: subscription_root, handler: handler)
      res = outcome { run(schema, "subscription { changed { value } }") }
      dump("S02-handler-#{handler}", res)
      expect(res["raised"]).to eq(config_error.name), res.inspect
    end
    expect(ran).to eq([])
  end

  it "[security] S03 a root whose own rule is not observed but holds `authorize: true` resolver from an observed parent raises from execute" do
    r = resolver
    parent = Class.new(base_object) do
      graphql_name "QueryParent"
      authorize :read, model: Object, observe: "rollout"
      field :touch, resolver: r, authorize: true
    end
    query = Class.new(parent) do
      graphql_name "Query"
      authorize :read, model: Object
      field :ping, String, null: true, hash_key: :ping
    end
    allow_all = VerifierByAction.new(read: true)
    res = outcome { run(schema_for(query: query, adapter: allow_all, handler: true), "{ touch }") }
    dump("S03", res)
    expect(res["raised"]).to eq(config_error.name), res.inspect
    expect(ran).to eq([])
  end

  it "[security] S04 a root inheriting an observed rule and a resolver from its parent raises from execute under rescue_from" do
    r = resolver
    parent = Class.new(base_object) do
      graphql_name "QueryParent"
      authorize :read, model: Object, observe: "rollout"
      field :touch, resolver: r
    end
    query = Class.new(parent) { graphql_name "Query" }
    res = outcome { run(schema_for(query: query, handler: true), "{ touch }") }
    dump("S04", res)
    expect(res["raised"]).to eq(config_error.name), res.inspect
    expect(ran).to eq([])
  end

  it "[security] S05 an observed root holding a resolver from an interface raises from execute under rescue_from" do
    r = resolver
    iface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Touchable"
      field :touch, resolver: r
    end
    query = Class.new(base_object) do
      graphql_name "Query"
      implements iface
      authorize :read, model: Object, observe: "rollout"
      field :ping, String, null: true, hash_key: :ping
    end
    res = outcome { run(schema_for(query: query, handler: true), "{ touch ping }") }
    dump("S05", res)
    expect(res["raised"]).to eq(config_error.name), res.inspect
    expect(ran).to eq([])
  end

  # ------------------------------------------------------------------ Warden fallback

  it "[security] S06 an observed ROOT whose override of a parent's resolver is hidden (visible_when) raises from execute; r never runs" do
    child = hidden_override_child(name: "Query")
    [false, true].each do |handler|
      res = outcome { run(schema_for(query: child, handler: handler), "{ touch ping }") }
      dump("S06-handler-#{handler}", res)
      expect(res["raised"]).to eq(config_error.name), res.inspect
    end
    expect(ran).to eq([])
  end

  it "[security] S07 an observed nested type whose override is hidden by a field class's own visible? (no visible_when) never runs r" do
    hidden_field = Class.new(base_field) { define_method(:visible?) { |_ctx| false } }
    r = resolver
    parent = Class.new(base_object) do
      graphql_name "DocParent"
      authorize :read, model: Object
      field :touch, resolver: r
    end
    child = Class.new(parent) do
      graphql_name "Doc"
      authorize :read, model: Object, observe: "rollout"
      field_class hidden_field
      field :touch, String, null: true, hash_key: :secret
      field_class superclass.field_class
      field :ping, String, null: true, hash_key: :ping
    end
    res = outcome { run(schema_for(query: nested(child), handler: true), "{ doc { touch ping } }") }
    dump("S07", res)
    expect(ran).to eq([]), res.inspect
  end

  it "[security] S08 observed_reason through the fallback: a non-observed child hides its override of an observed parent's `authorize: true` resolver" do
    r = resolver
    parent = Class.new(base_object) do
      graphql_name "DocParent"
      authorize :read, model: Object, observe: "rollout"
      field :touch, resolver: r, authorize: true
    end
    child = Class.new(parent) do
      graphql_name "Doc"
      authorize :read, model: Object
      field :touch, String, null: true, hash_key: :secret, authorize: :manage, visible_when: :export
      field :ping, String, null: true, hash_key: :ping
    end
    allow_read = VerifierByAction.new(read: true, export: false)
    nested_res = outcome { run(schema_for(query: nested(child), adapter: allow_read, handler: true), "{ doc { touch ping } }") }
    dump("S08-nested", nested_res)
    expect(ran).to eq([]), nested_res.inspect

    root_parent = Class.new(base_object) do
      graphql_name "QueryParent"
      authorize :read, model: Object, observe: "rollout"
      field :touch, resolver: r, authorize: true
    end
    root = Class.new(root_parent) do
      graphql_name "Query"
      authorize :read, model: Object
      field :touch, String, null: true, hash_key: :secret, authorize: :manage, visible_when: :export
      field :ping, String, null: true, hash_key: :ping
    end
    root_res = outcome { run(schema_for(query: root, adapter: allow_read, handler: true), "{ touch ping }") }
    dump("S08-root", root_res)
    expect(root_res["raised"]).to eq(config_error.name), root_res.inspect
    expect(ran).to eq([])
  end

  it "[security] S09 through the fallback, the parent's resolver `prepare:` never runs (nested, rescue_from)" do
    child = hidden_override_child(r: resolver_with_prepare)
    res = outcome { run(schema_for(query: nested(child), handler: true), '{ doc { touch(x: "a") ping } }') }
    dump("S09", res)
    expect(ran).to eq([]), res.inspect
  end

  it "[security] S10 through the fallback, the parent's resolver `loads:` is never coerced (nested, rescue_from)" do
    log = ran
    target = Class.new(GraphQL::Schema::Object) do
      graphql_name "Target"
      field :id, GraphQL::Types::ID, null: true
    end
    child = hidden_override_child(r: resolver_with_loads(target))
    schema = schema_for(query: nested(child), handler: true, extra: proc {
      orphan_types target
      define_singleton_method(:object_from_id) { |_id, _ctx| log << :loads; nil }
      define_singleton_method(:resolve_type) { |*| target }
    })
    res = outcome { run(schema, '{ doc { touch(docId: "1") ping } }') }
    dump("S10", res)
    expect(ran).to eq([]), res.inspect
  end

  it "[security] S11 three levels: grandparent resolver, two hidden overrides, nested: r never runs" do
    r = resolver
    grand = Class.new(base_object) do
      graphql_name "DocGrand"
      authorize :read, model: Object
      field :touch, resolver: r
    end
    parent = Class.new(grand) do
      graphql_name "DocParent"
      field :touch, String, null: true, hash_key: :secret, authorize: :manage, visible_when: :export
    end
    child = Class.new(parent) do
      graphql_name "Doc"
      authorize :read, model: Object, observe: "rollout"
      field :touch, String, null: true, hash_key: :secret, authorize: :manage, visible_when: :export
      field :ping, String, null: true, hash_key: :ping
    end
    res = outcome { run(schema_for(query: nested(child), handler: true), "{ doc { touch ping } }") }
    dump("S11", res)
    expect(ran).to eq([]), res.inspect
  end

  it "[security] S12 interface fallback: an observed type hides its override of an interface's resolver field (nested and root)" do
    r = resolver
    iface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Touchable"
      field :touch, resolver: r
    end
    doc = Class.new(base_object) do
      graphql_name "Doc"
      implements iface
      authorize :read, model: Object, observe: "rollout"
      field :touch, String, null: true, hash_key: :secret, authorize: :manage, visible_when: :export
      field :ping, String, null: true, hash_key: :ping
    end
    res = outcome { run(schema_for(query: nested(doc), handler: true), "{ doc { touch ping } }") }
    dump("S12-nested", res)
    expect(ran).to eq([]), res.inspect

    root = Class.new(base_object) do
      graphql_name "Query"
      implements iface
      authorize :read, model: Object, observe: "rollout"
      field :touch, String, null: true, hash_key: :secret, authorize: :manage, visible_when: :export
      field :ping, String, null: true, hash_key: :ping
    end
    root_res = outcome { run(schema_for(query: root, handler: true), "{ touch ping }") }
    dump("S12-root", root_res)
    expect(root_res["raised"]).to eq(config_error.name), root_res.inspect
    expect(ran).to eq([])
  end

  # ------------------------------------------------------------------ multiplex / operation selection

  it "[security] S13 a multiplex mixing a bad mutation and a good query: nothing of the bad one runs, in both orders" do
    good_log = ran
    good = Class.new(GraphQL::Schema::Resolver) do
      type String, null: true
      define_method(:resolve) { good_log << :good; "GOOD" }
    end
    query = fine_query(extra: proc { field :good, resolver: good, authorize: :none, reason: "x" })
    [false, true].each do |handler|
      schema = schema_for(query: query, mutation: bad_mutation, handler: handler)
      bad_q = { query: "mutation { doIt { ok } }", root_value: {}, context: { user: :bob } }
      good_q = { query: "{ good ping }", root_value: { ping: "pong" }, context: { user: :bob } }
      first = outcome { multiplex(schema, [bad_q, good_q]) }
      second = outcome { multiplex(schema, [good_q, bad_q]) }
      dump("S13-handler-#{handler}", { bad_first: first, good_first: second, ran: ran.dup })
      expect(ran).not_to include(:mutation_body)
    end
  end

  it "[security] S14 a multi-operation document: operation_name selects the bad mutation root -> raises; the query -> served" do
    schema = schema_for(query: fine_query, mutation: bad_mutation, handler: true)
    doc = "query A { ping } mutation B { doIt { ok } }"
    b = outcome { run(schema, doc, operation_name: "B") }
    a = outcome { run(schema, doc, operation_name: "A") }
    dump("S14", { b: b, a: a })
    expect(b["raised"]).to eq(config_error.name), b.inspect
    expect(a.dig("result", "data", "ping")).to eq("pong")
    expect(ran).to eq([])
  end

  it "[security] S15 context[:trace] (documented fallback): the bad root still runs nothing, under rescue_from" do
    schema = schema_for(query: bad_query, handler: true)
    res = outcome { run(schema, "{ touch }", context: { user: :bob, trace: schema.new_trace }) }
    dump("S15", res)
    expect(ran).to eq([]), res.inspect
  end

  it "[security] S15b a bare GraphQL::Tracing::Trace as context[:trace] (documented fallback): nothing runs under rescue_from" do
    schema = schema_for(query: bad_query, handler: true)
    res = outcome { run(schema, "{ touch }", context: { user: :bob, trace: GraphQL::Tracing::Trace.new }) }
    dump("S15b", res)
    expect(ran).to eq([]), res.inspect
  end

  it "[security] S16 subscription trigger goes through execute_multiplex: a root made unobservable after subscribing raises on trigger, no update" do
    log = ran
    subs_class = Class.new(GraphQL::Subscriptions) do
      attr_reader :stored, :delivered
      def initialize(**options)
        super
        @stored = {}
        @delivered = []
      end
      def write_subscription(query, events)
        id = query.context[:subscription_id] = SecureRandom.hex(4)
        @stored[id] = { query_string: query.query_string, variables: {}, context: { user: query.context[:user] }, operation_name: nil, events: events }
      end
      def read_subscription(id) = @stored[id]
      def each_subscription_id(event)
        @stored.each { |id, s| yield id if s[:events].any? { |e| e.topic == event.topic } }
      end
      def deliver(id, result) = @delivered << [id, result.to_h]
      def delete_subscription(id) = @stored.delete(id)
      def execute_all(event, object)
        each_subscription_id(event) { |id| execute(id, event, object) }
      end
    end
    sub = Class.new(GraphQL::Schema::Subscription) do
      graphql_name "Changed"
      field :value, String, null: true
      define_method(:subscribe) { |**| log << :subscribe; :no_response }
      define_method(:update) { |**| log << :update; { value: "UPD" } }
    end
    subscription_root = Class.new(base_object) do
      graphql_name "Subscription"
      authorize :read, model: Object
      field :changed, subscription: sub, authorize: :none, reason: "x"
    end
    allow = VerifierByAction.new(read: true)
    schema = schema_for(query: fine_query, subscription: subscription_root, adapter: allow, extra: proc { use subs_class })
    first = outcome { run(schema, "subscription { changed { value } }") }
    subscription_root.authorize :read, model: Object, observe: "rollout"
    log.clear
    trig = outcome { schema.subscriptions.trigger(:changed, {}, Object.new) }
    dump("S16", { first: first, trigger: trig, delivered: schema.subscriptions.delivered, ran: log.dup })
    expect(log).not_to include(:update)
  end

  it "[preservation] P09c observed type, hidden override, parent's resolver block names a missing constant: which error (dump)" do
    r = resolver
    parent = Class.new(base_object) do
      graphql_name "DocParent"
      authorize :read, model: Object
      field(:touch, resolver: r) { VerifierMissingConstant }
    end
    child = Class.new(parent) do
      graphql_name "Doc"
      authorize :read, model: Object, observe: "rollout"
      field :touch, String, null: true, hash_key: :secret, authorize: :manage, visible_when: :export
      field :ping, String, null: true, hash_key: :ping
    end
    res = outcome { run(schema_for(query: nested(child)), "{ doc { ping } }") }
    dump("P09c", { res: res, ran: ran })
    expect(ran).to eq([])
  end

  it "[security] S17 Schema::Visibility with static profiles: an observed root holding a resolver raises from execute" do
    schema = schema_for(query: bad_query, handler: true, visibility: { profiles: { public: {} } })
    res = outcome { run(schema, "{ touch ping }", context: { user: :bob, visibility_profile: :public }) }
    dump("S17", res)
    expect(res["raised"]).to eq(config_error.name), res.inspect
    expect(ran).to eq([])
  end

  it "[security] S18 Schema::Visibility dynamic: an observed root whose resolver field is hidden from the user still raises from execute" do
    r = resolver
    query = Class.new(base_object) do
      graphql_name "Query"
      authorize :read, model: Object, observe: "rollout"
      field :touch, resolver: r, visible_when: :export
      field :ping, String, null: true, hash_key: :ping
    end
    schema = schema_for(query: query, handler: true, visibility: { dynamic: true })
    res = outcome { run(schema, "{ ping }") }
    dump("S18", res)
    expect(res["raised"]).to eq(config_error.name), res.inspect
    expect(ran).to eq([])
  end

  # ------------------------------------------------------------------ preservation

  it "[preservation] P01 a good observed root (plain fields only), refused user: served and :observed recorded (dump)" do
    query = Class.new(base_object) do
      graphql_name "Query"
      authorize :read, model: Object, observe: "rollout"
      field :ping, String, null: true, hash_key: :ping
    end
    res = outcome { run(schema_for(query: query), "{ ping }") }
    dump("P01", { res: res, signals: signals, asked: adapter.asked })
    expect(res.dig("result", "data", "ping")).to eq("pong")
    expect(signals.map(&:first)).to include(:observed)
  end

  it "[preservation] P02 invalid documents on a bad-root schema (dump: compare with main)" do
    schema = schema_for(query: bad_query, mutation: bad_mutation)
    cases = {
      parse: -> { run(schema, "{ touch ") },
      nil_string: -> { run(schema, nil) },
      unknown_op: -> { run(schema, "query A { touch }", operation_name: "Nope") },
      ambiguous: -> { run(schema, "query A { touch } query B { ping }") },
      validation: -> { run(schema, "{ nope }") },
      typename: -> { run(schema, "{ __typename }") }
    }
    outcomes = cases.transform_values { |c| outcome(&c) }
    dump("P02", outcomes)
    expect(ran).to eq([])
    expect(outcomes[:validation]["raised"]).to be_nil
    expect(outcomes[:validation].dig("result", "errors")).not_to be_empty
  end

  it "[preservation] P03 an empty multiplex answers [] (dump)" do
    res = outcome { multiplex(schema_for(query: bad_query), []) }
    dump("P03", res)
    expect(res["raised"]).to be_nil
  end

  it "[preservation] P04 a mutation or subscription operation on a schema without that root (dump)" do
    schema = schema_for(query: fine_query)
    res = { m: outcome { run(schema, "mutation { x }") }, s: outcome { run(schema, "subscription { x }") } }
    dump("P04", res)
    expect(res[:m]["raised"]).to be_nil
    expect(res[:s]["raised"]).to be_nil
  end

  it "[preservation] P05-P08 roots: no Base, no rule, authorize :none, Base not observed: resolvers served as on main (dump)" do
    r = resolver
    plain = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :touch, resolver: r
    end
    norule = Class.new(base_object) do
      graphql_name "Query"
      field :touch, resolver: r
    end
    none = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :touch, resolver: r, authorize: :none, reason: "x"
    end
    unobserved = Class.new(base_object) do
      graphql_name "Query"
      authorize :read, model: Object
      field :touch, resolver: r, authorize: :none, reason: "x"
    end
    allow = VerifierByAction.new(read: true)
    res = { plain: plain, norule: norule, none: none, unobserved: unobserved }.transform_values do |q|
      outcome { run(schema_for(query: q, adapter: allow), "{ touch }") }
    end
    dump("P05", { res: res, ran: ran })
    expect(res[:none].dig("result", "data", "touch")).to eq("RAN")
    expect(res[:unobserved].dig("result", "data", "touch")).to eq("RAN")
  end

  it "[preservation] P08b cost: get_field calls on a many-type schema without shadowed resolvers, and a 200-item list with one (dump)" do
    counts = Hash.new(0)
    counting = Module.new do
      define_method(:get_field) do |name, *rest|
        counts[[graphql_name, name]] += 1
        super(name, *rest)
      end
    end
    types = Array.new(30) do |i|
      Class.new(base_object) do
        graphql_name "T#{i}"
        authorize :read, model: Object
        extend counting
        10.times { |j| field :"f#{j}", String, null: true, hash_key: :"f#{j}" }
      end
    end
    r = resolver
    parent = Class.new(base_object) do
      graphql_name "ItemParent"
      authorize :read, model: Object
      field :touch, resolver: r
    end
    item = Class.new(parent) do
      graphql_name "Item"
      extend counting
      field :touch, String, null: true, hash_key: :f0
      field :f1, String, null: true, hash_key: :f1
    end
    q = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      types.each_with_index { |t, i| field :"t#{i}", t, null: true, authorize: :none, reason: "x", hash_key: :"t#{i}" }
      field :items, [item], null: false, authorize: :none, reason: "x", hash_key: :items
    end
    allow = VerifierByAction.new(read: true)
    schema = schema_for(query: q, adapter: allow)
    root = (0...30).to_h { |i| [:"t#{i}", (0...10).to_h { |j| [:"f#{j}", "v"] }] }
    root[:items] = Array.new(200) { { f0: "a", f1: "b" } }
    doc = "{ #{(0...30).map { |i| "t#{i} { f0 f5 }" }.join(" ")} items { touch f1 } }"
    res = outcome { run(schema, doc, root: root) }
    plain_calls = counts.select { |(t, _), _| t.start_with?("T") }.values.sum
    item_calls = counts.select { |(t, _), _| t == "Item" }
    dump("P08b", { plain_calls: plain_calls, item_calls: item_calls, asked: allow.asked.size, errors: res.dig("result", "errors") })
    expect(ran).to eq([])
  end

  it "[preservation] P09 no observe anywhere, nested type hides its override of a parent's resolver: signals and policy calls (dump)" do
    child = hidden_override_child(child_rule: {})
    allow_read = VerifierByAction.new(read: true, export: false, manage: true)
    schema = schema_for(query: nested(child), adapter: allow_read)
    not_selected = outcome { run(schema, "{ doc { ping } }") }
    s1 = signals.dup
    a1 = allow_read.asked.dup
    signals.clear
    allow_read.asked.clear
    selected = outcome { run(schema, "{ doc { touch } }") }
    dump("P09", { not_selected: not_selected, s1: s1, a1: a1, selected: selected, s2: signals, a2: allow_read.asked, ran: ran })
    # With no observe:, the check asks no policy about a field nobody selected.
    expect(not_selected["raised"]).to be_nil
    expect(s1.flatten).not_to include(:export)
    expect(a1.flatten.map { |each| each.respond_to?(:action) ? each.action : each }).not_to include(:export)
  end

  it "[preservation] P09b no observe anywhere: a visible override of a parent resolver whose field block names a missing constant (dump)" do
    r = resolver
    parent = Class.new(base_object) do
      graphql_name "DocParent"
      authorize :read, model: Object
      field(:touch, resolver: r) { VerifierMissingConstant }
    end
    child = Class.new(parent) do
      graphql_name "Doc"
      authorize :read, model: Object, observe: "rollout"
      field :touch, String, null: true, hash_key: :secret
      field :ping, String, null: true, hash_key: :ping
    end
    visible = outcome { run(schema_for(query: nested(child)), "{ doc { touch ping } }") }
    hidden_parent = Class.new(base_object) do
      graphql_name "DocParent"
      authorize :read, model: Object
      field(:touch, resolver: r) { VerifierMissingConstant }
    end
    hidden_child = Class.new(hidden_parent) do
      graphql_name "Doc"
      authorize :read, model: Object
      field :touch, String, null: true, hash_key: :secret, authorize: :manage, visible_when: :export
      field :ping, String, null: true, hash_key: :ping
    end
    allow_read = VerifierByAction.new(read: true, export: false)
    hidden_not_selected = outcome { run(schema_for(query: nested(hidden_child), adapter: allow_read), "{ doc { ping } }") }
    dump("P09b", { visible: visible, hidden_not_selected: hidden_not_selected, ran: ran })
    expect(visible.dig("result", "data", "doc", "touch")).to eq("S")
    expect(hidden_not_selected["raised"]).to be_nil
    expect(ran).to eq([])
  end

  it "[preservation] P10 audit text for a bad-root schema and a hidden-override schema (dump)" do
    a = armory::Audit.(schema_for(query: bad_query, mutation: bad_mutation)).to_s
    b = armory::Audit.(schema_for(query: nested(hidden_override_child))).to_s
    dump("P10", { bad_root: a.gsub(%r{/app/[^\s:)]+}, "<path>"), hidden: b.gsub(%r{/app/[^\s:)]+}, "<path>") })
  end

  it "[preservation] P11 run_partials on a bad-root schema whose partial type is fine (dump)" do
    skip "no Query#run_partials in #{GraphQL::VERSION}" unless GraphQL::Query.method_defined?(:run_partials)
    doc_type = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: Object
      field :ping, String, null: true, hash_key: :ping
    end
    query_type = bad_query(extra: proc { field :doc, doc_type, null: true, authorize: :none, reason: "x", hash_key: :doc })
    allow = VerifierByAction.new(read: true)
    schema = schema_for(query: query_type, adapter: allow)
    query = GraphQL::Query.new(schema, "{ doc { ping } }", root_value: { doc: { ping: "p" } }, context: { user: :bob })
    query.context[:__graphql_execute_next] = true if ArmoryEngine.next?
    res = outcome { query.run_partials([{ path: ["doc"], object: { ping: "PARTIAL" } }]) }
    dump("P11", res)
    expect(res["raised"]).to be_nil
  end

  it "[preservation] P12 Visibility dynamic: a child with two same-name overrides (one per audience) of a parent's resolver field" do
    r = resolver
    parent = Class.new(base_object) do
      graphql_name "DocParent"
      authorize :read, model: Object
      field :touch, resolver: r
    end
    child = Class.new(parent) do
      graphql_name "Doc"
      authorize :read, model: Object
      field :touch, String, null: true, hash_key: :secret, authorize: :none, reason: "x", visible_when: :export
      field :touch, Integer, null: true, hash_key: :n, authorize: :none, reason: "x", visible_when: :admin
      field :ping, String, null: true, hash_key: :ping
    end
    allow = VerifierByAction.new(read: true, export: true, admin: false)
    vis = outcome { run(schema_for(query: nested(child), adapter: allow, visibility: { dynamic: true }), "{ doc { ping } }") }
    warden = outcome { run(schema_for(query: nested(child), adapter: VerifierByAction.new(read: true, export: true, admin: false)), "{ doc { ping } }") }
    dump("P12", { visibility: vis, warden: warden, ran: ran })
    expect(vis.dig("result", "data", "doc", "ping")).to eq("p"), vis.inspect
    expect(warden.dig("result", "data", "doc", "ping")).to eq("p"), warden.inspect
  end

  it "[preservation] P13 method owners on the real classes (dump)" do
    schema = schema_for(query: bad_query)
    trace = schema.new_trace
    owners = trace.class.ancestors.select { |m| m.instance_methods(false).include?(:execute_multiplex) }.map { |m| m.name || m.inspect[0, 60] }
    dump("P13", {
      execute_multiplex_owner: trace.method(:execute_multiplex).owner.name,
      chain: owners,
      field_eql: GraphQL::Schema::Field.instance_method(:eql?).owner.name,
      field_hash: GraphQL::Schema::Field.instance_method(:hash).owner.name,
      field_eqeq: GraphQL::Schema::Field.instance_method(:==).owner.name
    })
  end

  it "[preservation] P14 Concurrency: a bad root raising in execute_multiplex leaves no slot taken, both `use` orders" do
    store = GraphQL::Armory::RateLimits::MemoryStore.new
    [:limits_first, :armory_first].each do |order|
      plugin = armory
      limiter = GraphQL::Armory::RateLimits::Concurrency
      before = order == :limits_first ? proc { limiter.use(self, store: store, limit: 1, soft: false, key: ->(q) { "k-#{order}" }) } : nil
      extra = order == :armory_first ? proc { limiter.use(self, store: store, limit: 1, soft: false, key: ->(q) { "k-#{order}" }) } : nil
      schema = schema_for(query: fine_query, mutation: bad_mutation, before: before, extra: extra)
      bad = outcome { run(schema, "mutation { doIt { ok } }") }
      good1 = outcome { run(schema, "{ ping }") }
      good2 = outcome { run(schema, "{ ping }") }
      dump("P14-#{order}", { bad: bad, good1: good1, good2: good2 })
      expect(good2.dig("result", "data", "ping")).to eq("pong"), { bad: bad, good2: good2 }.inspect
    end
    expect(ran).to eq([])
  rescue ArgumentError => error
    dump("P14-error", error.message)
    raise
  end

  it "[preservation] P15 strict persisted queries: a raw query and a persisted bad-root query (dump)" do
    body = "{ touch }"
    manifest = GraphQL::Armory::PersistedQueries::Manifest.new({ Digest::SHA256.hexdigest(body) => body })
    schema = schema_for(query: bad_query, extra: proc { use GraphQL::Armory::PersistedQueries, store: manifest, strict: true })
    raw = outcome { run(schema, "{ ping }") }
    persisted = outcome { run(schema, nil, context: { user: :bob, operation_id: Digest::SHA256.hexdigest(body) }) }
    dump("P15", { raw: raw, persisted: persisted, ran: ran })
    expect(ran).to eq([])
  end

  it "[preservation] P16 version report" do
    dump("P16", { graphql: GraphQL::VERSION, engine: ArmoryEngine.current })
    $stdout.puts "[verifier] GraphQL::VERSION=#{GraphQL::VERSION} engine=#{ArmoryEngine.current}"
  end
end
