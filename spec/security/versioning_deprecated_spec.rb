# frozen_string_literal: true

# `deprecated: D` deprecates a member from version D on: graphql-ruby's `deprecation_reason` is static, so the class that
# defines the member makes two definitions of it, one up to D with no reason and one from D with it, through the same
# twins machinery as the explicit form. Each version sees exactly one.
RSpec.describe "use GraphQL::Armory::Versioning: deprecated:" do
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:controls) { versioning::Controls }
  let(:deprecations) { controls::Deprecations }
  let(:old) { "2024-06-01" }
  let(:new) { "2025-01-01" }

  let(:introspection) do
    <<~GRAPHQL
      {
        invoice: __type(name: "Invoice") { fields(includeDeprecated: true) { name isDeprecated deprecationReason args(includeDeprecated: true) { name } } }
        priced: __type(name: "Priced") { fields(includeDeprecated: true) { name isDeprecated deprecationReason } }
        query: __type(name: "Query") { fields(includeDeprecated: true) { name isDeprecated deprecationReason args(includeDeprecated: true) { name isDeprecated deprecationReason } } }
        filter: __type(name: "InvoiceFilter") { inputFields(includeDeprecated: true) { name isDeprecated deprecationReason } }
        status: __type(name: "Status") { enumValues(includeDeprecated: true) { name isDeprecated deprecationReason } }
      }
    GRAPHQL
  end

  def run(schema, query_string, version, root: deprecations::Root.example, **options)
    context = version ? { armory_version: version } : {}
    execute_query(schema, query_string, root_value: root, context: context.merge(options.delete(:context) || {}), **options).to_h
  end

  def schema_over(query_type, visibility, subscription: nil, authorization: false, &block)
    plugin = controls::Schema::PLUGINS.fetch(visibility)
    adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new
    labels = controls::Versions::LABELS
    retired = controls::Versions::RETIRED
    Class.new(ArmoryEngine.base_schema) do
      query(query_type)
      subscription(subscription) if subscription
      use plugin
      use GraphQL::Armory::Versioning, versions: labels, retired: retired, default: :latest
      use GraphQL::Armory::Authorization, adapter: adapter if authorization
      class_eval(&block) if block
    end
  end

  # Every deprecated member the introspection answer lists, as "Path: reason".
  def deprecated(data)
    found = []
    walk = lambda do |path, entries|
      Array(entries).each do |entry|
        found << "#{path}.#{entry['name']}: #{entry['deprecationReason']}" if entry["isDeprecated"]
        walk.("#{path}.#{entry['name']}", entry["args"]) if entry["args"]
      end
    end
    walk.("Invoice", data["invoice"]["fields"])
    walk.("Priced", data["priced"]["fields"])
    walk.("Query", data["query"]["fields"])
    walk.("InvoiceFilter", data["filter"]["inputFields"])
    walk.("Status", data["status"]["enumValues"])
    found.sort
  end

  def tags_arguments(data) = data["invoice"]["fields"].find { |field| field["name"] == "tags" }["args"].map { |arg| arg["name"] }

  let(:deprecated_from_new) do
    [
      "Invoice.amount: Use `total`", "Invoice.tags: Use `labels`", "InvoiceFilter.code: Use `number`", "Priced.amount: Use `total`",
      "Query.find.code: Use `number`", "Query.find: Use `lookup`", "Query.invoices.page: Use `cursor`", "Query.lookup.code: Use `number`",
      "Status.CANCELLED: Use `VOID`"
    ]
  end

  %i[warden visibility].each do |visibility|
    context "with #{visibility}" do
      let(:schema) { schema_over(deprecations::Query.example, visibility) }

      it "deprecates each member kind only from its version, and the latest version sees the deprecation" do
        answers = [old, new, nil].map { |version| run(schema, introspection, version)["data"] }

        expect(answers.map { |data| deprecated(data) }).to eq([[], deprecated_from_new, deprecated_from_new])
        # The block of a deprecated field runs once per definition, keeping its arguments' own lifecycles.
        expect(answers.map { |data| tags_arguments(data) }).to eq([["page"], ["first"], ["first"]])
      end

      it "runs every deprecated member in both versions, and prints @deprecated only from its version" do
        query = '{ invoice { total amount tags(%s) } invoices(page: 2, filter: { code: "A" }) lookup(code: "x") find(code: "y") status }'
        common = { "total" => 100, "amount" => 100 }
        rest = { "invoices" => ["filter.code=A", "page=2"], "lookup" => ["code=x"], "find" => ["code=y"], "status" => "CANCELLED" }

        expect(run(schema, format(query, "page: 1"), old)).to eq("data" => { "invoice" => common.merge("tags" => ["page=1"]), **rest })
        expect(run(schema, format(query, "first: 1"), new)).to eq("data" => { "invoice" => common.merge("tags" => ["first=1"]), **rest })
        # graphql 2.4 with json 3.1 cannot print a String argument in the SDL, with or without versioning.
        next unless ArmoryJsonPrinting.prints_strings?

        sdl = [old, new].map { |version| schema.to_definition(context: { armory_version: version }) }
        expect(sdl.map { |text| text.scan("@deprecated").size }).to eq([0, deprecated_from_new.size])
      end

      it "hides a deprecated member from a list that leaves deprecated members out, only from its version" do
        listing = '{ __type(name: "Query") { fields { name } } }'
        names = [old, new].map { |version| run(schema, listing, version)["data"]["__type"]["fields"].map { |field| field["name"] }.sort }

        expect(names).to eq([%w[find invoice invoices lookup status], %w[invoice invoices lookup status]])
      end

      it "refuses deprecated: on a subscription field's arguments, which graphql-ruby's trigger reads with no version" do
        b = deprecations::Bases.example
        from = new
        subscription = Class.new(b[:object]) do
          graphql_name "Subscription"
          field :invoice_changed, String, null: true do
            argument :since, String, required: false, deprecated: from, deprecation_reason: "Use `after`"
          end
        end

        expect { run(schema_over(deprecations::Query.example(b), visibility, subscription: subscription), "{ __typename }", new) }
          .to raise_error(versioning::ConfigurationError, /Subscription\.invoiceChanged: Subscription\.invoiceChanged\.since has two definitions/)
      end

      it "serves a deprecated subscription root field to triggers of each version" do
        b = deprecations::Bases.example
        from = new
        subscription = Class.new(b[:object]) do
          graphql_name "Subscription"
          field :invoice_changed, String, null: true, deprecated: from, deprecation_reason: "Use `invoiceUpdated`" do
            argument :id, GraphQL::Types::ID, required: true
          end
        end
        subscribed = schema_over(deprecations::Query.example(b), visibility, subscription: subscription) { use GraphQL::Subscriptions }
        reasons = [old, new].map do |version|
          run(subscribed, '{ __type(name: "Subscription") { fields(includeDeprecated: true) { deprecationReason } } }', version)["data"]["__type"]["fields"]
        end

        expect(reasons).to eq([[{ "deprecationReason" => nil }], [{ "deprecationReason" => "Use `invoiceUpdated`" }]])
        # The base Subscriptions class raises from `execute_all`, after the trigger found the field and read its arguments.
        [old, new].each do |version|
          expect { subscribed.subscriptions.trigger(:invoice_changed, { id: "1" }, nil, context: { armory_version: version }) }
            .to raise_error(GraphQL::RequiredImplementationMissingError)
        end
      end

      it "deprecates a mutation's argument, on its generated input type too, and a field of its payload" do
        b = deprecations::Bases.example
        from = new
        base = Class.new(GraphQL::Schema::RelayClassicMutation) do
          include GraphQL::Armory::Versioning::Base
          argument_class(b[:argument])
          field_class(b[:field])
          object_class(b[:object])
          input_object_class(b[:input])
        end
        close = Class.new(base) do
          graphql_name "Close"
          argument :code, String, required: false, deprecated: from, deprecation_reason: "Use `number`"
          field :result, String, null: true
          field :legacy, String, null: true, deprecated: from, deprecation_reason: "Use `result`"
          # Execution::Next calls methods on what it resolves, so the payload is a record, not a Hash.
          define_method(:resolve) { |code: nil| Struct.new(:result, :legacy).new("closed #{code}", "closed") }
        end
        mutation = Class.new(b[:object]) { graphql_name "Mutation"; field :close, mutation: close }
        schema = schema_over(deprecations::Query.example(b), visibility) { mutation(mutation) }
        shape = '{ i: __type(name: "CloseInput") { inputFields(includeDeprecated: true) { name deprecationReason } } ' \
                'p: __type(name: "ClosePayload") { fields(includeDeprecated: true) { name deprecationReason } } }'
        write = 'mutation { close(input: { code: "A" }) { result legacy } }'

        reasons = [old, new].map do |version|
          data = run(schema, shape, version)["data"]
          (data["i"]["inputFields"] + data["p"]["fields"]).to_h { |member| [member["name"], member["deprecationReason"]] }
        end

        expect(reasons).to eq(
          [{ "clientMutationId" => nil, "code" => nil, "result" => nil, "legacy" => nil },
           { "clientMutationId" => nil, "code" => "Use `number`", "result" => nil, "legacy" => "Use `result`" }]
        )
        expect([old, new].map { |version| run(schema, write, version) }).to all(eq("data" => { "close" => { "result" => "closed A", "legacy" => "closed" } }))
      end

      it "is one member for Authorization's audit, and runs under Authorization in each version" do
        guarded = schema_over(deprecations::Query.example(deprecations::Bases.example(authorization: true)), visibility, authorization: true)
        report = GraphQL::Armory::Authorization::Audit.(guarded)

        # The resolver has no Authorization rule: its two definitions of Query.find are reported once, as one member.
        expect(report.problems.map { |problem| [problem.kind, problem.path] }).to eq([[:unprotected, "Query.find"], [:unprotected, "Query.lookup"]])
        expect([old, new].map { |version| run(guarded, "{ find(code: \"y\") invoice { amount } }", version) })
          .to all(eq("data" => { "find" => ["code=y"], "invoice" => { "amount" => 100 } }))
      end

      it "runs a persisted operation against each version's definitions" do
        stored = '{ __type(name: "Query") { fields { name } } status }'
        persisted = schema_over(deprecations::Query.example, visibility) do
          use GraphQL::Armory::PersistedQueries, store: GraphQL::Armory::PersistedQueries::Store::Substitute.new(stored), strict: true
        end
        id = Digest::SHA256.hexdigest(stored)
        answers = [old, new].map { |version| run(persisted, nil, version, context: { operation_id: id }) }

        expect(answers.map { |result| result["data"]["__type"]["fields"].map { |field| field["name"] }.include?("find") }).to eq([true, false])
        expect(answers.map { |result| result["data"]["status"] }).to eq(%w[CANCELLED CANCELLED])
      end
    end
  end

  context "when a member is declared" do
    let(:b) { deprecations::Bases.example }

    it "refuses deprecated: without deprecation_reason:, or on the label of added: or removed:" do
      from = new
      expect { Class.new(b[:object]) { graphql_name "T"; field :total, Integer, null: true, deprecated: from } }
        .to raise_error(versioning::ConfigurationError, /total: deprecated: needs deprecation_reason:/)
      expect { Class.new(b[:input]) { graphql_name "T"; argument :code, String, required: false, deprecated: from, deprecation_reason: "x", removed: from } }
        .to raise_error(versioning::ConfigurationError, /code: deprecated: must come after added: and before removed:/)
      expect { Class.new(b[:enum]) { graphql_name "T"; value "A", deprecated: from, deprecation_reason: "x", added: from } }
        .to raise_error(versioning::ConfigurationError, /A: deprecated: must come after added: and before removed:/)
      expect { Class.new(b[:object]) { graphql_name "T"; field :total, Integer, null: true, deprecated: 2025, deprecation_reason: "x" } }
        .to raise_error(versioning::ConfigurationError, /total: deprecated: must be a non-empty String naming a version, got 2025/)
    end

    it "refuses deprecated: where the class that defines the member does not include Base" do
      from = new
      base_field = b[:field]
      expect { Class.new(GraphQL::Schema::Object) { graphql_name "T"; field_class(base_field); field :total, Integer, null: true, deprecated: from, deprecation_reason: "x" } }
        .to raise_error(versioning::ConfigurationError, /total: deprecated: needs .*include GraphQL::Armory::Versioning::Base/)
    end

    it "refuses deprecated: on a subscription class's arguments" do
      from = new
      expect { Class.new(b[:subscription]) { argument :since, String, required: false, deprecated: from, deprecation_reason: "x" } }
        .to raise_error(versioning::ConfigurationError, /since: deprecated: cannot be used on a subscription's arguments/)
    end

    it "refuses deprecated: on a resolver: field whose resolver is deprecated itself, in every version" do
      skip "this graphql has no Resolver.deprecation_reason" unless GraphQL::Schema::Resolver.respond_to?(:deprecation_reason)
      from = new
      resolver = Class.new(b[:resolver]) { type String, null: true; deprecation_reason "Gone" }
      expect { Class.new(b[:object]) { graphql_name "T"; field :total, resolver: resolver, deprecated: from, deprecation_reason: "x" } }
        .to raise_error(versioning::ConfigurationError, /total: deprecated: .*resolver .*has its own deprecation_reason/)
    end

    it "generates an enum value method once, so graphql-ruby warns about nothing" do
      from = new
      kind = nil
      expect { kind = Class.new(b[:enum]) { graphql_name "Kind"; value "OLD", value_method: :old_kind, deprecated: from, deprecation_reason: "x" } }
        .not_to output.to_stderr
      expect(kind.old_kind).to eq("OLD")
    end

    it "combines with removed:, deprecated in the versions between" do
      query = Class.new(b[:object]) do
        graphql_name "Query"
        field :number, String, null: true
        field :total, Integer, null: true, deprecated: "2024-06-01", deprecation_reason: "x", removed: "2025-01-01"
      end
      listing = '{ __type(name: "Query") { fields(includeDeprecated: true) { name deprecationReason } } }'
      fields = [old, new].map { |version| run(schema_over(query, :visibility), listing, version)["data"]["__type"]["fields"] }

      expect(fields).to eq([[{ "name" => "number", "deprecationReason" => nil }, { "name" => "total", "deprecationReason" => "x" }],
                            [{ "name" => "number", "deprecationReason" => nil }]])
    end

    it "refuses a deprecated: version after removed: the first time a query asks" do
      from = new
      query = Class.new(b[:object]) { graphql_name "Query"; field :total, Integer, null: true, deprecated: from, deprecation_reason: "x", removed: "2024-06-01" }
      expect { run(schema_over(query, :visibility), "{ total }", old) }.to raise_error(versioning::ConfigurationError, /Query\.total: .*comes before/)
    end
  end
end
