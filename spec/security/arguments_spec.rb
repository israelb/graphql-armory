# frozen_string_literal: true

# An argument covered by its field needs nothing; one that declares a rule is checked when the client sends it.
RSpec.describe "Authorization of arguments" do
  Archive = Struct.new(:invoices) do
    def invoices(include_internal: false, limit: nil, internal_tag: nil)
      @list
    end

    def list=(list)
      @list = list
    end
  end

  let(:world) { Dummy::World.build }

  def schema_for(adapter, argument_options: { authorize: :manage, model: Invoice })
    armory = GraphQL::Armory::Authorization
    base_argument = Class.new(GraphQL::Schema::Argument) { include armory::Base }
    base_field = Class.new(GraphQL::Schema::Field) do
      include armory::Base
      argument_class base_argument
    end
    base = Class.new(GraphQL::Schema::Object) do
      include armory::Base
      field_class base_field
      default_action :read
    end
    invoice = Class.new(base) do
      graphql_name "Invoice"
      field :number, String, null: false
    end
    options = argument_options
    query = Class.new(base) do
      graphql_name "Query"
      authorize :none, reason: "root type"
      field :invoices, [invoice], authorize: :none, reason: "narrowed by the scope" do
        argument :include_internal, GraphQL::Types::Boolean, required: false, **options
        argument :limit, Integer, required: false
        argument :internal_tag, String, required: false, visible_when: :export, model: Invoice
      end
    end

    Class.new(ArmoryEngine.base_schema) do
      query query
      use armory, adapter: adapter
    end
  end

  def run(schema, user, query)
    archive = Archive.new
    archive.list = [world.a1, world.a2]
    execute_query(schema, query, context: { current_user: user }, root_value: archive)
  end

  def numbers(result)
    result.dig("data", "invoices")&.map { |invoice| invoice["number"] }
  end

  %i[pundit cancan].each do |adapter|
    describe "with #{adapter}" do
      let(:schema) { schema_for(adapter) }

      it "lets everyone omit the restricted argument" do
        expect(numbers(run(schema, world.alice, "{ invoices { number } }"))).to eq(%w[A-1 A-2])
      end

      it "denies the field to a user who sends the restricted argument without the right" do
        result = run(schema, world.alice, "{ invoices(includeInternal: true) { number } }")

        expect(result["data"]).to eq("invoices" => nil)
      end

      it "denies it even when the value sent is false, because the argument was used" do
        result = run(schema, world.alice, "{ invoices(includeInternal: false) { number } }")

        expect(result["data"]).to eq("invoices" => nil)
      end

      it "answers the field to a user who has the right" do
        expect(numbers(run(schema, world.carol, "{ invoices(includeInternal: true) { number } }"))).to eq(%w[A-1 A-2])
      end

      it "leaves an argument with no rule to its field" do
        expect(numbers(run(schema, world.alice, "{ invoices(limit: 1) { number } }"))).to eq(%w[A-1 A-2])
      end

      it "hides an argument with visible_when from users who cannot export, like one that never existed" do
        hidden = run(schema, world.alice, '{ invoices(internalTag: "x") { number } }')["errors"].map { |e| e["message"] }
        never = run(schema, world.alice, '{ invoices(neverExisted: "x") { number } }')["errors"].map { |e| e["message"] }

        expect(hidden.map { |m| m.sub("internalTag", "X") }).to eq(never.map { |m| m.sub("neverExisted", "X") })
      end

      it "shows that argument in introspection only to users who can export" do
        query = '{ __type(name: "Query") { fields { name args { name } } } }'
        names = ->(user) { run(schema, user, query).dig("data", "__type", "fields").find { |f| f["name"] == "invoices" }["args"].map { |a| a["name"] }.sort }

        expect([names.(world.alice).include?("internalTag"), names.(world.carol).include?("internalTag")]).to eq([false, true])
      end

      it "reports in the audit an argument action the policy does not define" do
        broken = schema_for(adapter, argument_options: { authorize: :no_such_action, model: Invoice })

        problems = GraphQL::Armory::Authorization::Audit.(broken).problems.select { |p| p.kind == :adapter }

        expect(problems.empty?).to be(adapter == :cancan)
      end

      it "lists a bypassed argument in the audit with its reason" do
        bypassed = schema_for(adapter, argument_options: { authorize: :none, reason: "public filter" })

        report = GraphQL::Armory::Authorization::Audit.(bypassed)

        expect(report.bypasses.map(&:path)).to include("Query.invoices(include_internal)")
      end
    end
  end

  it "asks for a model when the field's type wraps none" do
    schema = schema_for(:pundit, argument_options: { authorize: :manage })

    expect { run(schema, world.alice, "{ invoices(includeInternal: true) { number } }") }
      .to raise_error(GraphQL::Armory::Authorization::ConfigurationError, /model:/)
  end

  it "refuses `authorize: true` on an argument instead of ignoring it" do
    expect { schema_for(:pundit, argument_options: { authorize: true }) }.to raise_error(ArgumentError, /authorize/)
  end
end
