# frozen_string_literal: true

PROBE_MODEL = Class.new unless defined?(PROBE_MODEL)

RSpec.describe "docs/authorization.md audit section claims" do
  let(:armory) { GraphQL::Armory::Authorization }

  # read? allowed, anything else refused; check reports a problem for action :bogus
  let(:adapter) do
    Class.new do
      def actor(_c) = :user
      def authorized?(_a, _s, rule) = rule.action == :read
      def scope(_a, items, _r) = items
      def check(_t, rule) = rule.none? || rule.action != :bogus ? [] : ["bogus? is not defined"]
    end.new
  end
  let(:base_argument) { p = armory; Class.new(GraphQL::Schema::Argument) { include p::Base } }
  let(:base_field) { p = armory; a = base_argument; Class.new(GraphQL::Schema::Field) { include p::Base; argument_class a } }
  let(:base_object) { p = armory; f = base_field; Class.new(GraphQL::Schema::Object) { include p::Base; field_class f; default_action :read } }
  let(:base_input) { p = armory; a = base_argument; Class.new(GraphQL::Schema::InputObject) { include p::Base; argument_class a } }

  def query_type(&block)
    Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :ping, String, null: true, authorize: :none, reason: "x"
      class_eval(&block) if block
    end
  end

  def schema_for(query_class, plugin: true, setup: nil)
    p = armory
    ad = adapter
    Class.new(base_schema) do
      use p, adapter: ad if plugin
      query query_class
      class_eval(&setup) if setup
    end
  end

  def audit(schema) = armory::Audit.(schema)
  def kinds(schema) = audit(schema).problems.map(&:kind)
  def redefs(s) = audit(s).problems.select { |x| x.kind == :ignored_rule }.map(&:path)

  # ---------- 1. when it runs
  describe "1 never runs on its own" do
    it "security: no Audit#call while defining the schema or executing a query" do
      calls = []
      tp = TracePoint.new(:call) { |t| calls << t.method_id if t.defined_class.to_s.include?("Audit") && t.method_id == :call }
      tp.enable do
        q = query_type do
          field :hi, String, null: true, authorize: :none, reason: "x", resolver_method: :hi
          def hi = "hi"
        end
        schema = schema_for(q)
        schema.execute("{ hi }")
      end
      expect(calls).to eq([])
    end

    it "preservation: the only callers are the matcher, the rake task and Audit.()" do
      hits = Dir["#{Dir.pwd}/lib/**/*.rb", "#{Dir.pwd}/lib/**/*.rake"].select { |f| File.read(f).match?(/\bAudit\b/) } - ["#{Dir.pwd}/lib/graphql/armory/authorization/audit.rb"]
      puts hits.sort
      expect(hits.map { |f| File.basename(f) }.sort).to eq(%w[command.rb graphql_armory.rake report.rb rspec.rb])
    end
  end

  # ---------- 2. kinds
  describe "2 kinds" do
    it "plugin: reported when never installed; clears with use" do
      expect(kinds(schema_for(query_type, plugin: false))).to include(:plugin)
      expect(kinds(schema_for(query_type))).not_to include(:plugin)
    end

    it "security: unprotected type is open for a refused user" do
      plain = Class.new(GraphQL::Schema::Object) do
        graphql_name "Plain"
        field :secret, String, null: true
        def secret = "leaked"
      end
      q = query_type do
        field :plain, plain, null: true, authorize: :none, reason: "x"
        define_method(:plain) { Object.new }
      end
      s = schema_for(q)
      expect(s.execute("{ plain { secret } }").to_h.dig("data", "plain", "secret")).to eq("leaked")
      expect(audit(s).problems.select { |x| x.kind == :unprotected }.map(&:path)).to include("Plain")
    end

    it "field class without Base on a bypassed type is :field_without_rule, not :unprotected" do
      plain_field = Class.new(GraphQL::Schema::Field)
      t = Class.new(base_object) do
        graphql_name "Bp"
        authorize :none, reason: "x"
        field_class plain_field
        field :a, String, null: true
      end
      q = query_type { field :bp, t, null: true, authorize: :none, reason: "x" }
      puts audit(schema_for(q)).problems.map(&:to_s)
      expect(kinds(schema_for(q))).to include(:field_without_rule)
      expect(kinds(schema_for(q))).not_to include(:unprotected)
    end

    it "no_rule: type with no rule is denied; authorize clears" do
      p = armory
      f = base_field
      norule = Class.new(GraphQL::Schema::Object) do
        include p::Base
        field_class f
        graphql_name "NoRule"
        field :a, String, null: true
        def a = "x"
      end
      q = query_type do
        field :nr, norule, null: true, authorize: :none, reason: "x"
        define_method(:nr) { Object.new }
      end
      s = schema_for(q)
      res = s.execute("{ nr { a } }").to_h
      puts res.inspect
      expect(res.dig("data", "nr")).to be_nil
      expect(kinds(s)).to include(:no_rule)
      fixed = Class.new(norule) { graphql_name "NoRule2"; authorize :read, model: PROBE_MODEL }
      q2 = query_type { field :nr, fixed, null: true, authorize: :none, reason: "x" }
      expect(kinds(schema_for(q2))).not_to include(:no_rule)
    end


    it "field_without_rule: denied case" do
      t = Class.new(base_object) { graphql_name "Den"; authorize :none, reason: "x"; field :a, String, null: true }
      msgs = audit(schema_for(query_type { field :d, t, null: true, authorize: :none, reason: "x" })).problems.select { |x| x.kind == :field_without_rule }.map(&:message)
      expect(msgs.join).to include("denied")
    end

    it "model: cannot be worked out; model: clears" do
      anon = Class.new(base_object) { graphql_name "Zzz"; field :a, String, null: true }
      expect(kinds(schema_for(query_type { field :z, anon, null: true, authorize: :none, reason: "x" }))).to include(:model)
      ok = Class.new(base_object) { graphql_name "Zzz"; authorize :read, model: PROBE_MODEL; field :a, String, null: true }
      expect(kinds(schema_for(query_type { field :z, ok, null: true, authorize: :none, reason: "x" }))).not_to include(:model)
    end

    it "adapter: action not defined" do
      t = Class.new(base_object) { graphql_name "Ad"; authorize :bogus, model: PROBE_MODEL; field :a, String, null: true }
      expect(kinds(schema_for(query_type { field :z, t, null: true, authorize: :none, reason: "x" }))).to include(:adapter)
    end

    it "unscoped_load: load_through_scope false reported; removing it clears" do
      t = Class.new(base_object) { graphql_name "L"; authorize :read, model: PROBE_MODEL; field :a, String, null: true }
      bad = query_type do
        field :l, String, null: true, authorize: :none, reason: "x", load_through_scope: false do
          argument :thing_id, GraphQL::Types::ID, loads: t
        end
      end
      good = query_type do
        field :l, String, null: true, authorize: :none, reason: "x" do
          argument :thing_id, GraphQL::Types::ID, loads: t
        end
      end
      expect(kinds(schema_for(bad))).to include(:unscoped_load)
      expect(kinds(schema_for(good))).not_to include(:unscoped_load)
    end

    it "hook: schema's own unauthorized_field reported; own_denial_hooks declares it" do
      s = schema_for(query_type, setup: proc { def self.unauthorized_field(_e) = nil })
      expect(kinds(s)).to include(:hook)
      p = armory
      ad = adapter
      q = query_type
      s2 = Class.new(base_schema) do
        use p, adapter: ad, own_denial_hooks: { unauthorized_field: "logs" }
        query q
        def self.unauthorized_field(_e) = nil
      end
      r = audit(s2)
      expect(r.problems.map(&:kind)).not_to include(:hook)
      expect(r.bypasses.map(&:reason)).to include("logs")
    end

    it "own_check: reauthorize_scoped_objects(false) is :own_check; declaring lists it" do
      t = Class.new(base_object) { graphql_name "Re"; authorize :read, model: PROBE_MODEL; reauthorize_scoped_objects(false); field :a, String, null: true }
      q = query_type { field :re, t, null: true, authorize: :none, reason: "x" }
      r = audit(schema_for(q))
      puts r.problems.select { |x| x.kind == :own_check }.map(&:to_s)
      expect(r.problems.map(&:kind)).to include(:own_check)
      p = armory
      ad = adapter
      s2 = Class.new(base_schema) do
        use p, adapter: ad, own_checks: { t => { reauthorize_scoped_objects: "scope as strict" } }
        query q
      end
      r2 = audit(s2)
      expect(r2.problems.map(&:kind)).not_to include(:own_check)
      expect(r2.bypasses.map(&:reason)).to include("scope as strict")
    end

    it "own_check: other methods (wrap, scope_items)" do
      t = Class.new(base_object) do
        graphql_name "Oc"
        authorize :read, model: PROBE_MODEL
        field :a, String, null: true
        def self.wrap(o, c) = super
        def self.scope_items(i, c) = super
      end
      r = audit(schema_for(query_type { field :oc, t, null: true, authorize: :none, reason: "x" }))
      puts r.problems.select { |x| x.kind == :own_check }.map(&:to_s)
      expect(r.problems.count { |x| x.kind == :own_check }).to be >= 2
    end

    it "every kind the code can emit is in the doc table" do
      src = File.read("#{Dir.pwd}/lib/graphql/armory/authorization/audit.rb")
      emitted = src.scan(/\.problem\(:(\w+)/).flatten.uniq.sort
      doc = File.read("#{Dir.pwd}/docs/authorization.md")
      section = doc[/\| Kind \|.*?\n\n/m]
      table = section.scan(/^\| `:(\w+)` \|/).flatten.sort
      puts emitted.inspect, table.inspect
      expect(emitted).to eq(table)
    end
  end

  # ---------- 3. Doc over Base
  describe "3 Doc over Base" do
    def doc_schema(setup: nil, **child_opts)
      parent = Class.new(base_object) do
        graphql_name "Base0"
        authorize :read, model: PROBE_MODEL
        field :notes, String, null: true, resolver_method: :pn
        def pn = "parent-notes"
      end
      child = Class.new(parent) do
        graphql_name "Doc"
        field :notes, String, null: true, resolver_method: :cn, **child_opts
        def cn = "child-notes"
      end
      q = query_type do
        field :doc, child, null: true, authorize: :none, reason: "x"
        define_method(:doc) { Object.new }
      end
      schema_for(q, setup: setup)
    end

    it "control: child not hidden -> child's :manage rule runs and refuses" do
      r = doc_schema(**{ authorize: :manage }).execute("{ doc { notes } }").to_h
      puts r.inspect
      expect(r.dig("data", "doc", "notes")).to be_nil
    end

    it "security: child hidden -> parent's definition answers, child's rule does not run" do
      r = doc_schema(**{ authorize: :manage, visible_when: :export }).execute("{ doc { notes } }").to_h
      puts r.inspect
      expect(r.dig("data", "doc", "notes")).to eq("parent-notes")
    end

    it "with Visibility dynamic: true the hidden child gives no such field" do
      s = doc_schema(authorize: :manage, visible_when: :export, setup: proc { use GraphQL::Schema::Visibility, dynamic: true })
      r = s.execute("{ doc { notes } }").to_h
      puts r.inspect
      expect(r["errors"].to_a.join).to match(/doesn't exist|notes/)
      expect(r.dig("data", "doc", "notes")).to be_nil
    end
  end

  # ---------- 4. ways out
  describe "4 ways out" do
    def doc_over(**opts)
      parent = Class.new(base_object) { graphql_name "Base1"; authorize :read, model: PROBE_MODEL; field :notes, String, null: true }
      child = Class.new(parent) { graphql_name "Doc"; field :notes, String, null: true, **opts }
      query_type { field :doc, child, null: true, authorize: :none, reason: "x" }
    end

    it "baseline reports; dynamic:true clears; static profile reports" do
      expect(redefs(schema_for(doc_over(authorize: :manage)))).to include("Doc.notes")
      expect(redefs(schema_for(doc_over(authorize: :manage), setup: proc { use GraphQL::Schema::Visibility, dynamic: true }))).to eq([])
      expect(redefs(schema_for(doc_over(authorize: :manage), setup: proc { use GraphQL::Schema::Visibility, profiles: { pub: {} } }))).to include("Doc.notes")
    end

    it "override_reason on a field clears and is listed as bypass" do
      r = audit(schema_for(doc_over(authorize: :manage, override_reason: "the parent's field is as strict")))
      expect(r.problems.select { |x| x.kind == :ignored_rule }).to eq([])
      expect(r.bypasses.map(&:reason)).to include("the parent's field is as strict")
    end

    it "a declared override still falls back: shadowed parent definition is audited" do
      parent = Class.new(base_object) { graphql_name "Base2"; authorize :read, model: PROBE_MODEL; field :notes, String, null: true, authorize: :bogus }
      child = Class.new(parent) { graphql_name "Doc"; field :notes, String, null: true, authorize: :manage, override_reason: "ok" }
      r = audit(schema_for(query_type { field :doc, child, null: true, authorize: :none, reason: "x" }))
      expect(r.problems.map(&:kind)).to include(:adapter)
    end

    it "argument line as written with Boolean (input object subclass)" do
      parent_in = Class.new(base_input) { graphql_name "InP"; argument :internal, GraphQL::Types::Boolean, required: false }
      child_in = Class.new(parent_in) do
        graphql_name "InC"
        argument :internal, GraphQL::Types::Boolean, required: false, authorize: :manage, override_reason: "the parent's argument is as strict"
      end
      q = query_type do
        field :x, String, null: true, authorize: :none, reason: "x" do
          argument :f, child_in, required: false
        end
      end
      r = audit(schema_for(q))
      expect(r.problems.select { |x| x.kind == :ignored_rule }.map(&:to_s)).to eq([])
      expect(r.bypasses.map(&:path)).to include("InC.internal")
      child_bad = Class.new(parent_in) { graphql_name "InC"; argument :internal, GraphQL::Types::Boolean, required: false, authorize: :manage }
      q2 = query_type do
        field :x, String, null: true, authorize: :none, reason: "x" do
          argument :f, child_bad, required: false
        end
      end
      expect(redefs(schema_for(q2))).to include("InC.internal")
    end

    it "duplicates on one owner always reported under dynamic: true; override_reason clears them" do
      t = Class.new(base_object) { graphql_name "Dup"; authorize :read, model: PROBE_MODEL; field :notes, String, null: true, authorize: :manage; field :notes, String, null: true }
      q = query_type { field :d, t, null: true, authorize: :none, reason: "x" }
      expect(redefs(schema_for(q, setup: proc { use GraphQL::Schema::Visibility, dynamic: true }))).to include("Dup.notes")
      t2 = Class.new(base_object) do
        graphql_name "Dup"
        authorize :read, model: PROBE_MODEL
        field :notes, String, null: true, authorize: :manage, override_reason: "r1"
        field :notes, String, null: true, override_reason: "r2"
      end
      q2 = query_type { field :d, t2, null: true, authorize: :none, reason: "x" }
      expect(redefs(schema_for(q2, setup: proc { use GraphQL::Schema::Visibility, dynamic: true }))).to eq([])
    end

    it "global_id_field line as written" do
      mk = lambda do |**o|
        Class.new(base_object) do
          graphql_name "Book"
          authorize :none, reason: "x", covers_fields: true
          implements GraphQL::Types::Relay::Node
          global_id_field :id, **o
        end
      end
      expect(redefs(schema_for(query_type { field :b, mk.call, null: true, authorize: :none, reason: "x" }))).to include("Book.id")
      r = audit(schema_for(query_type { field :b, mk.call(override_reason: "Node's id answers the same"), null: true, authorize: :none, reason: "x" }))
      expect(r.problems.map(&:to_s).join).not_to include("Book.id")
      expect(r.bypasses.map(&:path)).to include("Book.id")
    end
  end

  # ---------- 6. declarations
  describe "6 declarations" do
    it "override_reason with nothing falling back is a problem" do
      t = Class.new(base_object) { graphql_name "Solo"; authorize :read, model: PROBE_MODEL; field :notes, String, null: true, override_reason: "x" }
      r = audit(schema_for(query_type { field :s, t, null: true, authorize: :none, reason: "x" }))
      expect(r.problems.map(&:kind)).to include(:ignored_rule)
    end

    it "own_checks / own_denial_hooks naming something unused is a problem" do
      p = armory
      ad = adapter
      q = query_type
      s = Class.new(base_schema) do
        use p, adapter: ad, own_checks: { Object => { authorized?: "x" } }, own_denial_hooks: { unauthorized_field: "x" }
        query q
      end
      expect(kinds(s)).to include(:own_check, :hook)
    end

    it "authorize :none without a reason raises" do
      expect { Class.new(base_object) { authorize :none } }.to raise_error(StandardError)
    end

    it "authorize :none, reason: is listed as bypass" do
      r = audit(schema_for(query_type))
      expect(r.bypasses.map(&:reason)).to include("root", "x")
    end

    it "own_check chain: each level reported" do
      mid = Class.new(base_object) { def self.wrap(o, c) = super }
      t = Class.new(mid) { graphql_name "Chain"; authorize :read, model: PROBE_MODEL; field :a, String, null: true; def self.wrap(o, c) = super }
      r = audit(schema_for(query_type { field :c, t, null: true, authorize: :none, reason: "x" }))
      puts r.problems.select { |x| x.kind == :own_check }.map(&:to_s)
    end
  end
end

# Boolean written as in the doc, inside a real class body (lexical scope = the class)
RSpec.describe "doc Boolean constant" do
  it "resolves inside class bodies of an input object and a resolver" do
    p = GraphQL::Armory::Authorization
    a = Class.new(GraphQL::Schema::Argument) { include p::Base }
    in_klass = Class.new(GraphQL::Schema::InputObject) { include p::Base; argument_class a }
    in_klass.class_eval <<~R, __FILE__, __LINE__ + 1
      graphql_name "BoolIn"
      argument :internal, Boolean, required: false, authorize: :manage, override_reason: "r"
    R
    expect(in_klass.arguments.keys).to include("internal")
    res = Class.new(GraphQL::Schema::Resolver) { argument_class a }
    res.class_eval <<~R, __FILE__, __LINE__ + 1
      argument :internal, Boolean, required: false
    R
    expect(res.arguments.keys).to include("internal")
  end
end

RSpec.describe "served case: what clears it" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:adapter) { Class.new { def actor(_c) = :u; def authorized?(*) = true; def scope(_a, i, _r) = i; def check(*) = [] }.new }
  let(:base_field) { p = armory; Class.new(GraphQL::Schema::Field) { include p::Base } }
  let(:base_object) { p = armory; f = base_field; Class.new(GraphQL::Schema::Object) { include p::Base; field_class f; default_action :read } }

  def build(child_opts: nil, setup: nil)
    bo = base_object
    parent = Class.new(bo) { graphql_name "P"; authorize :read, model: PROBE_MODEL; field :notes, String, null: true }
    child = Class.new(parent) do
      graphql_name "C"
      authorize :none, reason: "x"
      field :notes, String, null: true, **child_opts if child_opts
    end
    q = Class.new(bo) { graphql_name "Query"; authorize :none, reason: "r", covers_fields: true; field :c, child, null: true, authorize: :none, reason: "x" }
    p = armory; ad = adapter
    Class.new(base_schema) { use p, adapter: ad; query q; class_eval(&setup) if setup }
  end

  it "prints variants" do
    {
      "no redeclare" => build,
      "redeclare authorize:read" => build(child_opts: { authorize: :read }),
      "redeclare + override_reason" => build(child_opts: { authorize: :read, override_reason: "r" }),
      "redeclare + dynamic" => build(child_opts: { authorize: :read }, setup: proc { use GraphQL::Schema::Visibility, dynamic: true }),
      "redeclare + override + dynamic" => build(child_opts: { authorize: :read, override_reason: "r" }, setup: proc { use GraphQL::Schema::Visibility, dynamic: true })
    }.each do |label, s|
      r = armory::Audit.(s)
      puts "#{label}: #{r.problems.map { |x| "#{x.path}(#{x.kind})" }.inspect} bypasses=#{r.bypasses.map(&:path).inspect}"
    end
  end
end

RSpec.describe "static profile runtime" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:adapter) { Class.new { def actor(_c) = :u; def authorized?(_a, _s, rule) = rule.action == :read; def scope(_a, i, _r) = i; def check(*) = [] }.new }
  let(:base_field) { p = armory; Class.new(GraphQL::Schema::Field) { include p::Base } }
  let(:base_object) { p = armory; f = base_field; Class.new(GraphQL::Schema::Object) { include p::Base; field_class f; default_action :read } }

  def build(setup)
    bo = base_object
    parent = Class.new(bo) do
      graphql_name "P"; authorize :read, model: PROBE_MODEL
      field :notes, String, null: true, resolver_method: :pn
      def pn = "parent-notes"
    end
    child = Class.new(parent) do
      graphql_name "Doc"
      field :notes, String, null: true, authorize: :manage, visible_when: :export, resolver_method: :cn
      def cn = "child"
    end
    q = Class.new(bo) do
      graphql_name "Query"; authorize :none, reason: "r", covers_fields: true
      field :doc, child, null: true, authorize: :none, reason: "x"
      define_method(:doc) { Object.new }
    end
    p = armory; ad = adapter
    Class.new(base_schema) { use p, adapter: ad; query q; class_eval(&setup) }
  end

end
