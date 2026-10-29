# frozen_string_literal: true

require "base64"

# Apps that use Relay global IDs decode them in `Schema.object_from_id`. A `loads:` argument must accept
# them, and still look the record up inside the user's scope, so a foreign id looks like a missing one.
RSpec.describe "Global IDs in loads:" do
  let(:world) { Dummy::World.build }

  def global_id(model_name, id)
    Base64.urlsafe_encode64("#{model_name}/#{id}", padding: false)
  end

  def schema_for(adapter, decodes: true, raising: false, on_unauthorized: :null)
    armory = GraphQL::Armory::Authorization
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
    invoice = Class.new(base_object) do
      graphql_name "Invoice"
      field :number, String, null: false
    end
    query = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root type; each field declares its own rule"
      field :invoice_by_ref, invoice, authorize: :none, reason: "loads through the scope" do
        argument :invoice_id, GraphQL::Types::ID, loads: invoice
      end
    end
    Class.new(ArmoryEngine.base_schema) do
      query query
      use armory, adapter: adapter, on_unauthorized: on_unauthorized
      define_singleton_method(:resolve_type) { |_abstract, _obj, _ctx| invoice }
      if decodes
        # `raising:` is graphql-ruby's documented decoder, `GlobalID.find`: it raises for a missing record.
        define_singleton_method(:object_from_id) do |id, _context|
          model_name, key = Base64.urlsafe_decode64(id).split("/", 2)
          raising ? Object.const_get(model_name).find(key) : Object.const_get(model_name).find_by(id: key)
        end
      end
    end
  end

  let(:root) do
    Class.new do
      def invoice_by_ref(invoice:)
        invoice
      end
    end.new
  end

  %i[pundit cancan].each do |adapter|
    context "with #{adapter}" do
      let(:schema) { schema_for(adapter) }

      def lookup(schema, id, user)
        execute_query(schema, "query($id: ID!) { invoiceByRef(invoiceId: $id) { number } }",
                      variables: { "id" => id }, context: { current_user: user }, root_value: root)
      end

      it "loads the user's own record by its global ID" do
        result = lookup(schema, global_id("Invoice", world.a1.id), world.alice)

        expect(result.to_h).to eq("data" => { "invoiceByRef" => { "number" => "A-1" } })
      end

      it "answers a foreign global ID exactly like one that does not exist" do
        foreign = lookup(schema, global_id("Invoice", world.b1.id), world.alice)
        missing = lookup(schema, global_id("Invoice", 0), world.alice)

        expect([foreign.to_h, foreign.to_h["data"]]).to eq([missing.to_h, { "invoiceByRef" => nil }])
      end

      it "does not load a record of another model that shares the primary key" do
        expect(world.account_a.id).to eq(world.a1.id)

        result = lookup(schema, global_id("Account", world.account_a.id), world.alice)

        expect(result.to_h["data"]).to eq("invoiceByRef" => nil)
      end

      it "answers a foreign and a missing ID identically when the decoder raises for a missing record" do
        schema = schema_for(adapter, raising: true, on_unauthorized: :error)
        foreign = lookup(schema, global_id("Invoice", world.b1.id), world.alice)
        missing = lookup(schema, global_id("Invoice", 0), world.alice)

        expect([foreign.to_h, foreign.to_h["data"]]).to eq([missing.to_h, { "invoiceByRef" => nil }])
      end

      it "denies a malformed ID like a missing one instead of raising" do
        malformed = lookup(schema, "%%%", world.alice)
        missing = lookup(schema, global_id("Invoice", 0), world.alice)

        expect(malformed.to_h).to eq(missing.to_h)
      end

      it "denies an ID the Encoder refuses like a missing one, in every mode" do
        encoder = Class.new(GraphQL::Armory::Encoder) { key("k" * 32) }
        tampered = encoder.encode("Invoice/#{world.a1.id}").reverse

        results = %i[null error].map do |mode|
          schema = schema_for(adapter, decodes: false, on_unauthorized: mode)
          schema.define_singleton_method(:object_from_id) do |id, _context|
            model_name, key = encoder.decode(id).split("/", 2)
            Object.const_get(model_name).find_by(id: key)
          end
          [lookup(schema, tampered, world.alice).to_h, lookup(schema, encoder.encode("Invoice/0"), world.alice).to_h]
        end

        expect(results.map { |refused, missing| [refused == missing, refused["data"]] }).to eq([[true, { "invoiceByRef" => nil }]] * 2)
      end

      it "still uses the id as the primary key when the schema decodes nothing" do
        result = lookup(schema_for(adapter, decodes: false), world.a1.id.to_s, world.alice)

        expect(result.to_h).to eq("data" => { "invoiceByRef" => { "number" => "A-1" } })
      end
    end
  end
end
