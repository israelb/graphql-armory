# frozen_string_literal: true

require "ostruct"

# A Symbol a type wraps is a record, maybe the client's text. Only the Symbol the schema author wrote as `model:`
# names a policy, as a String record stopped doing in #17.
class ArmorySymbolHeadlessPolicy
  def initialize(user, _subject) = @user = user
  def read? = @user == :allowed
  def manage? = @user == :allowed
end

class ArmorySymbolLaxPolicy
  def initialize(_user, _subject); end
  def read? = true
end

class ArmorySymbolRoot
  def said(**) = "SAID"
end

RSpec.describe "a Symbol as a subject" do
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
    field_base = base_field
    Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class field_base
    end
  end

  def query_schema(&block)
    plugin = armory
    query_class = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      class_eval(&block)
    end
    Class.new(base_schema) do
      use plugin, adapter: :pundit
      query query_class
    end
  end

  def run_query(schema, text, user) = execute_query(schema, text, root_value: ArmorySymbolRoot.new, context: { current_user: user }).to_h

  it "does not let a Symbol from a record name its own policy" do
    expect { adapter.authorized?(:someone, :armory_symbol_lax, armory::Rule.new(:read)) }.to raise_error(Pundit::NotDefinedError, /\Ano policy found for Symbol\z/)
  end

  it "refuses a Symbol record under a model, which is not that model" do
    rule = armory::Rule.new(:read, model: :armory_symbol_headless)

    expect { adapter.authorized?(:allowed, :armory_symbol_lax, rule) }.to raise_error(Pundit::NotDefinedError, /Symbol\z/)
  end

  it "keeps the Symbol the schema author wrote" do
    rule = armory::Rule.new(:read, model: :armory_symbol_headless)

    expect(adapter.authorized?(:allowed, :armory_symbol_headless, rule)).to be(true)
    expect(adapter.authorized?(:someone, :armory_symbol_headless, rule)).to be(false)
  end

  it "runs a Symbol model: with authorize: instead of raising TypeError" do
    schema = query_schema do
      field(:said, String, null: true, authorize: :none, reason: "x") do
        argument :tag, String, required: false, authorize: :manage, model: :armory_symbol_headless
      end
    end

    expect(run_query(schema, '{ said(tag: "x") }', :allowed).dig("data", "said")).to eq("SAID")
    expect(run_query(schema, '{ said(tag: "x") }', :someone).dig("data", "said")).to be_nil
  end

  it "runs a String model: with no constant the same way" do
    schema = query_schema do
      field(:said, String, null: true, authorize: :none, reason: "x") do
        argument :tag, String, required: false, authorize: :manage, model: "armory_symbol_headless"
      end
    end

    expect(run_query(schema, '{ said(tag: "x") }', :allowed).dig("data", "said")).to eq("SAID")
    expect(run_query(schema, '{ said(tag: "x") }', :someone).dig("data", "said")).to be_nil
  end

  it "keeps visible_when: on an argument with a Symbol model:" do
    schema = query_schema do
      field(:said, String, null: true, authorize: :none, reason: "x") do
        argument :tag, String, required: false, visible_when: :manage, model: :armory_symbol_headless
      end
    end

    expect(run_query(schema, '{ said(tag: "x") }', :allowed).dig("data", "said")).to eq("SAID")
    expect(run_query(schema, '{ said(tag: "x") }', :someone).dig("data", "said")).to be_nil
  end

  it "names a record whose `class` is a data member, without quoting it" do
    record = OpenStruct.new(class: "SECRET")
    authorize = armory::Authorize.new(adapter: armory::Adapters::Substitute.new(allow: true))

    expect(authorize.(record, armory::Rule.new(:read), {})).to be(true)
  end

  it "does not allow an Array item through a lying ==" do
    liar = Object.new
    def liar.==(_other) = true
    policy = Class.new(ArmorySymbolHeadlessPolicy) { define_method(:read?) { liar } }

    expect(adapter.scope(:someone, [Object.new], armory::Rule.new(:read, policy: policy))).to eq([])
  end
end

class ArmorySymbolDoc
  attr_reader :owner

  def initialize(owner) = @owner = owner
  def body(**) = "SECRET"
end

class ArmorySymbolDecorator
  def initialize(doc) = @doc = doc
  def owner = @doc.owner
  def body(**) = @doc.body
  def is_a?(klass) = super || @doc.is_a?(klass)
end

class ArmorySymbolDocPolicy
  def initialize(user, record)
    @user = user
    @record = record
  end

  def read? = true
  def internal? = Module === @record ? true : @record.owner == @user
end

class ArmorySymbolDecoratorPolicy < ArmorySymbolDocPolicy; end

class ArmorySymbolThingPolicy
  def initialize(user, _subject) = @user = user
  def read? = true
  def manage? = @user == :allowed
end

class ArmorySymbolCapital; end
class ArmorySymbolCapitalPolicy < ArmorySymbolThingPolicy; end

RSpec.describe "a Symbol or a decorator after the first correction" do
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
    field_base = base_field
    Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class field_base
    end
  end

  def schema_of(type)
    plugin = armory
    query_class = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :thing, type, null: true, authorize: :none, reason: "x"
    end
    Class.new(base_schema) do
      use plugin, adapter: :pundit
      query query_class
    end
  end

  def thing_of(type, record, user, selection)
    execute_query(schema_of(type), "{ thing { #{selection} } }", root_value: Struct.new(:thing).new(record), context: { current_user: user }).to_h
  end

  it "asks about the record when a decorator says it is an instance of the model" do
    type = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: ArmorySymbolDoc
      field(:body, String, null: true) { argument :internal, GraphQL::Types::Boolean, required: false, authorize: :internal }
    end
    decorated = ArmorySymbolDecorator.new(ArmorySymbolDoc.new(:owner))

    expect(thing_of(type, decorated, :stranger, "body(internal: true)").dig("data", "thing", "body")).to be_nil
    expect(thing_of(type, decorated, :owner, "body(internal: true)").dig("data", "thing", "body")).to eq("SECRET")
  end

  [[:armory_symbol_thing, :armory_symbol_thing], ["armory_symbol_thing", :armory_symbol_thing], [:ArmorySymbolCapital, :ArmorySymbolCapital]].each do |model, record|
    it "carries model: #{model.inspect} to a field's own rule" do
      type = Class.new(base_object) do
        graphql_name "Thing"
        authorize :read, model: model
        field :length, Integer, null: true, authorize: :manage
      end

      expect(thing_of(type, record, :allowed, "length").dig("data", "thing", "length")).to eq(record.length)
      expect(thing_of(type, record, :someone, "length").dig("data", "thing", "length")).to be_nil
    end
  end

  it "does not let a bare Symbol name a Scope" do
    adapter = armory::Adapters::Pundit.new

    expect { adapter.scope(:someone, :armory_symbol_thing, armory::Rule.new(:read)) }.to raise_error(Pundit::NotDefinedError, /\Ano policy found for Symbol\z/)
  end

  context "with CanCanCan" do
    let(:ability) do
      Class.new do
        include CanCan::Ability

        def initialize(_user = nil) = can(:read, :armory_dashboard)
      end.new
    end
    let(:adapter) { armory::Adapters::CanCan.new }

    it "does not let a Symbol record pick a rule" do
      expect(adapter.authorized?(ability, :armory_dashboard, armory::Rule.new(:read, model: ArmorySymbolDoc))).to be(false)
      expect(adapter.authorized?(ability, :armory_dashboard, armory::Rule.new(:read))).to be(false)
    end

    it "keeps the Symbol the schema author wrote" do
      expect(adapter.authorized?(ability, :armory_dashboard, armory::Rule.new(:read, model: :armory_dashboard))).to be(true)
      expect(adapter.authorized?(ability, :armory_dashboard, armory::Rule.new(:read, model: "armory_dashboard"))).to be(true)
    end
  end
end
