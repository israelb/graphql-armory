# frozen_string_literal: true

# The audit reads the model a type declares; the runtime read the record's class. Both must answer now, so neither
# a record of another class nor a subclass with a laxer policy serves a user the declared policy refuses.
class ArmoryDeclaredPolicyBase
  class Scope
    def initialize(_user, scope) = @scope = scope
    def resolve = @scope
  end

  def initialize(user, _record) = @user = user
end

class ArmoryDeclaredStrictBase < ArmoryDeclaredPolicyBase
  def read? = @user == :allowed
  def manage? = @user == :allowed
end

class ArmoryDeclaredLaxBase < ArmoryDeclaredPolicyBase
  def read? = true
  def manage? = true
end

class ArmoryDeclaredDoc
  def secret(**) = "SECRET"
end

class ArmoryDeclaredDocPolicy < ArmoryDeclaredStrictBase; end
class ArmoryDeclaredLaxSub < ArmoryDeclaredDoc; end
class ArmoryDeclaredLaxSubPolicy < ArmoryDeclaredLaxBase; end
class ArmoryDeclaredPlainSub < ArmoryDeclaredDoc; end

class ArmoryDeclaredPublic
  def secret(**) = "SECRET"
end

class ArmoryDeclaredPublicPolicy < ArmoryDeclaredLaxBase; end

class ArmoryDeclaredOpen
  def secret(**) = "SECRET"
end

class ArmoryDeclaredOpenPolicy < ArmoryDeclaredLaxBase; end
class ArmoryDeclaredStrictSub < ArmoryDeclaredOpen; end
class ArmoryDeclaredStrictSubPolicy < ArmoryDeclaredStrictBase; end

class ArmoryDeclaredNamed
  def secret(**) = "SECRET"
end

class ArmoryDeclaredNamedPolicy < ArmoryDeclaredStrictBase; end

RSpec.describe "the policy of the declared model and of the record's class" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:adapter) { armory::Adapters::Pundit.new }
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

  def type_of(model:, &block)
    Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: model
      block ? class_eval(&block) : field(:secret, String, null: true)
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

  def served(type, record, user, query = "{ doc { secret } }")
    root = Struct.new(:doc).new(record)
    execute_query(schema_of(type), query, root_value: root, context: { current_user: user }).to_h.dig("data", "doc", "secret")
  end

  it "does not serve a record of another class to a user the declared policy refuses" do
    type = type_of(model: ArmoryDeclaredDoc)

    expect(armory::Audit.(schema_of(type)).ok?).to be(true)
    expect(served(type, ArmoryDeclaredPublic.new, :someone)).to be_nil
    expect(served(type, ArmoryDeclaredPublic.new, :allowed)).to eq("SECRET")
  end

  it "does not serve a subclass with a laxer policy to a user the declared policy refuses" do
    type = type_of(model: ArmoryDeclaredDoc)

    expect(served(type, ArmoryDeclaredLaxSub.new, :someone)).to be_nil
    expect(served(type, ArmoryDeclaredLaxSub.new, :allowed)).to eq("SECRET")
  end

  it "keeps a subclass's stricter policy when the declared one is lax" do
    type = type_of(model: ArmoryDeclaredOpen)

    expect(served(type, ArmoryDeclaredStrictSub.new, :someone)).to be_nil
    expect(served(type, ArmoryDeclaredStrictSub.new, :allowed)).to eq("SECRET")
    expect(served(type, ArmoryDeclaredOpen.new, :someone)).to eq("SECRET")
  end

  it "serves a subclass with no policy of its own under the declared one" do
    type = type_of(model: ArmoryDeclaredDoc)

    expect(served(type, ArmoryDeclaredPlainSub.new, :someone)).to be_nil
    expect(served(type, ArmoryDeclaredPlainSub.new, :allowed)).to eq("SECRET")
  end

  it "reads a model named like the type, as the audit does" do
    base = base_object
    named = Class.new(base) do
      graphql_name "ArmoryDeclaredNamed"
      authorize :read
      field :secret, String, null: true
    end

    expect(served(named, ArmoryDeclaredPublic.new, :someone)).to be_nil
    expect(served(named, ArmoryDeclaredPublic.new, :allowed)).to eq("SECRET")
  end

  it "asks both for a field's authorize:" do
    type = type_of(model: ArmoryDeclaredOpen) { field :secret, String, null: true, authorize: :manage }
    strict = type_of(model: ArmoryDeclaredDoc) { field :secret, String, null: true, authorize: :manage }

    expect(served(strict, ArmoryDeclaredLaxSub.new, :someone)).to be_nil
    expect(served(type, ArmoryDeclaredStrictSub.new, :someone)).to be_nil
    expect(served(type, ArmoryDeclaredOpen.new, :someone)).to eq("SECRET")
  end

  it "asks both for an argument's authorize:" do
    type = type_of(model: ArmoryDeclaredOpen) do
      field(:secret, String, null: true) { argument :tag, String, required: false, authorize: :manage, model: ArmoryDeclaredDoc }
    end
    query = '{ doc { secret(tag: "x") } }'

    expect(served(type, ArmoryDeclaredLaxSub.new, :someone, query)).to be_nil
    expect(served(type, ArmoryDeclaredLaxSub.new, :allowed, query)).to eq("SECRET")
  end

  it "still lets a rule's policy: answer alone" do
    rule = armory::Rule.new(:read, policy: ArmoryDeclaredLaxBase, model: ArmoryDeclaredDoc)

    expect(adapter.authorized?(:someone, ArmoryDeclaredDoc.new, rule)).to be(true)
  end

  it "hands back the first answer that is not true, so the core can refuse it" do
    policy = Class.new(ArmoryDeclaredPolicyBase) { def read? = "yes" }
    record_class = Class.new(ArmoryDeclaredDoc)
    record_class.define_singleton_method(:policy_class) { policy }

    expect(adapter.authorized?(:allowed, record_class.new, armory::Rule.new(:read, model: ArmoryDeclaredOpen))).to eq("yes")
  end

  it "raises when neither the model nor the record has a policy" do
    rule = armory::Rule.new(:read, model: :armory_declared_ghost)

    expect { adapter.authorized?(:allowed, Object.new, rule) }.to raise_error(Pundit::NotDefinedError, /\Ano policy found for Object\z/)
  end
end
