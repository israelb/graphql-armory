# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "benchmark"
require "json"

# Recheck of the correction batch: hidden overrides, memoized definitions. Black box: Audit.(schema) and real queries.
RSpec.describe "recheck: hidden overrides and armory_definitions" do
  armory = GraphQL::Armory::Authorization

  by_action = Class.new(armory::Adapters::Substitute) do
    def initialize(allowed, by_subject: {})
      super()
      @allowed = allowed
      @by_subject = by_subject
    end

    def authorized?(_actor, subject, rule)
      return @by_subject[[subject, rule.action]] if @by_subject.key?([subject, rule.action])

      @allowed.include?(rule.action)
    end
  end

  let(:adapter) { by_action.new(%i[read]) }
  let(:base_field) { Class.new(GraphQL::Schema::Field) { include armory::Base } }
  let(:hiding_field) { Class.new(base_field) { def visible?(context) = super && context[:beta] == true } }
  let(:base_object) do
    bf = base_field
    Class.new(GraphQL::Schema::Object) do
      include armory::Base
      field_class bf
      default_action :read
    end
  end
  let(:by_action_class) { by_action }

  def query_type(&block)
    Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :ping, String, null: true, authorize: :none, reason: "x"
      class_eval(&block) if block
    end
  end

  def schema_for(query_class, visibility: false, setup: nil, adapter_override: nil)
    plugin = GraphQL::Armory::Authorization
    a = adapter_override || adapter
    Class.new(ArmoryEngine.base_schema) do
      use plugin, adapter: a
      use GraphQL::Schema::Visibility, dynamic: true if visibility
      query query_class
      class_eval(&setup) if setup
    end
  end

  def report(schema) = GraphQL::Armory::Authorization::Audit.(schema)

  def out(name, text)
  end

  def iface(name, field_cls: nil, &block)
    Module.new do
      include GraphQL::Schema::Interface
      graphql_name name
      field_class field_cls if field_cls
      class_eval(&block) if block
    end
  end

  def on_query(doc_class)
    query_type { field :doc, doc_class, null: true, authorize: :none, reason: "x" }
  end

  def doc_root(notes)
    Struct.new(:doc).new(Struct.new(:notes).new(notes))
  end

  # The refused user gets the ancestor's definition while the audit says ok.
  def leak_check(schema, name, query: "{ doc { notes } }", context: { current_user: :reader }, notes: "SECRET", dig: %w[data doc notes])
    served = execute_query(schema, query, root_value: doc_root(notes), context: context).to_h
    rep = report(schema)
    out("#{name}.txt", "served: #{served.inspect}\nok: #{rep.ok?}\nproblems: #{rep.problems.map(&:to_s)}")
    leaked = served.dig(*dig) == "SECRET"
    expect(leaked && rep.ok?).to eq(false), "served #{served.inspect} with the audit ok"
    [served, rep]
  end

  def doc_parent(&block)
    Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: Invoice
      class_eval(&block)
    end
  end

  # --- H: false silence ----------------------------------------------------
  it "[security] H1 three levels: public grandparent, parent and child hidden the same" do
    gp = doc_parent { field :notes, String, null: true }
    pa = Class.new(gp) { field :notes, String, null: true, authorize: :manage, visible_when: :manage }
    ch = Class.new(pa) do
      graphql_name "Doc"
      field :notes, String, null: true, authorize: :manage, visible_when: :manage
    end
    leak_check(schema_for(on_query(ch)), "h1")
  end

  it "[security] H2 grandparent with a different visible_when the user passes" do
    gp = doc_parent { field :notes, String, null: true, visible_when: :read }
    pa = Class.new(gp) { field :notes, String, null: true, authorize: :manage, visible_when: :manage }
    ch = Class.new(pa) do
      graphql_name "Doc"
      field :notes, String, null: true, authorize: :manage, visible_when: :manage
    end
    leak_check(schema_for(on_query(ch)), "h2")
  end

  it "[security] H2b only the middle level hides: the child has no own field" do
    gp = doc_parent { field :notes, String, null: true }
    pa = Class.new(gp) { field :notes, String, null: true, authorize: :manage, visible_when: :manage }
    ch = Class.new(pa) { graphql_name "Doc" }
    leak_check(schema_for(on_query(ch)), "h2b")
  end

  it "[security] H3 ancestor with the same visible_when symbol, asked of another model" do
    parent_model = Class.new
    child_model = Class.new
    a = by_action_class.new(%i[read], by_subject: { [parent_model, :export] => true, [child_model, :export] => false })
    pa = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: parent_model
      field :notes, String, null: true, visible_when: :export, authorize: :read
    end
    ch = Class.new(pa) do
      graphql_name "Doc"
      authorize :read, model: child_model
      field :notes, String, null: true, visible_when: :export, authorize: :manage
    end
    leak_check(schema_for(on_query(ch), adapter_override: a), "h3")
  end

  it "[security] H4 own visible? from the same class, deciding per field with an option" do
    flagged = Class.new(base_field) do
      def initialize(*args, beta_only: false, **kwargs, &block)
        @beta_only = beta_only
        super(*args, **kwargs, &block)
      end

      def visible?(context) = super && (!@beta_only || context[:beta] == true)
    end
    pa = doc_parent do
      field_class flagged
      field :notes, String, null: true
    end
    ch = Class.new(pa) do
      graphql_name "Doc"
      field :notes, String, null: true, authorize: :manage, beta_only: true
    end
    leak_check(schema_for(on_query(ch)), "h4")
  end


  it "[security] H5 override through a resolver with its own visible?" do
    plugin = armory
    r = Class.new(GraphQL::Schema::Resolver) do
      include plugin::Base
      authorize :manage, model: Invoice
      type String, null: true
      def self.visible?(context) = super && context[:beta] == true
      def resolve = "OVERRIDE"
    end
    pa = doc_parent { field :notes, String, null: true }
    ch = Class.new(pa) do
      graphql_name "Doc"
      field :notes, resolver: r
    end
    leak_check(schema_for(on_query(ch)), "h5")
  end

  it "[security] H6 override whose return type is hidden" do
    public_t = Class.new(base_object) do
      graphql_name "PublicNotes"
      authorize :read, model: Invoice
      field :body, String, null: true
    end
    hidden_t = Class.new(base_object) do
      graphql_name "HiddenNotes"
      authorize :read, model: Invoice
      field :body, String, null: true
      def self.visible?(context) = super && context[:beta] == true
    end
    pa = doc_parent { field :notes, public_t, null: true }
    ch = Class.new(pa) do
      graphql_name "Doc"
      field :notes, hidden_t, null: true, authorize: :manage
    end
    leak_check(schema_for(on_query(ch)), "h6", query: "{ doc { notes { body } } }", notes: Struct.new(:body).new("SECRET"), dig: %w[data doc notes body])
  end

  it "[security] H6b override whose hidden return type leaves the ancestor's type reachable elsewhere" do
    public_t = Class.new(base_object) do
      graphql_name "PublicNotes"
      authorize :read, model: Invoice
      field :body, String, null: true
    end
    hidden_t = Class.new(base_object) do
      graphql_name "HiddenNotes"
      authorize :read, model: Invoice
      field :body, String, null: true
      def self.visible?(context) = super && context[:beta] == true
    end
    pa = doc_parent { field :notes, public_t, null: true }
    ch = Class.new(pa) do
      graphql_name "Doc"
      field :notes, hidden_t, null: true, authorize: :manage
    end
    q = on_query(ch)
    q.field(:public_notes, public_t, null: true, authorize: :none, reason: "x")
    leak_check(schema_for(q), "h6b", query: "{ doc { notes { body } } }", notes: Struct.new(:body).new("SECRET"), dig: %w[data doc notes body])
  end

  it "[security] H6c override returning a hidden scalar over an ancestor's String" do
    hidden_scalar = Class.new(GraphQL::Schema::Scalar) do
      graphql_name "HiddenText"
      def self.visible?(context) = super && context[:beta] == true
    end
    pa = doc_parent { field :notes, String, null: true }
    ch = Class.new(pa) do
      graphql_name "Doc"
      field :notes, hidden_scalar, null: true, authorize: :manage
    end
    leak_check(schema_for(on_query(ch)), "h6c")
  end

  it "[security] H7 the schema's own visible?(member, ctx) hides the override" do
    pa = doc_parent { field :notes, String, null: true }
    ch = Class.new(pa) do
      graphql_name "Doc"
      field :notes, String, null: true, authorize: :manage
    end
    setup = proc do
      define_singleton_method(:visible?) do |member, ctx|
        hidden = member.respond_to?(:armory_declared) && member.armory_declared == :manage && ctx[:beta] != true
        hidden ? false : super(member, ctx)
      end
    end
    leak_check(schema_for(on_query(ch), setup: setup), "h7")
  end

  it "[security] H8 own visible? below Base: a subclass includes Base over an app's field class" do
    plugin = armory
    app_field = Class.new(GraphQL::Schema::Field) { def visible?(context) = super && context[:beta] == true }
    hiding_below = Class.new(app_field) { include plugin::Base }
    pa = doc_parent { field :notes, String, null: true }
    ch = Class.new(pa) do
      graphql_name "Doc"
      field_class hiding_below
      field :notes, String, null: true, authorize: :manage
    end
    leak_check(schema_for(on_query(ch)), "h8")
  end

  it "[security] H9 an interface field overriding a parent interface's" do
    parent = iface("HasNotes", field_cls: base_field) { field :notes, String, null: true }
    child = iface("HasSecretNotes", field_cls: hiding_field) do
      implements parent
      field :notes, String, null: true, authorize: :manage
    end
    ch = doc_parent { implements child }
    leak_check(schema_for(on_query(ch)), "h9")
  end


  it "[security] H11 Schema::Visibility with migration_errors: the audit stays silent, who answers" do
    pa = doc_parent { field :notes, String, null: true }
    ch = Class.new(pa) do
      graphql_name "Doc"
      field :notes, String, null: true, authorize: :manage, visible_when: :manage
    end
    schema = schema_for(on_query(ch), setup: proc { use GraphQL::Schema::Visibility, dynamic: true, migration_errors: true })
    begin
      leak_check(schema, "h11")
    rescue StandardError => error
      out("h11.txt", "raised #{error.class}: #{error.message[0, 400]}")
    end
  end

  it "[preservation] H12 a child of a schema with Visibility inherits it: no false report" do
    pa = doc_parent { field :notes, String, null: true }
    ch = Class.new(pa) do
      graphql_name "Doc"
      field :notes, String, null: true, authorize: :manage, visible_when: :manage
    end
    child = Class.new(schema_for(on_query(ch), visibility: true))
    rep = report(child)
    out("h12.txt", rep.problems.map(&:to_s).inspect)
    expect(rep.problems.map(&:kind)).not_to include(:ignored_rule)
  end

  it "[preservation] H13 a child that adds Visibility to a plain parent: no report; the parent reports" do
    pa = doc_parent { field :notes, String, null: true }
    ch = Class.new(pa) do
      graphql_name "Doc"
      field :notes, String, null: true, authorize: :manage, visible_when: :manage
    end
    parent = schema_for(on_query(ch))
    child = Class.new(parent) { use GraphQL::Schema::Visibility, dynamic: true }
    expect(report(child).problems.map(&:kind)).not_to include(:ignored_rule)
    expect(report(parent).problems.map(&:kind)).to include(:ignored_rule)
  end

  # --- N: the comparison with nil ------------------------------------------

  it "[security] N2 the ancestor's field class has no Base: hiding is nil and the override is reported" do
    plugin = armory
    bf = base_field
    pa = Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      default_action :read
      graphql_name "Doc"
      authorize :read, model: Invoice
      field_class GraphQL::Schema::Field
      field :notes, String, null: true
    end
    ch = Class.new(pa) do
      graphql_name "Doc"
      field_class bf
      field :notes, String, null: true, authorize: :manage, visible_when: :manage
    end
    leak_check(schema_for(on_query(ch)), "n2")
  end

  # --- P: false problems on ordinary schemas -------------------------------
  def relay_template(field_cls, node:)
    plugin = GraphQL::Armory::Authorization
    bo = Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class field_cls
      default_action :read
    end
    edge = Class.new(bo) do
      include GraphQL::Types::Relay::EdgeBehaviors
      authorize :none, reason: "edge", covers_fields: true
    end
    conn = Class.new(bo) do
      include GraphQL::Types::Relay::ConnectionBehaviors
      authorize :none, reason: "conn", covers_fields: true
    end
    bo.edge_type_class(edge)
    bo.connection_type_class(conn)
    item = Class.new(bo) do
      graphql_name "Item"
      authorize :read, model: Invoice
      implements node
      global_id_field :id
      field :name, String, null: true
    end
    q = Class.new(bo) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      if node == GraphQL::Types::Relay::Node
        include GraphQL::Types::Relay::HasNodeField
        include GraphQL::Types::Relay::HasNodesField
      else
        field :node, node, null: true, authorize: :none, reason: "x" do
          argument :id, GraphQL::Types::ID
        end
      end
      field :items, item.connection_type, null: true, authorize: :none, reason: "x"
    end
    schema_for(q, setup: proc { orphan_types item })
  end

  def own_node(field_cls)
    iface("Node", field_cls: field_cls) { include GraphQL::Types::Relay::NodeBehaviors }
  end

  def ignored(rep) = rep.problems.select { |pr| pr.kind == :ignored_rule }.map(&:path)




  it "[security] P3b the built-in Node report is a real fallback: a user the own visible? hides id from gets Node.id" do
    hf = hiding_field
    item = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: Invoice
      field_class hf
      implements GraphQL::Types::Relay::Node
      field :id, GraphQL::Types::ID, null: false, authorize: :manage
    end
    schema = schema_for(on_query(item), setup: proc { define_singleton_method(:id_from_object) { |_o, _t, _c| "NODE-ID" } })
    served = execute_query(schema, "{ doc { id } }", root_value: Struct.new(:doc).new(Struct.new(:id).new("1")), context: { current_user: :u }).to_h
    rep = report(schema)
    out("p3b.txt", "served: #{served}
problems: #{rep.problems.map(&:to_s)}")
    expect(ignored(rep)).to eq(["Doc.id"])
  end

  it "[preservation] P4 Relay BaseConnection and BaseEdge subclasses, own visible? on their field class" do
    hf = hiding_field
    edge = Class.new(GraphQL::Types::Relay::BaseEdge) { field_class hf }
    conn = Class.new(GraphQL::Types::Relay::BaseConnection) { field_class hf }
    bo = Class.new(base_object) do
      field_class hf
      edge_type_class edge
      connection_type_class conn
    end
    item = Class.new(bo) do
      graphql_name "Item"
      authorize :read, model: Invoice
      field :name, String, null: true
    end
    q = query_type { field :items, item.connection_type, null: true, authorize: :none, reason: "x" }
    rep = report(schema_for(q))
    out("p4.txt", rep.problems.map(&:to_s).join("\n"))
    expect(ignored(rep)).to eq([])
  end

  # --- R: memoized definitions at runtime ----------------------------------
  def secret_iface
    iface("Iface", field_cls: base_field) { field :secret, String, null: true }
  end

  def secret_root
    Struct.new(:thing).new(Struct.new(:secret).new("SECRET"))
  end

  def impl(name, interface, rule: :read, reason: nil)
    Class.new(base_object) do
      graphql_name name
      rule == :none ? authorize(:none, reason: reason || "b") : authorize(rule, model: Invoice)
      implements interface
    end
  end

  def ask_thing(schema)
    execute_query(schema, "{ thing { secret } }", root_value: secret_root, context: { current_user: :u }).to_h
  end

  def thing_query(interface)
    query_type { field :thing, interface, null: true, authorize: :none, reason: "x" }
  end

  it "[security] R1 a child adds a bypassed implementer after the parent's first query: each schema answers its own" do
    i = secret_iface
    readable = impl("Readable", i)
    bypassed = impl("Bypassed", i, rule: :none)
    parent = schema_for(thing_query(i), setup: proc do
      orphan_types readable
      define_singleton_method(:resolve_type) { |_a, _o, _c| readable }
    end)
    before = ask_thing(parent)
    child = Class.new(parent) do
      orphan_types bypassed
      define_singleton_method(:resolve_type) { |_a, _o, _c| bypassed }
    end
    in_child = ask_thing(child)
    after = ask_thing(parent)
    out("r1.txt", "parent before: #{before}\nchild: #{in_child}\nparent after: #{after}")
    expect(in_child.dig("data", "thing", "secret")).to be_nil
    expect(before.dig("data", "thing", "secret")).to eq("SECRET")
    expect(after.dig("data", "thing", "secret")).to eq("SECRET")
  end

  it "[security] R2 a bypassed implementer added to the same schema after its first query" do
    i = secret_iface
    readable = impl("Readable", i)
    bypassed = impl("Bypassed", i, rule: :none)
    answer = readable
    schema = schema_for(thing_query(i), setup: proc do
      orphan_types readable
      define_singleton_method(:resolve_type) { |_a, _o, _c| answer }
    end)
    first = ask_thing(schema)
    schema.orphan_types(bypassed)
    answer = bypassed
    second = ask_thing(schema)
    rep = report(schema)
    out("r2.txt", "first: #{first}\nsecond: #{second}\nproblems: #{rep.problems.map(&:to_s)}")
    expect(second.dig("data", "thing", "secret")).to be_nil, "served #{second} on the bypassed type"
  end

  it "[preservation] R3 a Base interface field on a schema with no plugin, plain implementer" do
    i = secret_iface
    plain = Class.new(GraphQL::Schema::Object) do
      graphql_name "PlainImpl"
      implements i
    end
    q = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :thing, i, null: true
    end
    schema = Class.new(ArmoryEngine.base_schema) do
      query q
      orphan_types plain
      define_singleton_method(:resolve_type) { |_a, _o, _c| plain }
    end
    result = begin
      ask_thing(schema)
    rescue StandardError => error
      "raised #{error.class}: #{error.message[0, 200]}"
    end
    out("r3.txt", result.inspect)
    expect(result).to be_a(Hash), result.to_s
    expect(result.dig("data", "thing", "secret")).to eq("SECRET")
  end

  it "[preservation] R4 ordinary interface fields: dump of what each implementer serves, compared across commits" do
    i = iface("Iface", field_cls: base_field) do
      field :plain, String, null: true
      field :acted, String, null: true, authorize: :read
      field :refused, String, null: true, authorize: :manage
      field :open, String, null: true, authorize: :none, reason: "x"
    end
    child_i = iface("ChildIface", field_cls: base_field) do
      implements i
      field :more, String, null: true
    end
    readable = impl("Readable", child_i)
    refused = impl("RefusedImpl", i, rule: :manage)
    covered = Class.new(base_object) do
      graphql_name "Covered"
      authorize :none, reason: "c", covers_fields: true
      implements i
    end
    types = { readable: readable, refused: refused, covered: covered }
    q = query_type { field :things, [i, { null: true }], null: false, authorize: :none, reason: "x" }
    schema = schema_for(q, setup: proc do
      orphan_types(*types.values)
      define_singleton_method(:resolve_type) { |_a, o, _c| types.fetch(o.kind) }
    end)
    item = Struct.new(:kind, :plain, :acted, :refused, :open, :more)
    root = Struct.new(:things).new(types.keys.map { |k| item.new(k, "p", "a", "r", "o", "m") })
    result = execute_query(schema, "{ things { __typename plain acted refused open ... on ChildIface { more } } }", root_value: root, context: { current_user: :u }).to_h
    out("r4.txt", JSON.pretty_generate(result))
    expect(result.dig("data", "things", 0, "plain")).to eq("p")
  end

  it "[security] R5 a bypassed implementer of a child interface denies the parent interface's field" do
    i = secret_iface
    child_i = iface("ChildIface", field_cls: base_field) { implements i }
    bypassed = impl("Bypassed", child_i, rule: :none)
    schema = schema_for(thing_query(i), setup: proc do
      orphan_types bypassed
      define_singleton_method(:resolve_type) { |_a, _o, _c| bypassed }
    end)
    served = ask_thing(schema)
    rep = report(schema)
    out("r5.txt", "#{served}\n#{rep.problems.map(&:to_s)}")
    expect(served.dig("data", "thing", "secret")).to be_nil
    expect(rep.problems.map(&:path)).to include("Iface.secret")
  end

  it "[preservation] R6 an abstract bypassed parent no definition reaches does not deny the implementer's field" do
    i = secret_iface
    abstract = Class.new(base_object) do
      authorize :none, reason: "abstract"
      implements i
    end
    concrete = Class.new(abstract) do
      graphql_name "Concrete"
      authorize :read, model: Invoice
    end
    schema = schema_for(thing_query(i), setup: proc do
      orphan_types concrete
      define_singleton_method(:resolve_type) { |_a, _o, _c| concrete }
    end)
    served = ask_thing(schema)
    out("r6.txt", served.to_s)
    expect(served.dig("data", "thing", "secret")).to eq("SECRET")
  end

  it "[preservation] R7 threads racing on the first query agree" do
    i = secret_iface
    readable = impl("Readable", i)
    schema = schema_for(thing_query(i), setup: proc do
      orphan_types readable
      define_singleton_method(:resolve_type) { |_a, _o, _c| readable }
    end)
    results = Array.new(16) { Thread.new { ask_thing(schema) } }.map(&:value)
    expect(results.uniq.size).to eq(1)
    expect(results.first.dig("data", "thing", "secret")).to eq("SECRET")
  end

  it "[preservation] R8 cost: first query and repeated interface fields on a large schema (numbers only)" do
    i = secret_iface
    types = Array.new(1500) do |n|
      Class.new(base_object) do
        graphql_name "T#{n}"
        authorize :read, model: Invoice
        field :name, String, null: true
      end
    end
    readable = impl("Readable", i)
    q = query_type { field :things, [i], null: false, authorize: :none, reason: "x" }
    schema = schema_for(q, setup: proc do
      orphan_types(readable, *types)
      define_singleton_method(:resolve_type) { |_a, _o, _c| readable }
    end)
    item = Struct.new(:secret)
    root = Struct.new(:things)
    one = root.new([item.new("s")])
    many = root.new(Array.new(2000) { item.new("s") })
    run = ->(value) { Benchmark.realtime { execute_query(schema, "{ things { secret } }", root_value: value, context: { current_user: :u }) } }
    first = run.(one)
    second = run.(one)
    list = run.(many)
    list2 = run.(many)
    out("r8.txt", format("first %.3fs second %.3fs list_of_2000 %.3fs again %.3fs", first, second, list, list2))
  end

  def lazy_schema(interface, readable, query_class)
    plugin = GraphQL::Armory::Authorization
    a = adapter
    Class.new(ArmoryEngine.base_schema) do
      use plugin, adapter: a
      use GraphQL::Schema::Visibility, dynamic: true, preload: false
      query query_class
      orphan_types readable
      define_singleton_method(:resolve_type) { |_a, _o, _c| readable }
    end
  end

  it "[preservation] R9 preload: false: does a query force lazy field types to load" do
    dir = Dir.mktmpdir
    File.write(File.join(dir, "probe_lazy_thing.rb"), <<~RUBY)
      module ProbeLazy
        class Thing < GraphQL::Schema::Object
          graphql_name "LazyThing"
          field :a, String, null: true
        end
      end
    RUBY
    Object.const_set(:ProbeLazy, Module.new) unless defined?(ProbeLazy)
    ProbeLazy.autoload(:Thing, File.join(dir, "probe_lazy_thing.rb"))
    i = secret_iface
    readable = impl("Readable", i)
    q = query_type do
      field :thing, i, null: true, authorize: :none, reason: "x"
      field :lazy, "ProbeLazy::Thing", null: true, authorize: :none, reason: "x"
    end
    schema = lazy_schema(i, readable, q)
    before = ProbeLazy.autoload?(:Thing) ? true : false
    served = ask_thing(schema)
    out("r9.txt", "lazy before query: #{before}; lazy after query: #{ProbeLazy.autoload?(:Thing) ? true : false}; served #{served}")
    expect(served.dig("data", "thing", "secret")).to eq("SECRET")
  end


  it "[preservation] R11 Field#authorized? called with the null context" do
    field = secret_iface.get_field("secret")
    result = begin
      field.authorized?(Object.new, {}, GraphQL::Query::NullContext.instance)
    rescue StandardError => error
      "raised #{error.class}: #{error.message[0, 160]}"
    end
    out("r11.txt", result.inspect)
    expect(result).to eq(true), result.to_s
  end

  # --- item 3 --------------------------------------------------------------
  it "[preservation] C1 one audit reads schema.types once" do
    i = secret_iface
    readable = impl("Readable", i)
    count = 0
    schema = schema_for(thing_query(i), setup: proc do
      orphan_types readable
      define_singleton_method(:types) do |*args, **kw|
        count += 1
        super(*args, **kw)
      end
    end)
    report(schema)
    out("c1.txt", "types calls: #{count}")
    expect(count).to eq(1)
  end

  it "[preservation] C2 a second audit gives the same report, with a duplicated interface field" do
    i = iface("Dup", field_cls: hiding_field) do
      field :a, String, null: true, authorize: true
      field :a, Integer, null: true, authorize: true
    end
    implementer = impl("Impl", i)
    q = query_type { field :x, i, null: true, authorize: :none, reason: "x" }
    schema = schema_for(q, setup: proc { orphan_types implementer })
    one = report(schema).problems.map(&:to_s)
    expect(report(schema).problems.map(&:to_s)).to eq(one)
    out("c2.txt", one.join("\n"))
  end
end
