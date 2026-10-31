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

class ArmoryMatrixLaxSame < ArmoryMatrixSame; end
class ArmoryMatrixLaxSamePolicy < ArmoryMatrixDocPolicy; end

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

  [["of another class", -> { ArmoryMatrixDoc.new }], ["of a subclass with a laxer policy", -> { ArmoryMatrixLaxSame.new }]].each do |shape, record|
    it "does not serve a record #{shape} with the audit ok" do
      type = Class.new(base_object) do
        graphql_name "Doc"
        authorize :manage, model: ArmoryMatrixSame
        field :notes, String, null: true
      end
      schema = schema_of(type)
      response = execute_query(schema, "{ doc { notes } }", root_value: Struct.new(:doc).new(record.call), context: { current_user: :someone }).to_h

      expect(armory::Audit.(schema).ok?).to be(true)
      expect(response.dig("data", "doc")).to be_nil
    end
  end

  it "does not say ok when a parent's field rule serves a laxer subclass the type's model would refuse" do
    parent = Class.new(base_object) do
      graphql_name "AbstractDoc"
      field :notes, String, null: true, authorize: :read
    end
    type = Class.new(parent) do
      graphql_name "Doc"
      authorize :none, reason: "x", covers_fields: true
    end
    named = Class.new(parent) do
      graphql_name "Doc"
      authorize :manage, model: ArmoryMatrixSame
    end

    expect(armory::Audit.(schema_of(named)).problems.map(&:kind)).to include(:foreign_model)
    expect(armory::Audit.(schema_of(type)).problems.map(&:kind)).not_to include(:foreign_model)
  end

  it "does not say ok for an app's type marked as introspection" do
    type = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: ArmoryMatrixDoc
      field :notes, String, null: true
      introspection(true)
      reauthorize_scoped_objects(false)
    end

    expect(armory::Audit.(schema_of(type)).ok?).to be(false)
  end

  it "does not say ok for a redefinition on a type that inherits graphql-ruby's introspection base" do
    plugin = armory
    field_base = base_field
    parent = Class.new(GraphQL::Introspection::BaseObject) do
      include plugin::Base
      field_class field_base
      graphql_name "Doc"
      authorize :read, model: ArmoryMatrixDoc
      field :notes, String, null: true
    end
    type = Class.new(parent) do
      graphql_name "Doc"
      field :notes, String, null: true, authorize: :manage
    end

    expect(armory::Audit.(schema_of(type)).ok?).to be(false)
  end

  it "leaves graphql-ruby's own introspection types alone" do
    type = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: ArmoryMatrixDoc
      field :notes, String, null: true
    end

    expect(armory::Audit.(schema_of(type)).ok?).to be(true)
  end

  it "does not say ok when a Base resolver's argument asks another policy than the type's" do
    plugin = armory
    argument_base = base_argument
    resolver = Class.new(GraphQL::Schema::Resolver) do
      include plugin::Base
      argument_class argument_base
      graphql_name "Via"
      type String, null: true
      authorize :read, model: ArmoryMatrixDoc
      argument :raw, GraphQL::Types::Boolean, required: false, authorize: :manage
      define_method(:resolve) { |**| "SECRET" }
    end
    type = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: ArmoryMatrixDoc, policy: ArmoryMatrixStrictPolicy
      field :via, resolver: resolver
    end
    schema = schema_of(type)
    response = execute_query(schema, "{ doc { via(raw: true) } }", root_value: Struct.new(:doc).new(ArmoryMatrixDoc.new), context: { current_user: :someone }).to_h

    expect(response.dig("data", "doc", "via")).to eq("SECRET")
    expect(armory::Audit.(schema).problems.map(&:kind)).to include(:foreign_policy)
  end

  it "stays quiet for a Base resolver's argument under the policy the resolver and the type share" do
    plugin = armory
    argument_base = base_argument
    resolver = Class.new(GraphQL::Schema::Resolver) do
      include plugin::Base
      argument_class argument_base
      graphql_name "Via"
      type String, null: true
      authorize :read, model: ArmoryMatrixDoc, policy: ArmoryMatrixStrictPolicy
      argument :raw, GraphQL::Types::Boolean, required: false, authorize: :manage
    end
    type = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: ArmoryMatrixDoc, policy: ArmoryMatrixStrictPolicy
      field :via, resolver: resolver
    end

    expect(armory::Audit.(schema_of(type)).problems.map(&:kind)).not_to include(:foreign_policy)
  end

  it "does not say ok when a Base resolver's own rule asks another policy than the type's" do
    plugin = armory
    resolver = Class.new(GraphQL::Schema::Resolver) do
      include plugin::Base
      graphql_name "Via"
      type String, null: true
      authorize :manage, model: ArmoryMatrixDoc
      define_method(:resolve) { |**| "SECRET" }
    end
    type = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: ArmoryMatrixDoc, policy: ArmoryMatrixStrictPolicy
      field :via, resolver: resolver
    end
    schema = schema_of(type)
    response = execute_query(schema, "{ doc { via } }", root_value: Struct.new(:doc).new(ArmoryMatrixDoc.new), context: { current_user: :someone }).to_h

    expect(response.dig("data", "doc", "via")).to eq("SECRET")
    expect(armory::Audit.(schema).problems.map(&:kind)).to include(:foreign_policy)
  end

  it "leaves a schema that replaces a built-in introspection type alone" do
    replacement = Module.new
    replacement.const_set(:EnumValueType, Class.new(GraphQL::Introspection::BaseObject) do
      graphql_name "__EnumValue"
      field :name, String, null: false, method: :graphql_name
      field :description, String, null: true
      field :is_deprecated, GraphQL::Types::Boolean, null: false
      field :deprecation_reason, String, null: true
    end)
    type = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: ArmoryMatrixDoc
      field :notes, String, null: true
    end
    schema = Class.new(schema_of(type)) { introspection replacement }

    expect(armory::Audit.(schema).ok?).to be(true)
  end

  it "does not say ok for a PageInfo subclass that adds a field" do
    type = Class.new(GraphQL::Types::Relay::PageInfo) do
      graphql_name "LeakyInfo"
      field :notes, String, null: true
    end

    expect(armory::Audit.(schema_of(type)).ok?).to be(false)
  end

  [:EntryPoints, :DynamicFields].each do |holder|
    it "does not say ok for a custom #{holder} field that leads to an unprotected type" do
      leak = Class.new(GraphQL::Schema::Object) do
        graphql_name "Leak"
        field :notes, String, null: true
      end
      replacement = Module.new
      replacement.const_set(holder, Class.new(GraphQL::Introspection.const_get(holder)) { field :__leak, leak, null: true, method: :__leak })
      type = Class.new(base_object) do
        graphql_name "Doc"
        authorize :read, model: ArmoryMatrixDoc
        field :notes, String, null: true
      end
      schema = Class.new(schema_of(type)) do
        use GraphQL::Schema::Visibility, dynamic: true
        introspection replacement
      end

      expect(armory::Audit.(schema).problems.map(&:path)).to include("Leak")
    end
  end

  context "with a direct Relay subclass" do
    let(:node) do
      Class.new(base_object) do
        graphql_name "Doc"
        authorize :read, model: ArmoryMatrixDoc
        field :notes, String, null: true
      end
    end

    def relay_schema(connection)
      plugin = armory
      query_class = Class.new(base_object) do
        graphql_name "Query"
        authorize :none, reason: "root", covers_fields: true
        field :docs, connection, null: true, authorize: :none, reason: "x", connection: false
      end
      Class.new(base_schema) do
        use plugin, adapter: :pundit
        query query_class
      end
    end

    def connection_over(edge, &body)
      Class.new(GraphQL::Types::Relay::BaseConnection) do
        graphql_name "DocConnection"
        edge_type(edge)
        class_eval(&body) if body
      end
    end

    def edge_of(type, &body)
      Class.new(GraphQL::Types::Relay::BaseEdge) do
        graphql_name "DocEdge"
        node_type(type)
        class_eval(&body) if body
      end
    end

    it "does not say ok for a connection that adds a field" do
      connection = connection_over(edge_of(node)) { field :secret, String, null: true }

      expect(armory::Audit.(relay_schema(connection)).problems.map(&:path)).to include("DocConnection")
    end

    it "does not say ok for an edge that adds a field" do
      connection = connection_over(edge_of(node) { field :secret, String, null: true })

      expect(armory::Audit.(relay_schema(connection)).problems.map(&:path)).to include("DocEdge")
    end

    it "does not say ok for a child whose parent adds the field" do
      parent = Class.new(GraphQL::Types::Relay::BaseConnection) { field :secret, String, null: true }
      edge = edge_of(node)
      child = Class.new(parent) do
        graphql_name "DocConnection"
        edge_type(edge)
      end

      expect(armory::Audit.(relay_schema(child)).problems.map(&:path)).to include("DocConnection")
    end

    it "does not say ok for a connection that gets a field from an interface" do
      interface = Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Noted"
        field :secret, String, null: true
      end
      connection = connection_over(edge_of(node)) { implements interface }

      expect(armory::Audit.(relay_schema(connection)).ok?).to be(false)
    end

    it "leaves a connection and an edge that add nothing alone" do
      problems = armory::Audit.(relay_schema(connection_over(edge_of(node)))).problems

      expect(problems.map(&:path)).not_to include("DocConnection", "DocEdge")
    end

    it "leaves the connection a type generates alone" do
      problems = armory::Audit.(relay_schema(node.connection_type)).problems

      expect(problems.map(&:path)).not_to include("DocConnection", "DocEdge")
    end
  end

  it "does not say ok for a PageInfo child whose parent adds the field" do
    parent = Class.new(GraphQL::Types::Relay::PageInfo) do
      graphql_name "MiddleInfo"
      field :notes, String, null: true
    end
    child = Class.new(parent) { graphql_name "ChildInfo" }

    expect(armory::Audit.(schema_of(child)).problems.map(&:path)).to include("ChildInfo")
  end

  it "does not say ok for a PageInfo subclass that gets a field from an interface" do
    interface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Noted"
      field :notes, String, null: true
    end
    type = Class.new(GraphQL::Types::Relay::PageInfo) do
      graphql_name "NotedInfo"
      implements interface
    end

    expect(armory::Audit.(schema_of(type)).ok?).to be(false)
  end

  it "leaves a PageInfo subclass that adds nothing alone" do
    type = Class.new(GraphQL::Types::Relay::PageInfo) { graphql_name "PlainInfo" }

    expect(armory::Audit.(schema_of(type)).problems.map(&:path)).not_to include("PlainInfo")
  end

  { EntryPoints: :__notes, DynamicFields: :__notes }.each do |holder, name|
    context "with a custom #{holder}" do
      def schema_with_introspection(holder, type_body = nil, &body)
        replacement = Module.new
        replacement.const_set(holder, Class.new(GraphQL::Introspection.const_get(holder), &body))
        type = Class.new(base_object) do
          graphql_name "Doc"
          authorize :read, model: ArmoryMatrixDoc
          field :notes, String, null: true
        end
        Class.new(schema_of(type)) do
          use GraphQL::Schema::Visibility, dynamic: true
          introspection replacement
        end
      end

      it "does not say ok for a scalar field added to it" do
        schema = schema_with_introspection(holder) { field name, String, null: true, method: name }

        expect(armory::Audit.(schema).problems.map(&:path)).to include("#{holder}.#{name}")
      end

      it "leaves a subclass that adds nothing alone" do
        expect(armory::Audit.(schema_with_introspection(holder) {}).ok?).to be(true)
      end
    end
  end

  it "does not say ok for a redefined built-in entry point" do
    replacement = Module.new
    replacement.const_set(:EntryPoints, Class.new(GraphQL::Introspection::EntryPoints) { field :__type, String, null: true, method: :__type })
    type = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: ArmoryMatrixDoc
      field :notes, String, null: true
    end
    schema = Class.new(schema_of(type)) { introspection replacement }

    expect(armory::Audit.(schema).problems.map(&:path)).to include("EntryPoints.__type")
  end

  context "with a RelayClassicMutation's arguments" do
    def schema_with_mutation_argument(**options)
      plugin = armory
      argument_base = base_argument
      mutation = Class.new(GraphQL::Schema::RelayClassicMutation) do
        include plugin::Base
        argument_class argument_base
        graphql_name "DoIt"
        authorize :read, model: ArmoryMatrixDoc
        field :ok, String, null: true
        argument :raw, GraphQL::Types::Boolean, required: false, **options
      end
      type = Class.new(base_object) do
        graphql_name "Doc"
        authorize :read, model: ArmoryMatrixDoc
        field :via, mutation: mutation
      end
      schema_of(type)
    end

    it "reports a missing action" do
      expect(armory::Audit.(schema_with_mutation_argument(authorize: :nope)).problems.map(&:kind)).to include(:adapter)
    end

    it "lists a declared bypass" do
      report = armory::Audit.(schema_with_mutation_argument(authorize: :none, reason: "public flag"))

      expect(report.bypasses.map(&:reason)).to include("public flag")
    end

    it "stays quiet for an action that exists" do
      problems = armory::Audit.(schema_with_mutation_argument(authorize: :manage)).problems

      expect(problems.map(&:path)).to eq(["DoItPayload"])
    end
  end

  context "with a Base resolver's arguments" do
    def schema_with_argument(**options)
      plugin = armory
      argument_base = base_argument
      resolver = Class.new(GraphQL::Schema::Resolver) do
        include plugin::Base
        argument_class argument_base
        graphql_name "Via"
        type String, null: true
        authorize :read, model: ArmoryMatrixDoc
        argument :raw, GraphQL::Types::Boolean, required: false, **options
      end
      type = Class.new(base_object) do
        graphql_name "Doc"
        authorize :read, model: ArmoryMatrixDoc
        field :via, resolver: resolver
      end
      schema_of(type)
    end

    it "reports a missing action" do
      expect(armory::Audit.(schema_with_argument(authorize: :nope)).problems.map(&:kind)).to include(:adapter)
    end

    it "lists a declared bypass" do
      report = armory::Audit.(schema_with_argument(authorize: :none, reason: "public flag"))

      expect(report.bypasses.map(&:reason)).to include("public flag")
    end

    it "stays quiet for an action that exists" do
      expect(armory::Audit.(schema_with_argument(authorize: :manage)).ok?).to be(true)
    end
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
