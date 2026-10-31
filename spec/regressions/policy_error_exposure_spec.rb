# frozen_string_literal: true

# Probes for fix/audit-backlog-exposure. Labels: [security] the feature must change the outcome,
# [preservation] behaviour that must stay, [pre-existing] outside the PR's claim, recorded to compare.
require "spec_helper"
require "ostruct"
require "fileutils"

ActiveRecord::Base.connection.create_table(:vfy_secrets, force: true) { |t| t.string :secret }
class VfySecret < ActiveRecord::Base; self.table_name = "vfy_secrets"; end

class VfyNoPolicyRecord
  def inspect = "SECRET-INSPECT"
  def to_s = "SECRET-TOS"
end

class VfyFakeRelation
  attr_reader :touched
  def initialize = @touched = []
  %i[inspect to_a load each to_s size].each { |name| define_method(name) { |*| @touched << name; "SECRET-REL" } }
end

class VfyLaxPolicy
  class Scope
    def initialize(_user, scope) = @scope = scope
    def resolve = @scope
  end
  attr_reader :user, :record
  def initialize(user, record) = (@user, @record = user, record)
  def read? = true
  def manage? = true
end

class VfyStrictPolicy < VfyLaxPolicy
  def manage? = user == :admin
end

class VfyNoManagePolicy
  class Scope
    def initialize(_user, scope) = @scope = scope
    def resolve = @scope
  end
  def initialize(_user, _record); end
  def read? = true
end

class VfyOverridePolicy < VfyLaxPolicy; end
class VfyInstanceOverride; def policy_class = VfyOverridePolicy; end
class VfyClassOverride; def self.policy_class = VfyOverridePolicy; end
class VfyStringOverride; def policy_class = "VfyOverridePolicy"; end
class VfyBrokenOverride
  def policy_class = "VfyAbsentPolicy"
  def inspect = "SECRET-INSPECT"
end
class VfyNilOverride
  def policy_class = nil
  def inspect = "SECRET-INSPECT"
end
class VfyNamedPolicy < VfyLaxPolicy; end
class VfyModelNamed; def model_name = "VfyNamed"; end
module VfyAdmin
  class Thing; end
  class ThingPolicy < VfyLaxPolicy; end
  class VfyTopThingPolicy < VfyLaxPolicy; end
end
class VfyTopThing; end
class VfyTopThingPolicy < VfyLaxPolicy
  def manage? = user == :admin
end
class VfyAnswerRecordPolicy < VfyLaxPolicy
  def read? = record
end
class VfySymbolPickedPolicy < VfyLaxPolicy; end
class VfyLaxPicked; end
class VfyLaxPickedPolicy < VfyLaxPolicy; end

VfyItem = Struct.new(:name)

# Execution::Next calls an object method by default; these probes define the field on the type.
VFY_LEGACY = Gem::Version.new(GraphQL::VERSION) >= Gem::Version.new("2.6") ? { resolve_legacy_instance_method: true }.freeze : {}.freeze

RSpec.describe "fix/audit-backlog-exposure probes" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:adapter) { armory::Adapters::Pundit.new }
  let(:rule) { armory::Rule.new(:read) }

  def caught
    yield
    nil
  rescue Exception => e # rubocop:disable Lint/RescueException
    e
  end

  def expect_clean_refusal(error)
    expect(error).to be_a(Pundit::NotDefinedError)
    expect(error.message).not_to match(/SECRET/)
  end

  def kit
    plugin = armory
    fld = Class.new(GraphQL::Schema::Field) { include plugin::Base }
    object = Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class fld
    end
    item = Class.new(object) do
      graphql_name "VfyItem"
      authorize :read, policy: VfyLaxPolicy, model: VfyItem
      field :name, String, null: true
    end
    edge = Class.new(GraphQL::Types::Relay::BaseEdge) do
      graphql_name "VfyItemEdge"
      node_type(item)
    end
    { field: fld, object: object, item: item, edge: edge, plugin: plugin }
  end

  def query_for(object, conn, items: [VfyItem.new("a")])
    Class.new(object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :items, conn, null: true, connection: true, authorize: :none, reason: "root", **VFY_LEGACY
      define_method(:items) { items }
    end
  end

  def schema_for(query_type, plugin: armory, mode: :null, rescue_not_defined: false)
    Class.new(base_schema) do
      query query_type
      use plugin, adapter: :pundit, on_unauthorized: mode
      rescue_from(Pundit::NotDefinedError) { |e, *| raise GraphQL::ExecutionError, e.message } if rescue_not_defined
    end
  end

  def audit(schema) = armory::Audit.call(schema)
  def foreign(report) = report.problems.select { |p| p.kind == :foreign_policy }.map(&:path)

  def direct_child_conn(kit, parent_policy:, child_policy: VfyStrictPolicy, parent_rule: :manage, &extra)
    field_class_ = kit[:field]
    plugin = kit[:plugin]
    parent = Class.new(GraphQL::Types::Relay::BaseConnection) do
      include plugin::Base
      field_class field_class_
      graphql_name "VfyParentConnection"
      authorize :read, policy: parent_policy if parent_policy
      field :total, Integer, null: true, authorize: parent_rule, **VFY_LEGACY
      define_method(:total) { object.items.size }
    end
    edge = kit[:edge]
    Class.new(parent) do
      graphql_name "VfyChildConnection"
      authorize :read, policy: child_policy if child_policy
      edge_type(edge)
      class_eval(&extra) if extra
    end
  end

  # ---- 1. every path that raises for a missing policy

  it("[security] 1a authorized? on a record") { expect_clean_refusal(caught { adapter.authorized?(:u, VfyNoPolicyRecord.new, rule) }) }

  it "[security] 1b scope on a real relation: no SQL, no contents" do
    VfySecret.create!(secret: "SECRET-ROW")
    sql = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, p| sql << p[:sql] unless p[:name] == "SCHEMA" }
    error = caught { adapter.scope(:u, VfySecret.all, rule) }
    ActiveSupport::Notifications.unsubscribe(sub)
    expect_clean_refusal(error)
    expect(sql).to eq([])
  end

  it "[security] 1b2 scope on a loaded relation does not quote rows" do
    VfySecret.create!(secret: "SECRET-ROW")
    expect_clean_refusal(caught { adapter.scope(:u, VfySecret.all.load, rule) })
  end

  it("[security] 1c scope on an Array") { expect_clean_refusal(caught { adapter.scope(:u, [VfyNoPolicyRecord.new], rule) }) }
  it("[security] 1d scope on a Hash") { expect_clean_refusal(caught { adapter.scope(:u, { a: "SECRET-HASH" }, rule) }) }

  it "[security] 1e scope on an AR-like relation touches nothing" do
    fake = VfyFakeRelation.new
    expect_clean_refusal(caught { adapter.scope(:u, fake, rule) })
    expect(fake.touched).to eq([])
  end

  it("[security] 1f authorized? on a String") { expect_clean_refusal(caught { adapter.authorized?(:u, "SECRET string", rule) }) }
  it("[security] 1g authorized? on an Array subject") { expect_clean_refusal(caught { adapter.authorized?(:u, [VfyNoPolicyRecord.new, VfyNoPolicyRecord.new], rule) }) }
  it("[security] 1h a Set of records") { expect_clean_refusal(caught { adapter.scope(:u, Set[VfyNoPolicyRecord.new], rule) }) }

  it "[preservation] 1i nil, Symbol and Class subjects raise the same class" do
    [nil, :vfy_absent, VfyNoPolicyRecord].each do |subject|
      expect(caught { adapter.authorized?(:u, subject, rule) }).to be_a(Pundit::NotDefinedError)
    end
  end

  it "[preservation] 1j nil message says NilClass, a Symbol names itself, a Class names itself" do
    expect(caught { adapter.authorized?(:u, nil, rule) }.message).to match(/nil/i)
    expect(caught { adapter.authorized?(:u, :vfy_absent, rule) }.message).to match(/vfy_absent|VfyAbsent/i)
    expect(caught { adapter.authorized?(:u, VfyNoPolicyRecord, rule) }.message).to include("VfyNoPolicyRecord")
  end

  it "[preservation] 1k audit check reports a missing policy, raises nothing" do
    expect(adapter.check(VfyNoPolicyRecord, rule).join).to match(/Policy not found/)
    expect(adapter.check(:vfy_absent, armory::Rule.new(:read, model: :vfy_absent)).join).to match(/Policy not found/)
  end

  def leak_schema(mode: :null, rescue_not_defined: false)
    k = kit
    leak = Class.new(k[:object]) do
      graphql_name "VfyLeak"
      authorize :read, model: VfyNoPolicyRecord
      field :secret, String, null: true, **VFY_LEGACY
      def secret = "SECRET-FIELD"
    end
    root = Class.new(k[:object]) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :leak, leak, null: true, authorize: :none, reason: "root", **VFY_LEGACY
      def leak = VfyNoPolicyRecord.new
    end
    schema_for(root, mode: mode, rescue_not_defined: rescue_not_defined)
  end

  %i[null error raise].each do |mode|
    it "[security] 1l full query, on_unauthorized #{mode}: raises the class with no contents, no data" do
      result = nil
      error = caught { result = execute_query(leak_schema(mode: mode), "{ leak { secret } }", context: { current_user: :u }).to_h }
      expect_clean_refusal(error)
      expect(result).to be_nil
    end
  end

  it "[security] 1m an app's rescue_from showing the text to the client: no contents, no data" do
    result = execute_query(leak_schema(rescue_not_defined: true), "{ leak { secret } }", context: { current_user: :u }).to_h
    expect(result.to_s).not_to match(/SECRET/)
    expect(result.dig("errors", 0, "message")).to match(/VfyNoPolicyRecord/)
  end

  it "[security] 1n a connection field rule with no policy does not quote the connection's items" do
    k = kit
    f = k[:field]
    plugin = k[:plugin]
    edge = k[:edge]
    conn = Class.new(GraphQL::Types::Relay::BaseConnection) do
      include plugin::Base
      field_class f
      graphql_name "VfyNoPolicyConnection"
      authorize :none, reason: "covered", covers_fields: true
      edge_type(edge)
      field :total, Integer, null: true, authorize: :read, **VFY_LEGACY
      def total = 1
    end
    items = [VfyNoPolicyRecord.new]
    error = caught { execute_query(schema_for(query_for(k[:object], conn, items: items)), "{ items { total } }", context: { current_user: :u }).to_h }
    expect_clean_refusal(error)
  end

  it "[security] 1o a relation behind a root field: refused, no SQL for rows, no contents" do
    VfySecret.create!(secret: "SECRET-ROW")
    k = kit
    type = Class.new(k[:object]) do
      graphql_name "VfySecretType"
      authorize :read, model: VfySecret
      field :secret, String, null: true, **VFY_LEGACY
    end
    root = Class.new(k[:object]) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :secrets, [type], null: true, authorize: :none, reason: "root", **VFY_LEGACY
      def secrets = VfySecret.all
    end
    result = nil
    error = caught { result = execute_query(schema_for(root), "{ secrets { secret } }", context: { current_user: :u }).to_h }
    expect_clean_refusal(error)
    expect(result).to be_nil
  end

  it "[preservation] 1p visible_when on a missing policy: raises the class, never shows the field" do
    k = kit
    plain = Class.new(k[:object]) do
      graphql_name "VfyPlain"
      authorize :read, policy: VfyLaxPolicy, model: VfyNoPolicyRecord
      field :open, String, null: true
    end
    hidden = Class.new(k[:object]) do
      graphql_name "VfyHidden"
      authorize :read, model: VfyNoPolicyRecord, visible_when: :export
      field :secret, String, null: true, **VFY_LEGACY
      def secret = "SECRET-FIELD"
    end
    root = Class.new(k[:object]) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :plain, plain, null: true, authorize: :none, reason: "root", **VFY_LEGACY
      field :hidden, hidden, null: true, authorize: :none, reason: "root", **VFY_LEGACY
      def hidden = VfyNoPolicyRecord.new
      def plain = VfyNoPolicyRecord.new
    end
    result = nil
    error = caught { result = execute_query(schema_for(root), "{ hidden { secret } }", context: { current_user: :u }).to_h }
    expect(error).to be_a(Pundit::NotDefinedError) if result.nil?
    expect(result.to_s).not_to include("SECRET-FIELD")
  end

  it "[preservation] 1q nil root object on a type with a rule: refused" do
    k = kit
    root = Class.new(k[:object]) do
      graphql_name "Query"
      authorize :read
      field :secret, String, null: true, authorize: true, **VFY_LEGACY
      def secret = "SECRET-FIELD"
    end
    result = nil
    error = caught { result = execute_query(schema_for(root), "{ secret }", context: { current_user: :u }, root_value: nil).to_h }
    puts "1q result: #{result}; error: #{error&.class}: #{error&.message}; at #{error&.backtrace&.first(3)}"
    expect(result.to_s).not_to include("SECRET-FIELD")
    expect(error).to be_a(Exception) if result.nil?
  end

  it "[preservation] 1r a resolver with no policy for its model: refused with the class" do
    k = kit
    plugin = k[:plugin]
    resolver = Class.new(GraphQL::Schema::Resolver) do
      include plugin::Base
      type String, null: true
      authorize :read, model: VfyNoPolicyRecord
      def resolve = "SECRET-FIELD"
    end
    root = Class.new(k[:object]) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :run, resolver: resolver
    end
    result = nil
    error = caught { result = execute_query(schema_for(root), "{ run }", context: { current_user: :u }).to_h }
    expect(result.to_s).not_to include("SECRET-FIELD")
    expect(error).to be_a(Pundit::NotDefinedError) if result.nil?
  end

  # ---- 2. records that lie; every way the finder answers

  it "[security] 2a a Struct with a `class` member does not put its value in the message" do
    record = Struct.new(:class, :secret).new("SECRET-CLASS-VALUE", "x")
    expect_clean_refusal(caught { adapter.authorized?(:u, record, rule) })
  end

  it "[security] 2b an OpenStruct with `class:` does not put its value in the message" do
    record = OpenStruct.new(class: "SECRET-CLASS-VALUE")
    expect_clean_refusal(caught { adapter.authorized?(:u, record, rule) })
  end

  it "[security] 2c an `is_a?` that claims Module does not put to_s in the message" do
    record = Class.new(VfyNoPolicyRecord) { def is_a?(klass) = klass == Module || super }.new
    expect_clean_refusal(caught { adapter.authorized?(:u, record, rule) })
  end

  it "[security] 2d an inspect that raises or runs a query is never called" do
    calls = []
    record = Class.new { define_method(:inspect) { calls << :inspect; raise "boom SECRET" } }.new
    expect_clean_refusal(caught { adapter.authorized?(:u, record, rule) })
    expect(calls).to eq([])
  end

  it "[security] 2e a SimpleDelegator around a record" do
    expect_clean_refusal(caught { adapter.authorized?(:u, SimpleDelegator.new(VfyNoPolicyRecord.new), rule) })
  end

  it "[preservation] 2f a BasicObject subject is refused, not served" do
    error = caught { adapter.authorized?(:u, BasicObject.new, rule) }
    expect(error).to be_a(Exception)
    expect(error.message).not_to match(/SECRET/)
  end



  it "[security] 2i policy_class naming nothing, or nil: refused with no contents" do
    expect_clean_refusal(caught { adapter.authorized?(:u, VfyBrokenOverride.new, rule) })
    expect_clean_refusal(caught { adapter.authorized?(:u, VfyNilOverride.new, rule) })
  end

  it "[preservation] 2j a NilClassPolicy still answers for nil, as under policy!" do
    stub = Class.new(VfyLaxPolicy)
    Object.const_set(:NilClassPolicy, stub)
    begin
      expect(adapter.authorized?(:u, nil, rule)).to eq(true)
    ensure
      Object.send(:remove_const, :NilClassPolicy)
    end
  end

  it "[preservation] 2k a rule's policy: wins over a subject with no policy" do
    expect(adapter.authorized?(:u, VfyNoPolicyRecord.new, armory::Rule.new(:read, policy: VfyLaxPolicy))).to eq(true)
  end

  it "[preservation] 2l a policy raising NotDefinedError itself passes through unchanged" do
    policy = Class.new(VfyLaxPolicy) { def read? = raise(Pundit::NotDefinedError, "mine") }
    expect(caught { adapter.authorized?(:u, VfyTopThing.new, armory::Rule.new(:read, policy: policy)) }.message).to eq("mine")
  end

  # ---- pre-existing neighbours, recorded

  it "[pre-existing] P1 a policy answering a record: AdapterError does not quote it" do
    record = VfyNoPolicyRecord.new
    error = caught { armory::Authorize.new(adapter: adapter).(record, armory::Rule.new(:read, policy: VfyAnswerRecordPolicy), Struct.new(:x) { def [](_k) = :u }.new) }
    expect(error).to be_a(armory::AdapterError)
    expect(error.message).not_to match(/SECRET/)
  end

  it "[pre-existing] P2 a String object does not choose its own policy" do
    expect(caught { adapter.authorized?(:u, "VfyLaxPicked", rule) }).to be_a(Pundit::NotDefinedError)
  end


  it "[security] 2n end to end on a list: OpenStructs with a `class` key go through scope first" do
    k = kit
    payloads = [JSON.parse('{"class":"SECRET-CLASS-VALUE","secret":"s"}', object_class: OpenStruct)]
    type = Class.new(k[:object]) do
      graphql_name "VfyPayload"
      authorize :read, scope: :in_memory, model: VfyNoPolicyRecord
      field :secret, String, null: true
    end
    root = Class.new(k[:object]) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :payloads, [type], null: true, authorize: :none, reason: "root", **VFY_LEGACY
      define_method(:payloads) { payloads }
    end
    result = nil
    error = caught { result = execute_query(schema_for(root, rescue_not_defined: true), "{ payloads { secret } }", context: { current_user: :u }).to_h }
    puts "2n client sees: #{result}; error: #{error&.class}: #{error&.message}"
    expect(result.to_s).not_to include("SECRET")
  end

  # ---- 3. connections and edges

  it "[security] 3a parent rule asks a laxer policy: audit reports; runtime compared" do
    k = kit
    conn = direct_child_conn(k, parent_policy: VfyLaxPolicy)
    schema = schema_for(query_for(k[:object], conn))
    served = execute_query(schema, "{ items { total } }", context: { current_user: :reader }).to_h
    puts "3a refused user gets: #{served}; authorized? owner: #{conn.method(:authorized?).owner}"
    expect(served.dig("data", "items", "total")).to eq(1)
    expect(foreign(audit(schema))).to include("VfyChildConnection.total")
  end

  it "[security] 3b parent rule with no policy at all" do
    k = kit
    conn = direct_child_conn(k, parent_policy: nil)
    expect(foreign(audit(schema_for(query_for(k[:object], conn))))).to include("VfyChildConnection.total")
  end

  it "[security] 3c a rule on an interface the connection implements" do
    k = kit
    f = k[:field]
    iface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "VfyCounted"
      field_class f
      field :counted, Integer, null: true, authorize: :manage
    end
    conn = direct_child_conn(k, parent_policy: VfyStrictPolicy) { implements iface }
    expect(foreign(audit(schema_for(query_for(k[:object], conn))))).to include("VfyChildConnection.counted")
  end

  it "[security] 3d a rule on an input object's argument of a connection field" do
    k = kit
    plugin = k[:plugin]
    arg = Class.new(GraphQL::Schema::Argument) { include plugin::Base }
    input = Class.new(GraphQL::Schema::InputObject) do
      graphql_name "VfyFilter"
      argument_class arg
      argument :secret, String, required: false, authorize: :manage, model: VfyItem
    end
    conn = direct_child_conn(k, parent_policy: VfyStrictPolicy) do
      field :filtered, Integer, null: true do
        argument :filter, input, required: false
      end
    end
    expect(foreign(audit(schema_for(query_for(k[:object], conn)))).join).to include("VfyChildConnection.filtered")
  end

  it "[security] 3e an edge subclass naming policy: over a parent's rule" do
    k = kit
    f = k[:field]
    plugin = k[:plugin]
    item = k[:item]
    parent = Class.new(GraphQL::Types::Relay::BaseEdge) do
      include plugin::Base
      field_class f
      graphql_name "VfyParentEdge"
      authorize :read, policy: VfyLaxPolicy
      field :weight, Integer, null: true, authorize: :manage, **VFY_LEGACY
      def weight = 7
    end
    edge = Class.new(parent) do
      graphql_name "VfyChildEdge"
      authorize :read, policy: VfyStrictPolicy
      node_type(item)
    end
    conn = Class.new(GraphQL::Types::Relay::BaseConnection) do
      graphql_name "VfyEdgeConnection"
      edge_type(edge)
    end
    schema = schema_for(query_for(k[:object], conn))
    served = execute_query(schema, "{ items { edges { weight } } }", context: { current_user: :reader }).to_h
    puts "3e refused user gets: #{served}; authorized? owner: #{edge.method(:authorized?).owner}"
    expect(foreign(audit(schema))).to include("VfyChildEdge.weight")
  end

  it "[security] 3f a PageInfo subclass naming policy: over a parent's rule" do
    k = kit
    f = k[:field]
    plugin = k[:plugin]
    parent = Class.new(GraphQL::Types::Relay::PageInfo) do
      include plugin::Base
      field_class f
      graphql_name "VfyParentPageInfo"
      authorize :read, policy: VfyLaxPolicy
      field :secret_count, Integer, null: true, authorize: :manage
    end
    page_info = Class.new(parent) do
      graphql_name "VfyChildPageInfo"
      authorize :read, policy: VfyStrictPolicy
    end
    conn = direct_child_conn(k, parent_policy: VfyStrictPolicy) { field :my_page_info, page_info, null: true }
    expect(foreign(audit(schema_for(query_for(k[:object], conn))))).to include("VfyChildPageInfo.secretCount").or include("VfyChildPageInfo.secret_count")
  end

  it "[security] 3g a generated connection through connection_type_class" do
    k = kit
    f = k[:field]
    plugin = k[:plugin]
    parent = Class.new(GraphQL::Types::Relay::BaseConnection) do
      include plugin::Base
      field_class f
      graphql_name "VfyGenParentConnection"
      authorize :read, policy: VfyLaxPolicy
      field :total, Integer, null: true, authorize: :manage, **VFY_LEGACY
    end
    child = Class.new(parent) do
      graphql_name "VfyGenChildConnection"
      authorize :read, policy: VfyStrictPolicy
    end
    item = Class.new(k[:object]) do
      graphql_name "VfyGenItem"
      authorize :read, policy: VfyLaxPolicy, model: VfyItem
      field :name, String, null: true
      connection_type_class(child)
    end
    report = audit(schema_for(query_for(k[:object], item.connection_type)))
    puts "3g reports: #{foreign(report)}"
    expect(foreign(report).join).to include(".total")
  end

  it "[preservation] 3h a connection naming policy: with its rule on itself is clean, and refuses" do
    k = kit
    f = k[:field]
    plugin = k[:plugin]
    edge = k[:edge]
    conn = Class.new(GraphQL::Types::Relay::BaseConnection) do
      include plugin::Base
      field_class f
      graphql_name "VfyOwnConnection"
      authorize :read, policy: VfyStrictPolicy
      edge_type(edge)
      field :total, Integer, null: true, authorize: :manage, **VFY_LEGACY
      define_method(:total) { object.items.size }
      field :flagged, Integer, null: true, authorize: true, **VFY_LEGACY
      define_method(:flagged) { 1 }
      field :counted, Integer, null: true do
        argument :limit, Integer, required: false
      end
      define_method(:counted) { |limit: nil| 2 }
    end
    schema = schema_for(query_for(k[:object], conn))
    expect(foreign(audit(schema))).to eq([])
    refused = execute_query(schema, "{ items { total } }", context: { current_user: :reader }).to_h
    admin = execute_query(schema, "{ items { total } }", context: { current_user: :admin }).to_h
    puts "3h reader: #{refused}; admin: #{admin}; owner: #{conn.method(:authorized?).owner}"
    expect(refused.dig("data", "items", "total")).to be_nil
    expect(admin.dig("data", "items", "total")).to eq(1)
  end

  it "[preservation] 3i a child that inherits the policy: is clean" do
    k = kit
    parent = direct_child_conn(k, parent_policy: VfyStrictPolicy, child_policy: nil)
    expect(foreign(audit(schema_for(query_for(k[:object], parent))))).to eq([])
  end

  it "[security] 3j the install template (ConnectionBehaviors) naming policy: is not silent" do
    k = kit
    edge = k[:edge]
    tpl = Class.new(k[:object]) do
      graphql_name "VfyTemplate"
      include GraphQL::Types::Relay::ConnectionBehaviors
      authorize :read, policy: VfyLaxPolicy
      field :total, Integer, null: true, authorize: :manage, **VFY_LEGACY
      define_method(:total) { object.items.size }
    end
    conn = Class.new(tpl) do
      graphql_name "VfyTemplateChildConnection"
      authorize :read, policy: VfyStrictPolicy
      edge_type(edge)
    end
    schema = schema_for(query_for(k[:object], conn))
    report = audit(schema)
    served = execute_query(schema, "{ items { total } }", context: { current_user: :reader }).to_h
    puts "3j kinds: #{report.problems.map { |p| [p.kind, p.path] }}; reader: #{served}; owner: #{conn.method(:authorized?).owner}"
    expect(report.problems.map(&:path).join).to include("VfyTemplateChildConnection")
  end

  it "[security] 3k the template with Base included after the behaviours" do
    k = kit
    f = k[:field]
    plugin = k[:plugin]
    edge = k[:edge]
    tpl = Class.new(GraphQL::Schema::Object) do
      graphql_name "VfyLateTemplate"
      field_class f
      include GraphQL::Types::Relay::ConnectionBehaviors
      include plugin::Base
      authorize :read, policy: VfyLaxPolicy
      field :total, Integer, null: true, authorize: :manage, **VFY_LEGACY
    end
    conn = Class.new(tpl) do
      graphql_name "VfyLateChildConnection"
      authorize :read, policy: VfyStrictPolicy
      edge_type(edge)
    end
    report = audit(schema_for(query_for(k[:object], conn)))
    puts "3k kinds: #{report.problems.map { |p| [p.kind, p.path] }}"
    expect(foreign(report)).to include("VfyLateChildConnection.total")
  end

  it "[preservation] 3l a connection without Base has no armory_rule and the audit does not crash" do
    k = kit
    edge = k[:edge]
    conn = Class.new(GraphQL::Types::Relay::BaseConnection) do
      graphql_name "VfyPlainConnection"
      edge_type(edge)
    end
    expect(foreign(audit(schema_for(query_for(k[:object], conn))))).to eq([])
  end

  it "[security] 4a filter: a bypassed connection naming policy: still gets checked" do
    k = kit
    f = k[:field]
    plugin = k[:plugin]
    edge = k[:edge]
    parent = Class.new(GraphQL::Types::Relay::BaseConnection) do
      include plugin::Base
      field_class f
      graphql_name "VfyBypassParentConnection"
      authorize :read, policy: VfyLaxPolicy
      field :total, Integer, null: true, authorize: :manage, **VFY_LEGACY
    end
    conn = Class.new(parent) do
      graphql_name "VfyBypassChildConnection"
      authorize :none, reason: "r", covers_fields: true, policy: VfyStrictPolicy
      edge_type(edge)
    end
    expect(foreign(audit(schema_for(query_for(k[:object], conn))))).to include("VfyBypassChildConnection.total")
  end

  it "[security] 4b filter: a visible_when: on the parent counts as a rule" do
    k = kit
    f = k[:field]
    plugin = k[:plugin]
    edge = k[:edge]
    parent = Class.new(GraphQL::Types::Relay::BaseConnection) do
      include plugin::Base
      field_class f
      graphql_name "VfyVisParentConnection"
      authorize :read, policy: VfyLaxPolicy
      field :total, Integer, null: true, visible_when: :manage, **VFY_LEGACY
    end
    conn = Class.new(parent) do
      graphql_name "VfyVisChildConnection"
      authorize :read, policy: VfyStrictPolicy
      edge_type(edge)
    end
    expect(foreign(audit(schema_for(query_for(k[:object], conn))))).to include("VfyVisChildConnection.total")
  end

  it "[preservation] 4c filter: model: resolving to the same policy is not a clean pass that serves" do
    k = kit
    conn = direct_child_conn(k, parent_policy: nil, child_policy: nil)
    f = k[:field]
    edge = k[:edge]
    parent = conn.superclass
    named = Class.new(parent) do
      graphql_name "VfyModelConnection"
      field_class f
      authorize :read, policy: VfyTopThingPolicy, model: VfyTopThing
      edge_type(edge)
    end
    schema = schema_for(query_for(k[:object], named))
    report = audit(schema)
    result = nil
    error = caught { result = execute_query(schema, "{ items { total } }", context: { current_user: :reader }).to_h }
    puts "4c foreign: #{foreign(report)}; result: #{result}; error: #{error&.class}"
    expect(result.to_h.dig("data", "items", "total")).to be_nil
  end



  # ---- dump for the no-false-alarm diff between A and B

  it "[preservation] 3z reports of a Relay schema with no policy: are dumped for the diff" do
    plugin = armory
    fld = Class.new(GraphQL::Schema::Field) { include plugin::Base }
    object = Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class fld
      default_action :read
    end
    template_edge = Class.new(object) do
      graphql_name "TemplateEdge"
      include GraphQL::Types::Relay::EdgeBehaviors
    end
    template_conn = Class.new(object) do
      graphql_name "TemplateConnection"
      include GraphQL::Types::Relay::ConnectionBehaviors
    end
    node = GraphQL::Types::Relay::Node
    template_item = Class.new(object) do
      graphql_name "TemplateItem"
      edge_type_class(template_edge)
      connection_type_class(template_conn)
      authorize :read, policy: VfyLaxPolicy, model: VfyItem
      implements node
      field :name, String, null: true
    end
    relay_edge = Class.new(GraphQL::Types::Relay::BaseEdge) do
      graphql_name "DirectEdge"
      node_type(template_item)
    end
    relay_conn = Class.new(GraphQL::Types::Relay::BaseConnection) do
      include plugin::Base
      field_class fld
      graphql_name "DirectConnection"
      edge_type(relay_edge)
      field :total, Integer, null: true, authorize: :manage, **VFY_LEGACY
    end
    edge_only = Class.new(GraphQL::Types::Relay::BaseEdge) do
      include plugin::Base
      field_class fld
      graphql_name "RuledEdge"
      authorize :read
      node_type(template_item)
    end
    nodes_conn = Class.new(GraphQL::Types::Relay::BaseConnection) do
      graphql_name "NodesConnection"
      edge_type(edge_only)
    end
    root = Class.new(object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :generated, template_item.connection_type, null: true, authorize: :none, reason: "r"
      field :direct, relay_conn, null: true, connection: true, authorize: :none, reason: "r"
      field :nodes_one, nodes_conn, null: true, connection: true, authorize: :none, reason: "r"
      field :edge, template_item.edge_type, null: true, authorize: :none, reason: "r"
    end
    relay = schema_for(root)
    dump = audit(relay).to_s
    dump2 = audit(IntegrationSchema.build(on_unauthorized: :null, sinks: [])).to_s
    expect(foreign(audit(relay))).to eq([])
  end
end
