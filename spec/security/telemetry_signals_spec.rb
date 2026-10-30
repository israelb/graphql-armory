# frozen_string_literal: true

require "digest"

# Encrypted IDs and persisted queries tell the app what they refused. A signal carries a reason and never an ID,
# an operation id, a key or a query: an attacker chooses those, and they would end up in the app's logs.
RSpec.describe "telemetry of encrypted IDs and persisted queries" do
  let(:armory) { GraphQL::Armory }
  let(:telemetry) { armory::Telemetry::Substitute.new }
  let(:sinks) { [->(signal, data) { telemetry.record(signal, **data) }] }

  describe "use GraphQL::Armory::IDs, sinks:" do
    let(:encoder) { armory::IDs::Controls::Encoder.example }
    let(:found) { { "1" => armory::IDs::Controls::Record.example(id: 1) } }

    def schema_for(**options)
      invoice = Class.new(GraphQL::Schema::Object) do
        graphql_name "Invoice"
        implements GraphQL::Types::Relay::Node
        field :number, String, null: false
      end
      payload = Class.new(GraphQL::Schema::Object) { graphql_name "Payload"; field :ok, GraphQL::Types::Boolean, null: false }
      query = Class.new(GraphQL::Schema::Object) do
        graphql_name "Query"
        field :ok, GraphQL::Types::Boolean, null: false
        field :node, GraphQL::Types::Relay::Node, null: true # reaches Node, so the types implementing it are visible
      end
      armory = self.armory
      found = self.found
      encoder = self.encoder
      sinks = self.sinks
      Class.new(ArmoryEngine.base_schema) do
        query query
        orphan_types invoice, payload
        use armory::IDs, encoder: encoder, find: ->(_type, key, _context) { found[key] }, sinks: sinks, **options
      end
    end

    def lookup(schema, id)
      schema.object_from_id(id, GraphQL::Query.new(schema, "{ ok }").context)
    end

    it "says why an ID was refused, and what resolved" do
      schema = schema_for
      lookup(schema, encoder.encode("Invoice/1"))
      lookup(schema, encoder.encode("Invoice/1").reverse)
      lookup(schema, encoder.encode("Invoice"))
      lookup(schema, encoder.encode("Ghost/1"))
      lookup(schema, encoder.encode("Payload/1"))
      lookup(schema, encoder.encode("Invoice/9"))

      expect(telemetry.recorded).to eq(
        [[:id_resolved, { type: "Invoice" }],
         [:id_refused, { reason: :invalid }],
         [:id_refused, { reason: :malformed }],
         [:id_refused, { reason: :unknown_type }],
         [:id_refused, { reason: :unknown_type }],
         [:id_refused, { reason: :not_found, type: "Invoice" }]]
      )
    end

    it "never puts the ID, the key or the record in a signal" do
      schema = schema_for
      id = encoder.encode("Invoice/9")
      lookup(schema, id)
      lookup(schema, "forged-#{id}")

      expect(telemetry.recorded.flatten.map(&:to_s).join).not_to include(id, "9")
    end

    it "answers as before without sinks, and refuses bad sinks at boot" do
      expect(lookup(schema_for(sinks: []), encoder.encode("Invoice/1"))).to eq(found["1"])
      expect { schema_for(sinks: "log") }.to raise_error(armory::Telemetry::ConfigurationError, /sinks/)
    end
  end

  describe "use GraphQL::Armory::PersistedQueries, sinks:" do
    let(:invoices) { armory::PersistedQueries::Controls::Operations.invoices }
    let(:root) { armory::PersistedQueries::Controls::Root.example }

    def run(schema, query: nil, id: nil, **context)
      context = context.merge(operation_id: id) if id
      execute_query(schema, query, context: context, root_value: root).to_h
    end

    def schema_for(**options)
      query = armory::PersistedQueries::Controls::Query.example
      armory = self.armory
      store = armory::PersistedQueries::Store::Substitute.new(invoices)
      sinks = self.sinks
      Class.new(ArmoryEngine.base_schema) do
        query query
        use armory::PersistedQueries, store: store, sinks: sinks, **options
      end
    end

    it "says what ran by id and why a request was refused, strict or not" do
      strict = schema_for(strict: true)
      run(strict, id: Digest::SHA256.hexdigest(invoices))
      run(strict, id: "unknown")
      run(strict, id: Digest::SHA256.hexdigest(invoices), query: "{ secret }")
      run(strict, query: "{ secret }")
      run(strict, query: "{ secret }", armory_allow_raw_query: true)
      run(schema_for, query: "{ secret }")

      expect(telemetry.recorded).to eq(
        [[:operation_persisted, {}],
         [:operation_refused, { reason: :unknown_operation }],
         [:operation_refused, { reason: :mismatch }],
         [:operation_refused, { reason: :raw_query }],
         [:raw_query_allowed, {}],
         [:raw_query_run, {}]]
      )
    end

    it "never puts the operation id or the query in a signal" do
      run(schema_for(strict: true), id: "attacker-chosen-id", query: "{ secret }")

      expect(telemetry.recorded.flatten.map(&:to_s).join).not_to include("attacker-chosen-id", "secret")
    end

    it "runs as before without sinks, and refuses bad sinks at boot" do
      expect(run(schema_for(sinks: []), id: Digest::SHA256.hexdigest(invoices))["data"]).to eq("invoices" => ["A-1"])
      expect { schema_for(sinks: "log") }.to raise_error(armory::Telemetry::ConfigurationError, /sinks/)
    end
  end
end
