# frozen_string_literal: true

# A field declared with `added:` or `removed:` exists only in the versions it lives in: a client of another version cannot
# select it, introspect it, be suggested it or see it in that version's SDL.
RSpec.describe "use GraphQL::Armory::Versioning: fields" do
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:controls) { versioning::Controls }
  let(:resolved) { [] }
  let(:root) { controls::Root.example(resolved) }

  def run(schema, query_string, version)
    execute_query(schema, query_string, root_value: root, context: { armory_version: version }).to_h
  end

  def messages(result) = Array(result["errors"]).map { |error| error["message"] }

  def invoice_fields(schema, version)
    result = run(schema, '{ __type(name: "Invoice") { fields(includeDeprecated: true) { name isDeprecated deprecationReason } } }', version)
    result.dig("data", "__type", "fields").to_h { |field| [field["name"], [field["isDeprecated"], field["deprecationReason"]]] }
  end

  %i[warden visibility].each do |visibility|
    context "with #{visibility}" do
      let(:schema) { controls::Schema.example(visibility: visibility, base: ArmoryEngine.base_schema) }

      it "hides a field added in a later version from selection and from suggestions" do
        older = run(schema, "{ invoice { tags(first: 1) } }", "2024-06-01")
        older_typo = run(schema, "{ invoice { tagz } }", "2024-06-01")
        newer = run(schema, "{ invoice { tags(first: 1) } }", "2025-01-01")
        newer_typo = run(schema, "{ invoice { tagz } }", "2025-01-01")

        expect([messages(older), messages(older_typo), newer, messages(newer_typo)]).to eq(
          [["Field 'tags' doesn't exist on type 'Invoice'"], ["Field 'tagz' doesn't exist on type 'Invoice'"],
           { "data" => { "invoice" => { "tags" => ["paid"] } } }, ["Field 'tagz' doesn't exist on type 'Invoice' (Did you mean `tags`?)"]]
        )
        expect(resolved).to eq(%i[invoice tags])
      end

      it "removes a field from selection, introspection and the SDL of the version that removed it" do
        result = run(schema, "{ invoice { amount } }", "2025-01-01")
        sdl = schema.to_definition(context: { armory_version: "2025-01-01" })

        expect([messages(result), result.key?("data"), resolved]).to eq([["Field 'amount' doesn't exist on type 'Invoice'"], false, []])
        expect(invoice_fields(schema, "2025-01-01").keys.sort).to eq(%w[number tags total])
        expect([sdl.include?("amount"), sdl.include?("tags(first: Int): [String!]!")]).to eq([false, true])
        expect(schema.validate("{ invoice { amount } }", context: { armory_version: "2025-01-01" }).map(&:message)).to eq(["Field 'amount' doesn't exist on type 'Invoice'"])
      end

      it "serves a field in the versions it lives in, deprecated with graphql-ruby's own deprecation_reason:" do
        result = run(schema, "{ invoice { amount } }", "2024-06-01")

        expect(result).to eq("data" => { "invoice" => { "amount" => 100 } })
        expect(invoice_fields(schema, "2024-06-01")).to eq("amount" => [true, "Use `total`"], "number" => [false, nil], "total" => [false, nil])
        expect(schema.validate("{ invoice { amount } }", context: { armory_version: "2024-06-01" })).to eq([])
      end

      it "prints a field in the SDL of the versions it lives in, with its @deprecated" do
        skip "graphql before 2.6 with json 3.1 cannot print a String argument, with or without versioning" if Gem::Version.new(GraphQL::VERSION) < Gem::Version.new("2.6")

        sdl = schema.to_definition(context: { armory_version: "2024-06-01" })

        expect([sdl.include?('amount: Int! @deprecated(reason: "Use `total`")'), sdl.include?("total: Int!"), sdl.include?("tags")]).to eq([true, true, false])
      end

      it "keeps a field with no lifecycle in every served version" do
        results = %w[2024-06-01 2025-01-01].map { |version| run(schema, "{ invoice { number } }", version) }

        expect(results).to eq([{ "data" => { "invoice" => { "number" => "A-1" } } }] * 2)
      end

      # Increment 1 claims nothing about lookups with no context: graphql-ruby answers them without asking `visible?`.
      it "leaves context-less lookups answering every definition, whatever its lifecycle" do
        invoice = schema.get_type("Invoice")

        expect([invoice.get_field("amount")&.graphql_name, invoice.get_field("tags")&.graphql_name]).to eq(%w[amount tags])
        expect(invoice.fields.keys.sort).to eq(%w[amount number tags total])
        expect(invoice.get_field("amount").armory_lifecycle.to_h).to eq(removed: "2025-01-01")
      end
    end
  end

  it "refuses a lifecycle label that is not a non-empty String, or the same version for added: and removed:, when the field is defined" do
    base_field = controls::Field.example
    define = lambda do |**lifecycle|
      Class.new(GraphQL::Schema::Object) do
        graphql_name "Probe"
        field_class(base_field)
        field :probe, String, **lifecycle
      end
    end

    [{ added: "" }, { removed: :"2025-01-01" }, { added: 2024 }, { added: "2024-06-01", removed: "2024-06-01" }].each do |lifecycle|
      expect { define.(**lifecycle) }.to raise_error(versioning::ConfigurationError, /probe/)
    end
  end

  it "raises, naming the field, when a lifecycle names a version the schema does not declare or puts removed: before added:" do
    base_field = controls::Field.example
    schema_with = lambda do |**lifecycle|
      invoice = Class.new(GraphQL::Schema::Object) do
        graphql_name "Invoice"
        field_class(base_field)
        field :probe, String, **lifecycle
      end
      controls::Schema.example(visibility: :visibility, base: ArmoryEngine.base_schema, query: controls::Query.example(invoice))
    end

    expect { run(schema_with.(added: "2024-6-01"), "{ invoice { probe } }", "2025-01-01") }
      .to raise_error(versioning::ConfigurationError, /Invoice.probe: added: "2024-6-01" is not in versions:/)
    expect { run(schema_with.(added: "2025-01-01", removed: "2024-06-01"), "{ invoice { probe } }", "2025-01-01") }
      .to raise_error(versioning::ConfigurationError, /Invoice.probe: removed: "2024-06-01" comes before added: "2025-01-01"/)
  end
end
