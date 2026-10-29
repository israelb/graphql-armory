# frozen_string_literal: true

require "rspec/expectations"

# `require "graphql/armory/authorization/rspec"` in your spec helper, then:
#
#   expect(AppSchema).to be_fully_authorized
RSpec::Matchers.define :be_fully_authorized do
  match do |schema|
    @report = GraphQL::Armory::Authorization::Audit.(schema)
    @report.ok?
  end

  failure_message do |schema|
    "expected #{schema} to be fully authorized, but the audit found:\n#{@report}"
  end

  failure_message_when_negated do |schema|
    "expected #{schema} not to be fully authorized, but the audit found no problems"
  end
end
