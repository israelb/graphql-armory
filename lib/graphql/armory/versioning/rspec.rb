# frozen_string_literal: true

require "rspec/expectations"

# `require "graphql/armory/versioning/rspec"` in your spec helper, then:
#
#   expect(AppSchema).to have_consistent_versions
RSpec::Matchers.define :have_consistent_versions do
  match do |schema|
    (@report = GraphQL::Armory::Versioning::Audit.(schema)).ok?
  end

  failure_message do |schema|
    "expected #{schema} to have consistent versions, but the audit found:\n#{@report}"
  end

  failure_message_when_negated do |schema|
    "expected #{schema} not to have consistent versions, but the audit found no problems"
  end
end
