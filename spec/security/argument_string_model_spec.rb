# frozen_string_literal: true

# A String `model:` is the schema author's: it names a model, and only there is a String read that way.
class ArmoryStringModel
  def text(**) = "SECRET"
end

class ArmoryStringModelPolicy
  class Scope
    def initialize(_user, scope) = @scope = scope
    def resolve = @scope
  end

  def initialize(user, _record) = @user = user
  def read? = true
  def export? = @user == :admin
end

RSpec.describe "a String model: on an argument" do
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

  def schema_with(**rule)
    plugin = armory
    type = Class.new(base_object) do
      graphql_name "Note"
      authorize :read, model: ArmoryStringModel
      field :text, String, null: true do
        argument :tag, String, required: false, model: "ArmoryStringModel", **rule
      end
    end
    query_class = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :note, type, null: true, authorize: :none, reason: "x"
    end
    Class.new(base_schema) do
      use plugin, adapter: :pundit
      query query_class
    end
  end

  def ask(schema, user)
    root = Struct.new(:note).new(ArmoryStringModel.new)
    execute_query(schema, '{ note { text(tag: "x") } }', root_value: root, context: { current_user: user }).to_h
  end

  it "asks that model's policy for visible_when:" do
    schema = schema_with(visible_when: :export)

    expect(ask(schema, :admin).dig("data", "note", "text")).to eq("SECRET")
    expect(ask(schema, :someone)["errors"].first["message"]).to include("doesn't accept argument")
  end

  it "asks that model's policy for authorize:" do
    schema = schema_with(authorize: :export)

    expect(ask(schema, :admin).dig("data", "note", "text")).to eq("SECRET")
    expect(ask(schema, :someone).dig("data", "note", "text")).to be_nil
  end

  it "is resolved to the class, and a name with no constant stays a model name, like a Symbol" do
    model = lambda { |name| base_argument.new(:tag, String, required: false, model: name, owner: base_field).armory_model }

    expect(model.("ArmoryStringModel")).to eq(ArmoryStringModel)
    expect(model.("armory_string_model")).to eq(:armory_string_model)
    expect(model.(:armory_string_model)).to eq(:armory_string_model)
    expect(armory::Adapters::Pundit.new.found_policy("ArmoryStringModel")).to eq(ArmoryStringModelPolicy)
  end

  it "still takes a Symbol model for visible_when:" do
    plugin = armory
    type = Class.new(base_object) do
      graphql_name "Note"
      authorize :read, model: ArmoryStringModel
      field :text, String, null: true do
        argument :tag, String, required: false, model: :armory_string_model, visible_when: :export
      end
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

    expect(ask(schema, :admin).dig("data", "note", "text")).to eq("SECRET")
  end
end
