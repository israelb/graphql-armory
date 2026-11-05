# frozen_string_literal: true

# The audit's checks of what a version serves without refusing anything, one shape at a time, beyond the matrix's rows.
RSpec.describe "GraphQL::Armory::Versioning::Audit hazards" do
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:old) { "2024-06-01" }
  let(:new) { "2025-01-01" }

  def audit(schema) = versioning::Audit.(schema)

  def found(report, kind) = report.problems.select { |problem| problem.kind == kind }

  def paths(report, kind) = found(report, kind).map(&:path)

  def run(schema, query_string, version, root: nil)
    execute_query(schema, query_string, root_value: root, context: { armory_version: version }).to_h
  end

  def record(**values) = Struct.new(*values.keys, keyword_init: true).new(**values)

  def schema_over(query_type, visibility, **options)
    plugin = versioning::Controls::Schema::PLUGINS.fetch(visibility)
    settings = { versions: versioning::Controls::Versions::LABELS, retired: versioning::Controls::Versions::RETIRED, default: :latest, **options }
    Class.new(ArmoryEngine.base_schema) do
      query(query_type)
      use plugin
      use GraphQL::Armory::Versioning, **settings
    end
  end

  def bases
    mod = versioning::Base
    membership = Class.new(GraphQL::Schema::TypeMembership) { include mod }
    argument = Class.new(GraphQL::Schema::Argument) { include mod }
    field = Class.new(GraphQL::Schema::Field) { include mod; argument_class(argument) }
    object = Class.new(GraphQL::Schema::Object) { include mod; field_class(field) }
    interface = Module.new do
      include GraphQL::Schema::Interface
      include mod
      field_class(field)
      type_membership_class(membership)
    end
    { argument: argument, field: field, object: object, interface: interface, membership: membership }
  end

  %i[warden visibility].each do |visibility|
    context "with #{visibility}" do
      describe ":fallback" do
        it "reports a field hidden on a subclass while its parent's definition lives in the version" do
          b = bases
          parent = Class.new(b[:object]) { graphql_name "Document"; field :title, String, null: true }
          child = Class.new(parent) { graphql_name "Contract"; field :title, String, null: true, removed: "2025-01-01" }
          query = Class.new(b[:object]) { graphql_name "Query"; field :contract, child, null: true; field :document, parent, null: true }
          schema = schema_over(query, visibility)

          served = run(schema, "{ contract { title } }", new, root: record(contract: record(title: "t"), document: nil))
          if visibility == :warden
            expect(served).to eq("data" => { "contract" => { "title" => "t" } })
          else
            expect(served["errors"].map { |error| error["message"] }).to eq(["Field 'title' doesn't exist on type 'Contract'"])
          end
          report = audit(schema)
          expect(paths(report, :fallback)).to eq(["Contract.title"])
          message = visibility == :warden ? /hides Contract's definition, so the Warden serves Document's/ : /Contract no longer has title in 2025-01-01, though Document's definition lives there/
          expect(found(report, :fallback).first.message).to match(message)
        end

        it "does not count an interface whose membership the version hides" do
          b = bases
          totaled = Module.new { include b[:interface]; graphql_name "Totaled"; field :total, Integer, null: true }
          invoice = Class.new(b[:object]) do
            graphql_name "Invoice"
            implements totaled, removed: "2025-01-01"
            field :id, GraphQL::Types::ID, null: true
            field :total, Integer, null: true, removed: "2025-01-01"
          end
          other = Class.new(b[:object]) { graphql_name "Other"; implements totaled; field :id, GraphQL::Types::ID, null: true }
          query = Class.new(b[:object]) { graphql_name "Query"; field :invoice, invoice, null: true; field :other, other, null: true }

          expect(paths(audit(schema_over(query, visibility)), :fallback)).to eq([])
        end

        it "does not report a field versioned with its interface's definition" do
          b = bases
          totaled = Module.new { include b[:interface]; graphql_name "Totaled"; field :id, GraphQL::Types::ID, null: true; field :total, Integer, null: true, removed: "2025-01-01" }
          invoice = Class.new(b[:object]) { graphql_name "Invoice"; implements totaled; field :total, Integer, null: true, removed: "2025-01-01" }
          query = Class.new(b[:object]) { graphql_name "Query"; field :invoice, invoice, null: true }

          expect(audit(schema_over(query, visibility)).problems).to eq([])
        end
      end
    end
  end
end
