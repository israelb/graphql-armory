# frozen_string_literal: true

# A rule on a field or argument asks another question of the type's policy. A `policy:` on the type used to be dropped,
# so Pundit asked the policy found from the record instead, which may answer differently.
class ArmoryPolicyDoc
  def notes(**) = "SECRET"
end

class ArmoryPolicyDocPolicy
  class Scope
    def initialize(_user, scope) = @scope = scope
    def resolve = @scope
  end

  def initialize(_user, _record); end
  def read? = true
  def manage? = true
end

class ArmoryStrictDocPolicy < ArmoryPolicyDocPolicy
  def initialize(user, _record) = @user = user
  def manage? = @user == :admin
end

class ArmoryNoManagePolicy
  class Scope
    def initialize(_user, scope) = @scope = scope
    def resolve = @scope
  end

  def initialize(_user, _record); end
  def read? = true
end

RSpec.describe "a field or argument rule under the type's policy:" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:base_argument) do
    plugin = armory
    Class.new(GraphQL::Schema::Argument) { include plugin::Base }
  end
  let(:base_field) do
    plugin = armory
    argument = base_argument
    Class.new(GraphQL::Schema::Field) do
      include plugin::Base
      argument_class argument
    end
  end
  let(:base_object) do
    plugin = armory
    field = base_field
    Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class field
    end
  end

  def doc_type(**rule, &block)
    Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: ArmoryPolicyDoc, **rule
      class_eval(&block)
    end
  end

  def schema_of(type)
    plugin = armory
    query_class = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :doc, type, null: true, authorize: :none, reason: "x"
    end
    Class.new(base_schema) do
      use plugin, adapter: :pundit
      query query_class
    end
  end

  def ask(schema, query, user)
    root = Struct.new(:doc).new(ArmoryPolicyDoc.new)
    execute_query(schema, query, root_value: root, context: { current_user: user }).to_h
  end

  it "asks the type's policy for a field's authorize:" do
    schema = schema_of(doc_type(policy: ArmoryStrictDocPolicy) { field :notes, String, null: true, authorize: :manage })

    expect(ask(schema, "{ doc { notes } }", :someone).dig("data", "doc", "notes")).to be_nil
    expect(ask(schema, "{ doc { notes } }", :admin).dig("data", "doc", "notes")).to eq("SECRET")
  end

  it "asks the parent's policy for a field a bypassed type inherits" do
    field_klass = base_field
    parent = Class.new(base_object) do
      field_class field_klass
      authorize :read, policy: ArmoryStrictDocPolicy, model: ArmoryPolicyDoc
      field :notes, String, null: true, authorize: :manage
    end
    child = Class.new(parent) do
      graphql_name "Doc"
      authorize :none, reason: "public"
    end

    expect(ask(schema_of(child), "{ doc { notes } }", :someone).dig("data", "doc", "notes")).to be_nil
  end

  it "asks the type's policy for a field's visible_when:" do
    schema = schema_of(doc_type(policy: ArmoryStrictDocPolicy) { field :notes, String, null: true, visible_when: :manage })

    expect(ask(schema, "{ doc { notes } }", :someone)["errors"]).not_to be_nil
    expect(ask(schema, "{ doc { notes } }", :admin).dig("data", "doc", "notes")).to eq("SECRET")
  end

  it "asks the type's policy for an argument's authorize: and visible_when:" do
    guarded = doc_type(policy: ArmoryStrictDocPolicy) do
      field :notes, String, null: true do
        argument :raw, GraphQL::Types::Boolean, required: false, authorize: :manage
      end
    end
    hidden = doc_type(policy: ArmoryStrictDocPolicy) do
      field :notes, String, null: true do
        argument :raw, GraphQL::Types::Boolean, required: false, visible_when: :manage
      end
    end

    expect(ask(schema_of(guarded), "{ doc { notes(raw: true) } }", :someone).dig("data", "doc", "notes")).to be_nil
    expect(ask(schema_of(guarded), "{ doc { notes(raw: true) } }", :admin).dig("data", "doc", "notes")).to eq("SECRET")
    expect(ask(schema_of(hidden), "{ doc { notes(raw: true) } }", :someone)["errors"]).not_to be_nil
  end

  it "audits the action against the type's policy" do
    declared = lambda { |**options| schema_of(doc_type(policy: ArmoryNoManagePolicy) { field :notes, String, null: true, **options }) }
    with_argument = schema_of(doc_type(policy: ArmoryNoManagePolicy) do
      field :notes, String, null: true do
        argument :raw, GraphQL::Types::Boolean, required: false, authorize: :manage
      end
    end)

    [declared.(authorize: :manage), declared.(visible_when: :manage), with_argument].each do |schema|
      expect(armory::Audit.(schema).problems.map(&:message)).to include(a_string_including("ArmoryNoManagePolicy#manage? is not defined"))
    end
  end

  it "keeps asking the record's policy when the type names none" do
    schema = schema_of(doc_type { field :notes, String, null: true, authorize: :manage })

    expect(ask(schema, "{ doc { notes } }", :someone).dig("data", "doc", "notes")).to eq("SECRET")
    expect(armory::Audit.(schema).problems).to eq([])
  end
end
