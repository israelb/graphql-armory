# frozen_string_literal: true

# Two audit checks: `:profiles`, where `profiles: true` meets a check that needs the query's own context (Authorization's
# `visible_when:` or the app's own `visible?`), which a profile's frozen Hash does not carry; and `:retired_only`, a
# member or twin that lives only in retired versions, which no client can reach any more.
RSpec.describe "GraphQL::Armory::Versioning::Audit: profiles and retired-only members" do
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:audit) { versioning::Audit }
  let(:labels) { versioning::Controls::Versions::LABELS }
  let(:retired) { versioning::Controls::Versions::RETIRED }

  def findings = audit::Findings.new

  def profiles_report(schema)
    found = findings
    audit::Profiles.(schema, found)
    found.report
  end

  def retired_report(schema, **options)
    found = findings
    audit::RetiredOnly.(schema, found, **options)
    found.report
  end

  def rows(report) = report.problems.map { |problem| [problem.kind, problem.path, problem.information?] }

  def bases(authorization: false)
    mods = [GraphQL::Armory::Versioning::Base]
    mods << GraphQL::Armory::Authorization::Base if authorization
    argument = Class.new(GraphQL::Schema::Argument) { mods.each { |mod| include mod } }
    field = Class.new(GraphQL::Schema::Field) { mods.each { |mod| include mod }; argument_class(argument) }
    object = Class.new(GraphQL::Schema::Object) { mods.each { |mod| include mod }; field_class(field) }
    value = Class.new(GraphQL::Schema::EnumValue) { include GraphQL::Armory::Versioning::Base }
    enum = Class.new(GraphQL::Schema::Enum) { include GraphQL::Armory::Versioning::Base; enum_value_class(value) }
    { argument: argument, field: field, object: object, enum: enum, value: value }
  end

  def schema_over(query_type, profiles:, authorization: false, versions: labels, retired_labels: retired, &block)
    adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new
    Class.new(ArmoryEngine.base_schema) do
      query(query_type)
      use GraphQL::Armory::Versioning, versions: versions, retired: retired_labels, default: :latest, profiles: profiles
      use GraphQL::Schema::Visibility, profiles: (profiles ? GraphQL::Armory::Versioning.profiles(self) : {}), dynamic: true
      use GraphQL::Armory::Authorization, adapter: adapter if authorization
      class_eval(&block) if block
    end
  end

  describe "Audit::Profiles" do
    def visible_when_query
      b = bases(authorization: true)
      secret = Class.new(b[:object]) do
        graphql_name "Secret"
        authorize :read, model: ::Struct, visible_when: :export
        field :code, String, null: true
      end
      Class.new(b[:object]) do
        graphql_name "Query"
        authorize :read, model: ::Struct
        field :notes, String, null: true, visible_when: :export do
          argument :tag, String, required: false, visible_when: :export
        end
        field :secret, secret, null: true
      end
    end

    it "reports every visible_when: under profiles: true, where the profile's Hash has no user" do
      report = profiles_report(schema_over(visible_when_query, profiles: true, authorization: true))

      expect(rows(report)).to contain_exactly([:profiles, "Query.notes", false], [:profiles, "Query.notes.tag", false], [:profiles, "Secret", false])
      expect(report.ok?).to be(false)
      expect(report.problems.first.message).to match(/profiles: true.*visible_when:/)
    end

    it "reports nothing without profiles: true" do
      expect(rows(profiles_report(schema_over(visible_when_query, profiles: false, authorization: true)))).to eq([])
    end

    it "reports the app's own visible? on a field, argument, enum value or type class, and on the schema, under profiles: true" do
      b = bases
      own_field = Class.new(b[:field]) { def visible?(context) = super && !context[:hide] }
      own_value = Class.new(b[:value]) { def visible?(context) = super }
      kind = Class.new(b[:enum]) { graphql_name "Kind"; enum_value_class(own_value); value "A" }
      shown = Class.new(b[:object]) do
        graphql_name "Shown"
        def self.visible?(context) = super && context[:user]
        field :x, String, null: true
      end
      query = Class.new(b[:object]) do
        graphql_name "Query"
        field_class(own_field)
        field :kind, kind, null: true
        field :shown, shown, null: true
      end
      schema = schema_over(query, profiles: true) do
        def self.visible?(member, context) = super
      end

      paths = rows(profiles_report(schema)).map { |row| row[1] }

      expect(paths).to include(a_string_ending_with("#visible?")).and include(a_string_ending_with(".visible?"))
      expect(paths.size).to eq(4)
      expect(profiles_report(schema).problems.map(&:kind).uniq).to eq([:profiles])
    end

    it "reports no visible? that comes from graphql-ruby or the gem" do
      b = bases(authorization: true)
      query = Class.new(b[:object]) { graphql_name "Query"; authorize :read, model: ::Struct; field :x, String, null: true, added: "2025-01-01" }

      expect(rows(profiles_report(schema_over(query, profiles: true, authorization: true)))).to eq([])
    end
  end

  describe "Audit::RetiredOnly" do
    def retired_query
      b = bases
      old_type = Class.new(b[:object]) { graphql_name "Old"; lifecycle removed: "2024-06-01"; field :x, String, null: true }
      kind = Class.new(b[:enum]) do
        graphql_name "Kind"
        value "A"
        value "GONE", removed: "2024-06-01"
      end
      Class.new(b[:object]) do
        graphql_name "Query"
        field :old, old_type, null: true
        field :kind, kind, null: true
        field :legacy, String, null: true, removed: "2024-06-01"
        field :total, Integer, null: true, removed: "2025-01-01"
        field :list, [String], null: true do
          argument :page, Integer, required: false, removed: "2024-06-01"
          argument :first, Integer, required: false, added: "2024-06-01"
        end
      end
    end

    it "lists each member that lives only in retired versions as information, which ok? ignores" do
      report = retired_report(schema_over(retired_query, profiles: false))

      expect(rows(report)).to contain_exactly(
        [:retired_only, "Old", true], [:retired_only, "Kind.GONE", true], [:retired_only, "Query.legacy", true], [:retired_only, "Query.list.page", true]
      )
      expect(report.ok?).to be(true)
      expect(report.problems.find { |problem| problem.path == "Query.legacy" }.message).to match(/only in retired versions \(2024-01-15\).*Delete it/)
    end

    it "makes them problems with strict: true" do
      report = retired_report(schema_over(retired_query, profiles: false), strict: true)

      expect(rows(report).map(&:last).uniq).to eq([false])
      expect(report.ok?).to be(false)
    end

    it "lists a twin that lives only in retired versions, and not its served twin" do
      b = bases
      query = Class.new(b[:object]) do
        graphql_name "Query"
        field :amount, Integer, null: true, removed: "2024-06-01"
        field :amount, String, null: true, added: "2024-06-01"
      end

      report = retired_report(schema_over(query, profiles: false))

      expect(rows(report)).to eq([[:retired_only, "Query.amount", true]])
      expect(report.problems.first.message).to include('{:removed=>"2024-06-01"}').or include('{removed: "2024-06-01"}')
    end

    it "lists a membership that lives only in retired versions" do
      membership = Class.new(GraphQL::Schema::TypeMembership) { include GraphQL::Armory::Versioning::Base }
      b = bases
      a = Class.new(b[:object]) { graphql_name "A"; field :x, String, null: true }
      c = Class.new(b[:object]) { graphql_name "C"; field :y, String, null: true }
      union = Class.new(GraphQL::Schema::Union) do
        include GraphQL::Armory::Versioning::Base
        graphql_name "Thing"
        type_membership_class(membership)
        possible_types a
        possible_types c, removed: "2024-06-01"
      end
      query = Class.new(b[:object]) { graphql_name "Query"; field :thing, union, null: true }

      expect(rows(retired_report(schema_over(query, profiles: false)))).to eq([[:retired_only, "C.belongsTo.Thing", true]])
    end

    it "lists nothing on a schema with no retired version, nor a label versions: does not hold" do
      b = bases
      query = Class.new(b[:object]) do
        graphql_name "Query"
        field :x, String, null: true, removed: "2024-06-01"
        field :y, String, null: true, removed: "1999-01-01"
      end

      expect(rows(retired_report(schema_over(query, profiles: false, retired_labels: [])))).to eq([])
      expect(rows(retired_report(schema_over(query, profiles: false)))).to eq([[:retired_only, "Query.x", true]])
    end
  end
end
