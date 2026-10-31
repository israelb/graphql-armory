# frozen_string_literal: true

require "spec_helper"
require "graphql/armory/authorization/adapters/pundit"
require "graphql/armory/authorization/adapters/cancan"

module PrbLog
  def self.asks = (@asks ||= [])
end

class PrbRel
  def initialize(items) = @items = items
  def find_by(_conditions) = @items.first
  def to_a = @items
end

class PrbInvoice
  def self.primary_key = :id
  def self.all = PrbRel.new([new])
  def id = 1
  def notes(**) = "SECRET"
end

class PrbBasePolicy
  class Scope
    def initialize(_user, scope) = @scope = scope
    def resolve = @scope
  end

  def initialize(user, record)
    @user = user
    @record = record
  end

  def self.action(name, &block)
    define_method(:"#{name}?") do
      PrbLog.asks << "#{self.class}##{name}?"
      instance_eval(&block)
    end
  end
end

# The policy Pundit finds from the record: answers yes to everything.
class PrbInvoicePolicy < PrbBasePolicy
  action(:read) { true }
  action(:manage) { true }
  action(:export) { true }
end

class PrbLaxPolicy < PrbInvoicePolicy; end

class PrbStrictPolicy < PrbBasePolicy
  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve = @user == :admin ? @scope : PrbRel.new([])
  end

  action(:read) { true }
  action(:manage) { @user == :admin }
  action(:export) { @user == :admin }
  action(:only_strict) { @user == :admin }
end

class PrbNoManagePolicy < PrbBasePolicy
  action(:read) { true }
end

class PrbAbility
  include CanCan::Ability
  def initialize(_user)
    can :read, PrbInvoice
    can :approve, PrbInvoice
  end
end

class PrbRoot
  attr_reader :record

  def initialize(record = PrbInvoice.new) = @record = record
  def doc = record
  def docs = [record]
  def conn = [record]
  def raw = { notes: "SECRET" }
  def loaded(doc: nil) = doc&.notes
end

RSpec.describe "RECHECK: field and argument rules under the type's policy:" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:ba) { plugin = armory; Class.new(GraphQL::Schema::Argument) { include plugin::Base } }
  let(:bf) do
    plugin = armory
    arg = ba
    Class.new(GraphQL::Schema::Field) do
      include plugin::Base
      argument_class arg
    end
  end
  let(:bo) do
    plugin = armory
    fk = bf
    Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class fk
      def self.default_graphql_name = "Anon#{object_id}"
    end
  end
  let(:bi) do
    plugin = armory
    arg = ba
    Class.new(GraphQL::Schema::InputObject) do
      include plugin::Base
      argument_class arg
      def self.default_graphql_name = "AnonIn#{object_id}"
    end
  end

  before { PrbLog.asks.clear }

  def obs(id, *parts) = puts("OBS[#{id}|#{ArmoryEngine.current}|#{GraphQL::VERSION}] #{parts.map { |part| part.to_s.gsub(/0x[0-9a-f]+/, "0x").gsub(/Anon\d+/, "Anon") }.join(' | ')}")

  def query_of(type = nil, extra: nil)
    base = bo
    Class.new(base) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :doc, type, null: true, authorize: :none, reason: "x" if type
      class_eval(&extra) if extra
    end
  end

  def schema_with(query_type, adapter: :pundit, dynamic: false, mutation_type: nil)
    plugin = armory
    Class.new(base_schema) do
      use plugin, adapter: adapter
      use GraphQL::Schema::Visibility, dynamic: true if dynamic
      query query_type
      mutation mutation_type if mutation_type
      def self.resolve_type(abstract, _object, _context) = abstract # only `loads:` of a concrete type asks here
    end
  end

  def schema_of(type, **options) = schema_with(query_of(type), **options)

  def ask(schema, query, user: :someone, root: PrbRoot.new, ability: nil)
    context = { current_user: user }
    context[:current_ability] = ability if ability
    execute_query(schema, query, root_value: root, context: context).to_h
  rescue StandardError => error
    { "raised" => "#{error.class}: #{error.message}" }
  end

  def audit(schema)
    armory::Audit.(schema).problems.map { |problem| "#{problem.kind} #{problem.path}: #{problem.message}" }
  rescue StandardError => error
    ["AUDIT RAISED #{error.class}: #{error.message}"]
  end

  def policed(policy = PrbStrictPolicy, action: :read, **rule, &block)
    base = bo
    Class.new(base) do
      graphql_name "Doc"
      authorize action, model: PrbInvoice, policy: policy, **rule
      class_eval(&block) if block
    end
  end

  def run(id, schema, query, path:)
    PrbLog.asks.clear
    refused = ask(schema, query)
    refused_asks = PrbLog.asks.dup
    PrbLog.asks.clear
    allowed = ask(schema, query, user: :admin)
    obs(id, "refused=#{refused.inspect}", "asked=#{refused_asks.uniq}", "admin=#{allowed.inspect}", "audit=#{audit(schema)}")
    [refused.dig("data", *path), allowed.dig("data", *path), refused_asks]
  end

  # P3: input objects have no rule.

  it "[preservation] P3b argument on an input object's class without model: is reported and fails closed" do
    arg_input = Class.new(bi) { graphql_name "Filter"; argument :raw, GraphQL::Types::Boolean, required: false, authorize: :manage }
    type = policed { field(:notes, String, null: true) { argument :filter, arg_input, required: false } }
    schema = schema_of(type)
    refused, = run("P3b", schema, "{ doc { notes(filter: { raw: true }) } }", path: %w[doc notes])
    expect(refused).to be_nil
  end

  # P4: resolvers and mutations.
  def resolver_of(policy: nil, plain: false, **argument_options, &block)
    plugin = armory
    arg = ba
    Class.new(GraphQL::Schema::Resolver) do
      include plugin::Base unless plain
      argument_class arg
      graphql_name "Via"
      type String, null: true
      authorize(:read, model: PrbInvoice, **(policy ? { policy: policy } : {})) unless plain
      argument :raw, GraphQL::Types::Boolean, required: false, **argument_options
      define_method(:resolve) { |**| "SECRET" }
      class_eval(&block) if block
    end
  end

  it "[security] P4 argument on a Base resolver with policy: asks it" do
    r = resolver_of(policy: PrbStrictPolicy, authorize: :manage)
    schema = schema_with(query_of(extra: proc { field :via, resolver: r }))
    refused, allowed, = run("P4", schema, "{ via(raw: true) }", path: %w[via])
    expect(refused).to be_nil
    expect(allowed).to eq("SECRET")
  end




  # P5: interfaces cannot include Base, so they have no rule and no policy.
  def interface_of(&block)
    fk = bf
    Module.new do
      include GraphQL::Schema::Interface
      field_class fk
      graphql_name "Documented"
      class_eval(&block)
    end
  end



  # P6: subclasses.
  def parent_of(policy, &block)
    base = bo
    rule = policy ? { policy: policy } : {}
    Class.new(base) do
      authorize :read, model: PrbInvoice, **rule
      class_eval(&block)
    end
  end

  def child_of(parent, policy)
    Class.new(parent) do
      graphql_name "Doc"
      authorize :read, model: PrbInvoice, policy: policy
    end
  end



  it "[preservation] P6c parent Strict, child Lax: the inherited field stays strict" do
    parent = parent_of(PrbStrictPolicy) { field :notes, String, null: true, authorize: :manage }
    refused, = run("P6c", schema_of(child_of(parent, PrbLaxPolicy)), "{ doc { notes } }", path: %w[doc notes])
    expect(refused).to be_nil
  end

  it "[security] P6d child redeclares the field: the child's policy answers" do
    parent = parent_of(PrbLaxPolicy) { field :notes, String, null: true, authorize: :manage }
    child = child_of(parent, PrbStrictPolicy)
    child.class_eval { field :notes, String, null: true, authorize: :manage, override_reason: "x" }
    refused, = run("P6d", schema_of(child), "{ doc { notes } }", path: %w[doc notes])
    expect(refused).to be_nil
  end

  it "[security] P6e child inherits parent's policy: with no rule of its own, field defined on the child" do
    parent = parent_of(PrbStrictPolicy) { field :other, String, null: true, authorize: :none, reason: "x" }
    child = Class.new(parent) { graphql_name "Doc"; field :notes, String, null: true, authorize: :manage }
    refused, = run("P6e", schema_of(child), "{ doc { notes } }", path: %w[doc notes])
    expect(refused).to be_nil
  end

  it "[security] P7 resolver field with its own authorize: on a Strict type" do
    r = resolver_of(plain: true)
    type = policed { field :via, resolver: r, authorize: :manage }
    refused, = run("P7", schema_of(type), "{ doc { via } }", path: %w[doc via])
    expect(refused).to be_nil
  end

  it "[security] P7b Base resolver field with its own authorize: on a Strict type" do
    r = resolver_of(policy: PrbLaxPolicy)
    type = policed { field :via, resolver: r, authorize: :manage }
    refused, = run("P7b", schema_of(type), "{ doc { via } }", path: %w[doc via])
    expect(refused).to be_nil
  end

  # P8: Schema::Visibility, dynamic: true.
  def field_names(schema, user)
    ask(schema, '{ __type(name: "Doc") { fields { name } } }', user: user).dig("data", "__type", "fields")&.map { |f| f["name"] }
  end

  it "[security] P8 field visible_when: under Visibility dynamic is hidden by the type's policy" do
    type = policed { field :open, String, null: true, authorize: :none, reason: "x"; field :notes, String, null: true, visible_when: :manage }
    schema = schema_of(type, dynamic: true)
    obs("P8", field_names(schema, :someone), field_names(schema, :admin), ask(schema, "{ doc { notes } }"))
    expect(field_names(schema, :someone)).not_to include("notes")
    expect(field_names(schema, :admin)).to include("notes")
    expect(ask(schema, "{ doc { notes } }").dig("data", "doc", "notes")).to be_nil
  end

  it "[security] P8b type visible_when: under Visibility dynamic, with policy:" do
    inner = policed(visible_when: :manage) { field :notes, String, null: true, authorize: :none, reason: "x" }
    schema = schema_of(inner, dynamic: true)
    seen = ask(schema, '{ __type(name: "Doc") { name } }')
    obs("P8b", seen, ask(schema, '{ __type(name: "Doc") { name } }', user: :admin), ask(schema, "{ doc { notes } }"))
    expect(seen.dig("data", "__type")).to be_nil
  end

  it "[security] P8c authorize: and visible_when: of one field both ask the type's policy" do
    type = policed { field :notes, String, null: true, authorize: :manage, visible_when: :export }
    schema = schema_of(type, dynamic: true)
    refused, allowed, asks = run("P8c", schema, "{ doc { notes } }", path: %w[doc notes])
    expect(refused).to be_nil
    expect(allowed).to eq("SECRET")
    expect(asks.grep(/PrbInvoicePolicy/)).to eq([])
  end

  it "[security] P8d argument visible_when: under Visibility dynamic is hidden by the type's policy" do
    type = policed { field(:notes, String, null: true) { argument :raw, GraphQL::Types::Boolean, required: false, visible_when: :manage } }
    schema = schema_of(type, dynamic: true)
    refused = ask(schema, "{ doc { notes(raw: true) } }")
    obs("P8d", refused, ask(schema, "{ doc { notes(raw: true) } }", user: :admin))
    expect(refused.dig("data", "doc", "notes")).to be_nil
    expect(ask(schema, "{ doc { notes(raw: true) } }", user: :admin).dig("data", "doc", "notes")).to eq("SECRET")
  end

  # P9: lists, connections, loads keep the type's policy.
  it "[security] P9 Array items are filtered by the type's policy, not the record's" do
    type = policed(action: :manage) { field :notes, String, null: true }
    q = query_of(extra: proc { field :docs, [type], null: false, authorize: :none, reason: "x" })
    refused, allowed, = run("P9", schema_with(q), "{ docs { notes } }", path: %w[docs])
    expect(refused).to eq([])
    expect(allowed).to eq([{ "notes" => "SECRET" }])
  end

  it "[security] P9b loads: goes through the type's policy Scope, not the record's" do
    type = policed { field :notes, String, null: true, authorize: :none, reason: "x" }
    q = query_of(extra: proc {
      field(:loaded, String, null: true, authorize: :none, reason: "x") { argument :doc_id, GraphQL::Types::ID, loads: type, as: :doc, required: true }
    })
    refused, allowed, = run("P9b", schema_with(q), '{ loaded(docId: "1") }', path: %w[loaded])
    expect(refused).to be_nil
    expect(allowed).to eq("SECRET")
  end

  it "[security] P9c connection nodes: item rule and a field rule both keep the type's policy" do
    type = policed { field :notes, String, null: true, authorize: :manage }
    q = query_of(extra: proc { field :conn, type.connection_type, null: true, authorize: :none, reason: "x" })
    refused, allowed, = run("P9c", schema_with(q), "{ conn { nodes { notes } } }", path: %w[conn nodes])
    expect(refused).to eq([{ "notes" => nil }])
    expect(allowed).to eq([{ "notes" => "SECRET" }])
  end

  # P10: forms of policy:.
  it "[preservation] P10 policy: as a Symbol: no data at runtime; report what the audit does" do
    type = policed(:PrbStrictPolicy) { field :notes, String, null: true, authorize: :manage }
    refused, = run("P10", schema_of(type), "{ doc { notes } }", path: %w[doc notes])
    expect(refused).to be_nil
  end

  it "[preservation] P10c policy: Symbol on a bypass, with a field rule" do
    type = Class.new(bo) { graphql_name "Doc"; authorize :none, reason: "x", policy: :PrbStrictPolicy, model: PrbInvoice; field :notes, String, null: true, authorize: :manage }
    refused, = run("P10c", schema_of(type), "{ doc { notes } }", path: %w[doc notes])
    expect(refused).to be_nil
  end

  # P11: CanCan.
  def cancan_ask(schema, query) = ask(schema, query, ability: PrbAbility.new(nil))
  def cancan_adapter = armory::Adapters::CanCan.new

  it "[preservation] P11 CanCan: a type with policy: refuses, field rule included, and the audit says so" do
    type = policed { field :notes, String, null: true, authorize: :approve }
    schema = schema_of(type, adapter: cancan_adapter)
    answer = cancan_ask(schema, "{ doc { notes } }")
    obs("P11", answer, audit(schema))
    expect(answer["raised"]).to include("policy: is a Pundit option")
    expect(audit(schema).join).to include("policy: is a Pundit option")
  end



  it "[preservation] P11d CanCan: a type with no policy: keeps working" do
    type = Class.new(bo) { graphql_name "Doc"; authorize :read, model: PrbInvoice; field :notes, String, null: true, authorize: :approve; field :denied, String, null: true, authorize: :destroy, method: :notes }
    schema = schema_of(type, adapter: cancan_adapter)
    answer = cancan_ask(schema, "{ doc { notes denied } }")
    obs("P11d", answer, audit(schema))
    expect(answer.dig("data", "doc")).to eq({ "notes" => "SECRET", "denied" => nil })
    expect(audit(schema)).to eq([])
  end

  # P12: no policy: same reports and results as B.
  it "[preservation] P12 dump of reports and results with no policy: (diff against B)" do
    plain = Class.new(bo) do
      graphql_name "Doc"
      authorize :read, model: PrbInvoice
      field :notes, String, null: true, authorize: :manage
      field :whole, String, null: true, authorize: true, method: :notes
      field :open, String, null: true, authorize: :none, reason: "o", method: :notes
      field(:arg, String, null: true, method: :notes) { argument :raw, GraphQL::Types::Boolean, required: false, authorize: :manage }
      field :vis, String, null: true, visible_when: :export, method: :notes
      field :typo, String, null: true, authorize: :nope, method: :notes
    end
    schema = schema_of(plain)
    puts "DUMP P12 #{audit(schema).sort}"
    puts "DUMP P12 #{ask(schema, '{ doc { notes whole open arg(raw: true) vis } }')}"
    puts "DUMP P12 typo #{ask(schema, '{ doc { typo } }')}"
    puts "DUMP P12 definition #{schema.to_definition(context: { armory_full_schema: true }).gsub(/\s+/, ' ')}"
    %i[pundit cancan].each do |adapter|
      built = IntegrationSchema.build(adapter: adapter)
      puts "DUMP P12 integration #{adapter} #{audit(built).sort.join(' || ').gsub(/0x[0-9a-f]+/, '0x')}"
    end
    expect(audit(schema).join).to include("#nope? is not defined")
  end

  it "[preservation] P12b authorize: true and :none under policy: answer the type's rule and the bypass" do
    type = policed(action: :manage) do
      field :whole, String, null: true, authorize: true, method: :notes
      field :open, String, null: true, authorize: :none, reason: "o", method: :notes
    end
    q = query_of(type)
    refused = ask(schema_with(q), "{ doc { whole open } }")
    allowed = ask(schema_with(q), "{ doc { whole open } }", user: :admin)
    obs("P12b", refused, allowed)
    expect(refused.dig("data", "doc")).to be_nil
    expect(allowed.dig("data", "doc")).to eq({ "whole" => "SECRET", "open" => "SECRET" })
  end

  it "[security] P12c a Hash parent (raw object) under policy: Strict, field rule" do
    type = policed { field :notes, String, null: true, authorize: :manage, hash_key: :notes }
    q = query_of(extra: proc { field :raw, type, null: true, authorize: :none, reason: "x" })
    refused, allowed, = run("P12c", schema_with(q), "{ raw { notes } }", path: %w[raw notes])
    expect(refused).to be_nil
    expect(allowed).to eq("SECRET")
  end

  # P13: who answers.
  it "[preservation] P13 armory_policy is the plugin's on the real classes" do
    obs("P13", bf.instance_method(:armory_policy).owner, ba.instance_method(:armory_policy).owner)
    expect(bf.instance_method(:armory_policy).owner).to eq(armory::Integration::Field)
    expect(ba.instance_method(:armory_policy).owner).to eq(armory::Integration::Argument)
  end


  it "[preservation] P13c field and argument classes without Base do not break audit or runtime" do
    type = Class.new(bo) do
      graphql_name "Doc"
      field_class GraphQL::Schema::Field
      authorize :read, model: PrbInvoice, policy: PrbStrictPolicy
      field(:notes, String, null: true) { argument :raw, GraphQL::Types::Boolean, required: false }
    end
    schema = schema_of(type)
    answer = ask(schema, "{ doc { notes(raw: true) } }")
    obs("P13c", answer, audit(schema))
    expect(answer.dig("data", "doc", "notes")).to eq("SECRET")
    expect(audit(schema).join).not_to include("NoMethodError")
  end

  it "[preservation] P14 no resolver, mutation or input class answers owner, so armory_policy reads the right thing" do
    answers = [GraphQL::Schema::Resolver, GraphQL::Schema::Mutation, GraphQL::Schema::RelayClassicMutation, GraphQL::Schema::InputObject, GraphQL::Schema::Directive, GraphQL::Schema::Object].map { |klass| [klass.name, klass.respond_to?(:owner)] }
    obs("P14", answers)
    expect(answers.map(&:last).uniq).to eq([false])
  end

  # P15: audit.
  it "[preservation] P15b an action only the type's policy has: audit clean and it runs" do
    type = policed { field :notes, String, null: true, authorize: :only_strict }
    schema = schema_of(type)
    refused, allowed, = run("P15b", schema, "{ doc { notes } }", path: %w[doc notes])
    expect(audit(schema)).to eq([])
    expect(refused).to be_nil
    expect(allowed).to eq("SECRET")
  end


end
