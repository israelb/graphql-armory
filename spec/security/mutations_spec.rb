# frozen_string_literal: true

# A mutation is an action, not a read: it always needs an explicit rule, and it is checked after its
# `loads:` arguments are loaded through the user's scope, so the policy sees the record.
RSpec.describe "Authorization of mutations" do
  let(:world) { Dummy::World.build }
  let(:calls) { [] }

  def schema_for(adapter, on_denied: :default, with_rule: true, action: :approve, on_unauthorized: :null)
    armory = GraphQL::Armory::Authorization
    calls = self.calls
    base_argument = Class.new(GraphQL::Schema::Argument) { include armory::Base }
    base_field = Class.new(GraphQL::Schema::Field) do
      include armory::Base
      argument_class base_argument
    end
    base_object = Class.new(GraphQL::Schema::Object) do
      include armory::Base
      field_class base_field
      default_action :read
    end
    payload = Class.new(base_object) do
      authorize :none, reason: "payload of a mutation that checks its own rule", covers_fields: true
    end
    invoice = Class.new(base_object) do
      graphql_name "Invoice"
      field :number, String, null: false
    end
    error = Class.new(payload) do
      graphql_name "MutationError"
      field :message, String, null: false, hash_key: :message
      field :code, String, null: false, hash_key: :code
    end
    base_mutation = Class.new(GraphQL::Schema::Mutation) do
      include armory::Base
      object_class payload
      field_class base_field
      argument_class base_argument
    end
    approve = Class.new(base_mutation) do
      graphql_name "ApproveInvoice"
      authorize action, model: Invoice, on_denied: on_denied if with_rule
      argument :invoice_id, GraphQL::Types::ID, loads: invoice
      field :invoice, invoice, null: true, hash_key: :invoice
      field :errors, [error], null: false, hash_key: :errors

      define_method(:resolve) do |invoice:|
        calls << invoice.number
        { invoice: invoice, errors: [] }
      end
    end
    forgotten = Class.new(base_mutation) do
      graphql_name "Forgotten"
      field :ok, GraphQL::Types::Boolean, null: false

      define_method(:resolve) do
        calls << :forgotten
        { ok: true }
      end
    end
    mutation = Class.new(base_object) do
      graphql_name "Mutation"
      authorize :none, reason: "root type; each mutation declares its own rule"
      field :approve_invoice, mutation: approve
      field :forgotten, mutation: forgotten
    end
    query = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root type"
      field :ping, String, null: false, authorize: :none, reason: "health check"
    end

    Class.new(ArmoryEngine.base_schema) do
      query query
      mutation mutation
      use armory, adapter: adapter, on_unauthorized: on_unauthorized
    end
  end

  def approve(schema, user, id)
    query = "mutation($id: ID!) { approveInvoice(invoiceId: $id) { invoice { number } errors { message code } } }"
    execute_query(schema, query, variables: { "id" => id.to_s }, context: { current_user: user }, root_value: Object.new)
  end

  %i[pundit cancan].each do |adapter|
    describe "with #{adapter}" do
      let(:schema) { schema_for(adapter) }

      it "runs the mutation for a user who has the right on the record" do
        result = approve(schema, world.carol, world.a1.id)

        expect([result.dig("data", "approveInvoice", "invoice", "number"), calls]).to eq(["A-1", ["A-1"]])
      end

      it "does not run it for a user without the right, and answers null" do
        result = approve(schema, world.alice, world.a1.id)

        expect([result["data"], calls]).to eq([{ "approveInvoice" => nil }, []])
      end

      it "answers a foreign record like one that does not exist: the load goes through the scope" do
        foreign = approve(schema, world.carol, world.b1.id)
        missing = approve(schema, world.carol, 999_999)

        expect([foreign, calls]).to eq([missing, []])
      end

      it "returns errors as data with on_denied: :errors, and still does not run" do
        result = approve(schema_for(adapter, on_denied: :errors), world.alice, world.a1.id)

        expect([result.dig("data", "approveInvoice"), calls]).to eq(
          [{ "invoice" => nil, "errors" => [{ "message" => "Not allowed", "code" => "FORBIDDEN" }] }, []]
        )
      end

      it "follows the schema's error mode by default" do
        result = approve(schema_for(adapter, on_unauthorized: :error), world.alice, world.a1.id)

        expect(result["errors"].map { |e| e["message"] }).to eq(["Not found"])
      end

      it "denies a mutation that declares no rule, even to an admin" do
        query = "mutation { forgotten { ok } }"
        result = execute_query(schema, query, context: { current_user: world.carol }, root_value: Object.new)

        expect([result["data"], calls]).to eq([{ "forgotten" => nil }, []])
      end

      it "lists in the audit a mutation with no rule and a bypass with its reason" do
        report = GraphQL::Armory::Authorization::Audit.(schema)

        expect([report.problems.any? { |p| p.kind == :no_rule && p.path == "Mutation.forgotten" },
                report.bypasses.map(&:path).include?("Mutation")]).to eq([true, true])
      end

      it "reports in the audit an action the policy does not define" do
        problems = GraphQL::Armory::Authorization::Audit.(schema_for(adapter, action: :no_such_action)).problems

        expect(problems.any? { |p| p.kind == :adapter }).to be(adapter == :pundit)
      end
    end
  end

  it "refuses an on_denied it does not know instead of ignoring it" do
    expect { schema_for(:pundit, on_denied: :bogus) }.to raise_error(ArgumentError, /on_denied/)
  end
end
