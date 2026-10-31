# frozen_string_literal: true

require "fileutils"

# Independent verification probes of the audit's definition walk. Black box: only Audit.(schema) and real queries.
RSpec.describe "probes: audit definition walk" do
  armory = GraphQL::Armory::Authorization

  # Answers by action, so a user may :read and not :manage.
  by_action = Class.new(armory::Adapters::Substitute) do
    def initialize(allowed)
      super()
      @allowed = allowed
    end

    def authorized?(_actor, _subject, rule)
      @allowed.include?(rule.action)
    end
  end

  hide = proc { def self.visible?(context) = super && context[:beta] == true }

  let(:hide) { hide }
  let(:adapter) { by_action.new(%i[read]) }
  let(:base_field) { Class.new(GraphQL::Schema::Field) { include armory::Base } }
  let(:base_object) do
    bf = base_field
    Class.new(GraphQL::Schema::Object) do
      include armory::Base
      field_class bf
      default_action :read
    end
  end

  def plain(name = "Plain", hidden: true)
    type = Class.new(GraphQL::Schema::Object) do
      graphql_name name
      field :secret, String, null: true
    end
    type.class_eval(&hide) if hidden
    type
  end

  def query_type(&block)
    Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :ping, String, null: true, authorize: :none, reason: "x"
      class_eval(&block) if block
    end
  end

  def schema_for(query_class, visibility: true, setup: nil, options: {})
    plugin = GraphQL::Armory::Authorization
    a = adapter
    Class.new(ArmoryEngine.base_schema) do
      use plugin, adapter: a, **options
      use GraphQL::Schema::Visibility, dynamic: true if visibility
      query query_class
      class_eval(&setup) if setup
    end
  end

  def report(schema) = GraphQL::Armory::Authorization::Audit.(schema)
  def paths(schema) = report(schema).problems.map(&:path)

  def run_query(schema, text, root: nil, context: { current_user: :u, beta: true })
    execute_query(schema, text, root_value: root, context: context).to_h
  end

  def iface(name = "Iface", field_cls: nil, &block)
    Module.new do
      include GraphQL::Schema::Interface
      graphql_name name
      field_class field_cls if field_cls
      class_eval(&block) if block
    end
  end

  def out(name, text)
  end

  # --- walk reach -------------------------------------------------------
  it "[security] W2 resolver class `type` is followed" do
    t = plain
    r = Class.new(GraphQL::Schema::Resolver) { type t, null: true }
    q = query_type { field :x, resolver: r, authorize: :none, reason: "x" }
    expect(paths(schema_for(q))).to include("Plain")
  end

  it "[security] W2b argument added by a field extension is followed" do
    t = plain
    ext = Class.new(GraphQL::Schema::FieldExtension) do
      define_method(:apply) { field.argument(:thing_id, "ID", required: false, loads: t) }
    end
    q = query_type { field :x, String, null: true, authorize: :none, reason: "x", extensions: [ext] }
    expect(paths(schema_for(q))).to include("Plain")
  end

  it "[security] W3 resolver argument loads: is followed" do
    t = plain
    r = Class.new(GraphQL::Schema::Resolver) do
      type String, null: true
      argument :thing_id, "ID", required: false, loads: t
    end
    q = query_type { field :x, resolver: r, authorize: :none, reason: "x" }
    expect(paths(schema_for(q))).to include("Plain")
  end

  it "[security] W4 relay classic mutation payload and input loads: are followed" do
    pay = plain("PayPlain")
    load = plain("LoadPlain")
    m = Class.new(GraphQL::Schema::RelayClassicMutation) do
      graphql_name "DoIt"
      field :result, pay, null: true
      argument :thing_id, "ID", required: false, loads: load
    end
    root = Class.new(base_object) do
      graphql_name "Mutation"
      authorize :none, reason: "root", covers_fields: true
      field :do_it, mutation: m, authorize: :none, reason: "x"
    end
    root.class_eval(&hide)
    found = paths(schema_for(query_type, setup: proc { mutation root }))
    expect(found).to include("PayPlain", "LoadPlain")
  end

  it "[security] W5 subscription payload is followed" do
    pay = plain
    s = Class.new(GraphQL::Schema::Subscription) do
      graphql_name "Sub"
      field :thing, pay, null: true
    end
    root = Class.new(base_object) do
      graphql_name "Subscription"
      authorize :none, reason: "root", covers_fields: true
      field :sub, subscription: s, authorize: :none, reason: "x"
    end
    expect(paths(schema_for(query_type, setup: proc { subscription root }))).to include("Plain")
  end

  it "[security] W6 hidden input object loads: and the loaded type are followed" do
    t = plain
    input = Class.new(GraphQL::Schema::InputObject) do
      graphql_name "Opts"
      argument :thing_id, "ID", required: false, loads: t
    end
    input.class_eval(&hide)
    q = query_type do
      field :x, String, null: true, authorize: :none, reason: "x" do
        argument :opts, input, required: false
      end
    end
    expect(paths(schema_for(q))).to include("Plain", "Opts(thing_id)")
  end



  it "[security] W8 a parent interface and its field types are followed" do
    t = plain
    parent = iface("ParentIface") do
      field :deep, t, null: true
      definition_methods { def visible?(context) = super && context[:beta] == true }
    end
    child = iface("ChildIface") do
      implements parent
      definition_methods { def visible?(context) = super && context[:beta] == true }
    end
    q = query_type { field :x, child, null: true, authorize: :none, reason: "x" }
    expect(paths(schema_for(q))).to include("Plain")
  end

  it "[security] W9 a custom edge class with its own node_type is followed" do
    t = plain
    edge = Class.new(GraphQL::Types::Relay::BaseEdge) do
      graphql_name "PlainEdge"
      node_type t
    end
    conn = Class.new(GraphQL::Types::Relay::BaseConnection) do
      graphql_name "PlainConnection"
      edge_type edge
    end
    q = query_type { field :x, conn, null: true, authorize: :none, reason: "x" }
    expect(paths(schema_for(q))).to include("Plain")
  end

  it "[security] W10 a child schema audits its parent's orphans and roots" do
    t = plain
    t2 = plain("OnRoot")
    q = query_type { field :x, t2, null: true, authorize: :none, reason: "x" }
    parent = schema_for(q, setup: proc { orphan_types t })
    child = Class.new(parent)
    expect(paths(child)).to include("Plain", "OnRoot")
  end

  it "[security] W11 lazy roots with preload:false are followed and the audit does not raise" do
    t = plain
    q = query_type { field :x, t, null: true, authorize: :none, reason: "x" }
    plugin = GraphQL::Armory::Authorization
    a = adapter
    schema = Class.new(ArmoryEngine.base_schema) do
      use plugin, adapter: a
      use GraphQL::Schema::Visibility, dynamic: true, preload: false
      query { q }
    end
    expect(paths(schema)).to include("Plain")
  end

  it "[security] W12a a string type name on a hidden path is followed" do
    stub = plain
    Object.const_set(:ProbeStringPlain, stub) unless defined?(::ProbeStringPlain)
    q = query_type { field :x, "ProbeStringPlain", null: true, authorize: :none, reason: "x" }
    expect(paths(schema_for(q))).to include("Plain")
  end


  it "[preservation] W13 Schema.from_definition reports the same as main" do
    sdl = "type Query { a: Foo } type Foo { b: String } interface I { c: String } union U = Foo"
    built = GraphQL::Schema.from_definition(sdl)
    out("from_definition.txt", report(built).to_s)
    expect(report(built).ok?).to be(false)
  end

  describe "W14 extra_types" do
    def extra_schema
      t = Class.new(GraphQL::Schema::Object) { graphql_name "Extra" }
      field_cls = base_field
      i = iface("Iface", field_cls: field_cls) { field :secret, String, null: true, authorize: :none, reason: "x" }
      t.class_eval { implements i }
      t.class_eval(&hide)
      q = query_type { field :thing, i, null: true, authorize: :none, reason: "x" }
      s = schema_for(q, setup: proc {
        extra_types t
        define_singleton_method(:resolve_type) { |_abs, _obj, _ctx| t }
      })
      [s, Struct.new(:thing).new(Struct.new(:secret).new("SECRET"))]
    end

  end

  # --- the override: all_field_definitions keeps one per name, get_field falls back when it is hidden --------
  describe "W15 override hidden by visible_when: falls back to the ancestor's definition" do
    def doc_type
      parent = Class.new(base_object) do
        graphql_name "Doc"
        authorize :read, model: Invoice
        field :notes, String, null: true
      end
      Class.new(parent) do
        graphql_name "Doc"
        field :notes, String, null: true, authorize: :manage, visible_when: :manage
      end
    end

    def doc_with_interface
      bf = base_field
      i = iface("HasNotes") do
        field_class bf
        field :notes, String, null: true
      end
      Class.new(base_object) do
        graphql_name "Doc"
        authorize :read, model: Invoice
        implements i
        field :notes, String, null: true, authorize: :manage, visible_when: :manage
      end
    end

    def leak_check(schema, name)
      root = Struct.new(:doc).new(Struct.new(:notes).new("SECRET"))
      served = run_query(schema, "{ doc { notes } }", root: root, context: { current_user: :reader })
      out("#{name}.txt", "#{served.inspect}\n#{report(schema)}")
      leaked = served.dig("data", "doc", "notes") == "SECRET"
      expect(leaked && report(schema).ok?).to eq(false), "served #{served.inspect} with the audit ok"
    end

    it "[security] W15a parent class field, plain schema: refused user vs audit" do
      c = doc_type
      leak_check(schema_for(query_type { field :doc, c, null: true, authorize: :none, reason: "x" }, visibility: false), "w15a")
    end

    it "[security] W15b parent class field, Visibility dynamic: refused user vs audit" do
      c = doc_type
      leak_check(schema_for(query_type { field :doc, c, null: true, authorize: :none, reason: "x" }), "w15b")
    end

    it "[security] W15c interface field, plain schema: refused user vs audit" do
      c = doc_with_interface
      leak_check(schema_for(query_type { field :doc, c, null: true, authorize: :none, reason: "x" }, visibility: false), "w15c")
    end

    it "[security] W15d interface field, Visibility dynamic: refused user vs audit" do
      c = doc_with_interface
      leak_check(schema_for(query_type { field :doc, c, null: true, authorize: :none, reason: "x" }), "w15d")
    end

    it "[security] W15e a type reached only by the ancestor's overridden field is audited" do
      t = plain("OnlyOnParent", hidden: false)
      parent = Class.new(base_object) do
        graphql_name "Doc"
        authorize :read, model: Invoice
        field :detail, t, null: true
      end
      child = Class.new(parent) do
        graphql_name "Doc"
        field :detail, String, null: true, authorize: :manage, visible_when: :manage
      end
      schema = schema_for(query_type { field :doc, child, null: true, authorize: :none, reason: "x" }, visibility: false)
      served = run_query(schema, "{ doc { detail { secret } } }",
                         root: Struct.new(:doc).new(Struct.new(:detail).new(Struct.new(:secret).new("SECRET"))),
                         context: { current_user: :reader })
      out("w15e.txt", "#{served.inspect}\n#{report(schema)}")
      expect(paths(schema)).to include("OnlyOnParent")
    end
  end


  it "[security] W16r the same override really loads through the parent's argument, compared with the audit" do
    loaded = []
    t = plain("Loaded", hidden: false)
    hidden_arg = Class.new(GraphQL::Schema::Argument) { def visible?(context) = super && context[:beta] == true }
    parent = Class.new(GraphQL::Schema::InputObject) do
      graphql_name "Opts"
      argument :thing_id, "ID", required: false, loads: t
    end
    child = Class.new(parent) do
      graphql_name "Opts"
      argument_class hidden_arg
      argument :thing_id, "ID", required: false
    end
    q = query_type do
      field :x, String, null: true, authorize: :none, reason: "x" do
        argument :opts, child, required: false
      end
      define_method(:x) { |opts: nil| opts.to_h.inspect }
    end
    schema = schema_for(q, visibility: false, setup: proc {
      define_singleton_method(:object_from_id) { |id, _c| loaded << id; Struct.new(:secret).new("SECRET") }
      define_singleton_method(:resolve_type) { |_a, _o, _c| t }
    })
    served = run_query(schema, '{ x(opts: {thingId: "foreign"}) }', root: Object.new, context: { current_user: :u })
    out("w16r.txt", "#{served.inspect}\nloaded=#{loaded.inspect}\n#{report(schema)}")
    expect(loaded.any? && report(schema).ok?).to eq(false), "loaded #{loaded} with the audit ok: #{served}"
  end

  it "[security] W7r a directive argument loads: really loads with no scope, compared with the audit" do
    loaded = []
    t = plain("DirLoaded", hidden: false)
    t.class_eval(&hide)
    dir = Class.new(GraphQL::Schema::Directive) do
      graphql_name "flag"
      locations GraphQL::Schema::Directive::FIELD
      argument :thing_id, "ID", required: false, loads: t
    end
    schema = schema_for(query_type { define_method(:ping) { "pong" } }, setup: proc {
      directive dir
      define_singleton_method(:object_from_id) { |id, _c| loaded << id; Struct.new(:secret).new("SECRET") }
      define_singleton_method(:resolve_type) { |_a, _o, _c| t }
    })
    served =
      begin
        run_query(schema, '{ ping @flag(thingId: "foreign") }', root: Object.new)
      rescue StandardError => e
        "raised #{e.class}: #{e.message[0, 200]}"
      end
    out("w7r.txt", "#{served.inspect}\nloaded=#{loaded.inspect}\n#{report(schema)}")
    expect(loaded.any? && report(schema).ok?).to eq(false), "loaded #{loaded} with the audit ok: #{served}"
  end

  it "[security] W12c a late bound field naming a hidden orphan is audited" do
    t = plain
    q = query_type { field :x, GraphQL::Schema::LateBoundType.new("Plain"), null: true, authorize: :none, reason: "x" }
    expect(paths(schema_for(q, setup: proc { orphan_types t }))).to include("Plain")
  end

  it "[preservation] W15p a visible override keeps its rule: no fallback" do
    parent = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: ::Invoice
      field :notes, String, null: true
    end
    c = Class.new(parent) do
      graphql_name "Doc"
      field :notes, String, null: true, authorize: :manage
    end
    schema = schema_for(query_type { field :doc, c, null: true, authorize: :none, reason: "x" }, visibility: false)
    root = Struct.new(:doc).new(Struct.new(:notes).new("SECRET"))
    served = run_query(schema, "{ doc { notes } }", root: root, context: { current_user: :reader })
    expect(served.dig("data", "doc", "notes")).to be_nil
  end

  it "[security] W15f a declared bypass on the parent's field, hidden override: is it listed" do
    parent = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: ::Invoice
      field :notes, String, null: true, authorize: :none, reason: "parent bypass"
    end
    c = Class.new(parent) do
      graphql_name "Doc"
      field :notes, String, null: true, authorize: :manage, visible_when: :manage
    end
    schema = schema_for(query_type { field :doc, c, null: true, authorize: :none, reason: "x" }, visibility: false)
    expect(report(schema).bypasses.map(&:reason)).to include("parent bypass")
  end

  it "[preservation] W15o owners: who answers on the real class" do
    parent = Class.new(base_object) { graphql_name "Doc"; authorize :read, model: ::Invoice; field :notes, String, null: true }
    c = Class.new(parent) { graphql_name "Doc"; field :notes, String, null: true, authorize: :manage, visible_when: :manage }
    f = c.all_field_definitions.first
    out("owners.txt", { get_field: c.method(:get_field).owner, all_field_definitions: c.method(:all_field_definitions).owner,
                        field_visible: f.method(:visible?).owner, field_authorized: f.method(:authorized?).owner,
                        definitions: c.all_field_definitions.map(&:armory_declared), ancestors_with_field: c.ancestors.select { |x| x.respond_to?(:own_fields) && x.own_fields["notes"] }.size }.inspect)
  end

  it "[preservation] I0b visible bypassed implementer, undeclared Base field: denied and reported (baseline of I2)" do
    bf = base_field
    i = iface("Iface", field_cls: bf) { field :secret, String, null: true }
    t = Class.new(base_object) do
      graphql_name "Bypassed"
      authorize :none, reason: "bypassed"
      implements i
    end
    q = query_type { field :thing, i, null: true, authorize: :none, reason: "x" }
    schema = schema_for(q, setup: proc {
      orphan_types t
      define_singleton_method(:resolve_type) { |_a, _o, _c| t }
    })
    served = run_query(schema, "{ thing { secret } }", root: Struct.new(:thing).new(Struct.new(:secret).new("SECRET")))
    out("i0b.txt", "#{served.inspect}\n#{report(schema)}")
    expect(served.dig("data", "thing", "secret")).to be_nil
    expect(paths(schema)).to include("Iface.secret")
  end

  # --- field level ----------------------------------------------------------
  it "[preservation] F2 a loads: under load_through_scope: false is listed" do
    t = plain("Loaded", hidden: false)
    q = query_type do
      field :x, String, null: true, authorize: :none, reason: "x", load_through_scope: false do
        argument :thing_id, "ID", required: false, loads: t
      end
    end
    expect(paths(schema_for(q, visibility: false))).to include(start_with("Query.x("))
  end

  it "[security] F3 an interface with a duplicated field is audited, not a crash" do
    hide_field = Class.new(base_field) { def visible?(context) = super && context[:beta] == true }
    i = iface("Dup", field_cls: hide_field) do
      field :a, String, null: true, authorize: true
      field :a, Integer, null: true, authorize: true
    end
    q = query_type { field :x, i, null: true, authorize: :none, reason: "x" }
    bo = base_object
    impl = Class.new(bo) do
      graphql_name "Impl"
      authorize :read, model: Invoice
      implements i
    end
    schema = schema_for(q, visibility: false, setup: proc { orphan_types impl })
    expect(report(schema).problems.map(&:kind)).to include(:field_without_rule)
  end

  # --- interface walk -------------------------------------------------------
  describe "I hidden bypassed implementer" do
    def impl_schema(hide_type:, field_cls:, visibility:, membership: false)
      i = iface("Iface", field_cls: field_cls) { field :secret, String, null: true }
      if membership
        m = Class.new(GraphQL::Schema::TypeMembership) { def visible?(context) = super && context[:beta] == true }
        i.type_membership_class(m)
      end
      t = Class.new(base_object) do
        graphql_name "Bypassed"
        authorize :none, reason: "bypassed"
        implements i
      end
      t.class_eval(&hide) if hide_type
      q = query_type { field :thing, i, null: true, authorize: :none, reason: "x" }
      schema_for(q, visibility: visibility, setup: proc {
        orphan_types t
        define_singleton_method(:resolve_type) { |_abs, _obj, _ctx| t }
      })
    end

    def check(schema, name)
      root = Struct.new(:thing).new(Struct.new(:secret).new("SECRET"))
      served = run_query(schema, "{ thing { secret } }", root: root)
      rep = report(schema)
      out("#{name}.txt", "#{served.inspect}\n#{rep}")
      leaked = served.dig("data", "thing", "secret") == "SECRET"
      expect(leaked && rep.problems.none? { |pr| pr.path == "Iface.secret" }).to eq(false), "served #{served.inspect}; problems #{rep.problems.map(&:to_s)}"
    end

    it "[security] I1 field class without Base, Visibility: reported where served" do
      check(impl_schema(hide_type: true, field_cls: GraphQL::Schema::Field, visibility: true), "i1")
    end

    it "[security] I2 undeclared Base field, Visibility: denied or reported" do
      check(impl_schema(hide_type: true, field_cls: base_field, visibility: true), "i2")
    end

    it "[security] I3 hidden membership, plain schema: reported where served" do
      check(impl_schema(hide_type: false, field_cls: base_field, visibility: false, membership: true), "i3")
    end

    it "[preservation] I1p hidden implementer on a plain schema stays reported" do
      check(impl_schema(hide_type: true, field_cls: GraphQL::Schema::Field, visibility: false), "i1p")
    end

    it "[preservation] I0 visible bypassed implementer stays denied or reported" do
      check(impl_schema(hide_type: false, field_cls: GraphQL::Schema::Field, visibility: true), "i0")
    end
  end

  # --- duplicates, boot -----------------------------------------------------
  it "[preservation] D1 two definitions both visible raise DuplicateNamesError on the audit" do
    a = plain("Twin", hidden: false)
    b = plain("Twin", hidden: false)
    q = query_type do
      field :a, a, null: true, authorize: :none, reason: "x"
      field :b, b, null: true, authorize: :none, reason: "x"
    end
    expect { report(schema_for(q, visibility: false)) }.to raise_error(GraphQL::Schema::DuplicateNamesError)
  end




  # --- clean schema / false problems ---------------------------------------
  describe "C clean" do
    def broad_schema
      plugin = GraphQL::Armory::Authorization
      bf = base_field
      bo = base_object
      a = adapter
      base_edge = Class.new(bo) do
        include GraphQL::Types::Relay::EdgeBehaviors
        authorize :none, reason: "edge", covers_fields: true
      end
      base_conn = Class.new(bo) do
        include GraphQL::Types::Relay::ConnectionBehaviors
        authorize :none, reason: "conn", covers_fields: true
        edge_type_class base_edge
      end
      base_bo = Class.new(bo) do
        edge_type_class base_edge
        connection_type_class base_conn
      end
      node_if = Module.new do
        include GraphQL::Schema::Interface
        include GraphQL::Types::Relay::NodeBehaviors
        graphql_name "Node"
        field_class bf
      end
      status = Class.new(GraphQL::Schema::Enum) do
        graphql_name "Status"
        value "A"
        value "B"
      end
      invoice = Class.new(base_bo) do
        graphql_name "Invoice"
        authorize :read, model: ::Invoice
        implements node_if
        field :number, String, null: false
        field :status, status, null: true
        field :notes, String, null: true, authorize: :manage, visible_when: :manage
      end
      account = Class.new(base_bo) do
        graphql_name "Account"
        authorize :read, model: ::Account
        field :name, String, null: true
        field :invoices, invoice.connection_type, null: true
      end
      search = Class.new(GraphQL::Schema::Union) do
        graphql_name "Search"
        possible_types invoice, account
      end
      input = Class.new(GraphQL::Schema::InputObject) do
        include plugin::Base
        graphql_name "Filter"
        argument :status, status, required: false
        argument :account_id, "ID", required: false, loads: account
      end
      mut = Class.new(GraphQL::Schema::RelayClassicMutation) do
        include plugin::Base
        graphql_name "Approve"
        authorize :manage, model: ::Invoice
        object_class base_bo
        field_class bf
        field :invoice, invoice, null: true
        argument :invoice_id, "ID", required: true, loads: invoice
      end
      mroot = Class.new(bo) do
        graphql_name "Mutation"
        authorize :none, reason: "root", covers_fields: true
        field :approve, mutation: mut
      end
      q = query_type do
        field :search, [search], null: true, authorize: :none, reason: "x"
        field :invoices, invoice.connection_type, null: true, authorize: :none, reason: "x" do
          argument :filter, input, required: false
        end
        field :account, account, null: true, authorize: :none, reason: "x"
      end
      Class.new(ArmoryEngine.base_schema) do
        use plugin, adapter: a
        use GraphQL::Schema::Visibility, dynamic: true
        query q
        mutation mroot
        orphan_types invoice
        define_singleton_method(:resolve_type) { |_abs, _obj, _ctx| invoice }
      end
    end

    it "[preservation] C1 broad schema report text is written for comparison" do
      out("broad.txt", report(broad_schema).to_s)
    end

    it "[preservation] C1b IntegrationSchema, flawed and clean, reports written for comparison" do
      out("integration_flawed.txt", report(IntegrationSchema.build).to_s)
      out("integration_clean.txt", report(IntegrationSchema.build(flawed: false)).to_s)
    end

    it "[preservation] C2 the dump is unchanged by an audit" do
      s = broad_schema
      before = s.to_definition(context: { armory_full_schema: true, current_user: :u })
      report(s)
      after = s.to_definition(context: { armory_full_schema: true, current_user: :u })
      out("dump.txt", after)
      expect(after).to eq(before)
    end

    it "[preservation] C4 no bypass line appears twice on a clean schema" do
      rep = report(broad_schema)
      expect(rep.bypasses.map(&:path).tally.select { |_, n| n > 1 }).to eq({})
    end
  end

  # --- declarations --------------------------------------------------------
  it "[security] X1 a bypass on one definition does not clear no rule on the other" do
    plugin_base = base_field
    a = Class.new(base_object) do
      graphql_name "Twin"
      authorize :none, reason: "x", covers_fields: true
    end
    no_default = Class.new(GraphQL::Schema::Object) do
      include GraphQL::Armory::Authorization::Base
      field_class plugin_base
    end
    b = Class.new(no_default) { graphql_name "Twin" }
    b.class_eval { def self.visible?(context) = context[:beta] == true }
    q = query_type do
      field :a, a, null: true, authorize: :none, reason: "x"
      field :b, b, null: true, authorize: :none, reason: "x"
    end
    rep = report(schema_for(q, visibility: false))
    expect(rep.problems.select { |pr| pr.path == "Twin" }.map(&:kind)).to include(:no_rule)
    expect(rep.bypasses.map(&:path)).to include("Twin")
  end

  it "[security] X2 own_checks on one definition does not clear the other's own check" do
    a = Class.new(base_object) do
      graphql_name "Twin"
      authorize :none, reason: "x", covers_fields: true
      def self.authorized?(_object, _context) = true
    end
    b = Class.new(base_object) do
      graphql_name "Twin"
      authorize :none, reason: "x", covers_fields: true
      def self.authorized?(_object, _context) = true
      def self.visible?(context) = context[:beta] == true
    end
    q = query_type do
      field :a, a, null: true, authorize: :none, reason: "x"
      field :b, b, null: true, authorize: :none, reason: "x"
    end
    rep = report(schema_for(q, visibility: false, options: { own_checks: { a => { authorized?: "declared on a" } } }))
    expect(rep.problems.select { |pr| pr.kind == :own_check }.size).to eq(1)
  end

  it "[security] X3 own_checks naming a hidden class is honoured, not called unused" do
    t = Class.new(base_object) do
      graphql_name "Hid"
      authorize :none, reason: "x", covers_fields: true
      def self.authorized?(_object, _context) = true
      def self.visible?(context) = context[:beta] == true
    end
    q = query_type { field :a, t, null: true, authorize: :none, reason: "x" }
    rep = report(schema_for(q, options: { own_checks: { t => { authorized?: "reason" } } }))
    expect(rep.problems.map(&:to_s)).to eq([])
    expect(rep.bypasses.map(&:path)).to include(end_with("authorized?"))
  end

  it "[security] X4 reauthorize off on a hidden connection's node is reported" do
    node = Class.new(base_object) do
      graphql_name "Hid"
      authorize :read, model: ::Invoice
      reauthorize_scoped_objects(false)
      def self.visible?(context) = context[:beta] == true
    end
    conn = node.connection_type
    conn.class_eval { def self.visible?(context) = context[:beta] == true }
    q = query_type { field :conn, conn, null: true, authorize: :none, reason: "x" }
    expect(paths(schema_for(q))).to include(end_with(".reauthorize_scoped_objects"))
  end

  # --- cost -----------------------------------------------------------------
  it "[preservation] R1 audit cost on large schemas, written for comparison" do
    bo = base_object
    build = lambda do |types, edges|
      all = Array.new(types) do |index|
        Class.new(bo) do
          graphql_name "T#{index}"
          authorize :none, reason: "x", covers_fields: true
          field :a, String, null: true, authorize: :none, reason: "x"
        end
      end
      with_edges = all.first(edges).map do |t|
        edge = Class.new(GraphQL::Types::Relay::BaseEdge) do
          include GraphQL::Armory::Authorization::Base
          graphql_name "#{t.graphql_name}E"
          authorize :read, model: ::Invoice
          node_type t
        end
        Class.new(GraphQL::Types::Relay::BaseConnection) do
          graphql_name "#{t.graphql_name}C"
          edge_type edge
        end
      end
      q = query_type do
        all.each { |t| field :"f_#{t.graphql_name.downcase}", t, null: true, authorize: :none, reason: "x" }
        with_edges.each { |c| field :"c_#{c.graphql_name.downcase}", c, null: true, authorize: :none, reason: "x" }
      end
      schema_for(q, visibility: false)
    end
    lines = [[1000, 0], [4000, 0], [1000, 100], [2000, 200]].map do |types, edges|
      schema = build.(types, edges)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      report(schema)
      format("types=%d edges=%d seconds=%.2f", types, edges, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0)
    end
    out("cost.txt", lines.join("\n"))
    puts lines
  end
end
