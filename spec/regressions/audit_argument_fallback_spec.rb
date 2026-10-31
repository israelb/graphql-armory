# frozen_string_literal: true

require "fileutils"

# Independent probes for PR #12 (audit of redefined arguments, fallback under Schema::Visibility profiles).
# Written from the code diff and docs/authorization.md before reading the PR's own specs.
RSpec.describe "PR12 probes" do
  armory = GraphQL::Armory::Authorization

  by_action = Class.new(armory::Adapters::Substitute) do
    def initialize(allowed)
      super()
      @allowed = allowed
    end

    def authorized?(_actor, _subject, rule) = @allowed.include?(rule.action)
  end

  # Hides a member from non-beta users (beta_only:), or shows it to one audience only (audience: :beta | :public).
  shown = lambda do |beta_only, audience, context|
    beta = context[:beta] == true
    (!beta_only || beta) && (audience.nil? || (audience == :beta) == beta)
  end

  let(:adapter) { by_action.new(%i[read]) }
  let(:arg_class) do
    s = shown
    Class.new(GraphQL::Schema::Argument) do
      include GraphQL::Armory::Authorization::Base
      define_method(:initialize) do |*args, beta_only: false, audience: nil, **kwargs, &block|
        @beta_only = beta_only
        @audience = audience
        super(*args, **kwargs, &block)
      end
      define_method(:visible?) { |context| super(context) && s.(@beta_only, @audience, context) }
    end
  end
  let(:field_class) do
    s = shown
    ac = arg_class
    Class.new(GraphQL::Schema::Field) do
      include GraphQL::Armory::Authorization::Base
      argument_class ac
      define_method(:initialize) do |*args, beta_only: false, audience: nil, **kwargs, &block|
        @beta_only = beta_only
        @audience = audience
        super(*args, **kwargs, &block)
      end
      define_method(:visible?) { |context| super(context) && s.(@beta_only, @audience, context) }
    end
  end
  let(:base_object) do
    fc = field_class
    Class.new(GraphQL::Schema::Object) do
      include GraphQL::Armory::Authorization::Base
      field_class fc
      default_action :read
    end
  end
  let(:base_input) do
    ac = arg_class
    Class.new(GraphQL::Schema::InputObject) do
      include GraphQL::Armory::Authorization::Base
      argument_class ac
    end
  end

  STRICT = { authorize: :manage, model: Invoice, beta_only: true }.freeze
  DECL = { override_reason: "declared" }.freeze

  def schema_for(query_class, mutation_class: nil, setup: nil, pre: nil, adapter_override: nil)
    plug = GraphQL::Armory::Authorization
    a = adapter_override || adapter
    Class.new(ArmoryEngine.base_schema) do
      use plug, adapter: a
      class_eval(&pre) if pre
      query query_class
      mutation mutation_class if mutation_class
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

  def doc_type(parent = base_object, name: "Doc", &block)
    Class.new(parent) do
      graphql_name name
      authorize :read, model: Invoice
      class_eval(&block) if block
    end
  end

  def resolver_pair(child_opts: STRICT, name: "NotesResolver", child: true)
    ac = arg_class
    parent = Class.new(GraphQL::Schema::Resolver) do
      graphql_name name
      argument_class ac
      type GraphQL::Types::String, null: true
      argument :internal, GraphQL::Types::Boolean, required: false
      def resolve(internal: false, **) = internal ? "SECRET" : "plain"
    end
    return [parent, nil] unless child

    kid = Class.new(parent) do
      graphql_name name
      argument :internal, GraphQL::Types::Boolean, required: false, **child_opts
    end
    [parent, kid]
  end

  def input_pair(child_opts: STRICT)
    parent_in = Class.new(base_input) do
      graphql_name "Filter"
      argument :internal, GraphQL::Types::Boolean, required: false
    end
    child_in = Class.new(parent_in) do
      graphql_name "Filter"
      argument :internal, GraphQL::Types::Boolean, required: false, **child_opts
    end
    [parent_in, child_in]
  end

  def report(schema) = GraphQL::Armory::Authorization::Audit.(schema)
  def ignored(rep) = rep.problems.select { |pr| pr.kind == :ignored_rule }.map(&:path)
  def flagged?(rep, suffix) = ignored(rep).any? { |path| path.end_with?(suffix) }

  def out(name, text)
  end

  def notes_root = Struct.new(:doc).new(Class.new { def notes(internal: false, filter: nil, outer: nil) = (internal || filter&.internal || outer&.filter&.internal) ? "SECRET" : "plain" }.new)

  def run(schema, query, root: notes_root, **context)
    execute_query(schema, query, root_value: root, context: context).to_h
  rescue StandardError => e
    "raised #{e.class}: #{e.message[0, 160]}"
  end

  def secret?(served) = served.is_a?(Hash) && served.to_s.include?("SECRET")

  # For field-level fallbacks: the field itself is what is protected.
  def secret_root = Struct.new(:doc).new(Struct.new(:notes).new("SECRET"))

  def summary(rep) = "ok: #{rep.ok?}\nignored: #{ignored(rep)}\nproblems: #{rep.problems.map { |pr| "#{pr.kind} #{pr.path}" }}\nbypasses: #{rep.bypasses.map(&:path)}"

  # Fails only when a hidden user gets SECRET while the audit flags nothing ending in `suffix`.
  def leak_check(name, schema, suffix, query:, root: notes_root, **context)
    served = run(schema, query, root: root, **context)
    rep = report(schema)
    out(name, "served: #{served.inspect}\n#{summary(rep)}")
    expect(secret?(served) && !flagged?(rep, suffix)).to eq(false), "#{name}: served #{served.inspect} and #{suffix} not flagged (#{summary(rep)})"
    [served, rep]
  end

  NOTES_INTERNAL = "{ doc { notes(internal: true) } }"

  # --- Arguments ---------------------------------------------------------------------------------
  it "[security] AR1 input object subclass redefines an argument: reported, declared clears it, runtime leak" do
    _, child_in = input_pair
    doc = doc_type { field(:notes, String, null: true) { argument :filter, child_in, required: false } }
    q = "{ doc { notes(filter: { internal: true }) } }"
    served, rep = leak_check("ar1", schema_for(on_query(doc)), "Filter.internal", query: q)
    _, child_d = input_pair(child_opts: STRICT.merge(DECL))
    doc_d = doc_type { field(:notes, String, null: true) { argument :filter, child_d, required: false } }
    schema_d = schema_for(on_query(doc_d))
    rep_d = report(schema_d)
    served_d = run(schema_d, q)
    shown_user = run(schema_for(on_query(doc)), q, beta: true)
    out("ar1b", "hidden: #{served}\ndeclared hidden: #{served_d}\nshown (control): #{shown_user}\ndeclared #{summary(rep_d)}")
    expect(ignored(rep)).to include("Filter.internal")
    expect(ignored(rep_d)).not_to include("Filter.internal")
    expect(rep_d.bypasses.map(&:path)).to include("Filter.internal")
    expect(secret?(shown_user)).to eq(false)
  end

  it "[security] AR2 resolver subclass redefines an argument (field resolver:)" do
    _, kid = resolver_pair
    doc = doc_type { field :notes, resolver: kid }
    served, rep = leak_check("ar2", schema_for(on_query(doc)), ".internal", query: NOTES_INTERNAL)
    out("ar2b", "secret: #{secret?(served)} ignored: #{ignored(rep)}")
    expect(flagged?(rep, "notes.internal")).to eq(true)
  end

  it "[security] AR3 Schema::Mutation subclass redefines an argument (field mutation:)" do
    ac = arg_class
    parent_m = Class.new(GraphQL::Schema::Mutation) do
      graphql_name "DoIt"
      argument_class ac
      field :result, String, null: true
      argument :internal, GraphQL::Types::Boolean, required: false
      def resolve(internal: false, **) = { result: internal ? "SECRET" : "plain" }
    end
    child_m = Class.new(parent_m) do
      graphql_name "DoIt"
      argument :internal, GraphQL::Types::Boolean, required: false, **STRICT
    end
    mut = query_with { graphql_name "Mutation"; field :do_it, mutation: child_m }
    schema = schema_for(on_query(doc_type { field :notes, String, null: true }), mutation_class: mut)
    served, rep = leak_check("ar3", schema, ".internal", query: "mutation { doIt(internal: true) { result } }")
    out("ar3b", "secret: #{secret?(served)}")
  end

  it "[security] AR4 RelayClassicMutation subclass redefines an argument: runtime vs report" do
    ac = arg_class
    parent_m = Class.new(GraphQL::Schema::RelayClassicMutation) do
      graphql_name "DoIt"
      argument_class ac
      field :result, String, null: true
      argument :internal, GraphQL::Types::Boolean, required: false
      def resolve(internal: false, **) = { result: internal ? "SECRET" : "plain" }
    end
    child_m = Class.new(parent_m) do
      graphql_name "DoIt"
      argument :internal, GraphQL::Types::Boolean, required: false, **STRICT
    end
    mut = query_with { graphql_name "Mutation"; field :do_it, mutation: child_m }
    schema = schema_for(on_query(doc_type { field :notes, String, null: true }), mutation_class: mut)
    served, rep = leak_check("ar4", schema, ".internal", query: "mutation { doIt(input: { internal: true }) { result } }")
    input_args = child_m.input_type.own_arguments["internal"]
    out("ar4b", "secret: #{secret?(served)} input own internal: #{Array(input_args).map(&:owner)}")
  end

  it "[security] AR5 a field's own argument beside a resolver's argument of the same name" do
    parent, = resolver_pair(child: false)
    doc = doc_type { field(:notes, resolver: parent) { argument :internal, GraphQL::Types::Boolean, required: false, **STRICT } }
    leak_check("ar5", schema_for(on_query(doc)), ".internal", query: NOTES_INTERNAL)
  end

  it "[security] AR6 the same argument twice on one field: both reported, declaring one leaves the other" do
    build = lambda do |decl|
      doc_type do
        field(:notes, String, null: true) do
          argument :internal, GraphQL::Types::Boolean, required: false, authorize: :manage, model: Invoice, audience: :beta, **decl
          argument :internal, GraphQL::Types::Boolean, required: false, audience: :public
        end
      end
    end
    served, rep = leak_check("ar6", schema_for(on_query(build.({}))), ".internal", query: NOTES_INTERNAL)
    rep_d = report(schema_for(on_query(build.(DECL))))
    out("ar6b", "plain: #{ignored(rep)}\ndeclared: #{ignored(rep_d)} bypasses #{rep_d.bypasses.map(&:path)}")
    expect(ignored(rep).count { |p| p.end_with?("notes.internal") }).to eq(2)
    expect(ignored(rep_d).count { |p| p.end_with?("notes.internal") }).to eq(1)
  end

  it "[security] AR7 a prepare: that redacts, lost on fallback through a resolver subclass" do
    _, kid = resolver_pair(child_opts: { beta_only: true, prepare: ->(_v, _c) { false } })
    doc = doc_type { field :notes, resolver: kid }
    leak_check("ar7", schema_for(on_query(doc)), ".internal", query: NOTES_INTERNAL)
  end

  it "[preservation] AR8 override_reason: on an argument class without Base raises, never ignored" do
    plain_input = -> { Class.new(GraphQL::Schema::InputObject) { graphql_name "P"; argument :x, String, required: false, override_reason: "y" } }
    plain_resolver = -> { Class.new(GraphQL::Schema::Resolver) { graphql_name "R"; argument :x, String, required: false, override_reason: "y" } }
    results = [plain_input, plain_resolver].map do |make|
      make.()
      "no error"
    rescue StandardError => e
      e.class.name
    end
    out("ar8", results.inspect)
    expect(results).to all(satisfy { |r| r != "no error" })
  end


  it "[preservation] AR9 a blank override_reason: on an argument raises ConfigurationError" do
    expect { input_pair(child_opts: { override_reason: "  " }) }.to raise_error(GraphQL::Armory::Authorization::ConfigurationError)
  end

  it "[security] AR10 nested input objects: the redefinition is reached only through an outer input" do
    _, child_in = input_pair
    outer = Class.new(base_input) do
      graphql_name "Outer"
      argument :filter, child_in, required: false
    end
    doc = doc_type { field(:notes, String, null: true) { argument :outer, outer, required: false } }
    leak_check("ar10", schema_for(on_query(doc)), "Filter.internal", query: "{ doc { notes(outer: { filter: { internal: true } }) } }")
  end

  it "[security] AR11 an argument redefined through a resolver on an interface field" do
    _, kid = resolver_pair
    fc = field_class
    iface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "HasNotes"
      field_class fc
      field :notes, resolver: kid
    end
    doc = doc_type { implements iface }
    leak_check("ar11", schema_for(on_query(doc)), ".internal", query: NOTES_INTERNAL)
  end

  it "[preservation] AR14 override_reason: on an argument with nothing to fall back to is a problem" do
    doc = doc_type { field(:notes, String, null: true) { argument :internal, GraphQL::Types::Boolean, required: false, override_reason: "x" } }
    rep = report(schema_for(on_query(doc)))
    out("ar14", summary(rep))
    expect(flagged?(rep, "notes.internal")).to eq(true)
  end

  # --- Visibility ---------------------------------------------------------------------------------
  def stricter_over_open
    pa = doc_type { field :notes, String, null: true }
    Class.new(pa) { graphql_name "Doc"; field :notes, String, null: true, authorize: :manage, beta_only: true }
  end

  def field_doc_with_filter
    _, child_in = input_pair
    doc_type { field(:notes, String, null: true) { argument :filter, child_in, required: false } }
  end

  FILTER_Q = "{ doc { notes(filter: { internal: true }) } }"

  it "[security] VI1 static profiles alone: field and input argument redefinitions, request names the profile" do
    setup = proc { use GraphQL::Schema::Visibility, profiles: { public: { beta: false } } }
    leak_check("vi1_field", schema_for(on_query(stricter_over_open), setup: setup), "Doc.notes", query: "{ doc { notes } }", root: secret_root, visibility_profile: :public)
    leak_check("vi1_field_first", schema_for(on_query(stricter_over_open), pre: setup), "Doc.notes", query: "{ doc { notes } }", root: secret_root, visibility_profile: :public)
    leak_check("vi1_arg", schema_for(on_query(field_doc_with_filter), setup: setup), "Filter.internal", query: FILTER_Q, visibility_profile: :public)
  end

  it "[security] VI2 dynamic plus profiles: the request names the profile" do
    setup = proc { use GraphQL::Schema::Visibility, dynamic: true, profiles: { public: { beta: false } } }
    leak_check("vi2_field", schema_for(on_query(stricter_over_open), setup: setup), "Doc.notes", query: "{ doc { notes } }", root: secret_root, visibility_profile: :public)
    leak_check("vi2_arg", schema_for(on_query(field_doc_with_filter), setup: setup), "Filter.internal", query: FILTER_Q, visibility_profile: :public)
  end

  it "[preservation] VI3 a profile name that is not configured" do
    dyn = schema_for(on_query(stricter_over_open), setup: proc { use GraphQL::Schema::Visibility, dynamic: true, profiles: { public: { beta: false } } })
    static = schema_for(on_query(stricter_over_open), setup: proc { use GraphQL::Schema::Visibility, profiles: { public: { beta: false } } })
    a = run(dyn, "{ doc { notes } }", visibility_profile: :nope)
    b = run(static, "{ doc { notes } }", visibility_profile: :nope)
    c = run(static, "{ doc { notes } }")
    out("vi3", "dynamic unknown: #{a}\nstatic unknown: #{b}\nstatic none: #{c}")
    expect([a, b, c].map { |s| secret?(s) }).to eq([false, false, false])
  end

  it "[security] VI4 a child schema turns the profile off" do
    parent = schema_for(on_query(field_doc_with_filter), setup: proc { use GraphQL::Schema::Visibility, dynamic: true })
    child = Class.new(parent) { self.use_visibility_profile = false }
    leak_check("vi4", child, "Filter.internal", query: FILTER_Q)
  end

  it "[security] VI5 use_visibility_profile = false set after the first audit" do
    schema = schema_for(on_query(field_doc_with_filter), setup: proc { use GraphQL::Schema::Visibility, dynamic: true })
    first = report(schema)
    first_served = run(schema, FILTER_Q)
    schema.use_visibility_profile = false
    served, rep = leak_check("vi5", schema, "Filter.internal", query: FILTER_Q)
    out("vi5b", "first: #{ignored(first)} served #{first_served}\nafter: #{ignored(rep)} served #{served}")
    expect(secret?(first_served)).to eq(false)
  end

  it "[security] VI6 Visibility inherited by a child schema that adds profiles" do
    parent = schema_for(on_query(field_doc_with_filter), setup: proc { use GraphQL::Schema::Visibility, dynamic: true })
    child = Class.new(parent) { use GraphQL::Schema::Visibility, profiles: { public: { beta: false } } }
    leak_check("vi6_child", child, "Filter.internal", query: FILTER_Q, visibility_profile: :public)
    p_served = run(parent, FILTER_Q)
    p_rep = report(parent)
    out("vi6_parent", "served: #{p_served}\n#{summary(p_rep)}")
    expect(secret?(p_served)).to eq(false)
  end

  it "[security] VI7 use GraphQL::Schema::Warden reports field and argument" do
    leak_check("vi7", schema_for(on_query(field_doc_with_filter), setup: proc { use GraphQL::Schema::Warden }), "Filter.internal", query: FILTER_Q)
  end

  it "[security] VI8 migration_errors: true" do
    schema = schema_for(on_query(field_doc_with_filter), setup: proc { use GraphQL::Schema::Visibility, dynamic: true, migration_errors: true })
    leak_check("vi8", schema, "Filter.internal", query: FILTER_Q)
    leak_check("vi8_skip", schema, "Filter.internal", query: FILTER_Q, skip_visibility_migration_error: true)
  end

  it "[preservation] VI9 preload: true, dynamic, no profiles: quiet and no leak" do
    schema = schema_for(on_query(field_doc_with_filter), setup: proc { use GraphQL::Schema::Visibility, dynamic: true, preload: true })
    served = run(schema, FILTER_Q)
    rep = report(schema)
    out("vi9", "served: #{served}\n#{summary(rep)}")
    expect(secret?(served)).to eq(false)
    expect(ignored(rep)).to be_empty
  end

  it "[security] VI10a dynamic Visibility, the same field twice on one owner, one per audience" do
    doc = doc_type do
      field :notes, String, null: true, authorize: :manage, audience: :beta
      field :notes, String, null: true, audience: :public
    end
    schema = schema_for(on_query(doc), setup: proc { use GraphQL::Schema::Visibility, dynamic: true })
    served, = leak_check("vi10a", schema, "Doc.notes", query: "{ doc { notes } }", root: secret_root)
    beta = run(schema, "{ doc { notes } }", root: secret_root, beta: true)
    no_vis = report(schema_for(on_query(doc)))
    out("vi10a_b", "public: #{served}\nbeta (strict def): #{beta}\nwithout Visibility: #{ignored(no_vis)}")
  end

  it "[security] VI10b dynamic Visibility, the same argument twice on one field, one per audience" do
    doc = doc_type do
      field(:notes, String, null: true) do
        argument :internal, GraphQL::Types::Boolean, required: false, authorize: :manage, model: Invoice, audience: :beta
        argument :internal, GraphQL::Types::Boolean, required: false, audience: :public
      end
    end
    schema = schema_for(on_query(doc), setup: proc { use GraphQL::Schema::Visibility, dynamic: true })
    leak_check("vi10b", schema, "notes.internal", query: NOTES_INTERNAL)
  end

  it "[security] VI10c dynamic Visibility, the same argument twice on one input object" do
    input = Class.new(base_input) do
      graphql_name "Filter"
      argument :internal, GraphQL::Types::Boolean, required: false, authorize: :manage, model: Invoice, audience: :beta
      argument :internal, GraphQL::Types::Boolean, required: false, audience: :public
    end
    doc = doc_type { field(:notes, String, null: true) { argument :filter, input, required: false } }
    schema = schema_for(on_query(doc), setup: proc { use GraphQL::Schema::Visibility, dynamic: true })
    leak_check("vi10c", schema, "Filter.internal", query: FILTER_Q)
  end

  it "[security] VI11a static profiles alone: a lazy field block's argument beside a resolver's" do
    parent, = resolver_pair(child: false)
    doc = doc_type { field(:notes, resolver: parent) { argument :internal, GraphQL::Types::Boolean, required: false, **STRICT } }
    schema = schema_for(on_query(doc), setup: proc { use GraphQL::Schema::Visibility, profiles: { public: { beta: false } } })
    rep = report(schema) # audit first, in a fresh process state, as `rake graphql_armory:audit` would
    served = run(schema, NOTES_INTERNAL, visibility_profile: :public)
    rep_after = report(schema)
    out("vi11a", "served: #{served}\nbefore query #{summary(rep)}\nafter query #{summary(rep_after)}")
    expect(secret?(served) && !flagged?(rep, "notes.internal")).to eq(false), "served #{served}, audit before the query: #{summary(rep)}"
  end

  it "[security] VI11b static profiles alone: the same argument twice in a lazy field block" do
    doc = doc_type do
      field(:notes, String, null: true) do
        argument :internal, GraphQL::Types::Boolean, required: false, authorize: :manage, model: Invoice, audience: :beta
        argument :internal, GraphQL::Types::Boolean, required: false, audience: :public
      end
    end
    schema = schema_for(on_query(doc), setup: proc { use GraphQL::Schema::Visibility, profiles: { public: { beta: false } } })
    rep = report(schema)
    served = run(schema, NOTES_INTERNAL, visibility_profile: :public)
    out("vi11b", "served: #{served}\n#{summary(rep)}")
    expect(secret?(served) && !flagged?(rep, "notes.internal")).to eq(false), "served #{served}, #{summary(rep)}"
  end

  it "[security] VI11c static profiles alone: an unscoped loads: inside a lazy field block (outside the diff)" do
    target = doc_type(name: "Target")
    build = lambda do |setup|
      t = target
      q = query_with do
        field(:target, t, null: true, authorize: :none, reason: "x", load_through_scope: false) { argument :target_id, GraphQL::Types::ID, loads: t }
      end
      schema_for(q, setup: setup)
    end
    plain = report(build.(nil))
    profiled = report(build.(proc { use GraphQL::Schema::Visibility, profiles: { public: {} } }))
    out("vi11c", "no Visibility: #{plain.problems.map { |pr| "#{pr.kind} #{pr.path}" }}\nprofiles: #{profiled.problems.map { |pr| "#{pr.kind} #{pr.path}" }}")
    expect(profiled.problems.map(&:kind)).to include(:unscoped_load)
  end

  it "[preservation] VI12 static profiles alone with an interface and a union: the audit does not raise" do
    fc = field_class
    iface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Thing"
      field_class fc
      field :name, String, null: true
    end
    doc = doc_type { implements iface; field :name, String, null: true }
    q = query_with { field :thing, iface, null: true, authorize: :none, reason: "x" }
    schema = schema_for(q, setup: proc { orphan_types(doc); use GraphQL::Schema::Visibility, profiles: { public: {} } })
    result = begin
      summary(report(schema))
    rescue StandardError => e
      "raised #{e.class}: #{e.message[0, 160]}"
    end
    out("vi12", result)
    expect(result).not_to start_with("raised")
  end

  it "[preservation] VI13 dynamic Visibility: a hidden interface's field does not fall back to the parent class's" do
    fc = field_class
    s = shown
    strict_i = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Strict"
      field_class fc
      field :notes, String, null: true, authorize: :manage
      definition_methods { define_method(:visible?) { |ctx| super(ctx) && s.(true, nil, ctx) } }
    end
    pa = doc_type { field :notes, String, null: true }
    doc = Class.new(pa) { graphql_name "Doc"; implements strict_i }
    schema = schema_for(on_query(doc), setup: proc { use GraphQL::Schema::Visibility, dynamic: true })
    served = run(schema, "{ doc { notes } }", root: secret_root)
    no_vis = run(schema_for(on_query(doc)), "{ doc { notes } }", root: secret_root)
    out("vi13", "dynamic: #{served}\nwarden: #{no_vis}\naudit warden: #{ignored(report(schema_for(on_query(doc))))}")
    expect(secret?(served)).to eq(false)
  end

  # --- Bookkeeping --------------------------------------------------------------------------------
  def redefined_schema = schema_for(on_query(field_doc_with_filter))
  def clean_schema = schema_for(on_query(doc_type { field :notes, String, null: true }))

  it "[security] BK1 one Audit object audits two schemas in turn" do
    s1 = redefined_schema
    s2 = clean_schema
    audit = GraphQL::Armory::Authorization::Audit.build(s1)
    r1 = audit.(s1)
    r2 = audit.(s2)
    r1b = audit.(s1)
    fresh2 = report(s2)
    out("bk1", "r1: #{ignored(r1)}\nr2: #{ignored(r2)}\nr1b: #{ignored(r1b)}\nfresh2: #{ignored(fresh2)}")
    expect(ignored(r1)).to include("Filter.internal")
    expect(ignored(r1b)).to eq(ignored(r1))
    expect(ignored(r2)).to eq(ignored(fresh2))
  end


  it "[preservation] BK3 an argument redefinition on a field inherited by two types is reported once" do
    _, kid = resolver_pair
    parent = doc_type(name: "ParentDoc") { field :notes, resolver: kid }
    doc = Class.new(parent) { graphql_name "Doc" }
    q = query_with do
      field :doc, doc, null: true, authorize: :none, reason: "x"
      field :parent_doc, parent, null: true, authorize: :none, reason: "x"
    end
    rep = report(schema_for(q))
    out("bk3", summary(rep))
    expect(ignored(rep).count { |p| p.end_with?("notes.internal") }).to eq(1)
  end

  it "[security] BK4 a declared field override over a parent field whose resolver redefines an argument" do
    _, kid = resolver_pair
    pa = doc_type { field :notes, resolver: kid }
    ch = Class.new(pa) { graphql_name "Doc"; field :notes, String, null: true, beta_only: true, override_reason: "the parent's field is as strict" }
    schema = schema_for(on_query(ch))
    served = run(schema, NOTES_INTERNAL)
    rep = report(schema)
    out("bk4", "served: #{served}\n#{summary(rep)}")
    expect(secret?(served) && !flagged?(rep, ".internal")).to eq(false), "served #{served}; #{summary(rep)}"
  end

  it "[security] BK5 a declared field override over a parent field with an unscoped loads: (outside the diff)" do
    target = doc_type(name: "Target")
    pa = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field(:target, target, null: true, authorize: :none, reason: "x", load_through_scope: false) { argument :target_id, GraphQL::Types::ID, loads: target }
    end
    ch = Class.new(pa) do
      graphql_name "Query"
      field(:target, target, null: true, authorize: :none, reason: "x", beta_only: true, override_reason: "same") { argument :target_id, GraphQL::Types::ID, loads: target }
    end
    rep = report(schema_for(ch))
    out("bk5", summary(rep))
    expect(rep.problems.map(&:kind)).to include(:unscoped_load)
  end

  # --- Visibility declared before the roots (no Rails: preload is false, nothing is traversed) ------
  PROFILES = proc { use GraphQL::Schema::Visibility, profiles: { public: { beta: false } } }
  DYNAMIC = proc { use GraphQL::Schema::Visibility, dynamic: true }

  it "[security] VI11d static profiles declared first: a lazy field block's argument beside a resolver's" do
    parent, = resolver_pair(child: false)
    doc = doc_type { field(:notes, resolver: parent) { argument :internal, GraphQL::Types::Boolean, required: false, **STRICT } }
    schema = schema_for(on_query(doc), pre: PROFILES)
    rep = report(schema)
    served = run(schema, NOTES_INTERNAL, visibility_profile: :public)
    rep_after = report(schema)
    out("vi11d", "served: #{served}\nbefore query #{summary(rep)}\nafter query #{summary(rep_after)}")
    expect(secret?(served) && !flagged?(rep, "notes.internal")).to eq(false), "served #{served}; audit before the query: #{summary(rep)}; after: #{summary(rep_after)}"
  end

  it "[security] VI11e static profiles declared first: the same argument twice in a lazy field block" do
    doc = doc_type do
      field(:notes, String, null: true) do
        argument :internal, GraphQL::Types::Boolean, required: false, authorize: :manage, model: Invoice, audience: :beta
        argument :internal, GraphQL::Types::Boolean, required: false, audience: :public
      end
    end
    schema = schema_for(on_query(doc), pre: PROFILES)
    rep = report(schema)
    served = run(schema, NOTES_INTERNAL, visibility_profile: :public)
    out("vi11e", "served: #{served}\n#{summary(rep)}")
    expect(secret?(served) && !flagged?(rep, "notes.internal")).to eq(false), "served #{served}; #{summary(rep)}"
  end

  it "[security] VI11f static profiles declared first: an unscoped loads: inside a lazy field block (outside the diff)" do
    target = doc_type(name: "Target")
    q = query_with do
      field(:target, target, null: true, authorize: :none, reason: "x", load_through_scope: false) { argument :target_id, GraphQL::Types::ID, loads: target }
    end
    rep = report(schema_for(q, pre: proc { use GraphQL::Schema::Visibility, profiles: { public: {} } }))
    out("vi11f", summary(rep))
    expect(rep.problems.map(&:kind)).to include(:unscoped_load)
  end

  it "[security] VI11g dynamic Visibility declared first: an unscoped loads: inside a lazy field block (control)" do
    target = doc_type(name: "Target")
    q = query_with do
      field(:target, target, null: true, authorize: :none, reason: "x", load_through_scope: false) { argument :target_id, GraphQL::Types::ID, loads: target }
    end
    rep = report(schema_for(q, pre: DYNAMIC))
    out("vi11g", summary(rep))
    expect(rep.problems.map(&:kind)).to include(:unscoped_load)
  end

  it "[security] AR8c dynamic Visibility declared first: override_reason: on a plain argument in a lazy block" do
    plain_field = Class.new(GraphQL::Schema::Field) { include GraphQL::Armory::Authorization::Base }
    doc = Class.new(base_object) do
      graphql_name "Doc"
      field_class plain_field
      authorize :read, model: Invoice
      field(:notes, String, null: true) do
        argument :internal, GraphQL::Types::Boolean, required: false
        argument :internal, GraphQL::Types::Boolean, required: false, override_reason: "y"
      end
    end
    schema = schema_for(on_query(doc), pre: DYNAMIC)
    rep = begin
      summary(report(schema))
    rescue StandardError => e
      "audit raised #{e.class}: #{e.message[0, 120]}"
    end
    served = run(schema, NOTES_INTERNAL)
    served2 = run(schema, NOTES_INTERNAL)
    out("ar8c", "audit: #{rep}\nserved: #{served}\nserved again: #{served2}")
    expect(rep).not_to start_with("ok: true")
  end

  it "[security] BK5b runtime: the declared child is scoped, the parent it falls back to is not" do
    account = Account.create!(name: "other")
    invoice = Invoice.create!(account: account, number: "SECRET-1")
    scoped_none = Class.new(by_action) { def scope(_actor, items, _rule) = items.none }.new(%i[read])
    target = doc_type(name: "Target") { field :number, String, null: true }
    pa = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field(:target, target, null: true, authorize: :none, reason: "x", load_through_scope: false) { argument :target_id, GraphQL::Types::ID, loads: target }
      def target(target: nil) = target
    end
    ch = Class.new(pa) do
      graphql_name "Query"
      field(:target, target, null: true, authorize: :none, reason: "x", beta_only: true, override_reason: "same") { argument :target_id, GraphQL::Types::ID, loads: target }
    end
    schema = schema_for(ch, adapter_override: scoped_none, setup: proc { define_singleton_method(:object_from_id) { |id, _c| Invoice.find_by(id: id) } })
    q = %({ target(targetId: "#{invoice.id}") { number } })
    hidden = run(schema, q, root: nil)
    shown_user = run(schema, q, root: nil, beta: true)
    rep = report(schema)
    got = ch.get_field("target", { beta: false })
    dbg = "get_field(Hash) owner: #{got&.owner == pa ? 'parent' : got&.owner.inspect} visible: #{got&.visible?({ beta: false })}"
    out("bk5b", "hidden: #{hidden}\nshown (control): #{shown_user}\n#{dbg}\n#{summary(rep)}")
    expect(secret?(hidden) && !rep.problems.map(&:kind).include?(:unscoped_load)).to eq(false), "hidden #{hidden}; #{summary(rep)}"
  end

  it "[security] BK5c runtime on a non-root type: the declared child is scoped, the parent it falls back to is not" do
    account = Account.create!(name: "other")
    invoice = Invoice.create!(account: account, number: "SECRET-1")
    scoped_none = Class.new(by_action) { def scope(_actor, items, _rule) = items.none }.new(%i[read])
    target = doc_type(name: "Target") { field :number, String, null: true }
    pa = doc_type do
      field(:target, target, null: true, authorize: :none, reason: "x", load_through_scope: false) { argument :target_id, GraphQL::Types::ID, loads: target }
      def target(target: nil) = target
    end
    ch = Class.new(pa) do
      graphql_name "Doc"
      field(:target, target, null: true, authorize: :none, reason: "x", beta_only: true, override_reason: "same") { argument :target_id, GraphQL::Types::ID, loads: target }
    end
    # Target must be reachable some other way, or the warden hides the fallback for its return type.
    qt = query_with do
      field :doc, ch, null: true, authorize: :none, reason: "x"
      field :other, target, null: true, authorize: :none, reason: "x"
    end
    schema = schema_for(qt, adapter_override: scoped_none, setup: proc { define_singleton_method(:object_from_id) { |id, _c| Invoice.find_by(id: id) } })
    q = %({ doc { target(targetId: "#{invoice.id}") { number } } })
    root = Struct.new(:doc).new(Class.new { def target(target: nil) = target }.new)
    hidden = run(schema, q, root: root)
    shown_user = run(schema, q, root: root, beta: true)
    rep = report(schema)
    out("bk5c", "hidden: #{hidden}\nshown (control): #{shown_user}\n#{summary(rep)}")
    expect(secret?(hidden) && !rep.problems.map(&:kind).include?(:unscoped_load)).to eq(false), "hidden #{hidden}; #{summary(rep)}"
  end

  # --- Noise on an ordinary schema ----------------------------------------------------------------
  def template_schema(setup)
    armory = GraphQL::Armory::Authorization
    ac = Class.new(GraphQL::Schema::Argument) { include armory::Base }
    fc = Class.new(GraphQL::Schema::Field) { include armory::Base; argument_class ac }
    base_obj = Class.new(GraphQL::Schema::Object) { include armory::Base; field_class fc; default_action :read }
    base_in = Class.new(GraphQL::Schema::InputObject) { include armory::Base; argument_class ac }
    node = GraphQL::Types::Relay::Node
    base_edge = Class.new(base_obj) { include GraphQL::Types::Relay::EdgeBehaviors; authorize :none, reason: "edge", covers_fields: true }
    base_conn = Class.new(base_obj) { include GraphQL::Types::Relay::ConnectionBehaviors; authorize :none, reason: "conn", covers_fields: true; edge_type_class(base_edge) if respond_to?(:edge_type_class) }
    doc = Class.new(base_obj) do
      graphql_name "Doc"
      authorize :read, model: Invoice
      implements node
      global_id_field :id, override_reason: "Node's id answers the same"
      field :title, String, null: true
      edge_type_class base_edge
      connection_type_class base_conn
    end
    filter = Class.new(base_in) { graphql_name "DocFilter"; argument :title, String, required: false }
    base_mut = Class.new(GraphQL::Schema::RelayClassicMutation) do
      argument_class ac
      field_class fc
      input_object_class base_in
      object_class base_obj
      graphql_name "BaseMutation"
    end
    create = Class.new(base_mut) do
      graphql_name "CreateDoc"
      authorize :none, reason: "x" if respond_to?(:authorize)
      argument :title, String, required: true
      field :doc, doc, null: true
      field :errors, [String], null: false
    end
    mut = Class.new(base_obj) { graphql_name "Mutation"; authorize :none, reason: "root", covers_fields: true; field :create_doc, mutation: create }
    q = Class.new(base_obj) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      include GraphQL::Types::Relay::HasNodeField
      field :docs, doc.connection_type, null: false do
        argument :filter, filter, required: false
      end
    end
    plug = armory
    a = adapter
    Class.new(ArmoryEngine.base_schema) do
      use plug, adapter: a
      query q
      mutation mut
      orphan_types doc
      define_singleton_method(:resolve_type) { |_t, _o, _c| doc }
      define_singleton_method(:object_from_id) { |_i, _c| nil }
      define_singleton_method(:id_from_object) { |_o, _t, _c| "x" }
      class_eval(&setup) if setup
    end
  end

  [["none", nil], ["dynamic", proc { use GraphQL::Schema::Visibility, dynamic: true }]].each do |label, setup|
    it "[preservation] NO1 install-template schema, Visibility #{label}: report text (compared A vs B outside)" do
      text = begin
        report(template_schema(setup)).to_s
      rescue StandardError => e
        "raised #{e.class}: #{e.message}"
      end
      out("no1_#{label}", text)
      expect(text).not_to start_with("raised")
    end
  end
end
