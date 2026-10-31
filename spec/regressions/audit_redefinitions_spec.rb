# frozen_string_literal: true

require "fileutils"

# Recheck of the "every redefinition is reported" round. Written from the diff; run per configuration.
RSpec.describe "final round: redefinitions" do
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

  def iface(name, **opts)
    bf = flagged
    Module.new do
      include GraphQL::Schema::Interface
      graphql_name name
      field_class bf
      field :notes, String, null: true, **opts
    end
  end

  def report(schema) = GraphQL::Armory::Authorization::Audit.(schema)
  def ignored(rep) = rep.problems.select { |pr| pr.kind == :ignored_rule }.map(&:path)

  def out(name, text)
  end

  def root_notes(notes) = Struct.new(:doc).new(Struct.new(:notes).new(notes))

  def run(schema, query, root, **context)
    execute_query(schema, query, root_value: root, context: { current_user: :reader }.merge(context)).to_h
  rescue StandardError => e
    "raised #{e.class}: #{e.message[0, 200]}"
  end

  def secret?(served) = served.is_a?(Hash) && served.to_s.include?("SECRET")

  # Fails only when a refused user gets the data while the audit says nothing about a redefinition.
  def silent_check(schema, name, query: "{ doc { notes } }", root: root_notes("SECRET"), **context)
    served = run(schema, query, root, **context)
    rep = begin
      report(schema)
    rescue StandardError => e
      out(name, "served: #{served.inspect}\naudit raised #{e.class}: #{e.message[0, 200]}")
      return [served, nil]
    end
    out(name, "served: #{served.inspect}\nok: #{rep.ok?}\nproblems: #{rep.problems.map(&:to_s).map { |t| t[0, 120] }}\nbypasses: #{rep.bypasses.map(&:path)}")
    expect(secret?(served) && rep.ok?).to eq(false), "served #{served.inspect} with the audit ok"
    [served, rep]
  end

  # Item 1: the case reports, and a declaration clears it.
  def reports_then_clears(name, plain, declared, path: "Doc.notes")
    rep = report(plain)
    cleared = report(declared)
    out(name, "plain: #{ignored(rep)}\ndeclared: #{ignored(cleared)}\nbypasses: #{cleared.bypasses.map(&:path)}")
    expect(ignored(rep)).to include(path)
    expect(ignored(cleared)).to be_empty
    expect(cleared.bypasses.map(&:path)).to include(path)
  end

  R = { override_reason: "declared" }.freeze

  # --- Item 1 ---------------------------------------------------------------
  it "[security] Y0 two interfaces" do
    build = lambda do |decl|
      open_i = iface("OpenNotes")
      strict_i = iface("StrictNotes", authorize: :manage, beta_only: true, **decl)
      both = Class.new(base_object) do
        graphql_name "Doc"
        authorize :read, model: Invoice
        implements open_i
        implements strict_i
      end
      schema_for(on_query(both))
    end
    reports_then_clears("y0", build.({}), build.(R))
  end

  [true, false].each do |lone_first|
    it "[security] Y#{lone_first ? 1 : 2} two interfaces and a lone implementer, lone first: #{lone_first}" do
      build = lambda do |decl|
        open_i = iface("OpenNotes")
        strict_i = iface("StrictNotes", authorize: :manage, beta_only: true, **decl)
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
        schema_for(q, setup: proc { orphan_types(*order) })
      end
      reports_then_clears("y#{lone_first ? 1 : 2}", build.({}), build.(R))
    end
  end

  it "[security] Y5 superclass plus interface" do
    build = lambda do |decl|
      strict_i = iface("StrictNotes", authorize: :manage, beta_only: true, **decl)
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
      schema_for(on_query(doc), setup: proc { orphan_types(doc, lone) })
    end
    reports_then_clears("y5", build.({}), build.(R))
  end

  it "[security] S2 same authorize: true, child's type is a covering bypass" do
    build = lambda do |decl|
      pa = doc_parent { field :notes, String, null: true, authorize: true }
      ch = child_of(pa) do
        authorize :none, reason: "covers", covers_fields: true
        field :notes, String, null: true, authorize: true, beta_only: true, **decl
      end
      schema_for(on_query(ch))
    end
    reports_then_clears("s2", build.({}), build.(R))
  end

  it "[security] S4 the override's argument has a rule" do
    arg = Class.new(GraphQL::Schema::Argument) { include GraphQL::Armory::Authorization::Base }
    build = lambda do |decl|
      pa = doc_parent { field(:notes, String, null: true) { argument :internal, GraphQL::Types::Boolean, required: false } }
      ch = child_of(pa) do
        field(:notes, String, null: true, beta_only: true, **decl) do
          argument_class arg
          argument :internal, GraphQL::Types::Boolean, required: false, authorize: :manage
        end
      end
      schema_for(on_query(ch))
    end
    reports_then_clears("s4", build.({}), build.(R))
  end

  it "[security] S5 the override's hidden return type has the stricter rule" do
    build = lambda do |decl|
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
      ch = child_of(pa) { field :notes, hidden_t, null: true, **decl }
      schema_for(on_query(ch))
    end
    reports_then_clears("s5", build.({}), build.(R))
  end

  it "[security] S6 the override adds a redacting extension" do
    redact = Class.new(GraphQL::Schema::FieldExtension) { def after_resolve(value:, **) = "REDACTED" }
    build = lambda do |decl|
      pa = doc_parent { field :notes, String, null: true }
      ch = child_of(pa) { field :notes, String, null: true, beta_only: true, extensions: [redact], **decl }
      schema_for(on_query(ch))
    end
    reports_then_clears("s6", build.({}), build.(R))
  end

  it "[security] S7 the override's resolver_method redacts" do
    build = lambda do |decl|
      pa = doc_parent { field :notes, String, null: true }
      ch = child_of(pa) do
        field :notes, String, null: true, beta_only: true, resolver_method: :redacted_notes, **decl
        def redacted_notes = "REDACTED"
      end
      schema_for(on_query(ch))
    end
    reports_then_clears("s7", build.({}), build.(R))
  end

  it "[security] S9 the app's field class with its own authorized?" do
    build = lambda do |decl|
      pa = doc_parent { field :notes, String, null: true }
      strict = Class.new(flagged) { def authorized?(_o, _a, ctx) = ctx[:staff] == true }
      ch = child_of(pa) do
        field_class strict
        field :notes, String, null: true, beta_only: true, **decl
      end
      plug = GraphQL::Armory::Authorization
      a = adapter
      q = on_query(ch)
      Class.new(ArmoryEngine.base_schema) do
        use plug, adapter: a, own_checks: { strict => { authorized?: "checked by staff flag" } }
        query q
      end
    end
    reports_then_clears("s9", build.({}), build.(R))
  end

  it "[security] D1 two definitions on one class: both report, one declared leaves the other" do
    build = lambda do |first, second|
      ch = doc_parent do
        field :notes, String, null: true, authorize: :manage, beta_only: true, **first
        field :notes, String, null: true, **second
      end
      schema_for(on_query(ch))
    end
    plain = ignored(report(build.({}, {})))
    half = ignored(report(build.(R, {})))
    both = ignored(report(build.(R, R)))
    out("d1", "plain: #{plain}\nhalf: #{half}\nboth: #{both}")
    expect(plain.size).to eq(2)
    expect(half.size).to eq(1)
    expect(both).to be_empty
  end

  # --- fall_back_from --------------------------------------------------------
  it "[security] B1 several definitions on the farthest level, a lone one nearest: declaring the nearest leaves both" do
    build = lambda do |decl|
      gp = doc_parent do
        field :notes, String, null: true, authorize: :manage, beta_only: true
        field :notes, String, null: true
      end
      ch = child_of(gp) { field :notes, String, null: true, authorize: :manage, beta_only: true, **decl }
      schema_for(on_query(ch))
    end
    plain = ignored(report(build.({})))
    half = ignored(report(build.(R)))
    out("b1", "plain: #{plain}\nhalf: #{half}")
    expect(plain.size).to eq(3)
    expect(half.size).to eq(2)
  end

  it "[preservation] B2 a lone definition is silent; declaring it is a problem" do
    plain = report(schema_for(on_query(doc_parent { field :notes, String, null: true })))
    declared = report(schema_for(on_query(doc_parent { field :notes, String, null: true, **R })))
    out("b2", "plain: #{ignored(plain)}\ndeclared: #{declared.problems.map(&:to_s)}")
    expect(ignored(plain)).to be_empty
    expect(ignored(declared)).to eq(["Doc.notes"])
  end

  it "[security] B3 three levels: declaring the leaf leaves the middle reported, with its hide served by the top" do
    gp = doc_parent { field :notes, String, null: true }
    pa = Class.new(gp) { field :notes, String, null: true, authorize: :manage, beta_only: true }
    ch = child_of(pa) { field :notes, String, null: true, authorize: :manage, beta_only: true, **R }
    served, rep = silent_check(schema_for(on_query(ch)), "b3")
    expect(secret?(served)).to eq(true)
    expect(ignored(rep)).to eq(["Doc.notes"])
  end

  it "[security] B3b a same-level pair on the farthest level of one type, nearest of another" do
    gp = Class.new(base_object) do
      authorize :read, model: Invoice
      field :notes, String, null: true, **R
    end
    a = Class.new(gp) { graphql_name "Doc" }
    b = Class.new(gp) do
      graphql_name "Other"
      field :notes, String, null: true, authorize: :manage, beta_only: true
    end
    q = query_with do
      field :doc, a, null: true, authorize: :none, reason: "x"
      field :other, b, null: true, authorize: :none, reason: "x"
    end
    rep = report(schema_for(q))
    out("b3b", rep.problems.map(&:to_s).inspect)
    expect(ignored(rep)).to include("Other.notes")
    expect(rep.problems.map(&:to_s).join).to include("nothing falls back") # reported at the first path that reaches it
  end

  # --- a module that is not an interface ---------------------------------------
  it "[security] M1 a plain module with HasFields included in the object: the fallback runs and the audit reports it" do
    bf = flagged
    mod = Module.new do
      extend GraphQL::Schema::Member::HasFields
      define_singleton_method(:field_class) { |*| bf }
      field :notes, String, null: true
    end
    ch = doc_parent do
      field :notes, String, null: true, authorize: :manage, beta_only: true
    end
    ch.include(mod)
    served, rep = silent_check(schema_for(on_query(ch)), "m1")
    out("m1b", "#{served}\n#{rep&.problems&.map(&:path)}")
    expect(ignored(rep)).to include("Doc.notes")
  end

  it "[security] M2 a module that includes an interface, included without implements" do
    i = iface("OpenNotes")
    mod = Module.new { include i }
    ch = begin
      doc_parent do
        include mod
        field :notes, String, null: true, authorize: :manage, beta_only: true
      end
    rescue StandardError => e
      out("m2", "definition raised #{e.class}: #{e.message[0, 200]}")
      next
    end
    served, rep = silent_check(schema_for(on_query(ch)), "m2")
    expect(ignored(rep)).not_to be_empty if secret?(served)
  end

  it "[security] M3 a module prepended to the object with a stricter field" do
    bf = flagged
    mod = Module.new do
      extend GraphQL::Schema::Member::HasFields
      define_singleton_method(:field_class) { |*| bf }
      field :notes, String, null: true, authorize: :manage, beta_only: true
    end
    ch = doc_parent { field :notes, String, null: true }
    ch.prepend(mod)
    served, rep = silent_check(schema_for(on_query(ch)), "m3")
    expect(ignored(rep)).not_to be_empty if secret?(served)
  end

  it "[security] M4 an interface inherited by another interface" do
    base_i = iface("OpenNotes")
    bf = flagged
    child_i = Module.new do
      include GraphQL::Schema::Interface
      include base_i
      graphql_name "StrictNotes"
      field_class bf
      field :notes, String, null: true, authorize: :manage, beta_only: true
    end
    ch = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: Invoice
      implements child_i
    end
    served, rep = silent_check(schema_for(on_query(ch)), "m4")
    expect(ignored(rep)).not_to be_empty if secret?(served)
  end

  # --- shared overrides and declarations ---------------------------------------
  it "[security] P1 two types share an inherited override: declared once on the parent, a third adds its own" do
    gp = Class.new(base_object) do
      authorize :read, model: Invoice
      field :notes, String, null: true
    end
    pa = Class.new(gp) { field :notes, String, null: true, authorize: :manage, **R }
    one = Class.new(pa) { graphql_name "One" }
    two = Class.new(pa) { graphql_name "Two" }
    three = Class.new(pa) do
      graphql_name "Three"
      field :notes, String, null: true, authorize: :admin, beta_only: true
    end
    q = query_with do
      field :one, one, null: true, authorize: :none, reason: "x"
      field :two, two, null: true, authorize: :none, reason: "x"
      field :three, three, null: true, authorize: :none, reason: "x"
    end
    rep = report(schema_for(q))
    out("p1", "ignored: #{ignored(rep)}\nbypasses: #{rep.bypasses.map(&:path)}")
    expect(ignored(rep)).to eq(["Three.notes"])
  end

  it "[security] P2 a declaration on a same-named field of an unrelated type clears nothing" do
    other = Class.new(base_object) do
      graphql_name "Other"
      authorize :read, model: Invoice
      field :notes, String, null: true
    end
    other_ch = Class.new(other) do
      graphql_name "OtherChild"
      field :notes, String, null: true, **R
    end
    pa = doc_parent { field :notes, String, null: true }
    ch = child_of(pa) { field :notes, String, null: true, authorize: :manage, beta_only: true }
    q = query_with do
      field :doc, ch, null: true, authorize: :none, reason: "x"
      field :other, other_ch, null: true, authorize: :none, reason: "x"
    end
    rep = report(schema_for(q))
    out("p2", ignored(rep).inspect)
    expect(ignored(rep)).to eq(["Doc.notes"])
  end

  it "[security] P3 one field object added to two types, overriding on only one" do
    source = Class.new(base_object) do
      graphql_name "Source"
      authorize :read, model: Invoice
      field :notes, String, null: true, authorize: :manage, beta_only: true
    end
    shared = source.own_fields["notes"]
    pa = doc_parent { field :notes, String, null: true }
    ch = child_of(pa) { add_field(shared) }
    q = query_with do
      field :doc, ch, null: true, authorize: :none, reason: "x"
      field :source, source, null: true, authorize: :none, reason: "x"
    end
    served, rep = silent_check(schema_for(q), "p3")
    expect(ignored(rep)).not_to be_empty if secret?(served)
  end

  it "[security] P4 a child class adds a definition next to an inherited, declared one" do
    pa = doc_parent { field :notes, String, null: true, **R }
    ch = child_of(pa) { field :notes, String, null: true, authorize: :manage, beta_only: true }
    served, rep = silent_check(schema_for(on_query(ch)), "p4")
    expect(ignored(rep)).not_to be_empty if secret?(served)
  end

  # --- rescue GraphQL::Error ---------------------------------------------------

  it "[preservation] E2 the fallback's type cannot load: an error, never data" do
    pa = doc_parent { field :notes, "ProbeMissing::Nope", null: true }
    ch = child_of(pa) { field :notes, String, null: true, beta_only: true }
    schema = schema_for(on_query(ch))
    served = run(schema, "{ doc { notes } }", root_notes("SECRET"))
    out("e2", served.inspect)
    expect(secret?(served)).to eq(false)
  end

  it "[preservation] E3 a current field whose type cannot load still raises at the audit" do
    pa = doc_parent { field :notes, String, null: true }
    ch = child_of(pa) { field :notes, "ProbeMissing::Nope", null: true }
    audit = begin
      report(schema_for(on_query(ch))).problems.map(&:to_s)
    rescue GraphQL::Error => e
      "raised #{e.class}"
    rescue StandardError => e
      "raised other #{e.class}: #{e.message[0, 100]}"
    end
    out("e3", audit.inspect)
    expect(audit).to start_with("raised")
  end

  it "[preservation] E4 a current argument whose type cannot load still raises at the audit" do
    ch = doc_parent do
      field :notes, String, null: true do
        argument :filter, "ProbeMissing::Nope", required: false
      end
    end
    audit = begin
      report(schema_for(on_query(ch))).problems.map(&:to_s)
    rescue StandardError => e
      "raised #{e.class}"
    end
    out("e4", audit.inspect)
    expect(audit).to start_with("raised")
  end

  it "[security] E5 a NameError that is not a missing type, inside an overridden field's block" do
    pa = doc_parent do
      field :notes, String, null: true do
        raise GraphQL::Armory::Authorization::ConfigurationError, "real configuration error" if respond_to?(:argument)
      end
    end
    ch = child_of(pa) { field :notes, String, null: true }
    audit = begin
      report(schema_for(on_query(ch))).problems.map(&:path)
    rescue StandardError => e
      "raised #{e.class}: #{e.message[0, 100]}"
    end
    out("e5", audit.inspect)
  end

  # --- the introspection filter ------------------------------------------------

  # --- schema.visibility as the "no fallback" switch -----------------------------
  def stricter_over_open
    pa = doc_parent { field :notes, String, null: true }
    child_of(pa) { field :notes, String, null: true, authorize: :manage, beta_only: true }
  end

  it "[preservation] V0 control: dynamic Visibility, no fallback, audit quiet" do
    served, rep = silent_check(schema_for(on_query(stricter_over_open), setup: proc { use GraphQL::Schema::Visibility, dynamic: true }), "v0")
    expect(secret?(served)).to eq(false)
    expect(ignored(rep)).to be_empty
  end

  it "[security] V1 dynamic plus a static profile: the request names the profile" do
    schema = schema_for(on_query(stricter_over_open), setup: proc { use GraphQL::Schema::Visibility, dynamic: true, profiles: { public: { beta: false } } })
    silent_check(schema, "v1", visibility_profile: :public)
  end

  it "[security] V1b the same hidden by visible_when: on the override" do
    pa = doc_parent { field :notes, String, null: true }
    ch = child_of(pa) { field :notes, String, null: true, authorize: :manage, visible_when: :manage }
    plug_setup = proc { use GraphQL::Schema::Visibility, dynamic: true, profiles: { public: {} } }
    silent_check(schema_for(on_query(ch), setup: plug_setup), "v1b", visibility_profile: :public)
  end

  it "[security] V1c static profiles alone, a request with its profile, and what the audit does" do
    schema = schema_for(on_query(stricter_over_open), setup: proc { use GraphQL::Schema::Visibility, profiles: { public: { beta: false } } })
    silent_check(schema, "v1c", visibility_profile: :public)
  end

  it "[security] V1d a static profile's fallback across an interface" do
    open_i = iface("OpenNotes")
    ch = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: Invoice
      implements open_i
      field :notes, String, null: true, authorize: :manage, beta_only: true
    end
    schema = schema_for(on_query(ch), setup: proc { use GraphQL::Schema::Visibility, dynamic: true, profiles: { public: { beta: false } } })
    silent_check(schema, "v1d", visibility_profile: :public)
  end


  it "[security] V3 a child schema turns the profile off: use_visibility_profile = false" do
    parent = schema_for(on_query(stricter_over_open), setup: proc { use GraphQL::Schema::Visibility, dynamic: true })
    child = Class.new(parent) { self.use_visibility_profile = false }
    served = run(child, "{ doc { notes } }", root_notes("SECRET"))
    rep = report(child)
    out("v3", "visibility: #{!child.visibility.nil?}\nserved: #{served}\nok: #{rep.ok?}\nignored: #{ignored(rep)}")
    expect(secret?(served) && rep.ok?).to eq(false), "served #{served} with the audit ok"
  end

  it "[security] V4 migration_errors: what runs while migrating" do
    schema = schema_for(on_query(stricter_over_open), setup: proc { use GraphQL::Schema::Visibility, dynamic: true, migration_errors: true })
    silent_check(schema, "v4")
    silent_check(schema, "v4_skip", skip_visibility_migration_error: true)
  end

  it "[preservation] V5 Visibility on the parent schema, the child inherits it" do
    parent = schema_for(on_query(stricter_over_open), setup: proc { use GraphQL::Schema::Visibility, dynamic: true })
    child = Class.new(parent)
    served, rep = silent_check(child, "v5")
    out("v5b", "child visibility: #{child.visibility.class}")
    expect(secret?(served)).to eq(false)
    expect(ignored(rep)).to be_empty
  end

  it "[security] V6 Visibility on a child only: the parent still falls back and still reports" do
    parent = schema_for(on_query(stricter_over_open))
    child = Class.new(parent) { use GraphQL::Schema::Visibility, dynamic: true }
    served, rep = silent_check(parent, "v6_parent")
    served_child, rep_child = silent_check(child, "v6_child")
    expect(secret?(served)).to eq(true)
    expect(ignored(rep)).to eq(["Doc.notes"])
    expect(secret?(served_child)).to eq(false)
    expect(ignored(rep_child)).to be_empty
  end

  it "[security] W1 use GraphQL::Schema::Warden: falls back and reports" do
    served, rep = silent_check(schema_for(on_query(stricter_over_open), setup: proc { use GraphQL::Schema::Warden }), "w1")
    expect(secret?(served)).to eq(true)
    expect(ignored(rep)).to eq(["Doc.notes"])
  end

  it "[security] W2 Visibility on the parent, Warden on the child" do
    parent = schema_for(on_query(stricter_over_open), setup: proc { use GraphQL::Schema::Visibility, dynamic: true })
    child = Class.new(parent) { use GraphQL::Schema::Warden }
    silent_check(child, "w2")
  end

  # --- global_id_field -----------------------------------------------------------
  it "[preservation] G1 global_id_field :id, override_reason: on a Base type over a Base Node, audit and query" do
    bf = flagged
    node = Module.new do
      include GraphQL::Schema::Interface
      field_class bf
      include GraphQL::Types::Relay::NodeBehaviors
      graphql_name "Node"
    end
    build = lambda do |decl|
      Class.new(base_object) do
        graphql_name "Doc"
        authorize :read, model: Invoice
        implements node
        global_id_field :id, **decl
      end
    end
    id_setup = proc { define_singleton_method(:id_from_object) { |_o, _t, _c| "the-id" } }
    plain = report(schema_for(on_query(build.({})), setup: id_setup))
    schema = schema_for(on_query(build.(override_reason: "Node's id answers the same")), setup: id_setup)
    declared = report(schema)
    served = run(schema, "{ doc { id } }", Struct.new(:doc).new(Object.new))
    out("g1", "plain: #{ignored(plain)}\ndeclared: #{ignored(declared)}\nbypasses: #{declared.bypasses.map(&:to_s)}\nserved: #{served}")
    expect(ignored(plain)).to eq(["Doc.id"])
    expect(ignored(declared)).to be_empty
    expect(served.dig("data", "doc", "id")).to eq("the-id")
  end

  it "[preservation] G2 the same over the built-in Relay Node" do
    build = lambda do |decl|
      Class.new(base_object) do
        graphql_name "Doc"
        authorize :read, model: Invoice
        implements GraphQL::Types::Relay::Node
        global_id_field :id, **decl
      end
    end
    id_setup = proc { define_singleton_method(:id_from_object) { |_o, _t, _c| "the-id" } }
    plain = report(schema_for(on_query(build.({})), setup: id_setup))
    declared = report(schema_for(on_query(build.(override_reason: "same")), setup: id_setup))
    out("g2", "plain: #{ignored(plain)}\ndeclared: #{ignored(declared)}")
    expect(ignored(plain)).to eq(["Doc.id"])
    expect(ignored(declared)).to be_empty
  end

  it "[preservation] G3 on a field class without Base: refused, not ignored" do
    expect do
      Class.new(GraphQL::Schema::Object) do
        graphql_name "Doc"
        global_id_field :id, override_reason: "x"
      end
    end.to raise_error(ArgumentError)
  end

  # --- outside fields: an input object's redefined argument --------------------
  it "[security] A1 an input object's subclass redefines an argument with a rule, hidden: falls back to the parent's" do
    arg = Class.new(GraphQL::Schema::Argument) do
      include GraphQL::Armory::Authorization::Base
      def initialize(*args, beta_only: false, **kwargs, &block)
        @beta_only = beta_only
        super(*args, **kwargs, &block)
      end

      def visible?(context) = super && (!@beta_only || context[:beta] == true)
    end
    parent_in = Class.new(GraphQL::Schema::InputObject) do
      include GraphQL::Armory::Authorization::Base
      argument_class arg
      graphql_name "Filter"
      argument :internal, GraphQL::Types::Boolean, required: false
    end
    child_in = Class.new(parent_in) do
      graphql_name "Filter"
      argument :internal, GraphQL::Types::Boolean, required: false, authorize: :manage, beta_only: true
    end
    ch = doc_parent do
      field :notes, String, null: true do
        argument :filter, child_in, required: false
      end
    end
    root = Struct.new(:doc).new(Class.new { def notes(filter: nil) = filter&.internal ? "SECRET" : "plain" }.new)
    served, rep = silent_check(schema_for(on_query(ch)), "a1", query: "{ doc { notes(filter: { internal: true }) } }", root: root)
    visible = run(schema_for(on_query(ch)), "{ doc { notes(filter: { internal: true }) } }", root, beta: true)
    out("a1b", "hidden: #{served}\nvisible (control): #{visible}\nok: #{rep&.ok?}")
    expect(secret?(served) && rep.ok?).to eq(false)
  end

  # --- second batch, after reading the first results ------------------------------
  it "[preservation] V1e control: the same user and profile, field shown: refused by the rule" do
    schema = schema_for(on_query(stricter_over_open), setup: proc { use GraphQL::Schema::Visibility, dynamic: true, profiles: { staff: { beta: true } } })
    served = run(schema, "{ doc { notes } }", root_notes("SECRET"), visibility_profile: :staff)
    out("v1e", served.inspect)
    expect(secret?(served)).to eq(false)
  end

  it "[preservation] V1f cause: get_field with a profile's Hash context walks past a hidden field" do
    type = stricter_over_open
    schema = schema_for(on_query(type), setup: proc { use GraphQL::Schema::Visibility, dynamic: true, profiles: { public: { beta: false } } })
    profile = schema.visibility.profile_for({ visibility_profile: :public })
    hash_rule = type.get_field("notes", { beta: false })&.armory_declared.inspect
    profile_context_class = profile.instance_variable_get(:@context).class
    profile_rule = profile.field(type, "notes")&.armory_declared.inspect
    out("v1f", "profile context: #{profile_context_class}\nget_field(Hash) declared: #{hash_rule}\nprofile.field declared: #{profile_rule}")
    expect(profile_context_class).to eq(Hash)
    expect(profile_rule).to eq("nil") # nil = the parent's field, which declares no rule; :manage = the override
  end

  it "[security] A2 the input argument control: shown, the rule refuses; under dynamic Visibility nothing falls back" do
    arg = Class.new(GraphQL::Schema::Argument) do
      include GraphQL::Armory::Authorization::Base
      def initialize(*args, beta_only: false, **kwargs, &block)
        @beta_only = beta_only
        super(*args, **kwargs, &block)
      end

      def visible?(context) = super && (!@beta_only || context[:beta] == true)
    end
    parent_in = Class.new(GraphQL::Schema::InputObject) do
      include GraphQL::Armory::Authorization::Base
      argument_class arg
      graphql_name "Filter"
      argument :internal, GraphQL::Types::Boolean, required: false
    end
    child_in = Class.new(parent_in) do
      graphql_name "Filter"
      argument :internal, GraphQL::Types::Boolean, required: false, authorize: :manage, beta_only: true
    end
    ch = doc_parent do
      field :notes, String, null: true do
        argument :filter, child_in, required: false
      end
    end
    root = Struct.new(:doc).new(Class.new { def notes(filter: nil) = filter&.internal ? "SECRET" : "plain" }.new)
    q = "{ doc { notes(filter: { internal: true }) } }"
    shown = run(schema_for(on_query(ch)), q, root, beta: true)
    under_vis = run(schema_for(on_query(ch), setup: proc { use GraphQL::Schema::Visibility, dynamic: true }), q, root)
    out("a2", "shown: #{shown}\nunder Visibility: #{under_vis}")
    expect(secret?(shown)).to eq(false)
    expect(secret?(under_vis)).to eq(false)
  end

  it "[security] E6 an overridden field's lazy block: are the types its arguments reach walked?" do
    secret_t = Class.new(GraphQL::Schema::Object) do
      graphql_name "OnlyViaOverriddenArg"
      field :body, String, null: true
    end
    input_t = Class.new(GraphQL::Schema::InputObject) do
      graphql_name "OnlyViaOverriddenInput"
      argument :x, String, required: false
    end
    pa = doc_parent do
      field :notes, String, null: true do
        argument :target_id, GraphQL::Types::ID, required: false, loads: secret_t
        argument :filter, input_t, required: false
      end
    end
    ch = child_of(pa) { field :notes, String, null: true, beta_only: true, override_reason: "declared" }
    schema = schema_for(on_query(ch), setup: proc { define_singleton_method(:object_from_id) { |_i, _c| Object.new } })
    names = GraphQL::Armory::Authorization::Definitions.(schema).map(&:graphql_name)
    rep = report(schema)
    field = pa.own_fields["notes"]
    served = run(schema, %({ doc { notes(targetId: "1") } }), root_notes("SECRET"))
    out("e6", "walked object: #{names.include?('OnlyViaOverriddenArg')}\nwalked input: #{names.include?('OnlyViaOverriddenInput')}\nargs: #{field.all_argument_definitions.map(&:graphql_name)}\nserved: #{served}\nok: #{rep.ok?}\nproblems: #{rep.problems.map(&:to_s)}")
    expect(names).to include("OnlyViaOverriddenArg", "OnlyViaOverriddenInput")
  end
end
