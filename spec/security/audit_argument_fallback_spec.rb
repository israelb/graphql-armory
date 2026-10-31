# frozen_string_literal: true

# Hidden from a user, a definition falls back to another of its name: graphql-ruby's `get_field` and `get_argument`
# skip what the Warden hides, whenever a request runs with a plain Hash context (no profile, or a static one).
RSpec.describe "audit of redefined arguments and static profiles" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:adapter) { armory::Adapters::Substitute.new(allow: false) }
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

  describe "what Schema::Visibility does not stop" do
    # `Visibility::Profile` skips the ancestor fallback, but among duplicates on one owner it still picks the visible one.
    it "reports duplicates on one owner under dynamic: true" do
      twice_field = Class.new(base_object) do
        graphql_name "Doc"
        authorize :read, model: ::Invoice
        field :notes, String, null: true, authorize: :manage
        field :notes, String, null: true
      end
      twice_argument = Class.new(base_input) do
        graphql_name "Filter"
        argument :internal, GraphQL::Types::Boolean, required: false, authorize: :manage
        argument :internal, GraphQL::Types::Boolean, required: false
      end
      query = query_type do
        field :doc, twice_field, null: true, authorize: :none, reason: "x"
        field :notes, String, null: true, authorize: :none, reason: "x" do
          argument :filter, twice_argument, required: false
        end
      end
      schema = schema_for(query, setup: proc { use GraphQL::Schema::Visibility, dynamic: true })

      expect(redefinitions(schema)).to include("Doc.notes", "Filter.internal")
    end

    # `schema.types` is what loads `field do ... end` blocks; a profile-only schema refuses that call.
    it "reads field blocks when static profiles come before the roots" do
      plugin = armory
      armory_adapter = adapter
      query = query_type do
        field :notes, String, null: true, authorize: :none, reason: "x" do
          argument :internal, GraphQL::Types::Boolean, required: false, authorize: :manage
          argument :internal, GraphQL::Types::Boolean, required: false
        end
      end
      schema = Class.new(base_schema) do
        use GraphQL::Schema::Visibility, profiles: { public: {} }
        use plugin, adapter: armory_adapter
        query query
      end

      expect(redefinitions(schema)).to include("Query.notes.internal")
    end
  end

  describe "a shadowed definition" do
    # A declared override still falls back: whatever it falls back to is audited like any field.
    it "audits the parent's field a declared override shadows" do
      plugin = armory
      argument_klass = base_argument
      parent_resolver = Class.new(GraphQL::Schema::Resolver) do
        include plugin::Base
        graphql_name "Notes"
        argument_class argument_klass
        type String, null: true
        authorize :none, reason: "x"
        argument :internal, GraphQL::Types::Boolean, required: false
      end
      child_resolver = Class.new(parent_resolver) do
        graphql_name "Notes"
        argument :internal, GraphQL::Types::Boolean, required: false, authorize: :manage
      end
      field_klass = base_field
      parent = Class.new(base_object) do
        field_class field_klass
        authorize :read, model: ::Invoice
        field :notes, resolver: child_resolver
      end
      child = Class.new(parent) do
        graphql_name "Doc"
        field :notes, String, null: true, override_reason: "the parent's field is as strict"
      end

      expect(redefinitions(schema_for(query_of(child)))).to include("Doc.notes.internal")
    end
  end

  describe "the shadowed definition's own checks" do
    def abstract_parent(&block)
      field_klass = base_field
      Class.new(base_object) do
        field_class field_klass
        authorize :read, model: ::Invoice
        class_eval(&block)
      end
    end

    def declared_child(parent)
      Class.new(parent) do
        graphql_name "Doc"
        field :notes, String, null: true, authorize: :manage, override_reason: "the parent's field is as strict"
      end
    end

    it "reports a shadowed resolver's own authorized?" do
      plugin = armory
      open = Class.new(GraphQL::Schema::Resolver) do
        include plugin::Base
        graphql_name "OpenNotes"
        type String, null: true
        authorize :manage, model: ::Invoice
        def authorized?(**) = true
      end
      child = declared_child(abstract_parent { field :notes, resolver: open })

      expect(report(schema_for(query_of(child))).problems.map(&:kind)).to include(:own_check)
    end

    it "does not swallow an error raised while checking a shadowed field" do
      plugin = armory
      boom = plugin::Adapters::Substitute.new(allow: false, raises_on_check: plugin::ConfigurationError.new("boom"))
      child = declared_child(abstract_parent { field :notes, String, null: true, authorize: :manage })
      query = query_of(child)
      schema = Class.new(base_schema) do
        use plugin, adapter: boom
        query query
      end

      expect { report(schema) }.to raise_error(plugin::ConfigurationError, "boom")
    end
  end

  describe "a field inherited by a bypassed type" do
    # graphql-ruby runs a field under its owner's rule, and the owner's type check never ran here: it is served.
    it "is reported as served, not as denied" do
      field_klass = base_field
      parent = Class.new(base_object) do
        field_class field_klass
        authorize :read, model: ::Invoice
        field :notes, String, null: true
      end
      child = Class.new(parent) do
        graphql_name "Doc"
        authorize :none, reason: "public"
      end
      schema = schema_for(query_of(child))
      root = Struct.new(:doc).new(Struct.new(:notes).new("SECRET"))
      result = execute_query(schema, "{ doc { notes } }", root_value: root, context: { current_user: :someone }).to_h

      problem = report(schema).problems.find { |candidate| candidate.path == "Doc.notes" }

      expect(problem.kind).to eq(:field_without_rule)
      expect(problem.message).to include("served with no check")
      expect(result.dig("data", "doc", "notes")).to eq("SECRET")
    end

    # `armory_rule_for` covers a field whose owner knows no rule at all; nothing checks it on the bypassed type.
    it "is reported as served when the parent does not include Base" do
      plugin = armory
      field_klass = base_field
      parent = Class.new(GraphQL::Schema::Object) do
        field_class field_klass
        field :notes, String, null: true
      end
      child = Class.new(parent) do
        include plugin::Base
        graphql_name "Doc"
        authorize :none, reason: "public"
      end
      schema = schema_for(query_of(child))
      root = Struct.new(:doc).new(Struct.new(:notes).new("SECRET"))
      result = execute_query(schema, "{ doc { notes } }", root_value: root, context: { current_user: :someone }).to_h

      expect(report(schema).problems.find { |candidate| candidate.path == "Doc.notes" }.message).to include("served with no check")
      expect(result.dig("data", "doc", "notes")).to eq("SECRET")
    end

    # graphql-ruby's own `Field#authorized?` answers true: a field class without Base checks nothing, own or inherited.
    it "is reported as served when the field class does not include Base" do
      field_klass = base_field
      parent = Class.new(base_object) do
        field_class field_klass
        authorize :read, model: ::Invoice
        field_class GraphQL::Schema::Field
        field :notes, String, null: true
      end
      child = Class.new(parent) do
        graphql_name "Doc"
        authorize :none, reason: "public"
        field_class GraphQL::Schema::Field
        field :own, String, null: true
      end
      schema = schema_for(query_of(child))
      root = Struct.new(:doc).new(Struct.new(:notes, :own).new("SECRET", "MINE"))
      result = execute_query(schema, "{ doc { notes own } }", root_value: root, context: { current_user: :someone }).to_h
      messages = report(schema).problems.select { |candidate| candidate.path.start_with?("Doc.") }.to_h { |problem| [problem.path, problem.message] }

      expect(messages.fetch("Doc.notes")).to include("does not include Base", "served with no check")
      expect(messages.fetch("Doc.own")).to include("does not include Base", "served with no check")
      expect(result.dig("data", "doc").values).to eq(%w[SECRET MINE])
    end

    it "does not call authorize: true served, since it runs under the owner's rule" do
      field_klass = base_field
      parent = Class.new(base_object) do
        field_class field_klass
        authorize :read, model: ::Invoice
        field :notes, String, null: true, authorize: true
      end
      doc = Class.new(parent) do
        graphql_name "Doc"
        authorize :none, reason: "public"
      end
      schema = schema_for(query_of(doc))
      root = Struct.new(:doc).new(Struct.new(:notes).new("SECRET"))
      result = execute_query(schema, "{ doc { notes } }", root_value: root, context: { current_user: :someone }).to_h
      problem = report(schema).problems.find { |candidate| candidate.path == "Doc.notes" }

      expect(problem&.message.to_s).not_to include("served")
      expect(result.dig("data", "doc", "notes")).to be_nil
    end

    it "still says denied when the parent has no rule of its own" do
      plugin = armory
      field_klass = base_field
      parent = Class.new(GraphQL::Schema::Object) do
        include plugin::Base
        field_class field_klass
        field :notes, String, null: true
      end
      child = Class.new(parent) do
        graphql_name "Doc"
        authorize :none, reason: "public"
      end
      root = Struct.new(:doc).new(Struct.new(:notes).new("SECRET"))
      schema = schema_for(query_of(child))
      result = execute_query(schema, "{ doc { notes } }", root_value: root, context: { current_user: :someone }).to_h

      expect(report(schema).problems.find { |candidate| candidate.path == "Doc.notes" }.message).to include("so it is denied")
      expect(result.dig("data", "doc", "notes")).to be_nil
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
