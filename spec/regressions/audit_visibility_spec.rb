# frozen_string_literal: true

# The action a field is hidden with is asked of the policy at runtime, so the audit must check that it exists.
class ArmoryRegressionHidden
  def notes(**) = "SECRET"
end

class ArmoryRegressionHiddenPolicy
  class Scope
    def initialize(_user, scope) = @scope = scope
    def resolve = @scope
  end

  def initialize(_user, _record); end
  def read? = true
  def export? = true
end

class ArmoryRegressionStrictHiddenPolicy < ArmoryRegressionHiddenPolicy
  undef_method :export?
end

RSpec.describe "the audit of a field's visible_when:" do
  let(:armory) { GraphQL::Armory::Authorization }

  def problems_of(**rule, &field_rule)
    plugin = armory
    base_field = Class.new(GraphQL::Schema::Field) { include plugin::Base }
    base_object = Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class base_field
    end
    type = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: ArmoryRegressionHidden, **rule
      class_eval(&field_rule)
    end
    query_class = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :doc, type, null: true, authorize: :none, reason: "x"
    end
    schema = Class.new(base_schema) do
      use plugin, adapter: :pundit
      query query_class
    end
    plugin::Audit.(schema).problems
  end

  it "reports an action the policy does not define" do
    problems = problems_of { field :notes, String, null: true, visible_when: :no_such_action }

    expect(problems.map(&:message)).to include(a_string_including("ArmoryRegressionHiddenPolicy#no_such_action? is not defined"))
  end

  it "asks the policy: the type names" do
    problems = problems_of(policy: ArmoryRegressionStrictHiddenPolicy) { field :notes, String, null: true, visible_when: :export }

    expect(problems.map(&:message)).to include(a_string_including("ArmoryRegressionStrictHiddenPolicy#export? is not defined"))
  end

  it "says nothing about an action the policy defines" do
    problems = problems_of { field :notes, String, null: true, visible_when: :export }

    expect(problems.map(&:message).grep(/export\?/)).to eq([])
  end
end
