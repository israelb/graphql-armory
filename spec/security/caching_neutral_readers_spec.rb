# frozen_string_literal: true

# Some readers read the context for a reason that does not change the answer: Versioning deciding the version (the
# resolved label is in the cache key, the raw value is not the answer's input) and Telemetry's sinks (a sink that logs
# `request_id` changes no data). They read inside `Caching.neutral`, so response caching's recorder does not count the
# read. The neutrality is per reader: the same key read by the app's own code is still recorded, and an Authorization
# adapter's actor read is never neutral.
RSpec.describe "Response caching: neutral readers" do
  let(:recorder_context) { GraphQL::Armory::Caching::Recorder::Substitute::Context }
  let(:record_keys) { GraphQL::Armory::Caching::RecordKeys }

  def recorder(result)
    record_keys.recorder(result.context)
  end

  # A field resolved by a method on the type, on both engines.
  def type_method = ArmoryEngine.supported? ? { resolve_legacy_instance_method: true } : {}

  describe "Versioning" do
    let(:versioning) { GraphQL::Armory::Versioning }
    let(:legacy) { type_method }

    # `invoice` from the controls, and `version`, which the app resolves from the raw `armory_version` itself.
    def schema_for(visibility)
      invoice = versioning::Controls::Invoice.example
      options = legacy
      query = Class.new(GraphQL::Schema::Object) do
        graphql_name "Query"
        field :invoice, invoice, null: false
        field :version, String, null: true, **options

        def version
          context[:armory_version]
        end
      end
      schema = versioning::Controls::Schema.example(visibility: visibility, query: query, base: ArmoryEngine.base_schema)
      schema.context_class(recorder_context)
      schema
    end

    def run(schema, query_string)
      execute_query(schema, query_string, context: { armory_version: "2024-06-01" }, root_value: versioning::Controls::Root.example)
    end

    %i[warden visibility].each do |visibility|
      context "with #{visibility}" do
        it "decides the version without the recorder counting its read of armory_version" do
          result = run(schema_for(visibility), "{ invoice { number } }")

          expect([result.to_h, recorder(result).class, recorder(result).read?(:armory_version)]).to eq(
            [{ "data" => { "invoice" => { "number" => "A-1" } } }, GraphQL::Armory::Caching::Recorder::Substitute, false]
          )
        end

        it "still records the app's own read of armory_version" do
          result = run(schema_for(visibility), "{ version }")

          expect([result.to_h, recorder(result).read?(:armory_version)]).to eq([{ "data" => { "version" => "2024-06-01" } }, true])
        end

        it "still refuses a retired version, with nothing recorded for its decision" do
          schema = schema_for(visibility)
          result = execute_query(schema, "{ invoice { number } }", context: { armory_version: "2024-01-15" }, root_value: versioning::Controls::Root.example)

          expect([result.to_h.dig("errors", 0, "extensions", "code"), recorder(result).read?(:armory_version)]).to eq(["RETIRED_API_VERSION", false])
        end
      end
    end
  end

  describe "Telemetry" do
    let(:seen) { [] }
    let(:legacy) { type_method }

    # A sink that takes the context reads `request_id` from it, as a logger would.
    def schema_for(adapter: GraphQL::Armory::Authorization::Adapters::Substitute.new)
      armory = GraphQL::Armory::Authorization
      seen = self.seen
      sink = ->(signal, _data, context) { seen << [signal, context[:request_id]] }
      options = legacy
      base_field = Class.new(GraphQL::Schema::Field) { include armory::Base }
      query = Class.new(GraphQL::Schema::Object) do
        include armory::Base
        field_class base_field
        graphql_name "Query"
        authorize :none, reason: "root type"
        field :ping, String, null: false, authorize: :none, reason: "health check", **options
        field :request_id, String, null: true, authorize: :none, reason: "echoes the request id", **options

        def ping = "pong"
        def request_id = context[:request_id]
      end

      schema = Class.new(ArmoryEngine.base_schema) do
        query query
        use armory, adapter: adapter, sinks: [sink]
      end
      schema.context_class(recorder_context)
      schema
    end

    def run(schema, query_string)
      execute_query(schema, query_string, context: { request_id: "r-1" }, root_value: Object.new)
    end

    it "calls the sinks without the recorder counting what they read" do
      result = run(schema_for, "{ ping }")

      expect([result.to_h, seen.uniq, recorder(result).read?(:request_id)]).to eq([{ "data" => { "ping" => "pong" } }, [[:bypassed, "r-1"]], false])
    end

    it "still records the app's own read of the same key" do
      result = run(schema_for, "{ requestId }")

      expect([result.to_h, recorder(result).read?(:request_id)]).to eq([{ "data" => { "requestId" => "r-1" } }, true])
    end

    it "keeps recording after a sink raises: only the sinks' own reads are neutral" do
      failing = ->(_signal, _data, context) { context[:request_id] && raise("down") }
      errors = []
      telemetry = GraphQL::Armory::Telemetry.build(sinks: [failing], on_sink_error: ->(error, signal) { errors << [error.class, signal] })
      context = GraphQL::Query.new(schema_for, "{ ping }", context: { request_id: "r-1" }).context

      telemetry.record(:allowed, context: context)
      expect([errors, record_keys.recorder(context).read?(:request_id)]).to eq([[[RuntimeError, :allowed]], false])

      context[:request_id]
      expect(record_keys.recorder(context).read?(:request_id)).to be(true)
    end
  end

  describe "Authorization's adapter" do
    it "keeps its actor read recorded: an actor the key does not hold is the leak caching must see" do
      schema = IntegrationSchema.build(adapter: :pundit)
      schema.context_class(recorder_context)
      result = execute_query(schema, "{ myInvoice { number } }", context: { current_user: world.alice }, root_value: IntegrationSchema::Root.new(my_invoice: world.a1))

      expect([result.to_h, recorder(result).read?(:current_user)]).to eq([{ "data" => { "myInvoice" => { "number" => "A-1" } } }, true])
    end
  end
end
