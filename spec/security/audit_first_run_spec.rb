# frozen_string_literal: true

class ArmoryFirstRunDoc
  def secret(**) = "SECRET"
end

class ArmoryFirstRunDocPolicy
  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve = @user == :allowed ? @scope : []
  end

  def initialize(user, _record) = @user = user
  def read? = @user == :allowed
end

RSpec.describe "the audit's first run" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:base_field) do
    plugin = armory
    Class.new(GraphQL::Schema::Field) { include plugin::Base }
  end
  let(:base_object) do
    plugin = armory
    field = base_field
    Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class field
    end
  end

  def visibility_schema(type, adapter: armory::Adapters::Substitute.new)
    plugin = armory
    query_class = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :thing, type, null: true, authorize: :none, reason: "x"
    end
    Class.new(GraphQL::Schema) do
      use plugin, adapter: adapter
      use GraphQL::Schema::Visibility, dynamic: true
      query query_class
    end
  end

  def texts(report) = report.problems.map(&:to_s)

  it "reports a type with no model on the first run, as later runs do" do
    type = Class.new(base_object) do
      graphql_name "ArmoryFirstRunNoModel"
      authorize :read
      field :x, String, null: true, visible_when: :export
    end
    schema = visibility_schema(type)
    first = armory::Audit.(schema)

    expect(first.ok?).to be(false)
    expect(first.problems.map(&:kind)).to include(:model)
    expect(texts(armory::Audit.(schema))).to eq(texts(first))
  end

  it "reports an interface whose visible_when: field cannot name a type, on the first run" do
    plain_field = Class.new(GraphQL::Schema::Field) { include GraphQL::Armory::Authorization::Base }
    shared = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "ArmoryFirstRunShared"
      field_class plain_field
      field :x, String, null: true, visible_when: :export
    end
    type = Class.new(base_object) do
      graphql_name "ArmoryFirstRunDoc"
      authorize :read
      implements shared
    end
    schema = visibility_schema(type)
    first = armory::Audit.(schema)

    expect(first.ok?).to be(false)
    expect(texts(armory::Audit.(schema))).to eq(texts(first))
  end

  it "still raises anything that is not a finding" do
    type = Class.new(base_object) do
      graphql_name "ArmoryFirstRunBroken"
      authorize :none, reason: "x", covers_fields: true
      field :x, String, null: true
      def self.visible?(_context) = raise(IOError, "broken")
    end

    expect { armory::Audit.(visibility_schema(type)) }.to raise_error(IOError)
  end
end

RSpec.describe "the audit's check objects" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:audit) { armory::Audit }

  it "are inert when built with nothing" do
    open_type = Class.new(GraphQL::Schema::Object) { graphql_name "Open" }

    expect { audit::OwnChecks.new.([]) }.not_to raise_error
    expect { audit::Overrides.new.(Class.new(GraphQL::Schema)) }.not_to raise_error
    expect(audit::ForeignPolicies.new.relay(open_type)).to be_nil
    expect { audit::TypeRules.new.(open_type) }.not_to raise_error
  end

  it "report into the findings they are given" do
    findings = audit::Findings.new
    audit::TypeRules.new(armory::Adapters::Null.new, findings).(Class.new(GraphQL::Schema::Object) { graphql_name "Open" })

    expect(findings.report.problems.map(&:kind)).to eq([:unprotected])
  end
end

RSpec.describe "the audit on the classes graphql-ruby's install generator writes" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:templates) { File.expand_path("../generators/graphql/templates", GraphQL::Armory::Authorization::Audit::GRAPHQL_RUBY_PATH) }

  # The generator's own files, with Base added where the install guide says.
  def generated(namespace, name)
    source = File.read(File.join(templates, "#{name}.erb")).gsub(/^<%.*%>\n/, "")
    source = source.sub(/^(\s*class \w+ < .*\n)/) { "#{Regexp.last_match(1)}include GraphQL::Armory::Authorization::Base\n" } if %w[base_argument base_field base_object].include?(name)
    namespace.module_eval(source)
  end

  it "does not say ok when a refused user gets the record" do
    namespace = Module.new
    %w[base_argument base_field base_object base_edge base_connection].each { |name| generated(namespace, name) }
    types = namespace.const_get(:Types)
    types::BaseObject.connection_type_class(types::BaseConnection)
    types::BaseObject.edge_type_class(types::BaseEdge)
    plugin = armory
    doc = Class.new(types::BaseObject) do
      graphql_name "Doc"
      authorize :read, model: ArmoryFirstRunDoc
      field :secret, String, null: true
    end
    query_class = Class.new(types::BaseObject) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :docs, doc.connection_type, null: true, authorize: :none, reason: "x"
    end
    schema = Class.new(base_schema) do
      use plugin, adapter: :pundit
      query query_class
    end
    root = Struct.new(:docs).new([ArmoryFirstRunDoc.new])
    response = execute_query(schema, "{ docs { nodes { secret } edges { node { secret } } } }", root_value: root, context: { current_user: :someone }).to_h

    expect(response.to_s.include?("SECRET") && armory::Audit.(schema).ok?).to be(false)
  end
end

RSpec.describe "the audit with CanCanCan" do
  let(:armory) { GraphQL::Armory::Authorization }

  it "reports what is uncovered and does not ask a policy" do
    plugin = armory
    field_base = Class.new(GraphQL::Schema::Field) { include plugin::Base }
    base = Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class field_base
    end
    uncovered = Class.new(base) do
      graphql_name "ArmoryCanCanUncovered"
      field :x, String, null: true
    end
    query_class = Class.new(base) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :thing, uncovered, null: true, authorize: :none, reason: "x"
    end
    schema = Class.new(base_schema) do
      use plugin, adapter: plugin::Adapters::CanCan.new
      query query_class
    end

    expect(armory::Audit.(schema).problems.map(&:kind)).to include(:no_rule)
    expect(armory::Audit.(schema).problems.map(&:kind)).not_to include(:foreign_model, :foreign_policy)
  end
end
