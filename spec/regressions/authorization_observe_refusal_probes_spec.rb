# frozen_string_literal: true

# Recheck of the design: a type under observe: that holds a resolver or mutation raises in its check.
# Each name starts with [security] or [preservation]. CHAR lines print what really happened.
module ObsF
  Doc = Struct.new(:id, :secret)

  class Decorator
    def initialize(inner) = @inner = inner
    def secret = @inner.secret
    def id = @inner.id
  end

  class ByAction < GraphQL::Armory::Authorization::Adapters::Substitute
    def initialize(allow_actions)
      super()
      @allow_actions = allow_actions
    end

    def authorized?(actor, subject, rule)
      @asked << [actor, subject, rule]
      @allow_actions.include?(rule.action)
    end
  end
end

RSpec.describe "observe: refuses a type holding a resolver" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:signals) { [] }
  let(:sink) { ->(signal, data) { signals << [signal, data] } }
  let(:record) { ObsF::Doc.new("1", "SECRET") }
  let(:refuse) { armory::Adapters::Substitute.new(allow: false) }
  let(:allow_all) { armory::Adapters::Substitute.new(allow: true) }
  let(:show_only) { ObsF::ByAction.new([:show]) }
  let(:ran) { [] }
  let(:base_field) do
    plugin = armory
    Class.new(GraphQL::Schema::Field) { include plugin::Base }
  end
  let(:base_object) do
    plugin = armory
    bf = base_field
    Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class bf
    end
  end

  # Records every step a query must not reach.
  def spy_resolver(superclass = GraphQL::Schema::Resolver)
    log = ran
    Class.new(superclass) do
      graphql_name "Touch" if superclass <= GraphQL::Schema::Mutation
      type String, null: true
      argument :input, String, required: false, prepare: ->(value, _ctx) { log << :prepare; value }
      define_method(:ready?) { |**_| log << :ready; true }
      define_method(:authorized?) { |**_| log << :authorized; true }
      define_method(:resolve) { |**_| log << :body; "ran" }
    end
  end

  def obj(name, parent: base_object, &block)
    Class.new(parent) do
      graphql_name name
      class_eval(&block)
    end
  end

  def observed(name = "Doc", parent: base_object, &block)
    obj(name, parent: parent) do
      authorize :read, model: Object, observe: "rollout"
      field :secret, String, null: true
      class_eval(&block) if block
    end
  end

  def root_of(fields)
    obj("Query") do
      authorize :none, reason: "root", covers_fields: true
      fields.each { |name, type| field name, type, null: true, authorize: :none, reason: "x", hash_key: name }
    end
  end

  def schema_for(query, adapter: refuse, orphans: [], resolve: nil, mutation: nil, handler: nil, error_class: StandardError)
    plugin = armory
    sinks = [sink]
    mutation_root = mutation
    Class.new(ArmoryEngine.base_schema) do
      query query
      mutation mutation_root if mutation_root
      orphan_types(*orphans) unless orphans.empty?
      define_singleton_method(:resolve_type) { |_type, _object, _context| resolve } if resolve
      rescue_from(error_class) { |_err, _obj, _args, _ctx, _field| handler.call } if handler
      use plugin, adapter: adapter, sinks: sinks
    end
  end

  # Result, or what it raised: an escaping raise is a refusal here.
  def run(schema, document, root: { doc: record }, **options)
    execute_query(schema, document, root_value: root, context: {}, **options).to_h
  rescue StandardError => error
    chain = []
    seen = error
    chain << seen.class.name while (seen = seen.cause)
    { "raised" => "#{error.class}: #{error.message[0, 70]}", "cause" => chain }
  end

  def char(label, response)
    STDOUT.puts "CHAR #{label} ran=#{ran.inspect} response=#{response.inspect[0, 330]} kinds=#{signals.map(&:first).inspect}"
  end

  def refused!(response)
    expect(ran).to be_empty
    expect(response.to_s).not_to include("SECRET")
  end

  q_touch = '{ doc { secret touch(input: "x") } }'
  let(:q) { q_touch }

  it "[env] versions" do
    STDOUT.puts "ENV graphql=#{GraphQL::VERSION} engine=#{ArmoryEngine.current}"
  end

  it "[control] the spy runs every step when nothing refuses, so an empty log means something" do
    r = spy_resolver
    type = obj("Doc") do
      authorize :read, model: Object
      field :secret, String, null: true
      field :touch, resolver: r
    end
    response = run(schema_for(root_of(doc: type), adapter: allow_all), q)
    char("control", response)
    expect(ran).to eq(%i[prepare ready authorized body])
  end

  describe "Q1 N1 authorize: true on an observed parent" do
    def parent_with(r)
      obj("Parent") do
        authorize :read, model: Object, observe: "rollout"
        field :secret, String, null: true
        field :touch, resolver: r, authorize: true
      end
    end

    it "[security] N1a-noargs same, with no argument: ready?, authorized?, body never run" do
      r = spy_resolver
      child = obj("Doc", parent: parent_with(r)) { authorize :show, model: Object }
      response = run(schema_for(root_of(doc: child), adapter: show_only), "{ doc { secret touch } }")
      char("N1a-noargs", response)
      expect(ran).to be_empty
    end

    it "[security] N1a-control the same parent with no observe: (does prepare run with an enforced rule?)" do
      r = spy_resolver
      parent = obj("Parent") do
        authorize :read, model: Object
        field :secret, String, null: true
        field :touch, resolver: r, authorize: true
      end
      child = obj("Doc", parent: parent) { authorize :show, model: Object }
      response = run(schema_for(root_of(doc: child), adapter: show_only), q)
      char("N1a-control", response)
      expect(ran - [:prepare]).to be_empty
    end

    it "[security] N1b bypass child that covers its fields" do
      r = spy_resolver
      child = obj("Doc", parent: parent_with(r)) { authorize :none, reason: "public", covers_fields: true }
      response = run(schema_for(root_of(doc: child)), q)
      char("N1b", response)
      expect(ran - [:prepare]).to be_empty
    end

    it "[security] N1c mutation: field" do
      r = spy_resolver(GraphQL::Schema::Mutation)
      child = obj("Doc", parent: parent_with(r)) { authorize :show, model: Object }
      response = run(schema_for(root_of(doc: child), adapter: show_only), "{ doc { secret touch } }")
      char("N1c", response)
      expect(ran).to be_empty
    end

    it "[characterization] N1d bypass child, nil-declared resolver on an observed parent: same as with no observe?" do
      r = spy_resolver
      observed_parent = obj("Parent") do
        authorize :read, model: Object, observe: "rollout"
        field :secret, String, null: true
        field :touch, resolver: r
      end
      child = obj("Doc", parent: observed_parent) { authorize :none, reason: "public", covers_fields: true }
      a = run(schema_for(root_of(doc: child)), q)
      with_observe = ran.dup
      ran.clear
      plain_parent = obj("Parent") do
        authorize :read, model: Object
        field :secret, String, null: true
        field :touch, resolver: r
      end
      child2 = obj("Doc", parent: plain_parent) { authorize :none, reason: "public", covers_fields: true }
      b = run(schema_for(root_of(doc: child2)), q)
      STDOUT.puts "CHAR N1d observed ran=#{with_observe} #{a.inspect[0, 160]} | plain ran=#{ran} #{b.inspect[0, 160]}"
      audit = GraphQL::Armory::Authorization::Audit.call(schema_for(root_of(doc: child)))
      STDOUT.puts "CHAR AUDIT N1d ok=#{audit.ok?} #{audit.problems.map { |x| [x.kind, x.path] }.inspect} bypasses=#{audit.bypasses.map(&:path).inspect}" if audit.respond_to?(:bypasses)
      expect(with_observe).to eq(ran)
    end
  end

  describe "Q1 N2 declaration shapes" do
    it "[security] N2a field class without Base" do
      r = spy_resolver
      plugin = armory
      plain = Class.new(GraphQL::Schema::Object) { include plugin::Base }
      response = run(schema_for(root_of(doc: observed(parent: plain) { field :touch, resolver: r })), q)
      char("N2a", response)
      refused!(response)
    end

    it "[security] N2b parent without Base" do
      r = spy_resolver
      bare = Class.new(GraphQL::Schema::Object) { field :touch, resolver: r }
      plugin = armory
      type = Class.new(bare) do
        include plugin::Base
        graphql_name "Doc"
        authorize :read, model: Object, observe: "rollout"
        field :secret, String, null: true
      end
      response = run(schema_for(root_of(doc: type)), q)
      char("N2b", response)
      refused!(response)
    end

    it "[security] N2c interface, own field class" do
      r = spy_resolver
      iface = Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Thing"
        field :touch, resolver: r
      end
      type = observed { implements iface }
      response = run(schema_for(root_of(doc: iface), orphans: [type], resolve: type), '{ doc { touch(input: "x") } }')
      char("N2c", response)
      refused!(response)
    end

    it "[security] N2d interface of an interface" do
      r = spy_resolver
      inner = Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Inner"
        field :touch, resolver: r
      end
      outer = Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Outer"
        implements inner
      end
      type = observed { implements outer }
      response = run(schema_for(root_of(doc: type), orphans: [type]), q)
      char("N2d", response)
      refused!(response)
    end

    it "[security] N2e interface implemented later, between two queries" do
      r = spy_resolver
      iface = Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Thing"
        field :touch, resolver: r
      end
      type = observed
      first = run(schema_for(root_of(doc: type)), "{ doc { secret } }")
      expect(first.dig("data", "doc", "secret")).to eq("SECRET")
      type.implements(iface)
      response = run(schema_for(root_of(doc: type), orphans: [type]), q)
      char("N2e", response)
      refused!(response)
    end

    it "[security] N2f a field added to an interface after the type implements it" do
      r = spy_resolver
      iface = Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Thing"
        field :other, String, null: true
      end
      type = observed { implements iface }
      iface.field :touch, resolver: r
      response = run(schema_for(root_of(doc: type), orphans: [type]), q)
      char("N2f", response)
      refused!(response)
    end

    it "[security] N2g subscription: field" do
      log = ran
      s = Class.new(GraphQL::Schema::Subscription) do
        graphql_name "Sub"
        type String, null: true
        define_method(:subscribe) { |**_| log << :body; "ran" }
      end
      type = observed { field :touch, subscription: s }
      response = run(schema_for(root_of(doc: type)), "{ doc { secret touch } }")
      char("N2g", response)
      refused!(response)
    end

    it "[security] N2h a RelayClassicMutation" do
      log = ran
      m = Class.new(GraphQL::Schema::RelayClassicMutation) do
        graphql_name "Touch"
        field :ok, GraphQL::Types::Boolean, null: true
        define_method(:resolve) { |**_| log << :body; { ok: true } }
      end
      type = observed { field :touch, mutation: m }
      response = run(schema_for(root_of(doc: type)), "{ doc { secret touch(input: {}) { ok } } }")
      char("N2h", response)
      refused!(response)
    end

    it "[security] N2j an union member" do
      r = spy_resolver
      type = observed { field :touch, resolver: r }
      resolved = type
      union = Class.new(GraphQL::Schema::Union) do
        graphql_name "U"
        possible_types type
        define_singleton_method(:resolve_type) { |_o, _c| resolved }
      end
      response = run(schema_for(root_of(doc: union)), '{ doc { ... on Doc { secret touch(input: "x") } } }')
      char("N2j", response)
      refused!(response)
    end

    it "[security] N2k an object in a list, no scope" do
      r = spy_resolver
      type = observed { field :touch, resolver: r }
      iface = Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Thing"
        field :secret, String, null: true
      end
      type.implements(iface)
      root = obj("Query") do
        authorize :none, reason: "root", covers_fields: true
        field :docs, [iface], null: true, authorize: :none, reason: "x", hash_key: :docs
      end
      response = run(schema_for(root, orphans: [type], resolve: type), '{ docs { ... on Doc { touch(input: "x") } } }', root: { docs: [record, record] })
      char("N2k", response)
      expect(ran).to be_empty
    end
  end

  describe "Q1 N3 rule and object shapes" do
    it "[security] N3a a rule with attribute:" do
      r = spy_resolver
      type = obj("Doc") do
        authorize :read, model: Object, attribute: :secret, observe: "rollout"
        field :secret, String, null: true
        field :touch, resolver: r
      end
      response = run(schema_for(root_of(doc: type)), q)
      char("N3a", response)
      refused!(response)
    end

    it "[security] N3b decorated in initialize" do
      r = spy_resolver
      type = observed do
        field :touch, resolver: r
        define_method(:initialize) { |object, context| super(ObsF::Decorator.new(object), context) }
      end
      response = run(schema_for(root_of(doc: type)), q)
      char("N3b", response)
      refused!(response)
    end

    it "[security] N3c decorated in authorized_new" do
      r = spy_resolver
      type = observed do
        field :touch, resolver: r
        define_singleton_method(:authorized_new) { |object, context| super(ObsF::Decorator.new(object), context) }
      end
      response = run(schema_for(root_of(doc: type)), q)
      char("N3c", response)
      refused!(response)
    end

    it "[security] N3d an allowed user: raises too" do
      r = spy_resolver
      response = run(schema_for(root_of(doc: observed { field :touch, resolver: r }), adapter: allow_all), q)
      char("N3d", response)
      refused!(response)
    end
  end

  describe "shadowed definitions" do
    it "[characterization] S1 child replaces the parent's resolver with a plain field, inheriting the observed rule" do
      r = spy_resolver
      parent = observed("Parent") { field :touch, resolver: r }
      child = obj("Doc", parent: parent) { field :touch, String, null: true, hash_key: :secret }
      response = run(schema_for(root_of(doc: child)), "{ doc { secret touch } }")
      char("S1", response)
      expect(ran).to be_empty
    end

    it "[security] S2 child replaces a plain field with a resolver" do
      r = spy_resolver
      parent = observed("Parent") { field :touch, String, null: true }
      child = obj("Doc", parent: parent) { field :touch, resolver: r }
      response = run(schema_for(root_of(doc: child)), q)
      char("S2", response)
      refused!(response)
    end

    it "[security] S3 parent with no rule holds the resolver, an observed child replaces it" do
      r = spy_resolver
      parent = obj("Parent") { field :touch, resolver: r }
      child = observed("Doc", parent: parent) { field :touch, String, null: true, hash_key: :secret }
      response = run(schema_for(root_of(doc: child)), "{ doc { secret touch } }")
      char("S3", response)
      expect(ran).to be_empty
    end

    it "[security] S4 two definitions of one field, one with a resolver" do
      r = spy_resolver
      type = observed do
        field :touch, String, null: true, hash_key: :secret
        field :touch, resolver: r
      end
      response = run(schema_for(root_of(doc: type)), "{ doc { secret touch } }")
      char("S4", response)
      expect(ran).to be_empty
    end

    it "[characterization] S5 a shadowed field whose definition block cannot load, on an observed type" do
      parent = obj("Parent") do
        authorize :read, model: Object, observe: "rollout"
        field(:gone, String, null: true) { argument :x, ThisConstantDoesNotExist }
      end
      child = obj("Doc", parent: parent) do
        field :gone, String, null: true, hash_key: :secret
      end
      response = run(schema_for(root_of(doc: child)), "{ doc { gone } }")
      char("S5", response)
    end

    it "[characterization] S5-control the same shadowed field, the rule enforced and allowed, no observe:" do
      parent = obj("Parent") do
        authorize :read, model: Object
        field(:gone, String, null: true) { argument :x, ThisConstantDoesNotExist }
      end
      child = obj("Doc", parent: parent) do
        field :gone, String, null: true, hash_key: :secret
      end
      response = run(schema_for(root_of(doc: child), adapter: allow_all), "{ doc { gone } }")
      char("S5-control", response)
    end
  end

  describe "a mutation response" do
    def save_mutation(type)
      log = ran
      rec = record
      plugin = armory
      m = Class.new(GraphQL::Schema::Mutation) do
        include plugin::Base
        graphql_name "Save"
        authorize :none, reason: "x"
        type type, null: true
        define_method(:resolve) { log << :mutation; rec }
      end
      obj("Mutation") do
        authorize :none, reason: "root", covers_fields: true
        field :save, mutation: m
      end
    end

    it "[security] R1 an observed type with a resolver, reached only in a mutation's response" do
      r = spy_resolver
      type = observed { field :touch, resolver: r }
      response = run(schema_for(root_of(other: observed("Other")), mutation: save_mutation(type)), 'mutation { save { secret touch(input: "x") } }')
      char("R1", response)
      expect(ran - [:mutation]).to be_empty
      expect(response.to_s).not_to include("SECRET")
    end

    it "[security] R2 same, no resolver: refused because only a query runs" do
      type = observed
      response = run(schema_for(root_of(other: observed("Other")), mutation: save_mutation(type)), "mutation { save { secret } }")
      char("R2", response)
      expect(response.to_s).not_to include("SECRET")
    end
  end

  describe "multiplex and partial" do
    def multiplex(schema, queries)
      ArmoryEngine.next? ? schema.multiplex_next(queries) : schema.multiplex(queries)
    end

    it "[security] X1 multiplex: a raising query, a shared context" do
      r = spy_resolver
      shared = {}
      schema = schema_for(root_of(doc: observed { field :touch, resolver: r }))
      out = begin
        multiplex(schema, [{ query: "{ doc { secret } }", root_value: { doc: record }, context: shared },
                           { query: q, root_value: { doc: record }, context: shared }]).map(&:to_h)
      rescue StandardError => error
        { "raised" => error.class.name }
      end
      char("X1", out)
      refused!(out)
    end

    it "[security] X2 multiplex: two observed types, one with a resolver, handler on: memo does not cross" do
      r = spy_resolver
      clean = observed("Clean")
      dirty = observed("Dirty") { field :touch, resolver: r }
      schema = schema_for(root_of(clean: clean, dirty: dirty), handler: -> {})
      out = multiplex(schema, [{ query: "{ clean { secret } }", root_value: { clean: record }, context: {} },
                               { query: "{ dirty { touch } }", root_value: { dirty: record }, context: {} }]).map(&:to_h)
      char("X2", out)
      expect(ran).to be_empty
      expect(out.first.dig("data", "clean", "secret")).to eq("SECRET")
    end

    def partial(schema, document, root, path)
      GraphQL::Query.new(schema, document, root_value: root, context: {}).run_partials([{ path: path, object: record }]).first.to_h
    rescue StandardError => error
      { "raised" => "#{error.class}: #{error.message[0, 70]}", "cause" => error.cause&.class&.name }
    end

    it "[security] P1 a partial on the observed object" do
      skip "no partial" unless defined?(GraphQL::Query::Partial)
      r = spy_resolver
      schema = schema_for(root_of(doc: observed { field :touch, resolver: r }))
      out = partial(schema, q, {}, ["doc"])
      char("P1", out)
      refused!(out)
    end

    it "[security] P2 a partial on the resolver field itself, the record as its parent" do
      skip "no partial" unless defined?(GraphQL::Query::Partial)
      r = spy_resolver
      schema = schema_for(root_of(doc: observed { field :touch, resolver: r }))
      out = partial(schema, q, {}, %w[doc touch])
      char("P2", out)
      expect(ran).to be_empty
    end

    it "[security] P3 a partial on the field, authorize: true on an observed parent, allowed child" do
      skip "no partial" unless defined?(GraphQL::Query::Partial)
      r = spy_resolver
      parent = obj("Parent") do
        authorize :read, model: Object, observe: "rollout"
        field :touch, resolver: r, authorize: true
      end
      child = obj("Doc", parent: parent) { authorize :show, model: Object }
      schema = schema_for(root_of(doc: child), adapter: show_only)
      out = partial(schema, '{ doc { touch(input: "x") } }', {}, %w[doc touch])
      char("P3", out)
      expect(ran - [:prepare]).to be_empty
    end
  end

  describe "Q2" do
    it "[security] O1 both selection orders give the same outcome" do
      r = spy_resolver
      schema = schema_for(root_of(doc: observed { field :touch, resolver: r }))
      a = run(schema, '{ doc { secret touch(input: "x") } }')
      b = run(schema, '{ doc { touch(input: "x") secret } }')
      char("O1", [a, b])
      expect(ran).to be_empty
      expect(a).to eq(b)
    end

    %w[ab ba].each do |order|
      it "[preservation] O2 same record through an observed type and an allowed type with a resolver, order #{order}" do
        r = spy_resolver
        seen = observed("Seen")
        open = obj("Open") do
          authorize :show, model: Object
          field :touch, resolver: r
        end
        doc = order == "ab" ? "{ seen { secret } open { touch } }" : "{ open { touch } seen { secret } }"
        response = run(schema_for(root_of(seen: seen, open: open), adapter: show_only), doc, root: { seen: record, open: record })
        char("O2-#{order}", response)
        expect(ran).to eq(%i[ready authorized body])
        expect(response.dig("data", "open", "touch")).to eq("ran")
        expect(response.dig("data", "seen", "secret")).to eq("SECRET")
      end

      it "[security] O3 same record through an observed type and a refused enforced type with a resolver, order #{order}" do
        r = spy_resolver
        seen = observed("Seen")
        closed = obj("Closed") do
          authorize :write, model: Object
          field :touch, resolver: r
        end
        doc = order == "ab" ? "{ seen { secret } closed { touch } }" : "{ closed { touch } seen { secret } }"
        response = run(schema_for(root_of(seen: seen, closed: closed)), doc, root: { seen: record, closed: record })
        char("O3-#{order}", response)
        expect(ran).to be_empty
      end
    end
  end

  describe "Q3 the audit" do
    def report_of(schema) = GraphQL::Armory::Authorization::Audit.call(schema)

    def describe_report(label, report)
      STDOUT.puts "CHAR AUDIT #{label} ok=#{report.ok?} #{report.problems.map { |x| [x.kind, x.path, x.message[0, 70]] }.inspect[0, 500]}"
    end

    it "[security] A1 N5 plain authorize: true on an observed parent, allowed child: refused user served, audit not ok" do
      parent = obj("Parent") do
        authorize :read, model: Object, observe: "rollout"
        field :secret, String, null: true, authorize: true
      end
      child = obj("Doc", parent: parent) { authorize :show, model: Object }
      schema = schema_for(root_of(doc: child), adapter: show_only)
      response = run(schema, "{ doc { secret } }")
      report = report_of(schema)
      char("A1", response)
      describe_report("A1", report)
      expect(report.ok?).to be(false)
      expect(report.problems.map(&:kind)).to include(:observed)
    end

    it "[security] A2 same with a child bypass" do
      parent = obj("Parent") do
        authorize :read, model: Object, observe: "rollout"
        field :secret, String, null: true, authorize: true
      end
      child = obj("Doc", parent: parent) { authorize :none, reason: "public", covers_fields: true }
      schema = schema_for(root_of(doc: child))
      response = run(schema, "{ doc { secret } }")
      report = report_of(schema)
      char("A2", response)
      describe_report("A2", report)
      expect(report.ok?).to be(false)
    end

    it "[security] A3 authorize: true on an observed grandparent, enforced middle, allowed grandchild" do
      top = obj("Top") do
        authorize :read, model: Object, observe: "rollout"
        field :secret, String, null: true, authorize: true
      end
      mid = obj("Mid", parent: top) { authorize :other, model: Object }
      leaf = obj("Doc", parent: mid) { authorize :show, model: Object }
      schema = schema_for(root_of(doc: leaf), adapter: show_only)
      response = run(schema, "{ doc { secret } }")
      report = report_of(schema)
      char("A3", response)
      describe_report("A3", report)
      expect(report.ok?).to be(false) if response.to_s.include?("SECRET")
    end

    it "[security] A4 the type that will raise says so, through an interface" do
      r = spy_resolver
      iface = Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Thing"
        field :touch, resolver: r
      end
      type = observed { implements iface }
      report = report_of(schema_for(root_of(doc: type), orphans: [type]))
      describe_report("A4", report)
      expect(report.problems.find { |x| x.kind == :observed && x.path == "Doc" }.message).to include("raises")
    end

    it "[security] A5 authorize: true with a resolver on an observed parent, allowed child: says it raises" do
      r = spy_resolver
      parent = obj("Parent") do
        authorize :read, model: Object, observe: "rollout"
        field :touch, resolver: r, authorize: true
      end
      child = obj("Doc", parent: parent) { authorize :show, model: Object }
      report = report_of(schema_for(root_of(doc: child), adapter: show_only))
      describe_report("A5", report)
      expect(report.problems.map(&:message).join).to include("raises")
    end

    it "[security] A6 a type with no resolver does not claim it will raise" do
      report = report_of(schema_for(root_of(doc: observed)))
      describe_report("A6", report)
      expect(report.problems.map(&:message).join).not_to include("raises")
      expect(report.problems.map(&:kind)).to include(:observed)
    end

    it "[security] A8 an observed rule on an interface owner, authorize: true" do
      plugin = armory
      fc = base_field
      iface = begin
        Module.new do
          include GraphQL::Schema::Interface
          include plugin::Base
          graphql_name "Thing"
          field_class fc
          authorize :read, model: Object, observe: "rollout"
          field :secret, String, null: true, authorize: true
        end
      rescue StandardError, NoMethodError => error
        STDOUT.puts "CHAR A8 declare raised #{error.class}: #{error.message[0, 100]}"
        nil
      end
      next unless iface

      type = obj("Doc") do
        implements iface
        authorize :show, model: Object
      end
      schema = schema_for(root_of(doc: type), adapter: show_only, orphans: [type])
      response = run(schema, "{ doc { secret } }")
      report = report_of(schema)
      char("A8", response)
      describe_report("A8", report)
      expect(report.ok?).to be(false) if response.to_s.include?("SECRET")
    end
  end

  describe "Q4 rescue_from" do
    handlers = { "true" => -> { true }, "string" => -> { "HANDLER" }, "nil" => -> {} }
    classes = { "StandardError" => StandardError, "ConfigurationError" => GraphQL::Armory::Authorization::ConfigurationError }

    classes.each do |class_name, error_class|
      handlers.each do |answer, handler|
        it "[security] H1 object check, #{class_name} handler answers #{answer}" do
          r = spy_resolver
          response = run(schema_for(root_of(doc: observed { field :touch, resolver: r }), handler: handler, error_class: error_class), q)
          char("H1 #{class_name} #{answer}", response)
          refused!(response)
        end

        it "[security] H2 field check on an observed parent, allowed child, #{class_name} handler answers #{answer}" do
          r = spy_resolver
          parent = obj("Parent") do
            authorize :read, model: Object, observe: "rollout"
            field :secret, String, null: true
            field :touch, resolver: r, authorize: true
          end
          child = obj("Doc", parent: parent) { authorize :show, model: Object }
          response = run(schema_for(root_of(doc: child), adapter: show_only, handler: handler, error_class: error_class), "{ doc { touch } }")
          char("H2 #{class_name} #{answer}", response)
          expect(ran).to be_empty
          expect(response.to_s).not_to include("\"ran\"")
        end

        it "[security] H3 root type, #{class_name} handler answers #{answer}" do
          r = spy_resolver
          root = obj("Query") do
            authorize :read, model: Object, observe: "rollout"
            field :secret, String, null: true, hash_key: :secret
            field :touch, resolver: r
          end
          response = run(schema_for(root, handler: handler, error_class: error_class), "{ secret touch }", root: { secret: "SECRET" })
          char("H3 #{class_name} #{answer}", response)
          refused!(response)
        end

        it "[security] H4 root type, nil root_value, #{class_name} handler answers #{answer}" do
          r = spy_resolver
          root = obj("Query") do
            authorize :read, model: Object, observe: "rollout"
            field :touch, resolver: r
          end
          response = run(schema_for(root, handler: handler, error_class: error_class), "{ touch }", root: nil)
          char("H4 #{class_name} #{answer}", response)
          expect(ran).to be_empty
        end
      end
    end

    it "[security] H0 root type, no handler at all" do
      r = spy_resolver
      root = obj("Query") do
        authorize :read, model: Object, observe: "rollout"
        field :secret, String, null: true, hash_key: :secret
        field :touch, resolver: r
      end
      response = run(schema_for(root), "{ secret touch }", root: { secret: "SECRET" })
      char("H0", response)
      refused!(response)
    end

    it "[security] H5 root type, a handler for NoMethodError answers true" do
      r = spy_resolver
      root = obj("Query") do
        authorize :read, model: Object, observe: "rollout"
        field :secret, String, null: true, hash_key: :secret
        field :touch, resolver: r
      end
      response = run(schema_for(root, handler: -> { true }, error_class: NoMethodError), "{ secret touch }", root: { secret: "SECRET" })
      char("H5", response)
      refused!(response)
    end

    it "[security] H6 mutation root observed, StandardError handler" do
      r = spy_resolver(GraphQL::Schema::Mutation)
      query_root = root_of(doc: observed)
      mroot = obj("Mutation") do
        authorize :read, model: Object, observe: "rollout"
        field :touch, mutation: r
      end
      response = run(schema_for(query_root, mutation: mroot, handler: -> { true }), "mutation { touch }", root: {})
      char("H6", response)
      expect(ran).to be_empty
    end
  end

  describe "Q5" do
    it "[preservation] K1 no resolver: served, recorded, no error" do
      response = run(schema_for(root_of(doc: observed)), "{ doc { secret } }")
      char("K1", response)
      expect(response).to eq("data" => { "doc" => { "secret" => "SECRET" } })
      expect(signals.map(&:first)).to include(:observed)
    end

    it "[preservation] K2 a resolver on a sibling type does not reach a clean observed type" do
      r = spy_resolver
      clean = observed("Clean")
      closed = obj("Closed") do
        authorize :write, model: Object
        field :touch, resolver: r
      end
      response = run(schema_for(root_of(clean: clean, closed: closed)), "{ clean { secret } closed { touch } }", root: { clean: record, closed: record })
      char("K2", response)
      expect(response.dig("data", "clean", "secret")).to eq("SECRET")
    end

    %w[clean-first dirty-first].each do |order|
      it "[security] K3 memo: a clean parent and a dirty child in one query, #{order}" do
        r = spy_resolver
        clean = observed("Clean")
        dirty = obj("Dirty", parent: clean) { field :touch, resolver: r }
        doc = order == "clean-first" ? "{ clean { secret } dirty { secret } }" : "{ dirty { secret } clean { secret } }"
        response = run(schema_for(root_of(clean: clean, dirty: dirty), adapter: refuse, handler: -> {}), doc, root: { clean: record, dirty: record })
        char("K3 #{order}", response)
        expect(response.dig("data", "clean", "secret")).to eq("SECRET")
        expect(response.dig("data", "dirty")).to be_nil
      end
    end

    it "[security] K4 a field added to the type between queries is read" do
      r = spy_resolver
      type = observed
      schema = schema_for(root_of(doc: type))
      expect(run(schema, "{ doc { secret } }").dig("data", "doc", "secret")).to eq("SECRET")
      type.field :touch, resolver: r
      response = run(schema, q)
      char("K4", response)
      refused!(response)
    end

    it "[characterization] K5 a field added during the query, after the memo was filled" do
      r = spy_resolver
      holder = []
      type = observed
      type.field(:add, String, null: true, resolver_method: :add_it)
      type.define_method(:add_it) do
        holder.first.field(:touch, resolver: r) unless holder.first.own_fields.key?("touch")
        "added"
      end
      holder << type
      schema = schema_for(root_of(doc: type))
      response = run(schema, "{ first: doc { add } second: doc { secret } }")
      char("K5", response)
      expect(ran).to be_empty
    end

    it "[security] K6 a definition block is loaded and its resolver read" do
      r = spy_resolver
      type = observed do
        field(:touch, resolver: r) { |f| f.argument(:extra, String, required: false) }
      end
      response = run(schema_for(root_of(doc: type)), q)
      char("K6", response)
      refused!(response)
    end

    it "[preservation] K7 a definition block on a plain field does not raise" do
      type = observed do
        field(:other, String, null: true, hash_key: :secret) { |f| f.argument(:extra, String, required: false) }
      end
      response = run(schema_for(root_of(doc: type)), "{ doc { other } }")
      char("K7", response)
      expect(response).to eq("data" => { "doc" => { "other" => "SECRET" } })
    end

    it "[preservation] K8 a field's own observe: on a plain field of an enforced type with a resolver" do
      r = spy_resolver
      type = obj("Doc") do
        authorize :show, model: Object
        field :secret, String, null: true, authorize: :read, observe: "rollout"
        field :touch, resolver: r
      end
      response = run(schema_for(root_of(doc: type), adapter: show_only), "{ doc { secret touch } }")
      char("K8", response)
      expect(response.dig("data", "doc", "secret")).to eq("SECRET")
      expect(response.dig("data", "doc", "touch")).to eq("ran")
    end
  end
end
