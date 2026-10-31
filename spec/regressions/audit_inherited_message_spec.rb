# frozen_string_literal: true

require "spec_helper"
require "graphql/armory/authorization/adapters/pundit"

class ArmProbeDoc
  def notes = "SECRET"
end

class ArmProbeDocPolicy
  def initialize(user, record) = (@user = user; @record = record)
  def read? = true
  def manage? = true
  class Scope; def initialize(*); end; def resolve = []; end
end

class ArmProbeStrictPolicy
  def initialize(user, record) = (@user = user; @record = record)
  def read? = @user == :allowed
  def manage? = @user == :allowed
  class Scope; def initialize(*); end; def resolve = []; end
end

class ArmProbeInvoice; end
ArmProbeInvoicePolicy = Class.new(ArmProbeStrictPolicy)

module ArmProbe; end

RSpec.describe "PROBES: inherited-field audit message" do
  new_text = "Give it authorize: where it is defined, or remove it"
  let(:new_text) { new_text }
  let(:armory) { GraphQL::Armory::Authorization }
  let(:base_field) { plugin = armory; Class.new(GraphQL::Schema::Field) { include plugin::Base } }
  let(:base_object) do
    plugin = armory
    fk = base_field
    Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class fk
      default_action :read
      # Fixture only: Execution::Next asks an owner's graphql_name, and these parents are anonymous and outside the schema.
      def self.default_graphql_name = "Anon#{object_id}"
    end
  end
  let(:root_type) do
    bo = base_object
    lambda do |child|
      Class.new(bo) do
        graphql_name "Query"
        authorize :none, reason: "root"
        field :doc, child, null: true, authorize: :none, reason: "r"
      end
    end
  end

  def obs(*parts) = puts("OBS[#{ArmoryEngine.current}/#{GraphQL::VERSION}] #{parts.map(&:to_s).join(' | ')}")

  def substitute(allow) = armory::Adapters::Substitute.new(allow: allow)

  def schema_on(root, adapter)
    plugin = armory
    Class.new(base_schema) do
      query root
      use plugin, adapter: adapter
    end
  end

  def schema_of(child, adapter) = schema_on(root_type.(child), adapter)

  def doc_root(object = Struct.new(:notes).new("SECRET")) = Struct.new(:doc).new(object)

  def ask(schema, query: "{ doc { notes } }", root: doc_root, user: :someone)
    execute_query(schema, query, root_value: root, context: { current_user: user }).to_h
  rescue StandardError => error
    { "raised" => "#{error.class}: #{error.message}" }
  end

  def findings(schema, path = "Doc.notes")
    armory::Audit.(schema).problems.select { |problem| problem.path == path }
  end

  # Unadvised: the message asks for the fix and tells the truth. Advised: cleared, refused gets nothing, allowed gets it.
  def follow_advice(shape)
    before = schema_of(shape.({}), substitute(false))
    problem = findings(before).first
    expect(problem.message).to include(new_text)
    expect(problem.kind).to eq(:field_without_rule)
    expect(ask(before).dig("data", "doc", "notes")).to eq("SECRET")

    advised = shape.({ authorize: :read })
    refused = schema_of(advised, substitute(false))
    expect(findings(refused)).to eq([])
    expect(ask(refused).dig("data", "doc", "notes")).to be_nil
    expect(ask(schema_of(advised, substitute(true))).dig("data", "doc", "notes")).to eq("SECRET")
  end

  def child_of(parent, covers: false)
    Class.new(parent) do
      graphql_name "Doc"
      authorize :none, reason: "public", covers_fields: covers
    end
  end

  let(:one_up) do
    bo = base_object
    outer = self
    lambda { |opts| parent = Class.new(bo) { authorize :read; field :notes, String, null: true, **opts }; outer.child_of(parent) }
  end

  it "[security] S1a owner one level up with a rule" do
    follow_advice(one_up)
  end

  it "[security] S1b owner :none covers_fields: true" do
    bo = base_object
    follow_advice(lambda { |opts| parent = Class.new(bo) { authorize :none, reason: "c", covers_fields: true; field :notes, String, null: true, **opts }; child_of(parent) })
  end

  it "[security] S1c owner two levels up, named in the message" do
    bo = base_object
    shape = lambda do |opts|
      gp = Class.new(bo) { authorize :read; field :notes, String, null: true, **opts }
      ArmProbe.const_set("Gp#{rand(10**9)}", gp)
      child_of(Class.new(gp))
    end
    follow_advice(shape)
    expect(findings(schema_of(shape.({}), substitute(false))).first.message).to include("inherited from ArmProbe::Gp")
  end

  it "[security] S1d owner without Base, field class with Base" do
    fk = base_field
    plugin = armory
    shape = lambda do |opts|
      plain = Class.new(GraphQL::Schema::Object) { field_class fk; field :notes, String, null: true, **opts }
      Class.new(plain) { include plugin::Base; graphql_name "Doc"; authorize :none, reason: "public" }
    end
    follow_advice(shape)
  end

  it "[preservation] K1e owner and field class without Base: other message, and authorize: cannot be given there" do
    plugin = armory
    plain = Class.new(GraphQL::Schema::Object) { field :notes, String, null: true }
    child = Class.new(plain) { include plugin::Base; graphql_name "Doc"; authorize :none, reason: "public" }
    schema = schema_of(child, substitute(false))
    expect(findings(schema).map(&:message)).to eq(["its field class does not include Base, so no rule runs on it: its type is bypassed and graphql-ruby's own " \
                                                   "authorized? answers true, so the field is served with no check. Use a field class that includes Base"])
    expect(ask(schema).dig("data", "doc", "notes")).to eq("SECRET")
    expect { Class.new(GraphQL::Schema::Object) { field :notes, String, null: true, authorize: :read } }.to raise_error(ArgumentError)
  end

  def root_shape(parent_body)
    bo = base_object
    lambda do |opts|
      base = Class.new(bo) do
        class_exec(&parent_body)
        field :notes, String, null: true, **opts
        def notes = "SECRET"
      end
      Class.new(base) { graphql_name "Query"; authorize :none, reason: "root" }
    end
  end

  # Execution::Next reads the object, not a `def notes` on the type: the Interpreter keeps the usual nil root.
  def legacy_root = ArmoryEngine.next? ? Struct.new(:notes).new("SECRET") : nil

  def follow_advice_on_root(shape)
    before = schema_on(shape.({}), substitute(false))
    problem = findings(before, "Query.notes").first
    expect(problem.message).to include(new_text)
    expect(ask(before, query: "{ notes }", root: legacy_root).dig("data", "notes")).to eq("SECRET")
    refused = schema_on(shape.({ authorize: :read }), substitute(false))
    expect(findings(refused, "Query.notes")).to eq([])
    expect(ask(refused, query: "{ notes }", root: legacy_root).dig("data", "notes")).to be_nil
    allowed = ask(schema_on(shape.({ authorize: :read }), substitute(true)), query: "{ notes }", root: legacy_root)
    obs("root allowed (Substitute)", allowed)
    expect(allowed.dig("data", "notes")).to eq("SECRET")
  end

  it "[security] S1f bypassed Query root inherits from a base query with a rule" do
    follow_advice_on_root(root_shape(proc { authorize :read }))
  end

  it "[security] S1g bypassed root inherits a field defined on the base object (default_action)" do
    follow_advice_on_root(root_shape(proc {}))
  end



  it "[security] S2a abstract parent with no model constant: advice brings no :model problem and no crash" do
    bo = base_object
    parent = Class.new(bo) { authorize :read; field :notes, String, null: true, authorize: :read }
    schema = schema_of(child_of(parent), :pundit)
    problems = armory::Audit.(schema).problems
    obs("S2a problems", problems.map(&:to_s))
    expect(problems.map(&:kind)).not_to include(:model)
    expect(findings(schema)).to eq([])
  end

  it "[security] S2b Pundit, parent with model:, child wraps an object with no policy: refused gets nothing" do
    bo = base_object
    parent = Class.new(bo) { authorize :read, model: ArmProbeInvoice; field :notes, String, null: true, authorize: :read }
    schema = schema_of(child_of(parent), :pundit)
    expect(findings(schema)).to eq([])
    result = ask(schema)
    obs("S2b refused", result)
    # Not result.to_s: Pundit's NotDefinedError message carries the record's inspect, which is the Struct here.
    expect(result.dig("data", "doc", "notes")).to be_nil
  end


  it "[security] S2c parent with policy:, advised bare authorize: must not ask a laxer policy" do
    bo = base_object
    parent = Class.new(bo) { authorize :read, policy: ArmProbeStrictPolicy, model: ArmProbeDoc; field :notes, String, null: true, authorize: :read }
    schema = schema_of(child_of(parent), :pundit)
    expect(findings(schema)).to eq([])
    result = ask(schema, root: doc_root(ArmProbeDoc.new), user: :refused)
    obs("S2c refused-by-Strict", result)
    expect(result.dig("data", "doc", "notes")).to be_nil
  end

  it "[security] S2c2 cause control: no bypass, field action on a type with policy: which policy answers?" do
    bo = base_object
    ArmProbe.const_set(:LaxRead, Class.new(ArmProbeStrictPolicy) { def read? = true }) unless defined?(ArmProbe::LaxRead)
    lr = ArmProbe::LaxRead
    type = Class.new(bo) { graphql_name "Doc"; authorize :read, policy: lr, model: ArmProbeDoc; field :notes, String, null: true, authorize: :manage }
    result = ask(schema_of(type, :pundit), root: doc_root(ArmProbeDoc.new), user: :refused)
    obs("S2c2 no bypass", result)
    expect(result.dig("data", "doc", "notes")).to be_nil
  end

  it "[security] S2c3 parent with policy:, authorize: true keeps the policy" do
    bo = base_object
    parent = Class.new(bo) { authorize :read, policy: ArmProbeStrictPolicy, model: ArmProbeDoc; field :notes, String, null: true, authorize: true }
    result = ask(schema_of(child_of(parent), :pundit), root: doc_root(ArmProbeDoc.new), user: :refused)
    obs("S2c3", result)
    expect(result.dig("data", "doc", "notes")).to be_nil
  end

  it "[security] S2d advice with a misspelled action: refused gets nothing, audit says?" do
    bo = base_object
    parent = Class.new(bo) { authorize :read, model: ArmProbeDoc; field :notes, String, null: true, authorize: :raed }
    schema = schema_of(child_of(parent), :pundit)
    obs("S2d audit", armory::Audit.(schema).problems.map(&:to_s))
    result = ask(schema, root: doc_root(ArmProbeDoc.new))
    obs("S2d refused", result)
    expect(result.to_s).not_to include("SECRET")
  end

  it "[preservation] K3a remove it from the parent: no data, a validation error, audit clean" do
    bo = base_object
    parent = Class.new(bo) { authorize :read; field :other, String, null: true, authorize: :read }
    schema = schema_of(child_of(parent), substitute(false))
    expect(findings(schema)).to eq([])
    result = ask(schema)
    obs("K3a", result)
    expect(result.to_s).not_to include("SECRET")
    expect(result["errors"]).not_to be_nil
  end

  it "[preservation] K3b remove it and redeclare with no rule on the child: denied, as the audit says" do
    bo = base_object
    parent = Class.new(bo) { authorize :read }
    child = Class.new(parent) { graphql_name "Doc"; authorize :none, reason: "public"; field :notes, String, null: true }
    [false, true].each do |allow|
      schema = schema_of(child, substitute(allow))
      expect(findings(schema).first.message).to eq("declares no rule and its type is bypassed, so it is denied")
      expect(ask(schema).dig("data", "doc", "notes")).to be_nil
    end
  end

  it "[security] S3c fixing only the nearest definition does not clear; grandparent is named" do
    bo = base_object
    gp = Class.new(bo) { authorize :read; field :notes, String, null: true }
    ArmProbe.const_set(:GrandOwner, gp)
    parent = Class.new(gp) { authorize :read; field :notes, String, null: true, authorize: :read }
    schema = schema_of(child_of(parent), substitute(false))
    problems = findings(schema)
    obs("S3c problems", problems.map(&:to_s), "refused", ask(schema))
    served = problems.select { |problem| problem.kind == :field_without_rule }
    expect(served.first.message).to include(new_text, "ArmProbe::GrandOwner")
    expect(ask(schema).dig("data", "doc", "notes")).to be_nil
  end

  it "[security] S4a no rule ran on this type: the adapter is asked nothing, until the advice" do
    adapter = substitute(false)
    schema = schema_of(one_up.({}), adapter)
    expect(findings(schema).first.message).to include("no rule ran on this type", new_text)
    ask(schema)
    expect(adapter.asked).to eq([])
    advised = substitute(false)
    ask(schema_of(one_up.({ authorize: :read }), advised))
    expect(advised.asked.map { |(_, _, rule)| rule.action }).to eq([:read])
  end

  it "[security] S4b field returning a type with a rule: is 'served with no check' true?" do
    bo = base_object
    secret = Class.new(bo) { graphql_name "Secret"; authorize :read; field :v, String, null: true }
    parent = Class.new(bo) { authorize :read; field :notes, secret, null: true }
    schema = schema_of(child_of(parent), substitute(false))
    expect(findings(schema).first.message).to include(new_text)
    result = ask(schema, query: "{ doc { notes { v } } }", root: doc_root(Struct.new(:notes).new(Struct.new(:v).new("SECRET"))))
    obs("S4b", result)
    expect(result.to_s).not_to include("SECRET")
  end



  it "[security] S4d2 authorize: true on an owner with a rule: refused gets nothing, allowed gets it" do
    expect(ask(schema_of(one_up.({ authorize: true }), substitute(false))).dig("data", "doc", "notes")).to be_nil
    expect(ask(schema_of(one_up.({ authorize: true }), substitute(true))).dig("data", "doc", "notes")).to eq("SECRET")
    expect(findings(schema_of(one_up.({}), substitute(false))).first.message).to include(new_text)
  end

  it "[security] S4e authorize: true on a covers_fields owner: nobody gets it" do
    bo = base_object
    parent = Class.new(bo) { authorize :none, reason: "c", covers_fields: true; field :notes, String, null: true, authorize: true }
    schema = schema_of(child_of(parent), substitute(true))
    obs("S4e", findings(schema).map(&:message), ask(schema))
    expect(ask(schema).dig("data", "doc", "notes")).to be_nil
    expect(findings(schema_of(one_up.({}), substitute(false))).first.message).to include(new_text)
  end

  it "[security] S4f authorize: 'read' (String) behaves as the Symbol" do
    follow_advice(lambda { |opts| one_up.(opts[:authorize] ? { authorize: "read" } : {}) })
  end

  it "[security] S4f2 authorize: false: no finding must not mean silently served" do
    schema = schema_of(one_up.({ authorize: false }), substitute(false))
    result = ask(schema)
    obs("S4f2", findings(schema).map(&:message), result)
    expect(result.to_s).not_to include("SECRET")
    expect(findings(schema_of(one_up.({}), substitute(false))).first.message).to include(new_text)
  end

  it "[preservation] K4g child with covers_fields: true is not bypassed for the audit" do
    bo = base_object
    parent = Class.new(bo) { authorize :read; field :notes, String, null: true }
    schema = schema_of(child_of(parent, covers: true), substitute(false))
    obs("K4g", findings(schema).map(&:message), ask(schema))
    expect(findings(schema)).to eq([])
  end

  it "[preservation] K5c kind and path of the finding, and the sentence around the change" do
    problem = findings(schema_of(one_up.({}), substitute(false))).first
    expect([problem.kind, problem.path]).to eq([:field_without_rule, "Doc.notes"])
    expect(problem.message).to start_with("declares no rule and its type is bypassed, but it is inherited from ")
    expect(problem.message).to include("so the field is served with no check")
  end

  it "[preservation] K5d dump one mixed report per configuration to diff against the other copy" do
    plugin = armory
    fk = base_field
    bo = base_object
    ArmProbe.const_set(:Dump, Module.new) unless defined?(ArmProbe::Dump)
    define = lambda { |name, klass| ArmProbe::Dump.const_set(name, klass); klass }

    rule_owner = define.(:RuleOwner, Class.new(bo) { authorize :read; field :a, String, null: true })
    covers_owner = define.(:CoversOwner, Class.new(bo) { authorize :none, reason: "c", covers_fields: true; field :b, String, null: true })
    none_owner = define.(:NoneOwner, Class.new(bo) { authorize :none, reason: "n"; field :c, String, null: true })
    plain_owner = define.(:PlainOwner, Class.new(GraphQL::Schema::Object) { field_class fk; field :d, String, null: true })
    plain_field = define.(:PlainField, Class.new(GraphQL::Schema::Object) { field :e, String, null: true })
    subclass = lambda do |parent, name|
      Class.new(parent) do
        include plugin::Base unless respond_to?(:armory_rule)
        graphql_name name
        authorize :none, reason: "b #{name}"
      end
    end
    types = { rule: subclass.(rule_owner, "T1"), covers: subclass.(covers_owner, "T2"), none: subclass.(none_owner, "T3"),
              plain: subclass.(plain_owner, "T4"), plain_field: subclass.(plain_field, "T5"),
              grand: subclass.(define.(:Middle, Class.new(rule_owner)), "T6"),
              ruled: Class.new(rule_owner) { graphql_name "T7"; field :own, String, null: true, authorize: :manage } }
    unprotected = Class.new(GraphQL::Schema::Object) { graphql_name "T8"; field :f, String, null: true }
    root = Class.new(bo) do
      graphql_name "Query"
      authorize :none, reason: "root"
      types.each { |name, type| field name, type, null: true, authorize: :none, reason: "r" }
      field :open, unprotected, null: true, authorize: :none, reason: "r"
      field :typed, String, null: true, authorize: true
    end
    text = armory::Audit.(schema_on(root, substitute(false))).to_s
    expect(text).to include("T1.a")
  end
end
