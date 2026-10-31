# frozen_string_literal: true

require "digest"

# Who a refusal was for, what a client can read from it, and what happens when the reporting itself fails.
RSpec.describe "Telemetry: context, failures and refusal codes" do
  let(:armory) { GraphQL::Armory }
  let(:query_text) { "{ invoices }" }
  let(:store) { armory::PersistedQueries::Manifest.new({ Digest::SHA256.hexdigest(query_text) => query_text }) }

  def query_type
    Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :invoices, [String], null: false
      def invoices = ["A-1"]
    end
  end

  def persisted_schema(**options)
    query = query_type
    persisted = store
    plugin = armory::PersistedQueries
    Class.new(GraphQL::Schema) do
      query query
      use plugin, store: persisted, **options
    end
  end

  def silently
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  describe "a sink that takes three arguments" do
    it "receives the query's context; one that takes two does not" do
      three = []
      two = []
      sinks = [->(signal, data, context) { three << [signal, data, context[:ip]] }, ->(signal, data) { two << [signal, data] }]

      persisted_schema(strict: true, sinks: sinks).execute(query_text, context: { ip: "10.0.0.1" })

      expect(three).to eq([[:operation_refused, { reason: :raw_query }, "10.0.0.1"]])
      expect(two).to eq([[:operation_refused, { reason: :raw_query }]])
    end

    it "receives an empty context when the query has none" do
      seen = []
      persisted_schema(strict: true, sinks: [->(_signal, _data, context) { seen << context }]).execute(query_text)

      expect(seen).to eq([{}])
    end

    it "accepts an object whose call takes three arguments, and a proc" do
      seen = []
      object = Class.new { define_method(:call) { |_signal, _data, context| seen << context[:ip] } }.new
      block = proc { |_signal, _data, context| seen << context[:ip] }

      armory::Telemetry.build(sinks: [object, block]).record(:denied, context: { ip: "10.0.0.1" })

      expect(seen).to eq(["10.0.0.1", "10.0.0.1"])
    end

    it "never gives the context to a sink that takes any arguments: it would log them" do
      seen = []
      armory::Telemetry.build(sinks: [->(*arguments) { seen << arguments }]).record(:denied, context: { token: "secret" }, type: "Invoice")

      expect(seen).to eq([[:denied, { type: "Invoice" }]])
    end

    it "keeps the context out of the signal's data" do
      seen = []
      armory::Telemetry.build(sinks: [->(_signal, data, _context) { seen << data }]).record(:denied, context: { ip: "10.0.0.1" }, type: "Invoice")

      expect(seen).to eq([{ type: "Invoice" }])
    end

    it "reaches the sinks of authorization, on its decisions and its lists" do
      authorization = armory::Authorization
      seen = []
      sinks = [->(signal, _data, context) { seen << [signal, context[:ip]] }]
      context = { ip: "10.0.0.1" }
      rule = authorization::Controls::Rule.example
      adapter = authorization::Adapters::Substitute.new(allow: true)

      authorization::Authorize.new(adapter: adapter, telemetry: armory::Telemetry.build(sinks: sinks)).(authorization::Controls::Subject.example, rule, context)
      authorization::Scope.build(adapter: adapter, sinks: sinks).([], rule, context)

      expect(seen).to eq([[:allowed, "10.0.0.1"], [:scoped, "10.0.0.1"]])
    end

    it "reaches the sinks of encrypted IDs" do
      seen = []
      encoder = armory::IDs::Controls::Encoder.example
      lookup = armory::IDs::Lookup.build(encoder: encoder, sinks: [->(signal, _data, context) { seen << [signal, context[:ip]] }])

      lookup.object_for("forged", { ip: "10.0.0.1" })

      expect(seen).to eq([[:id_refused, "10.0.0.1"]])
    end
  end

  describe "a sink that raises" do
    let(:broken) { ->(_signal, _data) { raise IOError, "metrics down: sk_live_SECRET" } }

    it "does not take the request down, and the next sink still runs" do
      seen = []
      result = nil
      output = silently do
        result = persisted_schema(sinks: [broken, ->(signal, _data) { seen << signal }]).execute(query_text)
      end

      expect(result["data"]).to eq("invoices" => ["A-1"])
      expect(seen).to eq([:raw_query_run])
      expect(output).to include("IOError", "raw_query_run")
    end

    it "does not change a refusal into a query that runs" do
      result = nil
      silently { result = persisted_schema(strict: true, sinks: [broken]).execute(query_text) }

      expect(result.to_h).not_to have_key("data")
      expect(result["errors"].map { |error| error["message"] }).to eq([armory::PersistedQueries::RAW_QUERY_REFUSED])
    end

    it "never prints the error's message by default: it may hold a secret" do
      output = silently { armory::Telemetry.build(sinks: [broken]).record(:denied) }

      expect(output).not_to include("SECRET")
    end

    it "goes to on_sink_error, with the error and the signal, instead of the default warning" do
      seen = []
      output = silently do
        armory::Telemetry.build(sinks: [broken], on_sink_error: ->(error, signal) { seen << [error.class, signal] }).record(:denied)
      end

      expect(seen).to eq([[IOError, :denied]])
      expect(output).to eq("")
    end

    it "fails the request closed when on_sink_error raises" do
      strict_log = ->(error, _signal) { raise error }
      schema = persisted_schema(sinks: [broken], on_sink_error: strict_log)

      expect { schema.execute(query_text) }.to raise_error(IOError)
    end

    it "refuses at boot an on_sink_error that is not callable, in every module" do
      expect { armory::Telemetry.build(on_sink_error: "log") }.to raise_error(armory::Telemetry::ConfigurationError, /on_sink_error/)
      expect { persisted_schema(on_sink_error: "log") }.to raise_error(armory::Telemetry::ConfigurationError, /on_sink_error/)
      expect { Class.new(GraphQL::Schema) { use GraphQL::Armory::IDs, encoder: GraphQL::Armory::IDs::Controls::Encoder.example, on_sink_error: "log" } }
        .to raise_error(armory::Telemetry::ConfigurationError, /on_sink_error/)
      expect { Class.new(GraphQL::Schema) { use GraphQL::Armory::Authorization, adapter: :pundit, on_sink_error: "log" } }
        .to raise_error(armory::Telemetry::ConfigurationError, /on_sink_error/)
    end

    it "does not read a sink's Encoder::InvalidError as a forged ID" do
      output = silently do
        encoder = armory::IDs::Controls::Encoder.example
        invalid = ->(_signal, _data) { raise armory::Encoder::InvalidError }
        lookup = armory::IDs::Lookup.build(encoder: encoder, sinks: [invalid])
        lookup.object_for("forged", {})
      end

      expect(output).to include("id_refused")
    end
  end

  describe "the code of a refusal" do
    def code_of(schema, text = nil, **context)
      schema.execute(text, context: context).to_h["errors"].map { |error| error.dig("extensions", "code") }
    end

    it "names each reason" do
      schema = persisted_schema(strict: true)

      expect(code_of(schema, query_text)).to eq(["RAW_QUERY_REFUSED"])
      expect(code_of(schema, operation_id: "unknown")).to eq(["UNKNOWN_OPERATION"])
      expect(code_of(schema, "{ __typename }", operation_id: Digest::SHA256.hexdigest(query_text))).to eq(["OPERATION_MISMATCH"])
    end

    it "keeps the message a client already reads" do
      error = persisted_schema(strict: true).execute(query_text).to_h["errors"].first

      expect(error["message"]).to eq(armory::PersistedQueries::RAW_QUERY_REFUSED)
    end
  end

  describe "a rate limit store that fails" do
    let(:failing_store) do
      Class.new do
        def take(_key, cost:, limit:, window:, force:) = raise(IOError, "store down")
        def acquire(_key, token:, limit:, ttl:, force:) = raise(IOError, "store down")
        def release(_key, token:) = raise(IOError, "store down")
        def spent(_key, limit:, window:) = raise(IOError, "store down")
        def spend(_key, amount:, limit:, window:) = raise(IOError, "store down")
      end.new
    end

    def limited_schema(limiter, **options)
      query = query_type
      Class.new(GraphQL::Schema) do
        query query
        use limiter, key: ->(_query) { "client" }, **options
      end
    end

    {
      points: [:Points, { limit: 10 }],
      concurrency: [:Concurrency, { limit: 10 }],
      time: [:Time, { limit: 10 }]
    }.each do |name, (constant, options)|
      it "records a signal from #{constant}, with the context, and still lets the query through" do
        seen = []
        result = nil
        silently do
          schema = limited_schema(armory::RateLimits.const_get(constant), store: failing_store, soft: false, sinks: [->(signal, data, context) { seen << [signal, data, context[:ip]] }], **options)
          result = schema.execute(query_text, context: { ip: "10.0.0.1" })
        end

        expect(result["data"]).to eq("invoices" => ["A-1"])
        expect(seen.first).to eq([:rate_limit_store_failed, { limiter: name, error: "IOError" }, "10.0.0.1"])
      end
    end

    it "still calls on_store_error, and still warns without one" do
      handled = []
      silently do
        limited_schema(armory::RateLimits::Points, store: failing_store, limit: 10, on_store_error: ->(error, _query) { handled << error.class }, sinks: []).execute(query_text)
      end
      output = silently { limited_schema(armory::RateLimits::Points, store: failing_store, limit: 10, sinks: [->(_signal, _data) {}]).execute(query_text) }

      expect(handled).to eq([IOError])
      expect(output).to include("query let through")
    end

    it "refuses bad sinks at boot" do
      expect { limited_schema(armory::RateLimits::Points, store: failing_store, limit: 10, sinks: "log") }
        .to raise_error(armory::Telemetry::ConfigurationError, /sinks/)
    end
  end
end
