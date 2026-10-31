# frozen_string_literal: true

RSpec.describe "a visible_when: that cannot name its model" do
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

  def bypassed(&block)
    Class.new(base_object) do
      graphql_name "ArmoryNamelessStats"
      authorize :none, reason: "public", covers_fields: true
      class_eval(&block) if block
    end
  end

  def schema_of(type, visibility: true)
    plugin = armory
    query_class = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :thing, type, null: true, authorize: :none, reason: "x"
    end
    Class.new(GraphQL::Schema) do
      use plugin, adapter: plugin::Adapters::Substitute.new
      use GraphQL::Schema::Visibility, dynamic: true if visibility
      query query_class
    end
  end

  def texts(report) = report.problems.map(&:to_s)

  def expect_reported_every_run(schema)
    first = armory::Audit.(schema)

    expect(first.problems.map(&:kind)).to include(:model)
    expect(texts(armory::Audit.(schema))).to eq(texts(first))
  end

  it "is reported on a field of a bypassed type" do
    expect_reported_every_run(schema_of(bypassed { field :y, String, null: true, authorize: :none, reason: "x", visible_when: :export }))
  end

  it "is reported on a bypassed type" do
    type = Class.new(base_object) do
      graphql_name "ArmoryNamelessStats"
      authorize :none, reason: "public", covers_fields: true, visible_when: :export
      field :y, String, null: true
    end

    expect_reported_every_run(schema_of(type))
  end

  it "is reported on an argument of a field" do
    type = bypassed do
      field(:y, String, null: true, authorize: :none, reason: "x") { argument :tag, String, required: false, visible_when: :export }
    end

    expect_reported_every_run(schema_of(type))
  end

  it "is reported on an input object's argument" do
    argument_base = base_argument
    input = Class.new(GraphQL::Schema::InputObject) do
      graphql_name "ArmoryNamelessInput"
      argument_class argument_base
      argument :tag, String, required: false, visible_when: :export
    end
    type = bypassed do
      field(:y, String, null: true, authorize: :none, reason: "x") { argument :filter, input, required: false }
    end

    expect(armory::Audit.(schema_of(type, visibility: false)).problems.map(&:kind)).to include(:model)
  end

  it "is reported with no Visibility too" do
    type = bypassed { field :y, String, null: true, authorize: :none, reason: "x", visible_when: :export }

    expect(armory::Audit.(schema_of(type, visibility: false)).problems.map(&:kind)).to include(:model)
  end

  it "stays quiet for a definition a child shadows, which Visibility never asks" do
    parent = Class.new(base_object) do
      graphql_name "ArmoryNamelessParent"
      field :y, String, null: true, visible_when: :export
    end
    type = Class.new(parent) do
      graphql_name "ArmoryNamedChild"
      authorize :read, model: String
      field :y, String, null: true, authorize: :read
    end

    expect(armory::Audit.(schema_of(type)).problems.map(&:kind)).not_to include(:model)
  end

  it "is reported for a parent's definition a child inherits" do
    parent = Class.new(base_object) do
      graphql_name "ArmoryNamelessParent"
      field :y, String, null: true, visible_when: :export
    end
    type = Class.new(parent) do
      graphql_name "ArmoryNamedChild"
      authorize :read, model: String
    end

    expect_reported_every_run(schema_of(type))
  end

  it "names an interface's field on the interface, once" do
    field_base = base_field
    shared = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "ArmoryNamelessShared"
      field_class field_base
      field :x, String, null: true, visible_when: :export
    end
    type = Class.new(base_object) do
      graphql_name "ArmoryNamedImplementer"
      authorize :read, model: String
      implements shared
    end
    paths = armory::Audit.(schema_of(type)).problems.select { |problem| problem.kind == :model }.map(&:path)

    expect(paths).to eq(["ArmoryNamelessShared.x"])
  end

  it "reports an argument once, however many checks reach it" do
    type = Class.new(base_object) do
      graphql_name "ArmoryNamelessStats"
      authorize :read
      field(:y, String, null: true) { argument :tag, String, required: false, visible_when: :export }
    end
    paths = armory::Audit.(schema_of(type)).problems.select { |problem| problem.kind == :model }.map(&:path)

    expect(paths).to eq(paths.uniq)
  end

  it "stays quiet when the model can be named" do
    type = Class.new(base_object) do
      graphql_name "ArmoryNamelessStats"
      authorize :read, model: String
      field :y, String, null: true, visible_when: :export
    end

    expect(armory::Audit.(schema_of(type)).problems.map(&:kind)).not_to include(:model)
  end

  it "does not say ok when an app's own visible? raises a ConfigurationError while listing" do
    config_error = armory::ConfigurationError
    type = bypassed do
      field :x, String, null: true
      define_singleton_method(:visible?) { |_context| raise config_error, "from the app" }
    end

    expect(armory::Audit.(schema_of(type)).ok?).to be(false)
  end

  it "does not hide an input object only a directive reaches" do
    doc = bypassed
    input = Class.new(GraphQL::Schema::InputObject) do
      graphql_name "ArmoryDirectiveInput"
      argument :doc_id, GraphQL::Types::ID, required: false, loads: doc
    end
    only_directive = Class.new(GraphQL::Schema::Directive) do
      graphql_name "armoryOnlyDirective"
      locations GraphQL::Schema::Directive::FIELD
      argument :filter, input, required: false
    end
    schema = schema_of(doc)
    schema.directive(only_directive)

    2.times { expect(armory::Audit.(schema).problems.map(&:kind)).to include(:unscoped_load) }
  end
end
