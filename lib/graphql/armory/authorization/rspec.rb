# frozen_string_literal: true

require "rspec/expectations"

# `require "graphql/armory/authorization/rspec"` in your spec helper, then:
#
#   expect(AppSchema).to be_fully_authorized
#   expect(AppSchema).to be_fully_authorized(baseline: "config/graphql_armory_baseline.json")   # fails only on new problems
RSpec::Matchers.define :be_fully_authorized do |baseline: nil|
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
    "expected #{schema} not to be fully authorized, but the audit found no problems"
  end
end
