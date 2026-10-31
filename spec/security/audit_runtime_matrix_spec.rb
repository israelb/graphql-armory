# frozen_string_literal: true

require "json"
require "ostruct"

# The invariant the audit exists for: if a user the type's policy refuses gets the data, the audit must not say ok.
# Each shape is one place a rule can live relative to the `policy:` that should answer it. A new way to break the
# invariant belongs here as a shape, not only as a spec of its own.
class ArmoryMatrixDoc
  def notes(**) = "SECRET"
end

class ArmoryMatrixDocPolicy
  class Scope
    def initialize(_user, scope) = @scope = scope
    def resolve = @scope
  end

  def initialize(_user, _record); end
  def read? = true
  def manage? = true
end

class ArmoryMatrixStrictPolicy < ArmoryMatrixDocPolicy
  def manage? = false
end

class ArmoryMatrixSame
  def notes(**) = "SECRET"
end

class ArmoryMatrixSamePolicy < ArmoryMatrixStrictPolicy; end

class ArmoryMatrixClientRecord < OpenStruct; end
class ArmoryMatrixClientRecordPolicy < ArmoryMatrixStrictPolicy; end

RSpec.describe "audit against runtime, for a user the type's policy refuses" do
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

  def strict_type(parent = base_object, &block)
    Class.new(parent) do
      graphql_name "Doc"
      authorize :read, policy: ArmoryMatrixStrictPolicy, model: ArmoryMatrixDoc
      class_eval(&block) if block
    end
  end

  def parent_type(**rule, &block)
    field_klass = base_field
    Class.new(base_object) do
      graphql_name "Base"
      field_class field_klass
      authorize :read, model: ArmoryMatrixDoc, **rule
      class_eval(&block)
    end
  end

  def interface_with(&block)
    field_klass = base_field
    Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Noted"
      field_class field_klass
      module_eval(&block)
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

  def input_type
    argument_klass = base_argument
    Class.new(GraphQL::Schema::InputObject) do
      graphql_name "Filter"
      argument_class argument_klass
      argument :raw, GraphQL::Types::Boolean, required: false, authorize: :manage, model: ArmoryMatrixDoc
    end
  end

  def plain_resolver
    argument_klass = base_argument
    Class.new(GraphQL::Schema::Resolver) do
      graphql_name "Notes"
      argument_class argument_klass
      type String, null: true
      argument :raw, GraphQL::Types::Boolean, required: false, authorize: :manage, model: ArmoryMatrixDoc
      def resolve(**) = "SECRET"
    end
  end

  def field_without_base_arguments
    plugin = armory
    Class.new(GraphQL::Schema::Field) { include plugin::Base }
  end

  def base_resolver
    plugin = armory
    argument_klass = base_argument
    input = input_type
    Class.new(GraphQL::Schema::Resolver) do
      include plugin::Base
      graphql_name "Notes"
      argument_class argument_klass
      type String, null: true
      authorize :read, policy: ArmoryMatrixStrictPolicy, model: ArmoryMatrixDoc
      argument :filter, input, required: false
      def resolve(**) = "SECRET"
    end
  end

  field_rule = proc { field :notes, String, null: true, authorize: :manage }
  argument_rule = proc do
    field :notes, String, null: true do
      argument :raw, GraphQL::Types::Boolean, required: false, authorize: :manage, model: ArmoryMatrixDoc
    end
  end
  raw = "{ doc { notes(raw: true) } }"
  bare = "{ doc { notes } }"

  shapes = {
    "a field rule on the type with the policy" => [bare, :clean, ->(spec) { spec.strict_type(&field_rule) }],
    "an argument rule on the type with the policy" => [raw, :clean, ->(spec) { spec.strict_type(&argument_rule) }],
    "a field rule on a parent with the policy" => [bare, :clean, ->(spec) { spec.strict_type(spec.parent_type(policy: ArmoryMatrixStrictPolicy, &field_rule)) }],
    "a field rule on a parent with the policy, under a bypassed child" => [bare, :clean, lambda { |spec|
      Class.new(spec.parent_type(policy: ArmoryMatrixStrictPolicy, &field_rule)) do
        graphql_name "Doc"
        authorize :none, reason: "public"
      end
    }],
    "a field rule on a parent, the policy on the subclass" => [bare, :reported, ->(spec) { spec.strict_type(spec.parent_type(&field_rule)) }],
    "an argument rule on a parent, the policy on the subclass" => [raw, :reported, ->(spec) { spec.strict_type(spec.parent_type(&argument_rule)) }],
    "a field rule on an interface, the policy on the implementer" => [bare, :reported, lambda { |spec|
      interface = spec.interface_with(&field_rule)
      spec.strict_type { implements interface }
    }],
    "an argument rule on an interface, the policy on the implementer" => [raw, :reported, lambda { |spec|
      interface = spec.interface_with(&argument_rule)
      spec.strict_type { implements interface }
    }],
    "an input object's argument rule, the policy on the type" => ["{ doc { notes(filter: { raw: true }) } }", :reported, lambda { |spec|
      input = spec.input_type
      spec.strict_type do
        field :notes, String, null: true do
          argument :filter, input, required: false
        end
      end
    }],
    "a plain resolver's argument rule, the policy on the type" => [raw, :reported, lambda { |spec|
      resolver = spec.plain_resolver
      spec.strict_type { field :notes, resolver: resolver }
    }],
    "an input object's rule, under a field class whose arguments do not include Base" => ["{ doc { notes(filter: { raw: true }) } }", :reported, lambda { |spec|
      input = spec.input_type
      plain_arguments = spec.field_without_base_arguments
      spec.strict_type do
        field_class plain_arguments
        field :notes, String, null: true do
          argument :filter, input, required: false
        end
      end
    }],
    "an input object's rule, on a Base resolver with the policy" => ["{ doc { notes(filter: { raw: true }) } }", :reported, lambda { |spec|
      resolver = spec.base_resolver
      spec.strict_type { field :notes, resolver: resolver }
    }],
    "a field rule beside a Base resolver on a parent, the policy on the subclass" => ["{ doc { notes } }", :reported, lambda { |spec|
      resolver = spec.base_resolver
      spec.strict_type(spec.parent_type { field :notes, resolver: resolver, authorize: :manage })
    }],
    "a field rule on a parent connection, the policy on the subclass" => [bare, :reported, lambda { |spec|
      node = spec.strict_type
      field_klass = spec.base_field
      plugin = spec.armory
      parent = Class.new(GraphQL::Types::Relay::BaseConnection) do
        include plugin::Base
        field_class field_klass
        graphql_name "BaseDocs"
        edge_type(node.edge_type)
        field :notes, String, null: true, authorize: :manage
      end
      Class.new(parent) do
        graphql_name "Docs"
        authorize :read, policy: ArmoryMatrixStrictPolicy, model: ArmoryMatrixDoc
      end
    }],
    "a field rule on a parent, the policy on a bypassed child" => [bare, :reported, lambda { |spec|
      Class.new(spec.parent_type(&field_rule)) do
        graphql_name "Doc"
        authorize :none, reason: "public", policy: ArmoryMatrixStrictPolicy, model: ArmoryMatrixDoc
      end
    }]
  }

  shapes.each do |name, (query, expected, build)|
    describe name do
      let(:schema) { schema_of(build.(self)) }
      let(:report) { armory::Audit.(schema) }
      let(:served) do
        root = Struct.new(:doc).new(ArmoryMatrixDoc.new)
        execute_query(schema, query, root_value: root, context: { current_user: :someone }).to_h.dig("data", "doc", "notes")
      end

      it "never serves the data with the audit ok" do
        expect(served == "SECRET" && report.ok?).to eq(false)
      end

      if expected == :clean
        it "refuses the user, and the audit has nothing to say about the policy" do
          expect(served).to be_nil
          expect(report.problems.map(&:kind)).not_to include(:foreign_policy)
        end
      else
        it "reports the rule that asks another policy" do
          expect(report.problems.map(&:kind)).to include(:foreign_policy)
          expect(report.problems.map(&:message)).to include(a_string_including("ArmoryMatrixStrictPolicy"))
        end
      end
    end
  end

  it "says nothing when the policy found from the record is the one the type names" do
    interface = interface_with(&field_rule)
    type = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, policy: ArmoryMatrixSamePolicy, model: ArmoryMatrixSame
      implements interface
    end
    root = Struct.new(:doc).new(ArmoryMatrixSame.new)
    schema = schema_of(type)

    expect(armory::Audit.(schema).problems.map(&:kind)).not_to include(:foreign_policy)
    expect(execute_query(schema, "{ doc { notes } }", root_value: root, context: { current_user: :someone }).to_h.dig("data", "doc", "notes")).to be_nil
  end

  it "does not crash on an argument type a shadowed definition never resolved" do
    late = GraphQL::Schema::LateBoundType.new("Filter")
    input = input_type
    parent = parent_type { field(:notes, String, null: true) { argument :filter, late, required: false } }
    type = strict_type(parent) do
      field :notes, String, null: true, override_reason: "as strict"
      field(:other, String, null: true) { argument :filter, input, required: false }
    end

    expect { armory::Audit.(schema_of(type)) }.not_to raise_error
  end

  it "reports nothing twice when a Base resolver and its type name the same policy" do
    resolver = base_resolver
    paths = armory::Audit.(schema_of(strict_type { field :notes, resolver: resolver })).problems.select { |problem| problem.kind == :foreign_policy }.map(&:path)

    expect(paths).to eq(paths.uniq)
  end

  it "does not serve a record whose own keys name a laxer policy" do
    type = Class.new(base_object) do
      graphql_name "Doc"
      authorize :manage, model: ArmoryMatrixSame
      field :notes, String, null: true
    end
    record = ArmoryMatrixClientRecord.new(JSON.parse('{"policy_class":"ArmoryMatrixDocPolicy","notes":"SECRET"}'))
    response = execute_query(schema_of(type), "{ doc { notes } }", root_value: Struct.new(:doc).new(record), context: { current_user: :someone }).to_h

    expect(response.dig("data", "doc")).to be_nil
  end

  it "does not serve a record whose klass method names a laxer model" do
    type = Class.new(base_object) do
      graphql_name "Doc"
      authorize :manage, model: ArmoryMatrixSame
      field :notes, String, null: true
    end
    record = ArmoryMatrixSame.new
    def record.klass = ArmoryMatrixDoc
    response = execute_query(schema_of(type), "{ doc { notes } }", root_value: Struct.new(:doc).new(record), context: { current_user: :someone }).to_h

    expect(response.dig("data", "doc")).to be_nil
  end

  it "says nothing when the type names no policy" do
    type = Class.new(parent_type(&field_rule)) do
      graphql_name "Doc"
      authorize :read, model: ArmoryMatrixDoc
    end

    expect(armory::Audit.(schema_of(type)).problems.map(&:kind)).not_to include(:foreign_policy)
  end
end
