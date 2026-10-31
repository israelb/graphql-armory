# frozen_string_literal: true

# `schema.types` is read with no request, so it leaves out what is hidden there and a request can still reach.
RSpec.describe "audit of types absent from schema.types" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:adapter) { armory::Adapters::Substitute.new(allow: false) }
  let(:base_field) do
    plugin = armory
    Class.new(GraphQL::Schema::Field) { include plugin::Base }
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

  def hidden_by_visible
    proc { def self.visible?(context) = super && context[:beta] == true }
  end

  def thing(name = "Thing", &block)
    Class.new(base_object) do
      graphql_name name
      field :secret, String, null: true
      class_eval(&block) if block
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

  def dynamic
    proc { use GraphQL::Schema::Visibility, dynamic: true }
  end

  def problems(schema)
    armory::Audit.(schema).problems
  end

  def flagged(schema)
    problems(schema).select { |problem| problem.path.end_with?(".reauthorize_scoped_objects") }
  end

  it "reports a type hidden by its own visible? under Visibility dynamic" do
    hidden = thing { reauthorize_scoped_objects(false) }
    hidden.class_eval(&hidden_by_visible)
    query = query_type { field :things, [hidden], null: true, authorize: :none, reason: "x" }
    schema = schema_for(query, setup: dynamic)

    expect(schema.types.values).not_to include(hidden)
    expect(flagged(schema).size).to eq(1)
  end

  it "reports a type reached only through a field hidden with no request" do
    hidden = thing { reauthorize_scoped_objects(false) }
    beta = Class.new(base_field) { def visible?(context) = super && context[:beta] == true }
    query = query_type do
      field_class beta
      field :things, [hidden], null: true, authorize: :none, reason: "x"
    end
    schema = schema_for(query, setup: dynamic)

    expect(schema.types.values).not_to include(hidden)
    expect(flagged(schema).size).to eq(1)
  end

  it "reports a hidden definition of a duplicated name, with no Visibility plugin" do
    first = thing { def self.visible?(context) = super && context[:beta] != true }
    second = thing { reauthorize_scoped_objects(false) }
    second.class_eval(&hidden_by_visible)
    query = query_type do
      field :things, [first], null: true, authorize: :none, reason: "x"
      field :things, [second], null: true, authorize: :none, reason: "x"
    end
    schema = schema_for(query)

    expect(schema.types["Thing"]).to equal(first)
    expect(flagged(schema).size).to eq(1)
  end

  it "runs every check on an absent type, not only the flag" do
    hidden = Class.new(GraphQL::Schema::Object) do
      graphql_name "Plain"
      field :secret, String, null: true
    end
    hidden.class_eval(&hidden_by_visible)
    query = query_type { field :plains, [hidden], null: true, authorize: :none, reason: "x" }

    expect(problems(schema_for(query, setup: dynamic)).map(&:kind)).to include(:unprotected)
  end

  it "reports the own scope_items of a connection's node that is absent" do
    hidden = thing("Hidden") { define_singleton_method(:scope_items) { |items, _context| items } }
    shown = thing("Shown")
    plugin = armory
    connection = Class.new(GraphQL::Types::Relay::BaseConnection) do
      include plugin::Base
      graphql_name "SwappedConnection"
      authorize :none, reason: "x", covers_fields: true
      edge_type(shown.edge_type)
      define_singleton_method(:node_type) { hidden }
    end
    query = query_type { field :things, connection, null: true, authorize: :none, reason: "x" }

    expect(problems(schema_for(query)).map(&:path)).to include(end_with(".scope_items"))
  end

  it "reaches hidden union members, interface implementers, orphans and argument types" do
    flag_off = proc do
      reauthorize_scoped_objects(false)
      def self.visible?(context) = super && context[:beta] == true
    end
    member = thing("Member", &flag_off)
    orphan = thing("Orphan", &flag_off)
    implementer_interface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Doc"
      field :secret, String, null: true
    end
    implementer_interface.orphan_types(thing("Implementer", &flag_off).tap { |type| type.implements(implementer_interface) })
    union = Class.new(GraphQL::Schema::Union) do
      graphql_name "Either"
      possible_types member
    end
    input = Class.new(GraphQL::Schema::InputObject) do
      graphql_name "Filter"
      argument :term, String, required: false
      def self.authorized?(_object, _arguments, _context) = true
      def self.visible?(context) = super && context[:beta] == true
    end
    query = query_type do
      field :either, union, null: true, authorize: :none, reason: "x"
      field :docs, [implementer_interface], null: true, authorize: :none, reason: "x"
      field :search, String, null: true, authorize: :none, reason: "x" do
        argument :filter, input, required: false
      end
    end
    schema = schema_for(query, setup: proc { use GraphQL::Schema::Visibility, dynamic: true; orphan_types orphan })

    expect(flagged(schema).size).to eq(3)
    expect(problems(schema).map(&:path)).to include(a_string_including(".authorized?"))
  end

  describe "an override hidden by visible_when:, which falls back to the ancestor's definition" do
    let(:interface) do
      field_klass = base_field
      Module.new do
        include GraphQL::Schema::Interface
        graphql_name "HasNotes"
        field_class field_klass
        field :notes, String, null: true
      end
    end

    def query_of(type)
      query_type { field :doc, type, null: true, authorize: :none, reason: "x" }
    end

    def doc(parent = base_object, implementing: nil)
      Class.new(parent) do
        graphql_name "Doc"
        authorize :read, model: ::Invoice
        implements implementing if implementing
        field :notes, String, null: true, authorize: :manage, visible_when: :manage
      end
    end

    it "reports it over an interface field and over a parent's field" do
      field_klass = base_field
      parent = Class.new(base_object) do
        field_class field_klass
        field :notes, String, null: true
      end

      expect(problems(schema_for(query_of(doc(implementing: interface)))).map(&:path)).to include("Doc.notes")
      expect(problems(schema_for(query_of(doc(parent)))).map(&:path)).to include("Doc.notes")
    end

    it "does not report it with Schema::Visibility, where no fallback happens" do
      expect(problems(schema_for(query_of(doc(implementing: interface)), setup: dynamic)).map(&:path)).not_to include("Doc.notes")
    end

    it "does not report a field with nothing to fall back to, or a parent hiding it the same way" do
      field_klass = base_field
      parent = Class.new(base_object) do
        field_class field_klass
        field :notes, String, null: true, visible_when: :manage
      end

      expect(problems(schema_for(query_of(doc))).map(&:path)).not_to include("Doc.notes")
      expect(problems(schema_for(query_of(doc(parent)))).map(&:path)).not_to include("Doc.notes")
    end
  end

  describe "an implementer hidden with no request" do
    let(:interface) do
      field_klass = base_field
      Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Iface"
        field_class field_klass
        field :secret, String, null: true
      end
    end
    let(:bypassed) do
      implemented = interface
      Class.new(base_object) do
        graphql_name "Bypassed"
        authorize :none, reason: "x"
        implements implemented
        def self.visible?(context) = super && context[:beta] == true
      end
    end

    def schema_with_bypassed
      implemented = interface
      implementer = bypassed
      query = query_type { field :thing, implemented, null: true, authorize: :none, reason: "x" }
      schema_for(query, setup: proc do
        use GraphQL::Schema::Visibility, dynamic: true
        orphan_types implementer
        define_singleton_method(:resolve_type) { |_abstract, _object, _context| implementer }
      end)
    end

    it "counts it as a bypass in the audit and when the field runs" do
      schema = schema_with_bypassed
      root = Struct.new(:thing).new(Struct.new(:secret).new("SECRET"))
      result = execute_query(schema, "{ thing { secret } }", root_value: root, context: { current_user: :someone, beta: true }).to_h

      expect(problems(schema).map(&:path)).to include("Iface.secret")
      expect(result.dig("data", "thing", "secret")).to be_nil
    end
  end

  it "does not raise on an interface with a duplicated field" do
    field_klass = base_field
    interface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Twice"
      field_class field_klass
      field :secret, String, null: true, authorize: :none, reason: "x"
      field :secret, String, null: true, authorize: :none, reason: "x"
    end
    implementer = thing { implements interface }
    query = query_type { field :thing, implementer, null: true, authorize: :none, reason: "x" }

    expect { problems(schema_for(query)) }.not_to raise_error
  end

  it "does not raise when every definition of a name is hidden with no request" do
    first = thing { def self.visible?(context) = super && context[:beta] == 1 }
    second = thing { def self.visible?(context) = super && context[:beta] == 2 }
    query = query_type do
      field :things, [first], null: true, authorize: :none, reason: "x"
      field :things, [second], null: true, authorize: :none, reason: "x"
    end

    expect { problems(schema_for(query)) }.not_to raise_error
  end

  it "leaves an ordinary schema with cycles clean" do
    author = Class.new(base_object) { graphql_name "Author"; authorize :none, reason: "x", covers_fields: true }
    book = Class.new(base_object) do
      graphql_name "Book"
      authorize :none, reason: "x", covers_fields: true
      field :author, author, null: true
    end
    author.field :books, book.connection_type, null: true
    query = query_type { field :books, book.connection_type, null: true, authorize: :none, reason: "x" }

    expect(problems(schema_for(query))).to eq([])
  end

  it "does not report a hidden definition twice, nor a visible one the walk also reaches" do
    hidden = thing { reauthorize_scoped_objects(false) }
    query = query_type do
      field :things, [hidden], null: true, authorize: :none, reason: "x"
      field :more, [hidden], null: true, authorize: :none, reason: "x"
    end

    expect(flagged(schema_for(query)).size).to eq(1)
    expect(problems(schema_for(query)).count { |problem| problem.path == "Thing" && problem.kind == :own_check }).to eq(0)
  end
end
