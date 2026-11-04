# frozen_string_literal: true

# `use GraphQL::Armory::Versioning` decides, for every query, which version of the schema it sees, from
# `context[:armory_version]`. A version it cannot serve is refused before anything runs, with a stable code and a
# message that never echoes what the client sent.
RSpec.describe "use GraphQL::Armory::Versioning: the gate" do
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:controls) { versioning::Controls }
  let(:resolved) { [] }
  let(:signals) { [] }
  let(:root) { controls::Root.example(resolved) }

  def schema_for(visibility:, default: :latest, query: controls::Query.example)
    sink = ->(signal, data) { signals << [signal, data] }
    controls::Schema.example(visibility: visibility, default: default, query: query, base: ArmoryEngine.base_schema, sinks: [sink])
  end

  def run(schema, query_string, **options)
    execute_query(schema, query_string, root_value: root, **options).to_h
  end

  def run_all(schema, queries)
    ArmoryEngine.next? ? GraphQL::Execution::Next.run_all(schema, queries, context: {}) : schema.multiplex(queries)
  end

  def codes(result) = Array(result["errors"]).map { |error| error.dig("extensions", "code") }
  def messages(result) = Array(result["errors"]).map { |error| error["message"] }

  # A field resolved by a method on the type, on both engines.
  def type_method = ArmoryEngine.supported? ? { resolve_legacy_instance_method: true } : {}

  %i[warden visibility].each do |visibility|
    context "with #{visibility}" do
      let(:schema) { schema_for(visibility: visibility) }

      it "serves the version a client names, and records it" do
        result = run(schema, "{ invoice { number amount } }", context: { armory_version: "2024-06-01" })

        expect([result, resolved, signals]).to eq(
          [{ "data" => { "invoice" => { "number" => "A-1", "amount" => 100 } } }, %i[invoice number amount], [[:version_served, { version: "2024-06-01" }]]]
        )
      end

      it "refuses a retired version, running nothing" do
        result = run(schema, "{ invoice { number } }", context: { armory_version: "2024-01-15" })

        expect([codes(result), messages(result), result.key?("data"), resolved, signals]).to eq(
          [["RETIRED_API_VERSION"], ["This API version is retired"], false, [], [[:version_refused, { reason: :retired }]]]
        )
      end

      it "refuses an unknown, future, empty or non-String version, running nothing" do
        bad = ["2023-01-01", "2026-01-01", "", "2024-06-01 ", "2024/06/01", :"2024-06-01", 20_240_601, ["2024-06-01"], { "v" => "2024-06-01" }]
        results = bad.map { |label| run(schema, "{ invoice { number } }", context: { armory_version: label }) }

        expect(results.map { |result| [codes(result), messages(result), result.key?("data")] }.uniq).to eq([[["UNKNOWN_API_VERSION"], ["Unknown API version"], false]])
        expect([resolved, signals.uniq]).to eq([[], [[:version_refused, { reason: :unknown }]]])
      end

      it "serves the latest version to a request with no version under default: :latest, and records it as defaulted" do
        absent = run(schema, "{ invoice { tags } }")
        explicit_nil = run(schema, "{ invoice { amount } }", context: { armory_version: nil })

        expect([absent, messages(explicit_nil), signals]).to eq(
          [{ "data" => { "invoice" => { "tags" => %w[paid urgent] } } }, ["Field 'amount' doesn't exist on type 'Invoice'"],
           [[:version_defaulted, { version: "2025-01-01" }]] * 2]
        )
      end

      it "serves the pinned label to a request with no version under default: \"<label>\"" do
        result = run(schema_for(visibility: visibility, default: "2024-06-01"), "{ invoice { amount } }")

        expect([result, signals]).to eq([{ "data" => { "invoice" => { "amount" => 100 } } }, [[:version_defaulted, { version: "2024-06-01" }]]])
      end

      it "refuses a request with no version under default: :refuse, running nothing" do
        result = run(schema_for(visibility: visibility, default: :refuse), "{ invoice { number } }")

        expect([codes(result), messages(result), result.key?("data"), resolved, signals]).to eq(
          [["MISSING_API_VERSION"], ["Send an API version"], false, [], [[:version_refused, { reason: :missing }]]]
        )
      end

      it "runs nothing for a refused version even with validate: false" do
        result = run(schema, "{ invoice { number } }", validate: false, context: { armory_version: "2024-01-15" })

        expect([codes(result), resolved]).to eq([["RETIRED_API_VERSION"], []])
      end

      it "resolves nothing for a field outside the version with validate: false" do
        # graphql 2.4's interpreter raises a NoMethodError instead; neither runs the field.
        expected = Gem::Version.new(GraphQL::VERSION) < Gem::Version.new("2.5") ? NoMethodError : GraphQL::Error
        expect { run(schema, "{ invoice { amount } }", validate: false, context: { armory_version: "2025-01-01" }) }.to raise_error(expected)
        expect(resolved).not_to include(:amount)
      end

      it "refuses a refused version even when the query brings its own validator" do
        validator = GraphQL::StaticValidation::Validator.new(schema: schema)
        query = schema.query_class.new(schema, "{ invoice { number } }", static_validator: validator, context: { armory_version: "2024-01-15" }, root_value: root)

        expect([run_all(schema, [query]).map { |result| codes(result.to_h) }, resolved]).to eq([[["RETIRED_API_VERSION"]], []])
      end

      it "gives each query of a multiplex its own version" do
        queries = %w[2024-06-01 2025-01-01].map { |label| { query: "{ invoice { amount } }", context: { armory_version: label }, root_value: root } }
        older, newer = run_all(schema, queries).map(&:to_h)

        expect([older, messages(newer), signals]).to eq(
          [{ "data" => { "invoice" => { "amount" => 100 } } }, ["Field 'amount' doesn't exist on type 'Invoice'"],
           [[:version_served, { version: "2024-06-01" }], [:version_served, { version: "2025-01-01" }]]]
        )
      end

      it "honours a version set by a custom context class, never applying the default policy to it" do
        context_class = Class.new(GraphQL::Query::Context) do
          def initialize(**options)
            super
            self[:armory_version] = "2024-06-01"
          end
        end
        schema.context_class(context_class)

        result = run(schema, "{ invoice { amount } }", context: {})

        expect([result, signals]).to eq([{ "data" => { "invoice" => { "amount" => 100 } } }, [[:version_served, { version: "2024-06-01" }]]])
      end

      it "tells a resolver which version its query sees" do
        options = type_method
        query = Class.new(controls::Query.example) do
          graphql_name "Query"
          field :api_version, String, null: false, **options

          def api_version
            version = GraphQL::Armory::Versioning.version(context)
            [version.label, version.index, version < "2025-01-01", version == "2024-06-01"].join(" ")
          end
        end

        result = run(schema_for(visibility: visibility, query: query), "{ apiVersion }", context: { armory_version: "2024-06-01" })

        expect(result).to eq("data" => { "apiVersion" => "2024-06-01 1 true true" })
      end

      it "runs a Query::Partial with its parent's version, recording no second signal" do
        skip "no Query::Partial" unless defined?(GraphQL::Query::Partial)

        options = type_method
        query = Class.new(controls::Query.example) do
          graphql_name "Query"
          field :via_partial, String, null: false, **options

          # The partial names another version in its own context: it still sees its parent's schema.
          def via_partial
            result = context.query.run_partials([{ path: ["invoice"], object: context[:invoice], context: { armory_version: "2025-01-01" } }]).first
            [result.to_h.dig("data", "amount"), GraphQL::Armory::Versioning.version(result.partial.context).label].join(" ")
          end
        end
        invoice = root.invoice
        resolved.clear

        result = run(schema_for(visibility: visibility, query: query), "{ invoice { amount } viaPartial }", context: { armory_version: "2024-06-01", invoice: invoice })

        expect([result.dig("data", "viaPartial"), signals]).to eq(["100 2024-06-01", [[:version_served, { version: "2024-06-01" }]]])
      end

      it "decides a query the app built itself from its own context, recording nothing" do
        served = GraphQL::Query.new(schema, "{ invoice { amount } }", context: { armory_version: "2024-06-01" }, root_value: root)
        refused = GraphQL::Query.new(schema, "{ invoice { amount } }", context: { armory_version: "2024-01-15" }, root_value: root)

        expect(run_all(schema, [served]).map(&:to_h)).to eq([{ "data" => { "invoice" => { "amount" => 100 } } }])
        expect { run_all(schema, [refused]) }.to raise_error(versioning::RefusedVersionError, "This API version is retired") { |error| expect(error.code).to eq("RETIRED_API_VERSION") }
        expect([resolved, signals]).to eq([%i[invoice amount], []])
      end

      it "dumps the version the default policy picks, and raises under default: :refuse naming the context to pass" do
        latest = schema.to_definition
        refusing = schema_for(visibility: visibility, default: :refuse)

        expect([latest.include?("amount"), latest.include?("tags")]).to eq([false, true])
        expect(schema.to_definition(context: { armory_full_schema: true })).to eq(latest)
        expect { refusing.to_definition }.to raise_error(versioning::MissingVersionError, /armory_version:/)
      end
    end
  end

  it "fails closed when a named Schema::Visibility profile reaches a versioned field" do
    query = controls::Query.example
    schema = Class.new(ArmoryEngine.base_schema) do
      query(query)
      use GraphQL::Schema::Visibility, profiles: { public: {} }, dynamic: true
      use GraphQL::Armory::Versioning, versions: %w[2024-06-01 2025-01-01], default: :latest
    end

    expect { run(schema, "{ invoice { amount } }", context: { armory_version: "2024-06-01", visibility_profile: :public }) }
      .to raise_error(versioning::ConfigurationError, /named Schema::Visibility profiles/)
    expect(resolved).not_to include(:amount)
  end

  it "gives Schema::Visibility's migration check the version of its query, even one only a custom context class answers" do
    query = controls::Query.example
    schema = Class.new(ArmoryEngine.base_schema) do
      query(query)
      use GraphQL::Schema::Visibility, migration_errors: true
      use GraphQL::Armory::Versioning, versions: %w[2024-06-01 2025-01-01], default: :latest
    end
    schema.context_class(Class.new(GraphQL::Query::Context) { def [](key) = key == :armory_version ? "2024-06-01" : super })

    result = run(schema, "{ invoice { amount } }", context: {})

    expect(result).to eq("data" => { "invoice" => { "amount" => 100 } })
  end

  it "keeps a persisted query refusal's code when both plugins refuse, in either use order" do
    query = controls::Query.example
    persisted = ->(schema) { schema.use(GraphQL::Armory::PersistedQueries, store: GraphQL::Armory::PersistedQueries::Store::Null.new, strict: true) }
    versioned = ->(schema) { schema.use(versioning, versions: %w[2024-06-01 2025-01-01], retired: %w[2024-06-01], default: :latest) }

    results = [[persisted, versioned], [versioned, persisted]].map do |plugins|
      schema = Class.new(ArmoryEngine.base_schema) do
        query(query)
        use GraphQL::Schema::Visibility
      end
      plugins.each { |plugin| plugin.(schema) }
      codes(run(schema, "{ invoice { number } }", context: { armory_version: "2024-06-01" }))
    end

    expect([results, resolved]).to eq([[["RAW_QUERY_REFUSED"]] * 2, []])
  end

  it "raises on the first query when the schema uses Schema::AlwaysVisible, even added after use" do
    schema = schema_for(visibility: :visibility)
    schema.use(GraphQL::Schema::AlwaysVisible)

    expect { run(schema, "{ invoice { number } }", context: { armory_version: "2024-06-01" }) }
      .to raise_error(versioning::ConfigurationError, /AlwaysVisible/)
    expect(resolved).to eq([])
  end

  it "refuses a second use, on the same schema or on a child" do
    schema = schema_for(visibility: :visibility)
    child = Class.new(schema)

    [schema, child].each do |target|
      expect { target.use(versioning, versions: %w[1 2], default: :latest) }.to raise_error(versioning::ConfigurationError, /use it once/)
    end
  end

  it "keeps the gate on a child schema and on a query class set after use" do
    schema = schema_for(visibility: :visibility)
    child = Class.new(schema)
    child.query_class(Class.new(GraphQL::Query))

    result = run(child, "{ invoice { number } }", context: { armory_version: "2024-01-15" })

    expect([codes(result), resolved]).to eq([["RETIRED_API_VERSION"], []])
  end
end
