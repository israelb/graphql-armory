# frozen_string_literal: true

# Named classes, because a class's location comes from its constant.
module AuditLocations
  Plugin = GraphQL::Armory::Authorization
  BaseArgument = Class.new(GraphQL::Schema::Argument) { include Plugin::Base }
  BaseField = Class.new(GraphQL::Schema::Field) do
    include Plugin::Base
    argument_class BaseArgument
  end

  class BaseObject < GraphQL::Schema::Object
    include Plugin::Base
    field_class BaseField
  end

  NO_RULE_LINE = __LINE__ + 1
  class NoRule < BaseObject
    field :name, String, null: true
  end

  class Bypassed < BaseObject
    authorize :none, reason: "public"
    FIELD_LINE = __LINE__ + 1
    field :secret, String, null: true
  end

  class PlainFields < BaseObject
    field_class GraphQL::Schema::Field
    RULE_LINE = __LINE__ + 1
    authorize :none, reason: "public"
    field :plain, String, null: true
  end

  class Checked < BaseObject
    authorize :none, reason: "root", covers_fields: true
    CHECK_LINE = __LINE__ + 1
    def self.authorized?(_object, _context) = true
    field :name, String, null: true
  end

  class Loading < BaseObject
    authorize :none, reason: "root", covers_fields: true
    field :find, String, null: true, load_through_scope: false do
      LOAD_LINE = __LINE__ + 1
      argument :thing_id, GraphQL::Types::ID, loads: NoRule
    end
  end

  class Query < BaseObject
    graphql_name "Query"
    authorize :none, reason: "root", covers_fields: true
    BYPASS_LINE = __LINE__ + 1
    field :id, String, null: true, authorize: :none, reason: "ids are public"
    field :no_rule, NoRule, null: true
    field :bypassed, Bypassed, null: true
    field :plain_fields, PlainFields, null: true
    field :checked, Checked, null: true
    field :loading, Loading, null: true
  end

  class Schema < GraphQL::Schema
    use Plugin, adapter: Plugin::Adapters::Substitute.new
    query Query
  end

  FILE = File.expand_path(__FILE__).delete_prefix("#{Dir.pwd}/")
end

RSpec.describe "the audit's file and line for each problem" do
  let(:audit) { GraphQL::Armory::Authorization::Audit }
  let(:report) { audit.(AuditLocations::Schema) }
  let(:file) { AuditLocations::FILE }

  def location_of(kind, path) = report.problems.find { |problem| problem.kind == kind && problem.path == path }&.location

  it "gives a type with no rule the line of its class" do
    expect(location_of(:no_rule, "NoRule")).to eq("#{file}:#{AuditLocations::NO_RULE_LINE}")
  end

  it "gives a field the line that declared it" do
    expect(location_of(:field_without_rule, "Bypassed.secret")).to eq("#{file}:#{AuditLocations::Bypassed::FIELD_LINE}")
  end

  it "gives a field whose class does not include Base the line of its type's rule" do
    expect(location_of(:field_without_rule, "PlainFields.plain")).to eq("#{file}:#{AuditLocations::PlainFields::RULE_LINE}")
  end

  it "gives an own check the line of its method" do
    problem = report.problems.find { |each| each.kind == :own_check }
    expect(problem.location).to eq("#{file}:#{AuditLocations::Checked::CHECK_LINE}")
  end

  it "gives an argument the line that declared it" do
    problem = report.problems.find { |each| each.kind == :unscoped_load }
    expect(problem.location).to eq("#{file}:#{AuditLocations::Loading::LOAD_LINE}")
  end

  it "gives a declared bypass the line that declared it" do
    bypass = report.bypasses.find { |each| each.path == "Query.id" }
    expect(bypass.location).to eq("#{file}:#{AuditLocations::Query::BYPASS_LINE}")
  end

  it "prints each location after its problem" do
    expect(report.to_s).to include("NoRule (no_rule): has no rule and no default_action, so it is denied (at #{file}:#{AuditLocations::NO_RULE_LINE})")
  end

  it "has no location for a problem it cannot place, and prints none" do
    problem = audit::Report::Problem.new(:no_rule, "Somewhere", "m")
    text = audit::Report.new(problems: [problem], bypasses: []).to_s

    expect(problem.location).to be_nil
    expect(text).to eq("1 problem:\n  Somewhere (no_rule): m\n")
  end

  it "keeps a problem accepted by the baseline when its code moves" do
    # A baseline refuses own checks, so they stay out of this one.
    kept = audit::Report.new(problems: report.problems.reject { |problem| problem.kind == :own_check }, bypasses: [])
    baseline = audit::Baseline.from(kept)
    moved = kept.problems.map { |problem| problem.dup.tap { |copy| copy.location = "elsewhere.rb:1" } }

    result = baseline.(audit::Report.new(problems: moved, bypasses: []))

    expect(result.new_problems).to eq([])
    expect(baseline.entries.map(&:to_h).flat_map(&:keys).uniq).not_to include("location")
  end
end
