# frozen_string_literal: true

# Hidden from a user, a definition falls back to another of its name: graphql-ruby's `get_field` and `get_argument`
# skip what the Warden hides, whenever a request runs with a plain Hash context (no profile, or a static one).
RSpec.describe "audit of redefined arguments and static profiles" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:adapter) { armory::Adapters::Substitute.new(allow: false) }
  let(:base_field) do
    plugin = armory
    Class.new(GraphQL::Schema::Field) { include plugin::Base }
  end
  let(:base_argument) do
    plugin = armory
    Class.new(GraphQL::Schema::Argument) { include plugin::Base }
  end
  let(:base_object) do
    plugin = armory
    field = base_field
    Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class field
      default_action :read
    end
  end
  let(:base_input) do
    plugin = armory
    argument = base_argument
    Class.new(GraphQL::Schema::InputObject) do
      include plugin::Base
      argument_class argument
    end
  end

  def query_type(&block)
    Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :ping, String, null: true, authorize: :none, reason: "x"
      class_eval(&block)
    end
  end

  def schema_for(query_class, setup: nil)
    plugin = armory
    armory_adapter = adapter
    Class.new(base_schema) do
      use plugin, adapter: armory_adapter
      query query_class
      class_eval(&setup) if setup
    end
  end

  def report(schema)
    armory::Audit.(schema)
  end

  def redefinitions(schema)
    report(schema).problems.select { |problem| problem.kind == :ignored_rule }.map(&:path)
  end

  def doc_over_parent(**child_options)
    field_klass = base_field
    parent = Class.new(base_object) do
      field_class field_klass
      authorize :read, model: ::Invoice
      field :notes, String, null: true
    end
    Class.new(parent) do
      graphql_name "Doc"
      field :notes, String, null: true, **child_options
    end
  end

  def query_of(type)
    query_type { field :doc, type, null: true, authorize: :none, reason: "x" }
  end

  describe "Schema::Visibility that still falls back" do
    it "reports a redefinition under a static profile, alone or beside dynamic: true" do
      static = schema_for(query_of(doc_over_parent(authorize: :manage)), setup: proc { use GraphQL::Schema::Visibility, profiles: { public: {} } })
      mixed = schema_for(query_of(doc_over_parent(authorize: :manage)), setup: proc { use GraphQL::Schema::Visibility, dynamic: true, profiles: { public: {} } })

      expect(redefinitions(static)).to include("Doc.notes")
      expect(redefinitions(mixed)).to include("Doc.notes")
    end

    it "reports it when a child schema turns the profile off" do
      parent = schema_for(query_of(doc_over_parent(authorize: :manage)), setup: proc { use GraphQL::Schema::Visibility, dynamic: true })
      child = Class.new(parent) { self.use_visibility_profile = false }

      expect(redefinitions(parent)).to eq([])
      expect(redefinitions(child)).to include("Doc.notes")
    end
  end

  describe "a redefined argument" do
    def filter_over_parent(**child_options)
      parent = Class.new(base_input) do
        graphql_name "Filter"
        argument :internal, GraphQL::Types::Boolean, required: false
      end
      Class.new(parent) do
        graphql_name "Filter"
        argument :internal, GraphQL::Types::Boolean, required: false, **child_options
      end
    end

    def query_with_filter(input)
      query_type do
        field :notes, String, null: true, authorize: :none, reason: "x" do
          argument :filter, input, required: false
        end
      end
    end

    it "reports an input object's argument redefined over its parent's, and takes its declaration" do
      plain = schema_for(query_with_filter(filter_over_parent(authorize: :manage)))
      declared = schema_for(query_with_filter(filter_over_parent(authorize: :manage, override_reason: "the parent's argument is as strict")))

      expect(redefinitions(plain)).to include("Filter.internal")
      expect(redefinitions(declared)).to eq([])
      expect(report(declared).bypasses.map(&:reason)).to include("the parent's argument is as strict")
    end

    it "reports both definitions of one argument on one input object" do
      twice = Class.new(base_input) do
        graphql_name "Filter"
        argument :internal, GraphQL::Types::Boolean, required: false, authorize: :manage
        argument :internal, GraphQL::Types::Boolean, required: false
      end

      expect(redefinitions(schema_for(query_with_filter(twice))).count("Filter.internal")).to eq(2)
    end

    it "reports a resolver's argument redefined over its parent resolver's" do
      plugin = armory
      argument_klass = base_argument
      parent = Class.new(GraphQL::Schema::Resolver) do
        include plugin::Base
        graphql_name "Notes"
        argument_class argument_klass
        type String, null: true
        authorize :none, reason: "x"
        argument :term, String, required: false
      end
      child = Class.new(parent) do
        graphql_name "Notes"
        argument :term, String, required: false, authorize: :manage
      end
      query = query_type { field :notes, resolver: child }

      expect(redefinitions(schema_for(query))).to include("Query.notes.term")
    end

    it "reports an override_reason: with nothing to declare, and refuses a blank one" do
      lone = Class.new(base_input) do
        graphql_name "Filter"
        argument :internal, GraphQL::Types::Boolean, required: false, override_reason: "stale"
      end

      expect(redefinitions(schema_for(query_with_filter(lone)))).to include("Filter.internal")
      expect { filter_over_parent(override_reason: " ") }.to raise_error(armory::ConfigurationError)
    end

    it "does not report arguments nobody redefines, nor under dynamic Visibility" do
      lone = Class.new(base_input) do
        graphql_name "Filter"
        argument :internal, GraphQL::Types::Boolean, required: false
        argument :term, String, required: false, authorize: :manage
      end
      dynamic = schema_for(query_with_filter(filter_over_parent(authorize: :manage)), setup: proc { use GraphQL::Schema::Visibility, dynamic: true })

      expect(redefinitions(schema_for(query_with_filter(lone)))).to eq([])
      expect(redefinitions(dynamic)).to eq([])
    end
  end
end
