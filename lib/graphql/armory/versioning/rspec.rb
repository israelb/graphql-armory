# frozen_string_literal: true

require "rspec/expectations"

# `require "graphql/armory/versioning/rspec"` in your spec helper, then:
#
#   expect(AppSchema).to have_consistent_versions
#   expect(AppSchema).to have_no_breaking_changes(from: "2024-06-01", to: "2025-01-01")
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

# For a version line that should only grow:
#
#   expect(AppSchema).to have_no_breaking_changes(from: "2024-06-01", to: "2025-01-01")
RSpec::Matchers.define :have_no_breaking_changes do |versions|
  match do |schema|
    !(@result = GraphQL::Armory::Versioning::Diff.(schema, from: versions.fetch(:from), to: versions.fetch(:to))).breaking?
  end

  failure_message do |schema|
    "expected #{schema} to have no breaking changes from #{versions[:from]} to #{versions[:to]}, but found:\n#{@result}"
  end

  failure_message_when_negated do |schema|
    "expected #{schema} to have breaking changes from #{versions[:from]} to #{versions[:to]}, but found none"
  end
end
