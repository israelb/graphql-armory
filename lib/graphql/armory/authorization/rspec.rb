# frozen_string_literal: true

require "rspec/expectations"

# `require "graphql/armory/authorization/rspec"` in your spec helper, then:
#
#   expect(AppSchema).to be_fully_authorized
#   expect(AppSchema).to be_fully_authorized(baseline: "config/graphql_armory_baseline.json")   # fails only on new problems
RSpec::Matchers.define :be_fully_authorized do |*positional, baseline: nil|
  raise ArgumentError, "be_fully_authorized takes baseline: path" unless positional.empty?

  match do |schema|
    report = GraphQL::Armory::Authorization::Audit.(schema)
    next (@report = report).ok? unless baseline

    @report = GraphQL::Armory::Authorization::Audit::Baseline.load(baseline).(report)
    @report.passes?
  end

  failure_message do |schema|
    "expected #{schema} to be fully authorized, but the audit found:\n#{@report}"
  end

  failure_message_when_negated do |schema|
    baseline ? "expected #{schema} not to pass its baseline, but it did:\n#{@report}" : "expected #{schema} not to be fully authorized, but the audit found no problems"
  end
end
