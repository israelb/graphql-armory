# frozen_string_literal: true

require "graphql/armory/versioning/rspec"

# `Versioning::Base` included in a field, argument, enum value or membership class after members were built with it:
# those members never got a lifecycle. Every query, `Versioning.types` and the audit name them and say what to do, instead
# of failing with a NoMethodError.
RSpec.describe "GraphQL::Armory::Versioning with Base included late" do
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:labels) { versioning::Controls::Versions::LABELS }
  let(:message) { /included GraphQL::Armory::Versioning::Base after .* was defined.*include Base in the class before defining/m }

  def schema_over(query_type, visibility: false)
    labels = self.labels
    Class.new(ArmoryEngine.base_schema) do
      query(query_type)
      use GraphQL::Schema::Visibility if visibility
      use GraphQL::Armory::Versioning, versions: labels, default: :latest
    end
  end

  def late_field_query
    field_class = Class.new(GraphQL::Schema::Field)
    query = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field_class field_class
      field :hi, String, null: true
      def hi = "hi"
    end
    field_class.include(GraphQL::Armory::Versioning::Base)
    query
  end

  # An input object's arguments are built when the class is defined (a field's block runs later, already with Base).
  def late_argument_query
    argument_class = Class.new(GraphQL::Schema::Argument)
    filter = Class.new(GraphQL::Schema::InputObject) do
      graphql_name "Filter"
      argument_class argument_class
      argument :text, String, required: false
    end
    argument_class.include(GraphQL::Armory::Versioning::Base)
    Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :echo, String, null: true do
        argument :filter, filter, required: false
      end
      def echo(filter: nil) = filter&.[](:text)
    end
  end

  def late_enum_value_query
    value_class = Class.new(GraphQL::Schema::EnumValue)
    color = Class.new(GraphQL::Schema::Enum) do
      graphql_name "Color"
      enum_value_class value_class
      value "RED"
    end
    value_class.include(GraphQL::Armory::Versioning::Base)
    Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :color, color, null: true
      def color = "RED"
    end
  end

  describe "a query" do
    it "security: a field built before Base raises ConfigurationError naming it, not NoMethodError" do
      schema = schema_over(late_field_query)

      expect { execute_query(schema, "{ hi }") }.to raise_error(GraphQL::Armory::Versioning::ConfigurationError, /Query\.hi/)
      expect { execute_query(schema, "{ hi }") }.to raise_error(GraphQL::Armory::Versioning::ConfigurationError, message)
    end

    it "security: an argument built before Base is named too" do
      schema = schema_over(late_argument_query)

      expect { execute_query(schema, "{ echo(filter: { text: \"a\" }) }") }
        .to raise_error(GraphQL::Armory::Versioning::ConfigurationError, /Filter\.text/)
    end

    it "security: an enum value built before Base is named too" do
      schema = schema_over(late_enum_value_query)

      expect { execute_query(schema, "{ color }") }.to raise_error(GraphQL::Armory::Versioning::ConfigurationError, /Color\.RED/)
    end

    it "preservation: Base included before the members are defined runs as before" do
      field_class = Class.new(GraphQL::Schema::Field) { include GraphQL::Armory::Versioning::Base }
      query = Class.new(GraphQL::Schema::Object) do
        graphql_name "Query"
        field_class field_class
        field :hi, String, null: true
        field :next_only, String, null: true, added: "2025-01-01"
        def hi = "hi"
        def next_only = "new"
      end
      schema = schema_over(query)
      root = Struct.new(:hi, :next_only).new("hi", "new") # Execution::Next resolves on the root object

      expect(execute_query(schema, "{ hi }", root_value: root, context: { armory_version: "2024-06-01" }).to_h)
        .to eq("data" => { "hi" => "hi" })
      expect(execute_query(schema, "{ hi nextOnly }", root_value: root, context: { armory_version: "2025-01-01" }).to_h)
        .to eq("data" => { "hi" => "hi", "nextOnly" => "new" })
    end
  end

  describe "paths that never build a query" do
    it "security: profiles: true with preload: true raises ConfigurationError while the schema is defined" do
      query = late_field_query
      labels = self.labels
      expect do
        Class.new(ArmoryEngine.base_schema) do
          query(query)
          use GraphQL::Armory::Versioning, versions: labels, default: :latest, profiles: true
          use GraphQL::Schema::Visibility, profiles: GraphQL::Armory::Versioning.profiles(self), preload: true
        end
      end.to raise_error(GraphQL::Armory::Versioning::ConfigurationError, /Query\.hi/)
    end

    it "security: a member built before Base after the schema already ran a query raises ConfigurationError, not NoMethodError" do
      query = Class.new(GraphQL::Schema::Object) do
        graphql_name "Query"
        field_class Class.new(GraphQL::Schema::Field) { include GraphQL::Armory::Versioning::Base }
        field :early, String, null: true
      end
      schema = schema_over(query)
      root = Struct.new(:early, :later).new("early", "later")
      expect(execute_query(schema, "{ early }", root_value: root).to_h).to eq("data" => { "early" => "early" })

      plain = Class.new(GraphQL::Schema::Field)
      query.field_class(plain)
      query.field(:later, String, null: true)
      plain.include(GraphQL::Armory::Versioning::Base)

      expect { execute_query(schema, "{ later }", root_value: root) }
        .to raise_error(GraphQL::Armory::Versioning::ConfigurationError, /Query\.later.*included GraphQL::Armory::Versioning::Base after/m)
    end
  end

  describe "the audit" do
    it "security: reports the late members under Schema instead of raising" do
      report = nil
      expect { report = versioning::Audit.(schema_over(late_field_query, visibility: true)) }.not_to raise_error

      expect(report.ok?).to be(false)
      refusals = report.problems.select { |problem| problem.kind == :refused && problem.path == "Schema" }.map(&:message)
      expect(refusals).to include(a_string_matching(/Query\.hi/).and(a_string_matching(message)))
    end
  end

  describe "Versioning.types" do
    it "security: refuses the schema with the same message" do
      expect { versioning.types(schema_over(late_field_query), "2025-01-01") }
        .to raise_error(GraphQL::Armory::Versioning::ConfigurationError, /Query\.hi/)
    end
  end
end
