# frozen_string_literal: true

require "fileutils"

# Recheck probes for PR #12, correction batch (6278bbe): duplicates under dynamic Visibility, block loading in
# Definitions.fields_at_every_level, and shadowed field definitions going through audit_fields.
RSpec.describe "PR12 recheck probes" do
  armory = GraphQL::Armory::Authorization

  by_action = Class.new(armory::Adapters::Substitute) do
    def initialize(allowed)
      super()
      @allowed = allowed
    end

    def authorized?(_actor, _subject, rule) = @allowed.include?(rule.action)
  end

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

  STRICT_R = { authorize: :manage, beta_only: true }.freeze
  DECL_R = { override_reason: "declared" }.freeze
  DYN = proc { use GraphQL::Schema::Visibility, dynamic: true }

  def schema_for(query_class, setup: nil, pre: nil, adapter_override: nil)
    plug = GraphQL::Armory::Authorization
    a = adapter_override || adapter
    Class.new(ArmoryEngine.base_schema) do
      use plug, adapter: a
      class_eval(&pre) if pre
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

  # An abstract parent: never referenced by the schema, so only its subclasses are types.
  def abstract_parent(&block) = Class.new(base_object) { class_eval(&block) if block }

  def doc_type(parent = base_object, name: "Doc", &block)
    Class.new(parent) do
      graphql_name name
      authorize :read, model: Invoice
      class_eval(&block) if block
    end
  end

  def report(schema) = GraphQL::Armory::Authorization::Audit.(schema)
  def kinds(rep) = rep.problems.map { |pr| "#{pr.kind} #{pr.path}" }
  def summary(rep) = "ok: #{rep.ok?}\nproblems: #{kinds(rep)}\nbypasses: #{rep.bypasses.map(&:path)}"

  def audit_text(schema)
    summary(report(schema))
  rescue StandardError => e
    "audit raised #{e.class}: #{e.message[0, 200]}"
  end

  def out(name, text)
  end

  def run(schema, query, root:, **context)
    execute_query(schema, query, root_value: root, context: context).to_h
  rescue StandardError => e
    "raised #{e.class}: #{e.message[0, 160]}"
  end

  def secret?(served) = served.is_a?(Hash) && served.to_s.include?("SECRET")
  def notes_root = Struct.new(:doc).new(Class.new { def notes(internal: false) = internal ? "SECRET" : "plain" }.new)
  def secret_root = Struct.new(:doc).new(Struct.new(:notes).new("SECRET"))

  it "[preservation] ENV records the graphql version" do
    out("env", "GraphQL::VERSION=#{GraphQL::VERSION} engine=#{ArmoryEngine.current}")
    expect(GraphQL::VERSION).to be_a(String)
  end

  # --- 3: shadowed fields and the rescue ----------------------------------------------------------
  # An adapter whose `check` raises a GraphQL::Error (ConfigurationError) for one action.
  let(:raising_adapter) do
    Class.new(by_action) do
      def check(_type, rule)
        raise GraphQL::Armory::Authorization::ConfigurationError, "boom is not configured" if rule.action == :boom

        []
      end
    end.new(%i[read])
  end

  it "[preservation] SH1a a non-shadowed field whose check raises: the audit raises" do
    target = doc_type(name: "Target")
    doc = doc_type { field(:notes, target, null: true, authorize: :boom, load_through_scope: false) { argument :target_id, GraphQL::Types::ID, loads: target } }
    text = audit_text(schema_for(on_query(doc), adapter_override: raising_adapter))
    out("sh1a", text)
    expect(text).to start_with("audit raised")
  end

  it "[security] SH1b a shadowed field whose check raises: not swallowed, and its unscoped loads: still reported" do
    target = doc_type(name: "Target")
    parent = abstract_parent { field(:notes, target, null: true, authorize: :boom, load_through_scope: false) { argument :target_id, GraphQL::Types::ID, loads: target } }
    doc = doc_type(parent) { field(:notes, target, null: true, **DECL_R) { argument :target_id, GraphQL::Types::ID, loads: target } }
    text = audit_text(schema_for(on_query(doc), adapter_override: raising_adapter))
    out("sh1b", text)
    expect(text.start_with?("audit raised") || text.include?("unscoped_load Doc.notes(target_id)")).to eq(true), text
  end

  it "[preservation] SH2 visible_when: on a type with no model, shadowed and not: no raise, :model reported" do
    ghost_plain = Class.new(base_object) { graphql_name "NoSuchModelXyz"; authorize :read; field :notes, String, null: true, visible_when: :export }
    parent = abstract_parent { field :notes, String, null: true, visible_when: :export }
    ghost_shadow = Class.new(parent) { graphql_name "NoSuchModelXyz"; authorize :read; field :notes, String, null: true, **DECL_R }
    a = audit_text(schema_for(on_query(ghost_plain)))
    b = audit_text(schema_for(on_query(ghost_shadow)))
    out("sh2", "plain: #{a}\nshadowed: #{b}")
    expect([a, b]).to all(include("model NoSuchModelXyz"))
    expect([a, b]).to all(satisfy { |t| !t.start_with?("audit raised") })
  end

  it "[preservation] SH3 a resolver with no model: reported on the shadowed definition with the child's path" do
    res = Class.new(GraphQL::Schema::Resolver) do
      include GraphQL::Armory::Authorization::Base
      graphql_name "NoModel"
      type String, null: true
      authorize :manage
      def resolve = "SECRET"
    end
    parent = abstract_parent { field :notes, resolver: res }
    doc = doc_type(parent) { field :notes, String, null: true, **STRICT_R, **DECL_R }
    text = audit_text(schema_for(on_query(doc)))
    out("sh3", text)
    expect(text).to include("model Doc.notes")
  end

  it "[preservation] SH4 a shadowed field whose return type cannot load is skipped; a live one raises" do
    parent = abstract_parent { field :notes, "MissingNotesType", null: true }
    doc = doc_type(parent) { field :notes, String, null: true, **DECL_R }
    shadowed = audit_text(schema_for(on_query(doc), pre: DYN))
    live_doc = doc_type { field :notes, "MissingNotesType", null: true }
    live = begin
      audit_text(schema_for(on_query(live_doc), pre: DYN))
    rescue StandardError => e
      "schema raised #{e.class}"
    end
    out("sh4", "shadowed: #{shadowed}\nlive: #{live}")
    expect(shadowed).not_to start_with("audit raised")
    expect(live).to match(/raised/)
  end

  # --- 3: own checks of a shadowed definition ------------------------------------------------------
  it "[security] OC1 a shadowed resolver's own authorized? (returns true): a hidden user gets SECRET; is it reported?" do
    open = Class.new(GraphQL::Schema::Resolver) do
      include GraphQL::Armory::Authorization::Base
      graphql_name "OpenNotes"
      type String, null: true
      authorize :manage, model: Invoice
      def authorized?(**) = true
      def resolve = "SECRET"
    end
    parent = abstract_parent { field :notes, resolver: open }
    doc = doc_type(parent) { field :notes, String, null: true, **STRICT_R, **DECL_R }
    schema = schema_for(on_query(doc))
    served = run(schema, "{ doc { notes } }", root: secret_root)
    rep = report(schema)
    out("oc1", "served: #{served}\n#{summary(rep)}")
    own = rep.problems.any? { |pr| pr.kind == :own_check }
    expect(secret?(served) && !own).to eq(false), "served #{served}; #{summary(rep)}"
  end

  it "[security] OC2 a shadowed field whose field class answers authorized? true" do
    fc = field_class
    open_fc = Class.new(fc) { def authorized?(*) = true }
    parent = Class.new(base_object) { field_class open_fc; field :notes, String, null: true, authorize: :manage }
    doc = doc_type(parent) { field_class fc; field :notes, String, null: true, **STRICT_R, **DECL_R }
    schema = schema_for(on_query(doc))
    served = run(schema, "{ doc { notes } }", root: secret_root)
    rep = report(schema)
    out("oc2", "served: #{served}\n#{summary(rep)}")
    own = rep.problems.any? { |pr| pr.kind == :own_check }
    expect(secret?(served) && !own).to eq(false), "served #{served}; #{summary(rep)}"
  end

  # --- 2: ensure_loaded run by the audit, then by a request ---------------------------------------
  def counting_extension
    Class.new(GraphQL::Schema::FieldExtension) do
      class << self
        attr_accessor :applied, :defined
      end
      self.applied = 0
      self.defined = 0
      def apply = self.class.applied += 1
      def after_define = self.class.defined += 1
    end
  end

  [["legacy", nil], ["dynamic first", proc { use GraphQL::Schema::Visibility, dynamic: true }]].each do |label, pre|
    it "[preservation] EL1 #{label}: a block loaded by the audit and then by requests runs once" do
      ext = counting_extension
      doc = doc_type do
        field(:notes, String, null: true) do
          argument :internal, GraphQL::Types::Boolean, required: false
          extension ext
        end
        def notes(internal: false) = internal ? "SECRET" : "plain"
      end
      schema = schema_for(on_query(doc), pre: pre)
      first = audit_text(schema)
      served = run(schema, "{ doc { notes(internal: false) } }", root: notes_root)
      second = audit_text(schema)
      field = doc.own_fields["notes"]
      args = field.own_arguments.values.flatten.size
      out("el1_#{label.tr(' ', '_')}", "applied: #{ext.applied} defined: #{ext.defined} args: #{args}\nserved: #{served}\nfirst: #{first}\nsecond: #{second}")
      expect([ext.applied, ext.defined, args]).to eq([1, 1, 1])
      expect(first).to eq(second)
      expect(served.to_s).not_to include("raised")
    end
  end

  it "[preservation] EL2 a shadowed field loaded by the audit, then served on fallback: its block ran once" do
    ext = counting_extension
    parent = abstract_parent do
      field(:notes, String, null: true) do
        argument :internal, GraphQL::Types::Boolean, required: false
        extension ext
      end
    end
    doc = doc_type(parent) { field :notes, String, null: true, **STRICT_R, **DECL_R }
    schema = schema_for(on_query(doc))
    before = ext.defined
    text = audit_text(schema)
    after_audit = ext.defined
    served = run(schema, "{ doc { notes } }", root: secret_root)
    out("el2", "before audit: #{before} after audit: #{after_audit} after request: #{ext.defined} applied: #{ext.applied}\nargs: #{parent.own_fields['notes'].own_arguments.size}\nserved: #{served}\n#{text}")
    expect([after_audit, ext.defined, ext.applied]).to eq([1, 1, 1])
  end

  it "[preservation] EL3 a shadowed field whose block raises: the audit fails loudly (compare with main)" do
    parent = abstract_parent { field(:notes, String, null: true) { raise "block of the shadowed notes failed" } }
    doc = doc_type(parent) { field :notes, String, null: true, **DECL_R }
    schema = schema_for(on_query(doc))
    served = run(schema, "{ doc { notes } }", root: secret_root, beta: true)
    text = audit_text(schema)
    out("el3", "served (override visible): #{served}\naudit: #{text}")
    expect(served.to_s).to include("SECRET")
    expect(text).to include("block of the shadowed notes failed")
  end

  # --- 2: blocks on interface fields and resolver-provided fields ---------------------------------
  it "[security] IF1 dynamic first: an argument twice in an interface field's block is reported" do
    iface = Module.new do
      include GraphQL::Schema::Interface
    end
    fc = field_class
    iface.module_eval do
      graphql_name "Noted"
      field_class fc
      field(:notes, String, null: true) do
        argument :internal, GraphQL::Types::Boolean, required: false, authorize: :manage, model: Invoice, audience: :beta
        argument :internal, GraphQL::Types::Boolean, required: false, audience: :public
      end
    end
    doc = doc_type { implements iface; def notes(internal: false) = internal ? "SECRET" : "plain" }
    schema = schema_for(on_query(doc), pre: DYN)
    served = run(schema, "{ doc { notes(internal: true) } }", root: notes_root)
    rep = report(schema)
    out("if1", "served: #{served}\n#{summary(rep)}")
    expect(kinds(rep).any? { |k| k.start_with?("ignored_rule") && k.end_with?("notes.internal") }).to eq(true), summary(rep)
  end

  it "[preservation] IF2 an interface field redefined on the implementer: shadowed there, path is the implementer's" do
    iface = Module.new { include GraphQL::Schema::Interface }
    fc = field_class
    target = doc_type(name: "Target")
    iface.module_eval do
      graphql_name "Noted"
      field_class fc
      field(:notes, target, null: true, load_through_scope: false) { argument :target_id, GraphQL::Types::ID, loads: target }
    end
    doc = doc_type { implements iface; field(:notes, target, null: true, **DECL_R) { argument :target_id, GraphQL::Types::ID, loads: target } }
    schema = schema_for(on_query(doc))
    rep = report(schema)
    levels = GraphQL::Armory::Authorization::Definitions.fields_at_every_level(doc).map { |f| f.owner == doc ? "doc" : "iface" }
    out("if2", "levels: #{levels}\n#{summary(rep)}")
    unscoped = kinds(rep).select { |k| k.start_with?("unscoped_load") }
    expect(levels).to eq(%w[doc iface])
    expect(unscoped).to include("unscoped_load Doc.notes(target_id)")
  end

  it "[security] RV1 dynamic first: a resolver field's block adds an argument the resolver also has, twice on the resolver" do
    ac = arg_class
    res = Class.new(GraphQL::Schema::Resolver) do
      graphql_name "NotesR"
      argument_class ac
      type String, null: true
      argument :internal, GraphQL::Types::Boolean, required: false, authorize: :manage, model: Invoice, audience: :beta
      argument :internal, GraphQL::Types::Boolean, required: false, audience: :public
      def resolve(internal: false) = internal ? "SECRET" : "plain"
    end
    doc = doc_type { field(:notes, resolver: res) }
    schema = schema_for(on_query(doc), pre: DYN)
    served = run(schema, "{ doc { notes(internal: true) } }", root: notes_root)
    rep = report(schema)
    out("rv1", "served: #{served}\n#{summary(rep)}")
    flagged = kinds(rep).any? { |k| k.start_with?("ignored_rule") && k.end_with?("notes.internal") }
    expect(secret?(served) && !flagged).to eq(false), "served #{served}; #{summary(rep)}"
  end

  # --- 1: duplicates with an ancestor --------------------------------------------------------------
  it "[security] DU1 dynamic: one definition on an ancestor and two hidden ones on the owner" do
    parent = abstract_parent { field :notes, String, null: true }
    doc = doc_type(parent) do
      field :notes, String, null: true, authorize: :manage, audience: :beta
      field :notes, String, null: true, authorize: :manage, beta_only: true, audience: :public
    end
    schema = schema_for(on_query(doc), pre: DYN)
    served = run(schema, "{ doc { notes } }", root: secret_root)
    rep = report(schema)
    out("du1", "served: #{served}\n#{summary(rep)}")
    flagged = rep.problems.select { |pr| pr.kind == :ignored_rule && pr.path == "Doc.notes" }.size
    expect(secret?(served) && flagged.zero?).to eq(false), "served #{served}; #{summary(rep)}"
  end

  it "[security] DU2 dynamic: two on an ancestor and one on the owner (ancestor unreachable under a profile)" do
    parent = abstract_parent do
      field :notes, String, null: true, audience: :beta
      field :notes, String, null: true, audience: :public
    end
    doc = doc_type(parent) { field :notes, String, null: true, authorize: :manage, beta_only: true }
    schema = schema_for(on_query(doc), pre: DYN)
    served = run(schema, "{ doc { notes } }", root: secret_root)
    rep = report(schema)
    out("du2", "served: #{served}\n#{summary(rep)}")
    flagged = rep.problems.any? { |pr| pr.kind == :ignored_rule && pr.path == "Doc.notes" }
    expect(secret?(served) && !flagged).to eq(false), "served #{served}; #{summary(rep)}"
  end

  # --- paths and duplication of a shadowed field's findings ---------------------------------------

  it "[preservation] PA2 a parent that is a type too: its field reported as Parent.x and, shadowed, as Child.x" do
    target = doc_type(name: "Target")
    parent = doc_type(name: "Parent") { field(:notes, target, null: true, load_through_scope: false) { argument :target_id, GraphQL::Types::ID, loads: target } }
    child = Class.new(parent) { graphql_name "Child"; field(:notes, target, null: true, **DECL_R) { argument :target_id, GraphQL::Types::ID, loads: target } }
    q = query_with do
      field :parent, parent, null: true, authorize: :none, reason: "x"
      field :child, child, null: true, authorize: :none, reason: "x"
    end
    rep = report(schema_for(q))
    out("pa2", summary(rep))
    expect(kinds(rep)).to include("unscoped_load Parent.notes(target_id)", "unscoped_load Child.notes(target_id)")
  end


  # --- cost -----------------------------------------------------------------------------------------
  it "[preservation] CO1 cost: 300 types x 80 fields, half of them shadowing a base field with a block" do
    base = abstract_parent do
      40.times { |i| field(:"f#{i}", String, null: true) { argument :a, GraphQL::Types::Boolean, required: false } }
    end
    types = Array.new(300) do |t|
      Class.new(base) do
        graphql_name "T#{t}"
        authorize :read, model: Invoice
        40.times { |i| field(:"f#{i}", String, null: true, **DECL_R) { argument :a, GraphQL::Types::Boolean, required: false } }
        40.times { |i| field(:"g#{i}", String, null: true) }
      end
    end
    q = query_with { types.each_with_index { |ty, i| field(:"t#{i}", ty, null: true, authorize: :none, reason: "x") } }
    schema = schema_for(q)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rep = report(schema)
    secs = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    out("co1", "audit seconds: #{secs.round(2)} problems: #{rep.problems.size} bypasses: #{rep.bypasses.size}")
    expect(secs).to be < 60
  end
end
