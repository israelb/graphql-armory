# frozen_string_literal: true

# graphql-ruby's install template includes ConnectionBehaviors and EdgeBehaviors in a class that already has Base.
# Those modules bring an `authorized?` that always answers true and wins over the plugin's, so a rule there never runs.
RSpec.describe "the audit and rules graphql-ruby's relay classes ignore" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:world) { Dummy::World.build }

  def build(connection: proc { authorize :none, reason: "a connection", covers_fields: true },
            edge: proc { authorize :none, reason: "an edge", covers_fields: true }, object: nil,
            direct_connection: nil, direct_edge: nil, resolver: nil, on_field: nil, **options)
    plugin = armory
    base_field = Class.new(GraphQL::Schema::Field) { include plugin::Base }
    base_field.class_eval(&on_field) if on_field
    base_object = Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class base_field
    end
    base_object.class_eval(&object) if object
    direct = lambda do |parent, body|
      Class.new(parent) do
        field_class base_field
        include plugin::Base
        class_eval(&body)
      end
    end
    connection_class = if direct_connection
      direct.(GraphQL::Types::Relay::BaseConnection, direct_connection)
    else
      Class.new(base_object) { include GraphQL::Types::Relay::ConnectionBehaviors }.tap { |klass| klass.class_eval(&connection) }
    end
    edge_class = if direct_edge
      direct.(GraphQL::Types::Relay::BaseEdge, direct_edge)
    else
      Class.new(base_object) { include GraphQL::Types::Relay::EdgeBehaviors }.tap { |klass| klass.class_eval(&edge) }
    end
    @connection_class = connection_class
    base_object.connection_type_class(connection_class)
    base_object.edge_type_class(edge_class)
    invoice_type = Class.new(base_object) do
      graphql_name "Invoice"
      authorize :read, model: ::Invoice
      field :id, String, null: false, authorize: :none, reason: "ids are public"
    end
    query_type = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "the root holds nothing"
      if resolver
        connection = invoice_type.connection_type
        field :invoices, resolver: Class.new(GraphQL::Schema::Resolver) {
          include plugin::Base
          type connection, null: true
          class_eval(&resolver)
        }
      else
        field :invoices, invoice_type.connection_type, null: true, authorize: :none, reason: "scoped by the node type"
      end
    end
    Class.new(base_schema) do
      use plugin, adapter: :pundit, **options
      query(query_type)
    end
  end

  def problems(schema)
    armory::Audit.(schema).problems.select { |problem| problem.kind == :ignored_rule }
  end

  let(:manage) { proc { authorize :manage, model: ::Invoice } }

  it "reports a rule on a connection class" do
    schema = build(connection: manage)

    expect(problems(schema).map(&:path)).to eq(["InvoiceConnection"])
    expect(problems(schema).first.message).to match(/never runs/).and match(/on a root field/).and match(/covers_fields: true/)
    expect(armory::Audit.(schema).ok?).to be(false)
  end

  it "reports a rule on an edge class" do
    expect(problems(build(edge: manage)).map(&:path)).to eq(["InvoiceEdge"])
  end

  it "reports a rule the class inherits from its base object" do
    schema = build(connection: proc {}, edge: proc {}, object: proc { authorize :read, model: ::Invoice })

    expect(problems(schema).map(&:path)).to contain_exactly("InvoiceConnection", "InvoiceEdge")
  end

  it "reports a default action the class inherits from its base object, once and with nothing else about it" do
    schema = build(connection: proc {}, object: proc { default_action :read })
    about_connection = armory::Audit.(schema).problems.select { |problem| problem.path.start_with?("InvoiceConnection") }

    expect(about_connection.map(&:kind)).to eq([:ignored_rule])
  end

  it "reports nothing for authorize :none, which says what really happens" do
    schema = build

    expect(problems(schema)).to eq([])
    expect(armory::Audit.(schema).ok?).to be(true)
  end

  # Verifier probes.
  describe "a class that subclasses graphql-ruby's relay classes directly" do
    let(:with_policy) { proc { authorize :manage, policy: InvoicePolicy } }

    def own_checks(schema)
      armory::Audit.(schema).problems.select { |problem| problem.kind == :own_check }
    end

    it "reports its own self.authorized?, which skips the rule" do
      rule = with_policy
      schema = build(direct_connection: proc do
        class_eval(&rule)
        def self.authorized?(_object, _context) = true
      end)

      expect(own_checks(schema).map(&:path)).to contain_exactly(end_with(".authorized?"))
      expect(run(schema).dig("data", "invoices", "pageInfo", "hasNextPage")).to be(false)
    end

    it "reports its own self.authorizes? and one that comes through extend" do
      own = Module.new { def authorized?(_object, _context) = true }
      rule = with_policy

      expect(own_checks(build(direct_connection: proc do
        class_eval(&rule)
        def self.authorizes?(_context) = false
      end)).map(&:path)).to contain_exactly(end_with(".authorizes?"))
      expect(own_checks(build(direct_connection: proc do
        class_eval(&rule)
        extend own
      end)).map(&:path)).to contain_exactly(end_with(".authorized?"))
    end

    it "lists a declared check as a bypass, not as a declaration that matches nothing" do
      plugin = armory
      schema = build(direct_connection: proc do
        authorize :manage, policy: InvoicePolicy
        def self.authorized?(_object, _context) = true
      end)
      holder = @connection_class
      declared = Class.new(schema) { use plugin, adapter: :pundit, own_checks: { holder => { authorized?: "checked elsewhere" } } }

      expect(own_checks(declared)).to eq([])
      expect(armory::Audit.(declared).bypasses.map(&:reason)).to include("checked elsewhere")
    end

    it "reports a rule on an edge class, which the nodes path never builds" do
      schema = build(direct_edge: with_policy)

      expect(problems(schema).map(&:path)).to eq(["InvoiceEdge"])
      expect(problems(schema).first.message).to match(/nodes/)
      expect(run(schema, "{ invoices { nodes { id } } }").dig("data", "invoices", "nodes")).not_to be_empty
    end

    it "does not report a rule on an edge class when the connection has no nodes field" do
      schema = build(direct_edge: with_policy, connection: proc do
        has_nodes_field(false)
        authorize :none, reason: "a connection", covers_fields: true
      end)

      expect(problems(schema)).to eq([])
      expect(run(schema, "{ invoices { edges { node { id } } } }").dig("data", "invoices", "edges")).to all(be_nil)
    end

    it "does not report a rule on a connection class, which does run" do
      schema = build(direct_connection: with_policy)

      expect(problems(schema)).to eq([])
      expect(run(schema).dig("data", "invoices")).to be_nil
    end
  end

  it "reports visible_when: on a template class, which its own visible? ignores" do
    schema = build(connection: proc { authorize :none, reason: "x", covers_fields: true, visible_when: :manage, model: ::Invoice })

    expect(problems(schema).map(&:path)).to eq(["InvoiceConnection"])
    expect(problems(schema).first.message).to match(/visible_when/)
  end

  describe "telling graphql-ruby's methods from the app's by where they are defined, not by their name" do
    after { GraphQL.send(:remove_const, :ArmoryProbeChecks) if GraphQL.const_defined?(:ArmoryProbeChecks, false) }

    def own_checks(schema)
      armory::Audit.(schema).problems.select { |problem| problem.kind == :own_check }
    end

    it "reports an app's check held in a module under the GraphQL namespace, and not as an ignored rule when it reaches the plugin" do
      GraphQL.const_set(:ArmoryProbeChecks, Module.new { def authorized?(object, context) = super })
      own = GraphQL::ArmoryProbeChecks
      schema = build(object: proc { extend own })

      expect(own_checks(schema).map(&:path)).to eq(["GraphQL::ArmoryProbeChecks.authorized?"])
      expect(problems(schema)).to eq([])
    end

    it "reports graphql-ruby's authorized? grafted onto an app's base field, which skips the rule" do
      schema = build(on_field: proc { define_method(:authorized?, GraphQL::Schema::Field.instance_method(:authorized?)) })

      expect(own_checks(schema).map(&:path)).to contain_exactly(end_with("#authorized?"))
    end

    it "reports graphql-ruby's authorized? grafted onto an app's resolver, which skips the rule" do
      schema = build(resolver: proc do
        authorize :manage, model: ::Invoice
        define_method(:authorized?, GraphQL::Schema::Resolver.instance_method(:authorized?))
        def resolve = ::Invoice.all
      end)

      expect(own_checks(schema).map(&:path)).to contain_exactly(end_with("#authorized?"))
    end

    it "keeps a rule ignored when a declared check on a template class only calls super" do
      plugin = armory
      schema = build(connection: proc do
        authorize :manage, model: ::Invoice
        def self.authorized?(object, context) = super
      end)
      holder = @connection_class
      declared = Class.new(schema) { use plugin, adapter: :pundit, own_checks: { holder => { authorized?: "calls super" } } }

      expect(problems(declared).map(&:path)).to eq(["InvoiceConnection"])
      expect(armory::Audit.(declared).ok?).to be(false)
    end
  end

  it "pins that a resolver's rule refuses on a root connection field, where a field rule has no parent to ask" do
    schema = build(resolver: proc do
      authorize :manage, model: ::Invoice
      def resolve = ::Invoice.all
    end)

    expect(problems(schema)).to eq([])
    expect(run(schema).dig("data", "invoices")).to be_nil
  end

  # What the report is for.
  it "pins that the rule does not run for a user it refuses" do
    expect(run(build(connection: manage)).dig("data", "invoices", "pageInfo", "hasNextPage")).to be(false)
  end

  def run(schema, query = "{ invoices { pageInfo { hasNextPage } } }")
    world
    root = Struct.new(:invoices).new(::Invoice.all)
    execute_query(schema, query, context: { current_user: world.alice }, root_value: root).to_h
  end
end
