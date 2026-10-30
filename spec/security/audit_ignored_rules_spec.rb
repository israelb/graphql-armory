# frozen_string_literal: true

# graphql-ruby's install template includes ConnectionBehaviors and EdgeBehaviors in a class that already has Base.
# Those modules bring an `authorized?` that always answers true and wins over the plugin's, so a rule there never runs.
RSpec.describe "the audit and rules graphql-ruby's relay classes ignore" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:world) { Dummy::World.build }

  def build(connection: proc { authorize :none, reason: "a connection", covers_fields: true },
            edge: proc { authorize :none, reason: "an edge", covers_fields: true }, object: nil)
    plugin = armory
    base_field = Class.new(GraphQL::Schema::Field) { include plugin::Base }
    base_object = Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class base_field
    end
    base_object.class_eval(&object) if object
    connection_class = Class.new(base_object) { include GraphQL::Types::Relay::ConnectionBehaviors }
    connection_class.class_eval(&connection)
    edge_class = Class.new(base_object) { include GraphQL::Types::Relay::EdgeBehaviors }
    edge_class.class_eval(&edge)
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
      field :invoices, invoice_type.connection_type, null: true, authorize: :none, reason: "scoped by the node type"
    end
    Class.new(base_schema) do
      use plugin, adapter: :pundit
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
    expect(problems(schema).first.message).to match(/never runs/).and match(/on the field/)
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

  # What the report is for.
  it "pins that the rule does not run for a user it refuses" do
    root = Struct.new(:invoices).new(::Invoice.all)
    world

    result = execute_query(build(connection: manage), "{ invoices { pageInfo { hasNextPage } } }",
                           context: { current_user: world.alice }, root_value: root).to_h

    expect(result.dig("data", "invoices", "pageInfo", "hasNextPage")).to be(false)
  end
end
