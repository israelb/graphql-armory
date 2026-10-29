# frozen_string_literal: true

RSpec.describe "GraphQL::Armory::Authorization lists and lookups" do
  let(:authorization) { GraphQL::Armory::Authorization }
  let(:world) { Dummy::World.build }

  def run(query, user:, mode: :null, type_action: :read, **root)
    schema = IntegrationSchema.build(on_unauthorized: mode, type_action: type_action)
    execute_query(schema, query, context: { current_user: user }, root_value: IntegrationSchema::Root.new(**root))
  end

  describe "a list" do
    it "never includes another account's objects" do
      result = run("{ invoices { number } }", user: world.alice, invoices: [world.a1, world.b1, world.a2])

      expect(result["data"]["invoices"]).to eq([{ "number" => "A-1" }, { "number" => "A-2" }])
    end

    it "is empty for a user who owns nothing in it" do
      result = run("{ invoices { number } }", user: world.bob, invoices: [world.a1, world.a2])

      expect(result["data"]["invoices"]).to eq([])
    end

    it "is empty when the type has no rule" do
      result = run("{ invoices { number } }", user: world.alice, type_action: nil, invoices: [world.a1])

      expect(result["data"]["invoices"]).to eq([])
    end

    it "still authorizes every item the scope let through" do
      schema = IntegrationSchema.build(adapter: authorization::Adapters::Substitute.new(allow: false))

      result = execute_query(schema, "{ invoices { number } }", context: { current_user: world.alice },
                                                                root_value: IntegrationSchema::Root.new(invoices: [world.a1, world.a2]))

      expect(result["data"]["invoices"]).to eq([nil, nil])
    end

    it "fails the query, not open, when the policy has no Scope" do
      note_type = Class.new(GraphQL::Schema::Object) do
        include GraphQL::Armory::Authorization::Base
        graphql_name "NoteThing"
        default_action :read
      end
      context = authorization::Controls::Context.example(current_user: world.alice)
      context.define_singleton_method(:schema) { IntegrationSchema.build }

      expect { note_type.scope_items(Note.all, context) }.to raise_error(authorization::MissingScopeError)
    end
  end

  describe "a connection" do
    let(:query) { "{ invoicesConnection(first: 1) { nodes { number } pageInfo { hasNextPage } totalCount } }" }

    it "paginates over the scoped relation" do
      world

      result = run(query, user: world.alice, invoices_connection: Invoice.order(:id))

      expect(result["data"]["invoicesConnection"]).to eq(
        "nodes" => [{ "number" => "A-1" }], "pageInfo" => { "hasNextPage" => true }, "totalCount" => 2
      )
    end

    it "counts only what the user may see" do
      world

      result = run(query, user: world.bob, invoices_connection: Invoice.order(:id))

      expect(result["data"]["invoicesConnection"]).to eq(
        "nodes" => [{ "number" => "B-1" }], "pageInfo" => { "hasNextPage" => false }, "totalCount" => 1
      )
    end
  end

  describe "a lookup by key through the scope" do
    let(:query) { "query($id: ID!) { invoice(id: $id) { number } }" }

    def lookup(user, id, mode: :null)
      schema = IntegrationSchema.build(on_unauthorized: mode)
      execute_query(schema, query, variables: { "id" => id.to_s }, context: { current_user: user },
                                   root_value: IntegrationSchema::Root.new)
    end

    it "finds an object of the user's own account" do
      expect(lookup(world.alice, world.a1.id)["data"]).to eq("invoice" => { "number" => "A-1" })
    end

    it "answers exactly as if the object did not exist when it belongs to someone else" do
      foreign = lookup(world.alice, world.b1.id)
      missing = lookup(world.alice, 999_999)

      expect(foreign["data"]).to eq("invoice" => nil)
      expect(foreign).to eq(missing)
    end

    it "does the same in every denial mode" do
      %i[null error].each do |mode|
        expect(lookup(world.alice, world.b1.id, mode: mode)).to eq(lookup(world.alice, 999_999, mode: mode))
      end
    end
  end

  describe "loads: through the scope" do
    let(:query) { "query($id: ID!) { invoiceViaRef(invoiceId: $id) { number } }" }

    def load_by(user, id, mode: :null)
      schema = IntegrationSchema.build(on_unauthorized: mode)
      execute_query(schema, query, variables: { "id" => id.to_s }, context: { current_user: user },
                                   root_value: IntegrationSchema::Root.new)
    end

    it "loads an object of the user's own account" do
      expect(load_by(world.alice, world.a1.id)["data"]).to eq("invoiceViaRef" => { "number" => "A-1" })
    end

    it "answers null for an object of another account" do
      result = load_by(world.alice, world.b1.id)

      expect(result["data"]).to eq("invoiceViaRef" => nil)
      expect(result["errors"]).to be_nil
    end

    it "answers a missing id and a foreign id byte for byte alike, in every mode" do
      %i[null error].each do |mode|
        foreign = load_by(world.alice, world.b1.id, mode: mode)
        missing = load_by(world.alice, 999_999, mode: mode)

        expect(foreign).to eq(missing)
      end
    end

    it "never says that the id exists, nor that it is missing" do
      text = load_by(world.alice, world.b1.id, mode: :error)["errors"].to_s

      expect(text).not_to match(/No object found|failed|authorization/i)
    end
  end
end
