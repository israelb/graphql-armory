# frozen_string_literal: true

require "stringio"
require "graphql/armory/versioning/rspec"

# Versioning's diff: what changes between two versions for a client built against the first, in three buckets. A
# change a client of `from` can trip on is never listed as safe.
RSpec.describe "GraphQL::Armory::Versioning::Diff" do
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:controls) { versioning::Controls }
  let(:evolution) { controls::Evolution }

  def pairs(changes) = changes.map { |change| [change.path, change.message] }

  # One field `x` on Query in 2024-06-01 and its twin in 2025-01-01, and the same for an argument `a` of `y`. `keep` and
  # `count` keep String and Int in both versions: a built-in scalar nothing uses is not in the schema.
  def schema_with(output: nil, input: nil, visibility: :visibility)
    base_argument = controls::Argument.example
    base_field = Class.new(GraphQL::Schema::Field) { include GraphQL::Armory::Versioning::Base; argument_class(base_argument) }
    query = Class.new(GraphQL::Schema::Object) do
      include GraphQL::Armory::Versioning::Base
      graphql_name "Query"
      field_class(base_field)
      field :keep, String, null: true
      field :count, Integer, null: true
      if output
        field :x, output[0], null: output[1], removed: "2025-01-01"
        field :x, output[2], null: output[3], added: "2025-01-01"
      end
      if input
        field :y, String, null: true do
          argument :a, input[0], required: input[1], removed: "2025-01-01"
          argument :a, input[2], required: input[3], added: "2025-01-01"
        end
      end
    end
    controls::Schema.example(visibility: visibility, query: query, base: ArmoryEngine.base_schema)
  end

  def diff(schema, from: evolution::FROM, to: evolution::TO) = versioning::Diff.(schema, from: from, to: to)

  %i[visibility warden].each do |visibility|
    context "with #{visibility}" do
      it "classifies every change between two versions in three buckets" do
        result = diff(evolution.example(visibility: visibility, base: ArmoryEngine.base_schema))

        expect(pairs(result.breaking)).to eq(evolution::BREAKING)
        expect(pairs(result.dangerous)).to eq(evolution::DANGEROUS)
        expect(pairs(result.safe)).to eq(evolution::SAFE)
        expect(result.breaking?).to be(true)
        expect(result.changes.map(&:bucket).uniq).to eq(%i[breaking dangerous safe])
      end

      it "reads the other way as the opposite change" do
        result = diff(evolution.example(visibility: visibility, base: ArmoryEngine.base_schema), from: evolution::TO, to: evolution::FROM)

        expect(pairs(result.breaking)).to include(["Money.amount", "field removed"], ["Contract", "type removed"],
                                                  ["Invoice.note", "type changed from String! to String"],
                                                  ["Query.customer", "type changed from Client to Customer"])
        expect(pairs(result.dangerous)).to include(["Invoice.code", "type changed from String to String!"], ["Status.CANCELLED", "value added"])
        expect(pairs(result.safe)).to include(["Invoice.label", "no longer deprecated"], ["Money.cents", "field added"],
                                              ["Query.invoices.limit", "type changed from Int! to Int"])
      end

      it "finds nothing between a version and itself" do
        result = diff(evolution.example(visibility: visibility, base: ArmoryEngine.base_schema), from: evolution::TO, to: evolution::TO)

        expect(result.changes).to eq([])
        expect(result.breaking?).to be(false)
        expect(result.to_s).to include("No changes")
      end
    end
  end

  describe "nullability, by the GraphQL spec's rules for outputs and inputs" do
    {
      [Integer, true, Integer, false] => [:dangerous, "type changed from Int to Int!"],
      [Integer, false, Integer, true] => [:breaking, "type changed from Int! to Int"],
      [[Integer, { null: true }], true, [Integer], true] => [:dangerous, "type changed from [Int] to [Int!]"],
      [[Integer], true, [Integer, { null: true }], true] => [:breaking, "type changed from [Int!] to [Int]"],
      [[Integer], true, Integer, true] => [:breaking, "type changed from [Int!] to Int"],
      [Integer, true, String, true] => [:breaking, "type changed from Int to String"],
    }.each do |(old_type, old_null, new_type, new_null), (bucket, message)|
      it "an output field: #{message} is #{bucket}" do
        result = diff(schema_with(output: [old_type, old_null, new_type, new_null]))

        expect(result.changes.map { |change| [change.bucket, change.path, change.message] }).to eq([[bucket, "Query.x", message]])
      end
    end

    {
      [Integer, false, Integer, true] => [:breaking, "type changed from Int to Int!"],
      [Integer, true, Integer, false] => [:safe, "type changed from Int! to Int"],
      [[Integer], false, [Integer, { null: true }], false] => [:safe, "type changed from [Int!] to [Int]"],
      [[Integer, { null: true }], false, [Integer], false] => [:breaking, "type changed from [Int] to [Int!]"],
      [Integer, false, String, false] => [:breaking, "type changed from Int to String"],
    }.each do |(old_type, old_required, new_type, new_required), (bucket, message)|
      it "an argument: #{message} is #{bucket}" do
        result = diff(schema_with(input: [old_type, old_required, new_type, new_required]))

        expect(result.changes.map { |change| [change.bucket, change.path, change.message] }).to eq([[bucket, "Query.y.a", message]])
      end
    end
  end

  it "says a default removed from a non-null argument makes it required" do
    base_argument = controls::Argument.example
    base_field = Class.new(GraphQL::Schema::Field) { include GraphQL::Armory::Versioning::Base; argument_class(base_argument) }
    query = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field_class(base_field)
      field :y, String, null: true do
        argument :a, Integer, required: false, default_value: 1, removed: "2025-01-01"
        argument :a, Integer, required: true, added: "2025-01-01"
        argument :b, Integer, required: false, added: "2025-01-01", default_value: 2
      end
    end
    result = diff(controls::Schema.example(query: query, base: ArmoryEngine.base_schema))

    expect(result.changes.map { |change| [change.bucket, change.path, change.message] }).to eq(
      [[:breaking, "Query.y.a", "type changed from Int to Int!"], [:safe, "Query.y.b", "argument added"]]
    )
  end

  it "prints the buckets, breaking first" do
    text = diff(evolution.example(base: ArmoryEngine.base_schema)).to_s

    expect(text).to start_with("From 2024-06-01 to 2025-01-01:\n")
    expect(text).to include("Breaking (16):\n  Archivable: type removed\n")
    expect(text.index("Breaking (16)")).to be < text.index("Dangerous (5)")
    expect(text.index("Dangerous (5)")).to be < text.index("Safe (7)")
  end

  describe "what it refuses" do
    it "refuses a label the schema does not list, and a retired one, naming it" do
      schema = evolution.example

      expect { diff(schema, to: "2026-01-01") }.to raise_error(versioning::UnknownVersionError, /"2026-01-01"/)
      expect { diff(schema, from: "2024-01-15") }.to raise_error(versioning::ConfigurationError, /"2024-01-15" is retired/)
    end

    it "refuses a schema without versioning" do
      plain = Class.new(GraphQL::Schema) { query(Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :x, String, null: true }) }

      expect { diff(plain) }.to raise_error(versioning::ConfigurationError, /never installed the plugin/)
    end

    it "compares nothing when built with new: it refuses instead of answering no changes" do
      expect { versioning::Diff.new.(from: "a", to: "b") }.to raise_error(versioning::ConfigurationError, /Diff\.build/)
    end
  end

  it "reads each version through its reader, which a Substitute can stand in for" do
    schema = evolution.example
    reader = versioning::Diff::Reader::Substitute.new
    reader.answer(evolution::FROM, versioning.types(schema, evolution::FROM))
    reader.answer(evolution::TO, versioning.types(schema, evolution::TO))

    result = versioning::Diff.new(reader).(from: evolution::FROM, to: evolution::TO)

    expect(reader.labels).to eq([evolution::FROM, evolution::TO])
    expect(pairs(result.breaking)).to eq(evolution::BREAKING)
    expect { versioning::Diff.new(reader).(from: evolution::FROM, to: "nope") }.to raise_error(versioning::ConfigurationError, /nope/)
  end

  it "does not let Authorization's visible_when hide a change" do
    adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: false)
    mods = [GraphQL::Armory::Versioning::Base, GraphQL::Armory::Authorization::Base]
    base_field = Class.new(GraphQL::Schema::Field) { mods.each { |mod| include mod } }
    query = Class.new(GraphQL::Schema::Object) do
      mods.each { |mod| include mod }
      graphql_name "Query"
      authorize :read, model: ::Struct
      field_class(base_field)
      field :keep, String, null: true
      field :secret, String, null: true, removed: "2025-01-01", visible_when: :admin?
    end
    schema = Class.new(ArmoryEngine.base_schema) do
      query(query)
      use GraphQL::Schema::Visibility
      use GraphQL::Armory::Versioning, versions: %w[2024-06-01 2025-01-01], default: :latest
      use GraphQL::Armory::Authorization, adapter: adapter
    end

    expect(pairs(diff(schema).breaking)).to eq([["Query.secret", "field removed"]])
  end

  describe "the matcher" do
    it "passes when nothing breaks, and lists the breaking changes when something does" do
      schema = evolution.example

      expect(schema).to have_no_breaking_changes(from: evolution::TO, to: evolution::TO)
      expect { expect(schema).to have_no_breaking_changes(from: evolution::FROM, to: evolution::TO) }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /Invoice\.amount: field removed/)
    end
  end

  describe "the rake command" do
    around do |example|
      Object.const_set(:ArmoryVersioningDiffSchema, evolution.example)
      example.run
    ensure
      Object.send(:remove_const, :ArmoryVersioningDiffSchema)
    end

    it "prints the diff and answers 1 when something breaks" do
      out = StringIO.new
      command = versioning::Diff::Command.new(out: out)

      expect(command.("ArmoryVersioningDiffSchema", evolution::FROM, evolution::TO)).to eq(1)
      expect(out.string).to include("Invoice.amount: field removed")
      expect(command.("ArmoryVersioningDiffSchema", evolution::TO, evolution::TO)).to eq(0)
    end

    it "answers 1 with a message for a missing argument, an unknown schema or an unknown version" do
      out = StringIO.new
      command = versioning::Diff::Command.new(out: out)

      expect(command.("ArmoryVersioningDiffSchema", evolution::FROM, nil)).to eq(1)
      expect(command.("", nil, nil)).to eq(1)
      expect(command.("NoSuchSchemaHere", evolution::FROM, evolution::TO)).to eq(1)
      expect(command.("ArmoryVersioningDiffSchema", evolution::FROM, "2030-01-01")).to eq(1)
      expect(out.string).to include("rake \"graphql_armory:versions:diff[YourSchema,FROM,TO]\"")
        .and include("No schema named NoSuchSchemaHere").and include("\"2030-01-01\" is not in versions")
    end

    it "answers what a Diff::Substitute is told, and records what it was asked" do
      out = StringIO.new
      result = versioning::Diff::Result.new(from: "a", to: "b", changes: [])
      substitute = versioning::Diff::Substitute.new(result)

      expect(versioning::Diff::Command.new(out: out, diff: substitute).("ArmoryVersioningDiffSchema", "a", "b")).to eq(0)
      expect(substitute.calls).to eq([[ArmoryVersioningDiffSchema, { from: "a", to: "b" }]])
      expect(out.string).to include("No changes")
    end
  end
end
