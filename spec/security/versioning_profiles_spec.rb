# frozen_string_literal: true

# `use GraphQL::Armory::Versioning, ..., profiles: true` runs each query under one named `Schema::Visibility` profile
# per served version, built by `Versioning.profiles(schema)`, so graphql-ruby computes each version's visibility once and
# keeps it. A query never runs under another profile: one that names its own is refused, and a profile Hash that did not
# come from `Versioning.profiles` fails closed.
RSpec.describe "use GraphQL::Armory::Versioning, profiles: true" do
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:controls) { versioning::Controls }
  let(:resolved) { [] }
  let(:signals) { [] }
  let(:root) { controls::Root.example(resolved) }
  let(:older) { "2024-06-01" }
  let(:newer) { "2025-01-01" }

  def schema_for(query: controls::Query.example, default: :latest, dynamic: false, preload: false, extra_profiles: {}, visibility: true)
    sink = ->(signal, data) { signals << [signal, data] }
    labels = controls::Versions::LABELS
    retired = controls::Versions::RETIRED
    Class.new(ArmoryEngine.base_schema) do
      query(query)
      use GraphQL::Armory::Versioning, versions: labels, retired: retired, default: default, sinks: [sink], profiles: true
      use GraphQL::Schema::Visibility, profiles: GraphQL::Armory::Versioning.profiles(self).merge(extra_profiles), dynamic: dynamic, preload: preload if visibility
    end
  end

  def run(schema, query_string, **options)
    execute_query(schema, query_string, root_value: root, **options).to_h
  end

  def run_all(schema, queries)
    ArmoryEngine.next? ? GraphQL::Execution::Next.run_all(schema, queries, context: {}) : schema.multiplex(queries)
  end

  def codes(result) = Array(result["errors"]).map { |error| error.dig("extensions", "code") }
  def messages(result) = Array(result["errors"]).map { |error| error["message"] }
  def type_method = ArmoryEngine.supported? ? { resolve_legacy_instance_method: true } : {}

  describe "Versioning.profiles" do
    it "answers one profile per served version, named after it, holding its label and the gate's own versions" do
      schema = schema_for
      profiles = versioning.profiles(schema)

      expect(profiles.keys).to eq(%i[armory_v_2024-06-01 armory_v_2025-01-01])
      expect(profiles.transform_values { |hash| hash.except(:armory_versions) }).to eq(
        "armory_v_2024-06-01": { armory_version: older }, "armory_v_2025-01-01": { armory_version: newer }
      )
      expect(profiles.values.map { |hash| hash[:armory_versions] }).to all(be(schema.armory_versioning.versions))
    end

    it "answers new Hashes each time, since Schema::Visibility freezes the ones it is given" do
      schema = schema_for

      expect(versioning.profiles(schema).values.map(&:frozen?).uniq).to eq([false])
    end

    it "raises for a schema whose use did not say profiles: true, or that never installed the plugin" do
      without = controls::Schema.example(base: ArmoryEngine.base_schema)
      query = controls::Query.example
      plain = Class.new(ArmoryEngine.base_schema) { query(query) }

      expect { versioning.profiles(without) }.to raise_error(versioning::ConfigurationError, /profiles: true/)
      expect { versioning.profiles(plain) }.to raise_error(versioning::ConfigurationError, /never installed the plugin/)
    end
  end

  describe "use" do
    it "refuses profiles: on graphql before 2.4.10, naming the version" do
      expect { versioning::Profiles.build(controls::Versions.example, enabled: true, graphql_version: "2.4.9") }
        .to raise_error(ArgumentError, /graphql 2\.4\.10 or later.*2\.4\.9/)
      expect(versioning::Profiles.build(controls::Versions.example, enabled: true, graphql_version: "2.4.10")).to be_enabled
    end

    it "takes only true or false" do
      query = controls::Query.example

      expect { Class.new(GraphQL::Schema) { query(query); use GraphQL::Armory::Versioning, versions: %w[a b], default: :latest, profiles: :yes } }
        .to raise_error(versioning::ConfigurationError, /profiles: must be true or false, got :yes/)
    end

    it "is off by default" do
      expect(controls::Schema.example.armory_versioning_profiles).not_to be_enabled
    end
  end

  [false, true].each do |dynamic|
    context "with dynamic: #{dynamic}" do
      let(:schema) { schema_for(dynamic: dynamic) }

      it "serves each version its own schema, under that version's profile, and records each decision" do
        old_result = run(schema, "{ invoice { number total amount } }", context: { armory_version: older })
        new_result = run(schema, "{ invoice { number total tags } }", context: { armory_version: newer })
        removed = run(schema, "{ invoice { amount } }", context: { armory_version: newer })
        added = run(schema, "{ invoice { tags } }", context: { armory_version: older })

        expect([old_result, new_result]).to eq(
          [{ "data" => { "invoice" => { "number" => "A-1", "total" => 100, "amount" => 100 } } },
           { "data" => { "invoice" => { "number" => "A-1", "total" => 100, "tags" => %w[paid urgent] } } }]
        )
        expect([messages(removed), messages(added)]).to eq([["Field 'amount' doesn't exist on type 'Invoice'"], ["Field 'tags' doesn't exist on type 'Invoice'"]])
        expect(schema.visibility.cached_profiles.keys).to contain_exactly(:"armory_v_2024-06-01", :"armory_v_2025-01-01")
        expect(signals).to eq([[:version_served, { version: older }], [:version_served, { version: newer }]] + [[:version_served, { version: newer }], [:version_served, { version: older }]])
      end

      it "keeps one profile per version across queries" do
        run(schema, "{ invoice { number } }", context: { armory_version: older })
        first = schema.visibility.cached_profiles[:"armory_v_2024-06-01"]
        run(schema, "{ invoice { amount } }", context: { armory_version: older })

        expect(schema.visibility.cached_profiles[:"armory_v_2024-06-01"]).to be(first)
      end

      it "introspects each version's own fields" do
        query = "{ __type(name: \"Invoice\") { fields(includeDeprecated: true) { name } } }"
        names = [older, newer].map { |label| run(schema, query, context: { armory_version: label }).dig("data", "__type", "fields").map { |field| field["name"] }.sort }

        expect(names).to eq([%w[amount number total], %w[number tags total]])
      end

      it "serves the default version under its profile to a request with no version" do
        result = run(schema, "{ invoice { tags } }")

        expect([result, signals]).to eq([{ "data" => { "invoice" => { "tags" => %w[paid urgent] } } }, [[:version_defaulted, { version: newer }]]])
      end

      it "refuses a retired, unknown or missing version with its code, running nothing" do
        retired = run(schema, "{ invoice { number } }", context: { armory_version: "2024-01-15" })
        unknown = run(schema, "{ invoice { number } }", context: { armory_version: "2099-01-01" })
        missing = run(schema_for(dynamic: dynamic, default: :refuse), "{ invoice { number } }")

        expect([retired, unknown, missing].map { |result| [codes(result), result.key?("data")] }).to eq(
          [[["RETIRED_API_VERSION"], false], [["UNKNOWN_API_VERSION"], false], [["MISSING_API_VERSION"], false]]
        )
        expect(resolved).to eq([])
      end

      it "gives each query of a multiplex its own version's profile" do
        queries = [older, newer].map { |label| { query: "{ invoice { amount } }", context: { armory_version: label }, root_value: root } }
        old_result, new_result = run_all(schema, queries).map(&:to_h)

        expect([old_result, messages(new_result)]).to eq([{ "data" => { "invoice" => { "amount" => 100 } } }, ["Field 'amount' doesn't exist on type 'Invoice'"]])
      end

      it "still tells a resolver which version its query sees" do
        options = type_method
        query = Class.new(controls::Query.example) do
          graphql_name "Query"
          field :api_version, String, null: false, **options

          def api_version = GraphQL::Armory::Versioning.version(context).label
        end

        expect(run(schema_for(query: query, dynamic: dynamic), "{ apiVersion }", context: { armory_version: older })).to eq("data" => { "apiVersion" => older })
      end

      it "dumps each version, and Versioning.types answers each version's schema" do
        views = [older, newer].map { |label| versioning.types(schema, label).fields(schema.query.get_field("invoice").type.unwrap).map(&:graphql_name) }

        expect(views).to eq([%w[number total amount], %w[number total tags]])
        # graphql 2.4 with json 3.1 cannot print the String of `amount`'s deprecation reason.
        next unless ArmoryJsonPrinting.prints_strings?

        dumps = [older, newer].map { |label| schema.to_definition(context: { armory_version: label }) }
        expect(dumps.map { |dump| [dump.include?("amount"), dump.include?("tags")] }).to eq([[true, false], [false, true]])
      end

      it "refuses a request whose context names another visibility profile, even one of another version" do
        other = run_refusing(schema, context: { armory_version: newer, visibility_profile: :"armory_v_2024-06-01" })
        own = run(schema, "{ invoice { amount } }", context: { armory_version: older, visibility_profile: :"armory_v_2024-06-01" })

        expect(other).to match(/visibility profile :"armory_v_2024-06-01".*:"armory_v_2025-01-01"/)
        expect(own).to eq("data" => { "invoice" => { "amount" => 100 } })
      end

      it "refuses a query given visibility_profile: by the app's code" do
        message = run_refusing(schema, context: { armory_version: newer }, visibility_profile: :"armory_v_2024-06-01")

        expect(message).to match(/visibility profile :"armory_v_2024-06-01"/)
      end

      it "refuses an app's own named profile next to the versioning ones, before anything runs" do
        mixed = schema_for(dynamic: dynamic, extra_profiles: { admin: {} })

        expect(run_refusing(mixed, context: { armory_version: older, visibility_profile: :admin })).to match(/visibility profile :admin/)
      end

      it "refuses a refused version that names a profile too, since that profile is the app's doing" do
        expect(run_refusing(schema, context: { armory_version: "2024-01-15", visibility_profile: :"armory_v_2024-06-01" })).to match(/visibility profile/)
      end

      it "refuses a version that a custom context class changes after the profile was picked" do
        context_class = Class.new(GraphQL::Query::Context) do
          def initialize(**options)
            super
            self[:armory_version] = "2024-06-01"
          end
        end
        schema.context_class(context_class)

        expect(run_refusing(schema, context: { armory_version: newer })).to match(/armory_v_2024-06-01/)
      end
    end
  end

  def run_refusing(schema, **options)
    run(schema, "{ invoice { number amount } }", **options)
    raise "expected a ConfigurationError"
  rescue versioning::ConfigurationError => error
    expect(resolved).to eq([])
    error.message
  end

  it "refuses profiles: true on a schema whose Schema::Visibility has no versioning profiles, or that uses the Warden" do
    query = controls::Query.example
    labels = controls::Versions::LABELS
    dynamic_only = Class.new(ArmoryEngine.base_schema) do
      query(query)
      use GraphQL::Armory::Versioning, versions: labels, default: :latest, profiles: true
      use GraphQL::Schema::Visibility, dynamic: true
    end
    warden = Class.new(ArmoryEngine.base_schema) do
      query(query)
      use GraphQL::Schema::Warden
      use GraphQL::Armory::Versioning, versions: labels, default: :latest, profiles: true
    end

    expect(run_refusing(dynamic_only, context: { armory_version: older })).to match(/Versioning\.profiles/)
    expect(run_refusing(warden, context: { armory_version: older })).to match(/Schema::Visibility/)
  end

  it "runs a query under the Warden when the app asks for it, still versioned" do
    schema = schema_for
    query = schema.query_class.new(schema, "{ invoice { amount } }", context: { armory_version: newer }, use_visibility_profile: false, root_value: root)

    expect(run_all(schema, [query]).map { |result| messages(result.to_h) }).to eq([["Field 'amount' doesn't exist on type 'Invoice'"]])
  end

  context "with preload: true" do
    it "computes every version's visibility when the schema loads" do
      schema = schema_for(preload: true)

      expect(schema.visibility.cached_profiles.keys).to contain_exactly(:"armory_v_2024-06-01", :"armory_v_2025-01-01")
      expect(run(schema, "{ invoice { amount } }", context: { armory_version: older })).to eq("data" => { "invoice" => { "amount" => 100 } })
    end

    it "refuses, when the schema loads, a lifecycle naming a label versions: does not hold" do
      base = controls::Field.example
      typo = Class.new(GraphQL::Schema::Object) do
        graphql_name "Typo"
        include GraphQL::Armory::Versioning::Base
        lifecycle added: "2024-13-01"
        field :x, String, null: true
      end
      query = Class.new(GraphQL::Schema::Object) do
        graphql_name "Query"
        field_class(base)
        field :typo, typo, null: true
      end

      expect { schema_for(query: query, preload: true) }.to raise_error(versioning::ConfigurationError, /Typo: added: "2024-13-01" is not in versions/)
    end

    it "refuses an app's own profile Hash, which carries no versions, when the schema loads" do
      expect { schema_for(preload: true, extra_profiles: { admin: {} }) }.to raise_error(versioning::ConfigurationError, /Versioning\.profiles/)
    end
  end

  it "fails closed when Authorization's visible_when: is asked under a profile (limit 6)" do
    adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: true)
    argument = Class.new(GraphQL::Schema::Argument) { include GraphQL::Armory::Versioning::Base; include GraphQL::Armory::Authorization::Base }
    base_field = Class.new(GraphQL::Schema::Field) do
      include GraphQL::Armory::Versioning::Base
      include GraphQL::Armory::Authorization::Base
      argument_class(argument)
    end
    query = Class.new(GraphQL::Schema::Object) do
      include GraphQL::Armory::Versioning::Base
      include GraphQL::Armory::Authorization::Base
      graphql_name "Query"
      field_class(base_field)
      authorize :read, model: ::Struct
      field :notes, String, null: true, visible_when: :export, added: "2025-01-01"
    end
    labels = controls::Versions::LABELS
    schema = Class.new(ArmoryEngine.base_schema) do
      query(query)
      use GraphQL::Armory::Versioning, versions: labels, default: :latest, profiles: true
      use GraphQL::Schema::Visibility, profiles: GraphQL::Armory::Versioning.profiles(self)
      use GraphQL::Armory::Authorization, adapter: adapter
    end

    expect { execute_query(schema, "{ notes }", context: { armory_version: newer }) }.to raise_error(GraphQL::Armory::Error, /visible_when: needs a per-query context/)
  end

  it "refuses a named profile on a schema without profiles: true, since it would keep one query's version for all" do
    query = controls::Query.example
    labels = controls::Versions::LABELS
    schema = Class.new(ArmoryEngine.base_schema) do
      query(query)
      use GraphQL::Schema::Visibility, profiles: { public: {} }, dynamic: true
      use GraphQL::Armory::Versioning, versions: labels, default: :latest
    end

    message = run_refusing(schema, context: { armory_version: older, visibility_profile: :public })

    expect(message).to match(/named Schema::Visibility profiles.*profiles: true/)
    expect(run(schema, "{ invoice { amount } }", context: { armory_version: older })).to eq("data" => { "invoice" => { "amount" => 100 } })
  end
end
