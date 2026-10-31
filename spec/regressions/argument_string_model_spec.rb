# frozen_string_literal: true

# Limited recheck of edc95aa..503db5a. Labels: [security] the feature must change the outcome; [preservation] must stay.
class VrNote
  def text(tag: nil) = "SECRET"
end
class VrLax; end
class VrNoPolicyModel; end
module VrNs; class Thing; end; end

class VrBasePolicy
  class Scope
    def initialize(_u, scope) = @scope = scope
    def resolve = @scope
  end
  class << self; attr_accessor :seen; end
  def initialize(user, record)
    @user = user
    VrBasePolicy.seen = record
  end
  def read? = true
  def export? = @user == :admin
end
class VrNotePolicy < VrBasePolicy; class Scope < VrBasePolicy::Scope; end; end
class VrGhostPolicy < VrBasePolicy; class Scope < VrBasePolicy::Scope; end; end
class VrOtherPolicy < VrBasePolicy; class Scope < VrBasePolicy::Scope; end; def export? = true; end
module VrNs; class ThingPolicy < VrBasePolicy; class Scope < VrBasePolicy::Scope; end; end; end
class VrLaxPolicy
  class Scope
    def initialize(_u, scope) = @scope = scope
    def resolve = @scope
  end
  def initialize(_u, _r); end
  def read? = true
  def export? = true
end
class VrStrictString
  class Scope
    def initialize(_u, _s); end
    def resolve = []
  end
  def initialize(_u, _r); end
  def read? = false
end
class VrRoot
  def note = VrNote.new
  def text(tag: nil) = "SECRET"
  def said(v:) = v
end

RSpec.describe "recheck of the String model correction" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:adapter) { armory::Adapters::Pundit.new }

  def base_argument
    @base_argument ||= begin
      plugin = armory
      Class.new(GraphQL::Schema::Argument) { include plugin::Base }
    end
  end

  def base_field
    @base_field ||= begin
      plugin = armory
      argument = base_argument
      Class.new(GraphQL::Schema::Field) do
        include plugin::Base
        argument_class argument
      end
    end
  end

  def base_object
    @base_object ||= begin
      plugin = armory
      field = base_field
      Class.new(GraphQL::Schema::Object) do
        include plugin::Base
        field_class field
      end
    end
  end

  def schema_of(query_class)
    plugin = armory
    Class.new(ArmoryEngine.base_schema) do
      query query_class
      use plugin, adapter: :pundit
    end
  end

  def query_with(&block)
    Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root"
      class_eval(&block)
    end
  end

  # The argument lives on a field of a type served by a record.
  def on_type(model:, type_rule: { model: VrNote }, **rule)
    type = Class.new(base_object) do
      graphql_name "Note"
      authorize :read, **type_rule
      field(:text, String, null: true) { argument :tag, String, required: false, model: model, **rule }
    end
    schema_of(query_with { field :note, type, null: true, authorize: :none, reason: "root" })
  end

  # On a root field there is no record, so the policy is asked about the model.
  def on_root(model:, **rule)
    schema_of(query_with do
      field(:text, String, null: true, authorize: :none, reason: "root") { argument :tag, String, required: false, model: model, **rule }
    end)
  end

  def run_q(schema, query, user)
    execute_query(schema, query, root_value: VrRoot.new, context: { current_user: user }).to_h
  end

  def noted(schema, user) = run_q(schema, '{ note { text(tag: "x") } }', user)
  def rooted(schema, user) = run_q(schema, '{ text(tag: "x") }', user)

  def outcome
    yield.to_s
  rescue StandardError => e
    "RAISED #{e.class}: #{e.message}"
  end

  def with_const(name, value)
    Object.const_set(name, value)
    yield
  ensure
    Object.send(:remove_const, name)
  end

  describe "item 1, String model" do
    it "[preservation] 1a visible_when on a type's field: allowed gets data, refused does not" do
      schema = on_type(model: "VrNote", visible_when: :export)
      expect(noted(schema, :admin).dig("data", "note", "text")).to eq("SECRET")
      refused = noted(schema, :someone)
      expect(refused.dig("data", "note", "text")).to be_nil
      expect(refused.to_s).not_to include("SECRET")
      expect(refused["errors"].first["message"]).to include("doesn't accept argument")
    end

    it "[security] 1b authorize on a type's field: allowed gets data, refused does not" do
      schema = on_type(model: "VrNote", authorize: :export)
      expect(noted(schema, :admin).dig("data", "note", "text")).to eq("SECRET")
      expect(VrBasePolicy.seen).to be_a(VrNote)
      expect(noted(schema, :someone).to_s).not_to include("SECRET")
    end

    it "[preservation] 1c visible_when on a root field" do
      schema = on_root(model: "VrNote", visible_when: :export)
      expect(rooted(schema, :admin).dig("data", "text")).to eq("SECRET")
      expect(rooted(schema, :someone).to_s).not_to include("SECRET")
    end

    it "[security] 1d authorize on a root field asks about the class" do
      schema = on_root(model: "VrNote", authorize: :export)
      expect(rooted(schema, :admin).dig("data", "text")).to eq("SECRET")
      expect(VrBasePolicy.seen).to eq(VrNote)
      expect(rooted(schema, :someone).to_s).not_to include("SECRET")
    end

    it "[security] 1e a namespaced String model, authorize" do
      schema = on_root(model: "VrNs::Thing", authorize: :export)
      expect(rooted(schema, :admin).dig("data", "text")).to eq("SECRET")
      expect(rooted(schema, :someone).to_s).not_to include("SECRET")
    end

    it "[preservation] 1f the argument's client value is not read as the model" do
      schema = on_root(model: "VrNote", authorize: :export)
      expect(run_q(schema, '{ text(tag: "VrLax") }', :someone).to_s).not_to include("SECRET")
    end

    it "[preservation] 1g a resolver's argument with a String model, authorize" do
      plugin = armory
      arg = base_argument
      resolver = Class.new(GraphQL::Schema::Resolver) do
        include plugin::Base
        argument_class arg
        graphql_name "R"
        type String, null: true
        authorize :read, model: VrNote
        argument :tag, String, required: false, model: "VrNote", authorize: :export
        def resolve(**) = "SECRET"
      end
      schema = schema_of(query_with { field :text, resolver: resolver })
      expect(rooted(schema, :admin).dig("data", "text")).to eq("SECRET")
      expect(rooted(schema, :someone).to_s).not_to include("SECRET")
    end
  end

  describe "item 2, Symbol model" do
    it "[preservation] 2a visible_when on a type's field" do
      schema = on_type(model: :vr_note, visible_when: :export)
      expect(noted(schema, :admin).dig("data", "note", "text")).to eq("SECRET")
      expect(noted(schema, :someone).to_s).not_to include("SECRET")
    end

    it "[preservation] 2b armory_model returns a Symbol and a Class as they are" do
      arg = ->(model) { base_argument.new(:tag, String, required: false, model: model, owner: base_field).armory_model }
      expect(arg.(:vr_note)).to eq(:vr_note)
      expect(arg.(VrNote)).to eq(VrNote)
    end

    it "[preservation] 2c Symbol with authorize: what happens (is_a? needs a Module)" do
      schema = on_type(model: :vr_note, authorize: :export)
      admin = outcome { noted(schema, :admin) }
      someone = outcome { noted(schema, :someone) }
      STDERR.puts "VR2c admin=#{admin} someone=#{someone} audit=#{armory::Audit.(schema).problems.map(&:to_s)}"
      expect(someone).not_to include("SECRET")
    end

    it "[preservation] 2d a String with no constant, authorize: what happens" do
      schema = on_root(model: "vr_ghost", authorize: :export)
      admin = outcome { rooted(schema, :admin) }
      someone = outcome { rooted(schema, :someone) }
      STDERR.puts "VR2d admin=#{admin} someone=#{someone} audit=#{armory::Audit.(schema).problems.map(&:to_s)}"
      expect(someone).not_to include("SECRET")
    end

    it "[preservation] 2e a String with no constant, visible_when" do
      schema = on_root(model: "vr_ghost", visible_when: :export)
      expect(rooted(schema, :admin).dig("data", "text")).to eq("SECRET")
      expect(rooted(schema, :someone).to_s).not_to include("SECRET")
      expect(armory::Audit.(schema).problems).to eq([])
    end
  end

  describe "item 3, found_policy and the audit" do
    it "[security] 3a found_policy with a String model name" do
      expect(adapter.found_policy("VrNote")).to eq(VrNotePolicy)
      expect(adapter.found_policy("vr_note")).to eq(VrNotePolicy)
      expect(adapter.found_policy("VrNs::Thing")).to eq(VrNs::ThingPolicy)
      expect(adapter.found_policy(:vr_note)).to eq(VrNotePolicy)
      expect(adapter.found_policy(VrNote)).to eq(VrNotePolicy)
      expect(adapter.found_policy("VrNoSuch")).to be_nil
    end

    it "[preservation] 3b audit ok and the runtime serves" do
      %i[authorize visible_when].each do |key|
        schema = on_type(model: "VrNote", key => :export)
        expect(armory::Audit.(schema).problems).to eq([])
        expect(noted(schema, :admin).dig("data", "note", "text")).to eq("SECRET")
      end
    end

    it "[preservation] 3c missing action: audit reports it and the runtime refuses, both rule kinds" do
      %i[authorize visible_when].each do |key|
        schema = on_type(model: "VrNote", key => :misspelled)
        expect(armory::Audit.(schema).problems.map(&:to_s).join).to include("misspelled")
        expect(outcome { noted(schema, :admin) }).to match(/RAISED GraphQL::Armory::Authorization::AdapterError.*misspelled/)
      end
    end

    it "[preservation] 3d a class with no policy: audit reports it and the runtime refuses, both rule kinds" do
      %i[authorize visible_when].each do |key|
        schema = on_type(model: "VrNoPolicyModel", key => :export)
        expect(armory::Audit.(schema).problems.map(&:to_s).join).to include("VrNoPolicyModelPolicy not found")
        expect(outcome { noted(schema, :admin) }).to match(/RAISED Pundit::NotDefinedError/)
      end
    end

    it "[preservation] 3e a String with no constant and no policy: audit reports it, the runtime refuses" do
      schema = on_root(model: "vr_no_such", visible_when: :export)
      expect(armory::Audit.(schema).problems.map(&:to_s).join).to include("not found")
      expect(outcome { rooted(schema, :admin) }).to match(/RAISED Pundit::NotDefinedError/)
    end

    def input_schema(policy, model)
      plugin = armory
      arg = base_argument
      input = Class.new(GraphQL::Schema::InputObject) do
        include plugin::Base
        argument_class arg
        graphql_name "Filter"
        argument :tag, String, required: false, model: model, authorize: :export
      end
      type = Class.new(base_object) do
        graphql_name "Note"
        authorize :read, model: VrNote, policy: policy
        field(:text, String, null: true) { argument :filter, input, required: false }
      end
      schema_of(query_with { field :note, type, null: true, authorize: :none, reason: "root" })
    end

    it "[security] 3f :foreign_policy agrees with what really runs, String like Class" do
      kinds = ->(policy, model) { armory::Audit.(input_schema(policy, model)).problems.map(&:kind) }
      expect(kinds.(VrNotePolicy, "VrNote")).to eq(kinds.(VrNotePolicy, VrNote))
      expect(kinds.(VrNotePolicy, "VrNote")).not_to include(:foreign_policy)
      expect(kinds.(VrOtherPolicy, "VrNote")).to include(:foreign_policy)
      # The type names VrOtherPolicy (export? is true for everyone); the input's argument asks VrNotePolicy.
      refused = run_q(input_schema(VrOtherPolicy, "VrNote"), '{ note { text(filter: { tag: "x" }) } }', :someone)
      expect(refused.to_s).not_to include("SECRET")
    end
  end

  describe "item 4, a String record" do
    def text_schema(**rule)
      text_type = Class.new(base_object) do
        graphql_name "Said"
        authorize :read, **rule
        field :upcase, String, null: true
      end
      schema_of(query_with { field(:said, text_type, null: true, authorize: :none, reason: "root") { argument :v, String } })
    end

    [["camel name", "VrLax"], ["snake name", "vr_lax"]].each do |label, text|
      it "[security] 4a #{label}: StringPolicy answers, not the policy the text names" do
        with_const(:StringPolicy, VrStrictString) do
          response = run_q(text_schema(model: VrNote), %({ said(v: "#{text}") { upcase } }), :someone)
          expect(response.dig("data", "said")).to be_nil
        end
      end

      it "[security] 4b #{label}: no StringPolicy raises, never the named policy" do
        expect(outcome { run_q(text_schema(model: VrNote), %({ said(v: "#{text}") { upcase } }), :someone) }).to match(/RAISED Pundit::NotDefinedError: .*no policy found for String\z/)
      end

      it "[security] 4c #{label}: the adapter directly, read asks StringPolicy" do
        with_const(:StringPolicy, VrStrictString) do
          expect(adapter.authorized?(:someone, text, armory::Rule.new(:read))).to eq(false)
        end
      end
    end

    it "[security] 4d a String model of the type does not let its name in the record pick the policy" do
      with_const(:StringPolicy, VrStrictString) do
        response = run_q(text_schema(model: "VrLax"), '{ said(v: "VrLax") { upcase } }', :someone)
        expect(response.dig("data", "said")).to be_nil
      end
    end
  end

  describe "item 5, docs D2 and D3" do
    it "[preservation] 5a D2: a misspelled action on a bypassed type's field passes the audit, raises, never serves" do
      type = Class.new(base_object) do
        graphql_name "Doc"
        authorize :none, reason: "public"
        field :text, String, null: true, authorize: :misspelled
      end
      schema = schema_of(query_with { field :note, type, null: true, authorize: :none, reason: "root" })
      expect(armory::Audit.(schema).problems).to eq([])
      expect(outcome { run_q(schema, "{ note { text } }", :admin) }).to match(/RAISED GraphQL::Armory::Authorization::AdapterError.*misspelled/)
    end

    it "[preservation] 5a2 D2: same type, a record with no policy, also raises and never serves" do
      type = Class.new(base_object) do
        graphql_name "Doc"
        authorize :none, reason: "public"
        field :upcase, String, null: true, authorize: :misspelled
      end
      schema = schema_of(query_with { field :plain, type, null: true, authorize: :none, reason: "root" })
      root = Struct.new(:plain).new(Class.new { def upcase = "SECRET" }.new)
      expect(armory::Audit.(schema).problems).to eq([])
      answer = outcome { execute_query(schema, "{ plain { upcase } }", root_value: root, context: { current_user: :admin }).to_h }
      expect(answer).to match(/RAISED Pundit::NotDefinedError/)
    end

    it "[preservation] 5b D2: a misspelled action on a resolver's argument passes the audit, raises, never serves" do
      plugin = armory
      arg = base_argument
      resolver = Class.new(GraphQL::Schema::Resolver) do
        include plugin::Base
        argument_class arg
        graphql_name "R"
        type String, null: true
        authorize :read, model: VrNote
        argument :tag, String, required: false, authorize: :misspelled
        def resolve(**) = "SECRET"
      end
      schema = schema_of(query_with { field :text, resolver: resolver })
      expect(armory::Audit.(schema).problems).to eq([])
      expect(outcome { rooted(schema, :admin) }).to match(/RAISED GraphQL::Armory::Authorization::AdapterError.*misspelled/)
    end

    def shadowed(type_ref)
      field_klass = base_field
      parent = Class.new(base_object) do
        graphql_name "Base"
        authorize :read, model: VrNote
        field_class field_klass
        field(:text, String, null: true) { argument :filter, type_ref, required: false }
      end
      child = Class.new(parent) do
        graphql_name "Doc"
        field :text, String, null: true, override_reason: "as strict"
      end
      schema_of(query_with { field :note, child, null: true, authorize: :none, reason: "root" })
    end

    it "[preservation] 5c D3: an argument naming a type that cannot load raises ArgumentError" do
      expect { armory::Audit.(shadowed("VrMissingConstant")) }.to raise_error(ArgumentError)
    end

    it "[preservation] 5d D3: a late-bound type that never resolves is skipped, no problem reported" do
      report = armory::Audit.(shadowed(GraphQL::Schema::LateBoundType.new("VrMissing")))
      expect(report.problems).to eq([])
      expect(report.ok?).to eq(true)
    end
  end
end
