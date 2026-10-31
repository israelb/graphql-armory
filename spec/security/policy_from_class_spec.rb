# frozen_string_literal: true

require "json"
require "ostruct"

# A record's own answers are data: they may come from the client. Only its class names its policy.
class ArmoryClassNote
  def text(**) = "SECRET"
end

class ArmoryClassStrictPolicy
  class Scope
    def initialize(_user, scope) = @scope = scope
    def resolve = []
  end

  def initialize(_user, _record); end
  def read? = false
end

class ArmoryClassNotePolicy < ArmoryClassStrictPolicy; end

class ArmoryClassLaxPolicy < ArmoryClassStrictPolicy
  class Scope
    def initialize(_user, scope) = @scope = scope
    def resolve = @scope
  end

  def read? = true
end

class ArmoryClassDeclared
  def self.policy_class = ArmoryClassLaxPolicy
end

class ArmoryClassNamed
  def self.model_name = "ArmoryClassLax"
end

class ArmoryClassKlass
  def klass = ArmoryClassDeclared
  def text(**) = "SECRET"
end

class ArmoryClassKlassPolicy < ArmoryClassStrictPolicy; end

class ArmoryClassRaisingKlass
  def klass(_required) = raise(NameError, "from the client's text")
end

class ArmoryClassRaisingKlassPolicy < ArmoryClassStrictPolicy; end

RSpec.describe "a record's own answers do not pick its policy" do
  # A global name Pundit would find for every spec in the process: it lives only during each example here.
  around do |example|
    Object.const_set(:OpenStructPolicy, Class.new(ArmoryClassStrictPolicy))
    example.run
  ensure
    Object.send(:remove_const, :OpenStructPolicy)
  end

  let(:armory) { GraphQL::Armory::Authorization }
  let(:adapter) { armory::Adapters::Pundit.new }
  let(:rule) { armory::Rule.new(:read) }

  def ask(record)
    plugin = armory
    base_field = Class.new(GraphQL::Schema::Field) { include plugin::Base }
    base_object = Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class base_field
    end
    type = Class.new(base_object) do
      graphql_name "Note"
      authorize :read, model: ArmoryClassNote
      field :text, String, null: true
    end
    query_class = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :note, type, null: true, authorize: :none, reason: "x"
    end
    schema = Class.new(base_schema) do
      use plugin, adapter: :pundit
      query query_class
    end
    execute_query(schema, "{ note { text } }", root_value: Struct.new(:note).new(record), context: { current_user: :someone }).to_h
  end

  it "does not serve a refused user through a policy_class key from the client" do
    record = OpenStruct.new(JSON.parse('{"policy_class":"ArmoryClassLaxPolicy","text":"SECRET"}'))

    expect(ask(record).dig("data", "note")).to be_nil
    expect(adapter.authorized?(:someone, record, rule)).to be(false)
  end

  it "does not serve a refused user through a model_name key from the client" do
    record = OpenStruct.new(JSON.parse('{"model_name":"ArmoryClassLax","text":"SECRET"}'))

    expect(ask(record).dig("data", "note")).to be_nil
    expect(adapter.authorized?(:someone, record, rule)).to be(false)
  end

  it "does not let an instance answer with its own policy_class" do
    record = ArmoryClassNote.new
    def record.policy_class = ArmoryClassLaxPolicy

    expect(adapter.authorized?(:someone, record, rule)).to be(false)
  end

  it "does not read an array as a namespace" do
    expect { adapter.authorized?(:someone, %i[armory_class_lax], rule) }.to raise_error(Pundit::NotDefinedError, /Array\z/)
  end

  it "does not let a klass key choose the policy of a list" do
    items = OpenStruct.new(klass: "ArmoryClassDeclared")

    expect(adapter.scope(:someone, items, rule)).to eq([])
  end

  it "still honours policy_class and model_name on the record's class" do
    expect(adapter.authorized?(:someone, ArmoryClassDeclared.new, rule)).to be(true)
    expect(adapter.authorized?(:someone, ArmoryClassNamed.new, rule)).to be(true)
  end

  it "does not let a record's klass method choose its policy" do
    expect(adapter.authorized?(:someone, ArmoryClassKlass.new, rule)).to be(false)
    expect(ask(ArmoryClassKlass.new).dig("data", "note")).to be_nil
    expect(adapter.scope(:someone, [ArmoryClassKlass.new], rule)).to eq([])
  end

  it "does not let a klass method choose the policy of a list that is no relation" do
    expect(adapter.scope(:someone, ArmoryClassKlass.new, rule)).to eq([])
  end

  it "does not call a record's klass method" do
    expect(adapter.authorized?(:someone, ArmoryClassRaisingKlass.new, rule)).to be(false)
  end

  it "still takes the policy of a real relation from its model" do
    expect(adapter.scope(world.alice, Credit.all, rule)).to be_a(ActiveRecord::Relation)
    expect { adapter.authorized?(world.alice, Credit.all, armory::Rule.new(:no_such_action)) }
      .to raise_error(armory::AdapterError, /#{Credit.policy_class} does not define no_such_action\?/)
  end

  it "still takes a class or a model name as it is" do
    expect(adapter.authorized?(:someone, ArmoryClassDeclared, rule)).to be(true)
    expect(adapter.authorized?(:someone, :armory_class_note, armory::Rule.new(:read, model: :armory_class_note))).to be(false)
  end
end
