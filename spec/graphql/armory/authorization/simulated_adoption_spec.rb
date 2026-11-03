# frozen_string_literal: true

require "tmpdir"

# docs/authorization.md, "Measuring before you adopt": an app with no armory, audited as if it had adopted it.
RSpec.describe "Auditing a schema before adopting the plugin" do
  z = GraphQL::Armory::Authorization

  def app
    base_field = Class.new(GraphQL::Schema::Field) do
      def authorized?(object, args, context) = super
    end
    base_object = Class.new(GraphQL::Schema::Object) { field_class base_field }
    thing = Class.new(base_object) do
      graphql_name "Thing"
      field :name, String
    end
    payload_owner = Class.new(GraphQL::Schema::RelayClassicMutation) do
      graphql_name "Activate"
      object_class base_object
      field_class base_field
      field :thing, thing
    end
    query = Class.new(base_object) do
      graphql_name "Query"
      field :thing, thing
    end
    mutation = Class.new(base_object) do
      graphql_name "Mutation"
      field :activate, mutation: payload_owner
    end
    schema = Class.new(GraphQL::Schema) do
      query query
      mutation mutation
    end
    { base_field: base_field, base_object: base_object, mutation_class: payload_owner, schema: schema, query: query }
  end

  define_method(:adopt) do |parts, **options|
    [parts[:base_field], parts[:base_object], parts[:mutation_class]].each { |klass| klass.include(z::Base) }
    parts[:base_object].default_action(:read)
    Class.new(parts[:schema]) { use z, adapter: :pundit, **options }
  end

  it "reports only the missing plugin and Base before the simulation, and the real work after it" do
    parts = app
    before = z::Audit.(parts[:schema])
    expect(before.problems.map(&:kind).uniq).to contain_exactly(:plugin, :unprotected)

    kinds = z::Audit.(adopt(parts)).problems.map(&:kind)

    expect(kinds).to include(:own_check, :no_rule, :field_without_rule)
  end

  it "leaves the app's schema without the plugin" do
    parts = app
    adopt(parts)

    expect(z::Audit.(parts[:schema]).problems.map(&:kind)).to include(:plugin)
  end

  it "lists a declared own check as a reason instead of a problem" do
    parts = app
    schema = adopt(parts, own_checks: { parts[:base_field] => { authorized?: "calls super" } })

    expect(z::Audit.(schema).problems.map(&:kind)).not_to include(:own_check)
  end

  context "with a payload field that would answer null" do
    def payload_problems(schema)
      z = GraphQL::Armory::Authorization
      z::Audit.(schema).problems.select { |problem| problem.kind == :field_without_rule }.map(&:path)
    end

    it "reports it while the mutation has no rule" do
      parts = app

      expect(payload_problems(adopt(parts))).to include(a_string_matching(/ActivatePayload.thing/))
    end

    it "clears it when the mutation has a rule, which covers its payload" do
      parts = app
      schema = adopt(parts)
      parts[:mutation_class].authorize :update, model: "Thing"

      expect(payload_problems(schema)).to eq([])
    end

    it "clears it with a public mutation that declares covers_fields" do
      parts = app
      schema = adopt(parts)
      parts[:mutation_class].authorize :none, reason: "sign in", covers_fields: true

      expect(payload_problems(schema)).to eq([])
    end
  end

  it "keeps a baseline of the simulation, which fails on a new field" do
    parts = app
    schema = adopt(parts, own_checks: { parts[:base_field] => { authorized?: "calls super" } })

    Dir.mktmpdir do |dir|
      path = File.join(dir, "baseline.json")
      z::Audit::Baseline.write(z::Audit.(schema), path)
      expect(z::Audit::Baseline.load(path).(z::Audit.(schema)).passes?).to be(true)

      parts[:query].field :other, String

      expect(z::Audit::Baseline.load(path).(z::Audit.(schema)).passes?).to be(false)
    end
  end
end
