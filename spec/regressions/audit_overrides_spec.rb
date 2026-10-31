# frozen_string_literal: true

require "fileutils"
require "benchmark"

# One correction round: rule_signature silence, override_reason, reported set, armory_implementers, noise.
RSpec.describe "round: override audit" do
  armory = GraphQL::Armory::Authorization

  by_action = Class.new(armory::Adapters::Substitute) do
    def initialize(allowed)
      super()
      @allowed = allowed
    end

    def authorized?(_actor, _subject, rule) = @allowed.include?(rule.action)
  end

  let(:adapter) { by_action.new(%i[read]) }
  let(:base_field) { Class.new(GraphQL::Schema::Field) { include armory::Base } }
  # Hides one field by an option, the shape H4 uses: same field class on both levels.
  let(:flagged) do
    Class.new(base_field) do
      def initialize(*args, beta_only: false, **kwargs, &block)
        @beta_only = beta_only
        super(*args, **kwargs, &block)
      end

      def visible?(context) = super && (!@beta_only || context[:beta] == true)
    end
  end
  let(:base_object) do
    bf = flagged
    Class.new(GraphQL::Schema::Object) do
      include armory::Base
      field_class bf
      default_action :read
    end
  end

  def schema_for(query_class, setup: nil)
    plug = GraphQL::Armory::Authorization
    a = adapter
    Class.new(ArmoryEngine.base_schema) do
      use plug, adapter: a
      query query_class
      class_eval(&setup) if setup
    end
  end

  def query_with(&block)
    Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      class_eval(&block)
    end
  end

  def on_query(type) = query_with { field :doc, type, null: true, authorize: :none, reason: "x" }

  def doc_parent(&block)
    Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: Invoice
      class_eval(&block)
    end
  end

  def child_of(parent, &block)
    Class.new(parent) do
      graphql_name "Doc"
      class_eval(&block)
    end
  end

  def report(schema) = GraphQL::Armory::Authorization::Audit.(schema)
  def kinds(rep) = rep.problems.map(&:kind)
  def paths(rep) = rep.problems.map(&:path)

  def out(name, text)
  end

  def run(schema, query, root, context: { current_user: :reader })
    execute_query(schema, query, root_value: root, context: context).to_h
  end

  def root_notes(notes) = Struct.new(:doc).new(Struct.new(:notes).new(notes))

  # The report and what the refused user receives, side by side. A security probe fails on data + audit ok.
  def leak_check(schema, name, query: "{ doc { notes } }", root: root_notes("SECRET"), dig: %w[data doc notes], context: { current_user: :reader })
    served = run(schema, query, root, context: context)
    rep = report(schema)
    out("#{name}.txt", "served: #{served.inspect}\nok: #{rep.ok?}\nproblems: #{rep.problems.map(&:to_s)}\nbypasses: #{rep.bypasses.map(&:to_s)}")
    expect(served.dig(*dig) == "SECRET" && rep.ok?).to eq(false), "served #{served.inspect} with the audit ok"
    [served, rep]
  end

  it "[preservation] E0 which lib runs" do
    out("e0.txt", GraphQL::Armory::Authorization::Audit.instance_method(:call).source_location.first)
  end

  # --- S: rule_signature false silence -------------------------------------
  it "[preservation] S1 same authorize: :manage, different reason: same effect, same rule runs" do
    pa = doc_parent { field :notes, String, null: true, authorize: :manage, reason: "parent" }
    ch = child_of(pa) { field :notes, String, null: true, authorize: :manage, reason: "child", beta_only: true }
    served, = leak_check(schema_for(on_query(ch)), "s1")
    expect(served.dig("data", "doc", "notes")).to be_nil
  end

  it "[security] S1b same authorize: :none, different reason: the listed reason is not the one that answers" do
    pa = doc_parent { field :notes, String, null: true, authorize: :none, reason: "public on the parent" }
    ch = child_of(pa) { field :notes, String, null: true, authorize: :none, reason: "child reason", beta_only: true }
    rep = report(schema_for(on_query(ch)))
    out("s1b.txt", rep.bypasses.map(&:to_s).inspect)
    expect(rep.bypasses.map(&:reason)).to include("public on the parent")
  end

  it "[security] S2 same authorize: true, child's type is a covering bypass (true = denied), parent's asks :read" do
    pa = doc_parent { field :notes, String, null: true, authorize: true }
    ch = child_of(pa) do
      authorize :none, reason: "covers", covers_fields: true
      field :notes, String, null: true, authorize: true, beta_only: true
    end
    leak_check(schema_for(on_query(ch)), "s2")
  end

  it "[security] S2b same authorize: true, owners with different type rules (:read vs :manage)" do
    pa = doc_parent { field :notes, String, null: true, authorize: true }
    ch = child_of(pa) do
      authorize :manage, model: Invoice
      field :notes, String, null: true, authorize: true, beta_only: true
    end
    leak_check(schema_for(on_query(ch)), "s2b")
  end

  it "[security] S3 no rule on both, parent's type a covering bypass, child's bypassed without cover" do
    pa = Class.new(base_object) do
      graphql_name "Doc"
      authorize :none, reason: "covers", covers_fields: true
      field :notes, String, null: true
    end
    ch = child_of(pa) do
      authorize :none, reason: "does not cover"
      field :notes, String, null: true, beta_only: true
    end
    leak_check(schema_for(on_query(ch)), "s3")
  end

  it "[security] S4 same field rule, the override's argument declares a rule the ancestor's does not" do
    arg = Class.new(GraphQL::Schema::Argument) { include GraphQL::Armory::Authorization::Base }
    pa = doc_parent { field(:notes, String, null: true) { argument :internal, GraphQL::Types::Boolean, required: false } }
    ch = child_of(pa) do
      field(:notes, String, null: true, beta_only: true) do
        argument_class arg
        argument :internal, GraphQL::Types::Boolean, required: false, authorize: :manage
      end
    end
    root = Struct.new(:doc).new(Class.new { def notes(internal: false) = internal ? "SECRET" : "plain" }.new)
    leak_check(schema_for(on_query(ch)), "s4", query: "{ doc { notes(internal: true) } }", root: root)
  end

  it "[security] S5 no field rule on either: the override's hidden return type has the stricter type rule" do
    public_t = Class.new(base_object) do
      graphql_name "PublicNotes"
      authorize :read, model: Invoice
      field :body, String, null: true
    end
    hidden_t = Class.new(base_object) do
      graphql_name "StaffNotes"
      authorize :manage, model: Invoice
      field :body, String, null: true
      def self.visible?(context) = super && context[:beta] == true
    end
    pa = doc_parent { field :notes, public_t, null: true }
    ch = child_of(pa) { field :notes, hidden_t, null: true }
    q = on_query(ch)
    q.field(:public_notes, public_t, null: true, authorize: :none, reason: "x")
    leak_check(schema_for(q), "s5", query: "{ doc { notes { body } } }",
                                               root: root_notes(Struct.new(:body).new("SECRET")), dig: %w[data doc notes body])
  end

  it "[preservation] S5b control: with nothing hidden the same user is refused through the override" do
    public_t = Class.new(base_object) do
      graphql_name "PublicNotes"
      authorize :read, model: Invoice
      field :body, String, null: true
    end
    strict_t = Class.new(base_object) do
      graphql_name "StaffNotes"
      authorize :manage, model: Invoice
      field :body, String, null: true
    end
    pa = doc_parent { field :notes, public_t, null: true }
    ch = child_of(pa) { field :notes, strict_t, null: true }
    served, = leak_check(schema_for(on_query(ch)), "s5b", query: "{ doc { notes { body } } }",
                                                          root: root_notes(Struct.new(:body).new("SECRET")), dig: %w[data doc notes body])
    expect(served.dig("data", "doc", "notes")).to be_nil
  end

  it "[security] S6 same rule, the override adds a redacting extension" do
    redact = Class.new(GraphQL::Schema::FieldExtension) { def after_resolve(value:, **) = "REDACTED" }
    pa = doc_parent { field :notes, String, null: true }
    ch = child_of(pa) { field :notes, String, null: true, beta_only: true, extensions: [redact] }
    leak_check(schema_for(on_query(ch)), "s6")
  end

  it "[security] S7 same rule, the override's resolver_method redacts" do
    pa = doc_parent { field :notes, String, null: true }
    ch = child_of(pa) do
      field :notes, String, null: true, beta_only: true, resolver_method: :redacted_notes
      def redacted_notes = "REDACTED"
    end
    leak_check(schema_for(on_query(ch)), "s7")
  end


  it "[security] S9 the app's field class with its own authorized?, declared in own_checks, same signature" do
    pa = doc_parent { field :notes, String, null: true }
    strict = Class.new(flagged) { def authorized?(_o, _a, ctx) = ctx[:staff] == true }
    ch = child_of(pa) do
      field_class strict
      field :notes, String, null: true, beta_only: true
    end
    plug = GraphQL::Armory::Authorization
    a = adapter
    q = on_query(ch)
    schema = Class.new(ArmoryEngine.base_schema) do
      use plug, adapter: a, own_checks: { strict => { authorized?: "checked by staff flag" } }
      query q
    end
    leak_check(schema, "s9")
  end

  it "[security] S10 a resolver subclass with another rule is reported" do
    r1 = Class.new(GraphQL::Schema::Resolver) do
      include GraphQL::Armory::Authorization::Base
      authorize :read, model: Invoice
      type String, null: true
      def resolve = "SECRET"
    end
    r2 = Class.new(r1) { authorize :manage, model: Invoice }
    pa = doc_parent { field :notes, resolver: r1 }
    ch = child_of(pa) { field :notes, resolver: r2, beta_only: true }
    _, rep = leak_check(schema_for(on_query(ch)), "s10")
    expect(paths(rep)).to include("Doc.notes")
  end

  it "[security] S11 interface default vs implementer: interface no rule, implementer :manage" do
    bf = flagged
    i = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "HasNotes"
      field_class bf
      field :notes, String, null: true
    end
    ch = doc_parent do
      implements i
      field :notes, String, null: true, authorize: :manage, beta_only: true
    end
    _, rep = leak_check(schema_for(on_query(ch)), "s11")
    expect(paths(rep)).to include("Doc.notes")
  end

  it "[preservation] S12 interface and implementer both :manage: same rule runs, nothing served" do
    bf = flagged
    i = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "HasNotes"
      field_class bf
      field :notes, String, null: true, authorize: :manage
    end
    ch = doc_parent do
      implements i
      field :notes, String, null: true, authorize: :manage, beta_only: true
    end
    served, = leak_check(schema_for(on_query(ch)), "s12")
    expect(served.dig("data", "doc", "notes")).to be_nil
  end

  # --- O: override_reason silently ignored ---------------------------------
  it "[preservation] O1 non-Base field class raises" do
    expect do
      Class.new(GraphQL::Schema::Object) do
        graphql_name "X"
        field :notes, String, null: true, override_reason: "x"
      end
    end.to raise_error(ArgumentError)
  end


  it "[security] O3 on a resolver field: listed as a bypass and clears the problem" do
    r = Class.new(GraphQL::Schema::Resolver) do
      include GraphQL::Armory::Authorization::Base
      authorize :manage, model: Invoice
      type String, null: true
      def resolve = "x"
    end
    pa = doc_parent { field :notes, String, null: true }
    ch = child_of(pa) { field :notes, resolver: r, override_reason: "declared" }
    rep = report(schema_for(on_query(ch)))
    out("o3.txt", "#{rep.problems.map(&:to_s)} #{rep.bypasses.map(&:to_s)}")
    expect(rep.bypasses.map(&:path)).to include("Doc.notes")
    expect(kinds(rep)).not_to include(:ignored_rule)
  end

  it "[security] O4 on a mutation payload field: not silently dropped" do
    bf = flagged
    plug = GraphQL::Armory::Authorization
    mut = Class.new(GraphQL::Schema::Mutation) do
      include plug::Base
      graphql_name "Do"
      authorize :none, reason: "x"
      field_class bf
      field :r, String, null: true, override_reason: "nothing falls back"
      def resolve = { r: "x" }
    end
    root = query_with { field :ping, String, null: true, authorize: :none, reason: "x" }
    mt = query_with do
      graphql_name "Mutation"
      field :do_it, mutation: mut
    end
    rep = report(schema_for(root, setup: proc { mutation mt }))
    out("o4.txt", "#{rep.problems.map(&:to_s)} #{rep.bypasses.map(&:to_s)}")
    expect(paths(rep).any? { |p| p.end_with?(".r") }).to eq(true), rep.problems.map(&:to_s).to_s
  end

  it "[security] O5 inherited: the reason on the middle level, the leaf overrides with another rule and no reason" do
    gp = doc_parent { field :notes, String, null: true }
    pa = Class.new(gp) { field :notes, String, null: true, authorize: :manage, override_reason: "declared here" }
    ch = child_of(pa) { field :notes, String, null: true, authorize: :admin }
    rep = report(schema_for(on_query(ch)))
    out("o5.txt", "#{rep.problems.map(&:to_s)} #{rep.bypasses.map(&:to_s)}")
    expect(kinds(rep)).to include(:ignored_rule)
    expect(rep.bypasses.map(&:reason)).to include("declared here")
  end

  it "[security] O6 a duplicated definition with the reason on only one" do
    pa = doc_parent { field :notes, String, null: true }
    ch = child_of(pa) do
      field :notes, String, null: true, authorize: :manage, override_reason: "declared"
      field :notes, Integer, null: true, authorize: :admin
    end
    rep = report(schema_for(on_query(ch)))
    out("o6.txt", "#{rep.problems.map(&:to_s)} #{rep.bypasses.map(&:to_s)}")
    expect(kinds(rep)).to include(:ignored_rule)
  end

  it "[security] O7 under Schema::Visibility: nothing falls back, so a problem and not a silent bypass" do
    pa = doc_parent { field :notes, String, null: true }
    ch = child_of(pa) { field :notes, String, null: true, authorize: :manage, override_reason: "x" }
    rep = report(schema_for(on_query(ch), setup: proc { use GraphQL::Schema::Visibility, dynamic: true }))
    out("o7.txt", rep.problems.map(&:to_s).to_s)
    expect(rep.bypasses.map(&:path)).not_to include("Doc.notes")
    expect(kinds(rep)).to include(:ignored_rule)
  end

  it "[security] O8 false and blank reasons" do
    pa = doc_parent { field :notes, String, null: true }
    expect { child_of(pa) { field :notes, String, null: true, override_reason: "  " } }.to raise_error(GraphQL::Armory::Authorization::ConfigurationError)
    ch = child_of(pa) { field :notes, String, null: true, authorize: :manage, override_reason: false }
    rep = report(schema_for(on_query(ch)))
    out("o8.txt", rep.problems.map(&:to_s).to_s)
    expect(kinds(rep)).to include(:ignored_rule)
  end

  # --- D: same-level definitions -------------------------------------------
  it "[security] D1 two definitions of one name on one class: the hidden one with a rule, its sibling with none" do
    ch = doc_parent do
      field :notes, String, null: true, authorize: :manage, beta_only: true
      field :notes, String, null: true
    end
    leak_check(schema_for(on_query(ch)), "d1")
  end

  # --- Y: reported set and paths -------------------------------------------
  def diamond(lone_first:, strict_opts: { authorize: :manage, beta_only: true })
    bf = flagged
    open_i = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "OpenNotes"
      field_class bf
      field :notes, String, null: true
    end
    strict_i = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "StrictNotes"
      field_class bf
      field :notes, String, null: true, **strict_opts
    end
    both = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: Invoice
      implements open_i
      implements strict_i
    end
    lone = Class.new(base_object) do
      graphql_name "Lone"
      authorize :read, model: Invoice
      implements strict_i
    end
    order = lone_first ? [both, lone] : [lone, both]
    q = query_with { field :doc, both, null: true, authorize: :none, reason: "x" }
    [schema_for(q, setup: proc { orphan_types(*order) }), both, lone]
  end

  it "[security] Y0 control: with no second implementer the same override is reported" do
    bf = flagged
    open_i = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "OpenNotes"
      field_class bf
      field :notes, String, null: true
    end
    strict_i = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "StrictNotes"
      field_class bf
      field :notes, String, null: true, authorize: :manage, beta_only: true
    end
    both = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: Invoice
      implements open_i
      implements strict_i
    end
    _, rep = leak_check(schema_for(on_query(both)), "y0")
    expect(kinds(rep)).to include(:ignored_rule)
  end

  it "[preservation] Y0c cause: walk order and the ancestor chain of the type that falls back" do
    schema, both, = diamond(lone_first: true)
    order = GraphQL::Armory::Authorization::Definitions.(schema).reject(&:introspection?).map(&:graphql_name)
    chain = both.ancestors.select { |a| a.respond_to?(:own_fields) && a.own_fields.key?("notes") }.map(&:graphql_name)
    out("y0c.txt", "walk: #{order}\nchain with notes: #{chain}\nserved by: #{both.get_field('notes').owner.graphql_name}")
  end

  it "[security] Y5 superclass shape: a class implementing the interface alone hides the fallback on a subclass of another class" do
    bf = flagged
    strict_i = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "StrictNotes"
      field_class bf
      field :notes, String, null: true, authorize: :manage, beta_only: true
    end
    parent = Class.new(base_object) do
      authorize :read, model: Invoice
      field :notes, String, null: true
    end
    doc = Class.new(parent) do
      graphql_name "Doc"
      implements strict_i
    end
    lone = Class.new(base_object) do
      graphql_name "Lone"
      authorize :read, model: Invoice
      implements strict_i
    end
    leak_check(schema_for(on_query(doc), setup: proc { orphan_types(doc, lone) }), "y5")
  end

  it "[security] Y1 one interface field falls back on a type implementing both, not on one implementing it alone (order A)" do
    schema, both, = diamond(lone_first: true)
    out("y1_chain.txt", both.ancestors.select { |a| a.respond_to?(:own_fields) }.map(&:graphql_name).inspect) rescue nil
    leak_check(schema, "y1")
  end

  it "[security] Y2 the same with the walk in the other order" do
    schema, = diamond(lone_first: false)
    leak_check(schema, "y2")
  end

  it "[security] Y3 the same field with override_reason: bypass or problem depending on the walk" do
    results = [true, false].map do |lone_first|
      schema, = diamond(lone_first: lone_first, strict_opts: { authorize: :manage, override_reason: "declared" })
      rep = report(schema)
      [rep.problems.map(&:to_s), rep.bypasses.map(&:path)]
    end
    out("y3.txt", results.inspect)
    expect(results[0]).to eq(results[1])
  end

  it "[preservation] Y4 one parent override inherited by several concrete types: one report, path of one of them" do
    gp = Class.new(base_object) do
      authorize :read, model: Invoice
      field :notes, String, null: true
    end
    pa = Class.new(gp) { field :notes, String, null: true, authorize: :manage }
    c1 = Class.new(pa) { graphql_name "ConcreteOne" }
    c2 = Class.new(pa) { graphql_name "ConcreteTwo" }
    q = query_with do
      field :one, c1, null: true, authorize: :none, reason: "x"
      field :two, c2, null: true, authorize: :none, reason: "x"
    end
    rep = report(schema_for(q))
    out("y4.txt", paths(rep).inspect)
    expect(paths(rep).grep(/notes/).size).to eq(1)
  end

  # --- M: armory_implementers memo ------------------------------------------
  def secret_iface
    bf = base_field
    Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Iface"
      field_class bf
      field :secret, String, null: true
    end
  end

  def impl(name, interface, none: false, hidden: false)
    Class.new(base_object) do
      graphql_name name
      none ? authorize(:none, reason: "b") : authorize(:read, model: Invoice)
      implements interface
      def self.visible?(ctx) = super && ctx[:beta] == true if hidden
    end
  end

  def thing_root = Struct.new(:thing).new(Struct.new(:secret).new("SECRET"))
  def ask(schema, ctx = {}) = run(schema, "{ thing { secret } }", thing_root, context: { current_user: :u }.merge(ctx))
  def thing_query(i) = query_with { field :thing, i, null: true, authorize: :none, reason: "x" }

  it "[security] M1 a hidden bypassed implementer added after the first query on the same schema" do
    i = secret_iface
    readable = impl("Readable", i)
    bypassed = impl("Bypassed", i, none: true, hidden: true)
    answer = readable
    schema = schema_for(thing_query(i), setup: proc do
      orphan_types readable
      define_singleton_method(:resolve_type) { |_a, _o, _c| answer }
    end)
    ask(schema)
    schema.orphan_types(bypassed)
    answer = bypassed
    second = ask(schema, beta: true)
    rep = report(schema)
    out("m1.txt", "#{second}\n#{rep.problems.map(&:to_s)}")
    expect(second.dig("data", "thing", "secret")).to be_nil, "served #{second} on the bypassed type, audit says #{rep.problems.map(&:path)}"
  end

  it "[security] M2 a child adds a hidden bypassed implementer: the child denies, the parent stays" do
    i = secret_iface
    readable = impl("Readable", i)
    bypassed = impl("Bypassed", i, none: true, hidden: true)
    parent = schema_for(thing_query(i), setup: proc do
      orphan_types readable
      define_singleton_method(:resolve_type) { |_a, _o, _c| readable }
    end)
    before = ask(parent)
    child = Class.new(parent) do
      orphan_types bypassed
      define_singleton_method(:resolve_type) { |_a, _o, _c| bypassed }
    end
    in_child = ask(child, beta: true)
    after = ask(parent)
    out("m2.txt", "#{before}\n#{in_child}\n#{after}")
    expect(in_child.dig("data", "thing", "secret")).to be_nil
    expect(after.dig("data", "thing", "secret")).to eq("SECRET")
  end

  it "[preservation] M4 threads racing over many interfaces agree" do
    bf = base_field
    ifaces = Array.new(40) do |n|
      Module.new do
        include GraphQL::Schema::Interface
        graphql_name "I#{n}"
        field_class bf
        field :secret, String, null: true
      end
    end
    one = Class.new(base_object) do
      graphql_name "One"
      authorize :read, model: Invoice
      ifaces.each { |i| implements i }
    end
    q = query_with { ifaces.each_with_index { |i, n| field :"t#{n}", i, null: true, authorize: :none, reason: "x" } }
    schema = schema_for(q, setup: proc do
      orphan_types one
      define_singleton_method(:resolve_type) { |_a, _o, _c| one }
    end)
    doc = "{ #{Array.new(40) { |n| "t#{n} { secret }" }.join(' ')} }"
    item = Struct.new(:secret).new("s")
    root = Struct.new(*Array.new(40) { |n| :"t#{n}" }).new(*Array.new(40) { item })
    results = Array.new(16) { Thread.new { run(schema, doc, root, context: { current_user: :u }) } }.map(&:value)
    expect(results.uniq.size).to eq(1)
    expect(results.first["errors"]).to be_nil
  end

  def cost_schema(implementers, setup_extra: nil)
    i = secret_iface
    types = Array.new(implementers) { |n| impl("T#{n}", i) }
    first = types.first
    q = query_with { field :things, [i], null: false, authorize: :none, reason: "x" }
    schema_for(q, setup: proc do
      orphan_types(*types)
      define_singleton_method(:resolve_type) { |_a, _o, _c| first }
      class_eval(&setup_extra) if setup_extra
    end)
  end

  def cost(schema, items: 2000)
    item = Struct.new(:secret).new("s")
    root = Struct.new(:things).new(Array.new(items) { item })
    2.times { run(schema, "{ things { secret } }", root, context: { current_user: :u }) }
    Benchmark.realtime { run(schema, "{ things { secret } }", root, context: { current_user: :u }) }
  end

  it "[preservation] M5 cost: 2000 items of an interface with 1 / 300 implementers, numbers only" do
    out("m5.txt", format("1 impl %.3fs; 300 impl %.3fs; 300 impl with Visibility %.3fs",
                         cost(cost_schema(1)), cost(cost_schema(300)),
                         cost(cost_schema(300, setup_extra: proc { use GraphQL::Schema::Visibility, dynamic: true }))))
  end

  # --- V: possible_types read with no request ------------------------------

  it "[preservation] V2 an implementer's visible? that needs a request, on an ordinary query" do
    i = secret_iface
    user = Struct.new(:admin)
    readable = Class.new(base_object) do
      graphql_name "Readable"
      authorize :read, model: Invoice
      implements i
      def self.visible?(context) = super && context[:current_user].admin
    end
    schema = schema_for(thing_query(i), setup: proc do
      orphan_types readable
      define_singleton_method(:resolve_type) { |_a, _o, _c| readable }
    end)
    result = begin
      ask(schema, current_user: user.new(true))
    rescue StandardError => e
      "raised #{e.class}: #{e.message[0, 200]}"
    end
    out("v2.txt", result.inspect)
    expect(result).to be_a(Hash), result.to_s
    expect(result.dig("data", "thing", "secret")).to eq("SECRET")
  end

  # --- F: fields_at_every_level --------------------------------------------
  it "[preservation] F1 an abstract ancestor's overridden field whose type cannot load: the audit" do
    pa = doc_parent { field :notes, "ProbeMissing::Nope", null: true }
    ch = child_of(pa) { field :notes, String, null: true }
    audit = begin
      report(schema_for(on_query(ch))).problems.map(&:to_s)
    rescue StandardError => e
      "audit raised #{e.class}: #{e.message[0, 160]}"
    end
    out("f1.txt", audit.inspect)
    expect(audit).to be_a(Array), audit.to_s
  end

  it "[preservation] F2 the same, on a query that touches an interface field" do
    i = secret_iface
    readable = impl("Readable", i)
    pa = doc_parent { field :notes, "ProbeMissing::Nope", null: true }
    ch = child_of(pa) { field :notes, String, null: true }
    q = thing_query(i)
    q.field(:doc, ch, null: true, authorize: :none, reason: "x")
    schema = schema_for(q, setup: proc do
      orphan_types readable
      define_singleton_method(:resolve_type) { |_a, _o, _c| readable }
    end)
    result = begin
      ask(schema)
    rescue StandardError => e
      "raised #{e.class}: #{e.message[0, 160]}"
    end
    out("f2.txt", result.inspect)
    expect(result).to be_a(Hash), result.to_s
  end

  it "[preservation] F3 a late-bound type on an abstract ancestor's overridden field" do
    pa = doc_parent { field :notes, GraphQL::Schema::LateBoundType.new("Nowhere"), null: true }
    ch = child_of(pa) { field :notes, String, null: true }
    audit = begin
      report(schema_for(on_query(ch))).problems.map(&:to_s)
    rescue StandardError => e
      "audit raised #{e.class}: #{e.message[0, 160]}"
    end
    out("f3.txt", audit.inspect)
    expect(audit).to be_a(Array), audit.to_s
  end

  it "[preservation] F4 visible_when on both levels of a type with no model: a :model problem, not a crash" do
    pa = Class.new(base_object) do
      graphql_name "NoSuchModelAnywhere"
      field :notes, String, null: true, visible_when: :manage
    end
    ch = Class.new(pa) do
      graphql_name "NoSuchModelAnywhere"
      field :notes, String, null: true, visible_when: :manage, authorize: :manage
    end
    audit = begin
      report(schema_for(on_query(ch))).problems.map(&:to_s)
    rescue StandardError => e
      "audit raised #{e.class}: #{e.message[0, 160]}"
    end
    out("f4.txt", audit.inspect)
    expect(audit).to be_a(Array), audit.to_s
  end

  # --- N: noise on ordinary schemas ----------------------------------------
  def typical_schema(with_overrides:)
    plug = GraphQL::Armory::Authorization
    bf = base_field
    arg = Class.new(GraphQL::Schema::Argument) { include plug::Base }
    bf.argument_class(arg)
    bo = Class.new(GraphQL::Schema::Object) do
      include plug::Base
      field_class bf
      default_action :read
    end
    edge = Class.new(bo) do
      include GraphQL::Types::Relay::EdgeBehaviors
      authorize :none, reason: "edge", covers_fields: true
    end
    conn = Class.new(bo) do
      include GraphQL::Types::Relay::ConnectionBehaviors
      authorize :none, reason: "conn", covers_fields: true
      field :total_count, Integer, null: false, authorize: :none, reason: "count"
    end
    bo.edge_type_class(edge)
    bo.connection_type_class(conn)
    node = Module.new do
      include GraphQL::Schema::Interface
      field_class bf
      include GraphQL::Types::Relay::NodeBehaviors
      graphql_name "Node"
    end
    timestamped = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Timestamped"
      field_class bf
      field :created_at, String, null: true
      field :label, String, null: true
    end
    make = lambda do |name|
      Class.new(bo) do
        graphql_name name
        authorize :read, model: Invoice
        implements node
        implements timestamped
        global_id_field :id
        field :name, String, null: true
        field :label, String, null: true, authorize: :none, reason: "public" if with_overrides
      end
    end
    types = %w[Alpha Beta Gamma Delta].map(&make)
    alpha = types.first
    create = Class.new(GraphQL::Schema::RelayClassicMutation) do
      include plug::Base
      graphql_name "CreateAlpha"
      authorize :manage, model: Invoice
      field_class bf
      field :alpha, alpha, null: true
      field :errors, [String], null: false, authorize: :none, reason: "own errors"
      argument :name, String
      def resolve(name:) = { alpha: nil, errors: [] }
    end
    create_sub = Class.new(create) do
      graphql_name "CreateBeta"
      field :errors, [String], null: false, authorize: :none, reason: "own errors"
    end
    m = Class.new(bo) do
      graphql_name "Mutation"
      authorize :none, reason: "root", covers_fields: true
      field :create_alpha, mutation: create
      field :create_beta, mutation: create_sub
    end
    q = Class.new(bo) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :node, node, null: true, authorize: :none, reason: "x" do
        argument :id, GraphQL::Types::ID
      end
      types.each { |t| field :"#{t.graphql_name.downcase}s", t.connection_type, null: true, authorize: :none, reason: "x" }
      field :edge_only, alpha.edge_type, null: true, authorize: :none, reason: "x"
    end
    a = adapter
    Class.new(ArmoryEngine.base_schema) do
      use plug, adapter: a
      query q
      mutation m
      orphan_types(*types)
    end
  end



  it "[preservation] N3 the same schema under Visibility: no :ignored_rule" do
    plain = typical_schema(with_overrides: true)
    rep = report(Class.new(plain) { use GraphQL::Schema::Visibility, dynamic: true })
    out("n3.txt", rep.problems.map(&:to_s).join("\n"))
    expect(kinds(rep)).not_to include(:ignored_rule)
  end
end
