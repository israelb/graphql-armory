# frozen_string_literal: true

require "rspec/expectations"
require "graphql/armory/caching/audit"

# `require "graphql/armory/caching/rspec"` in your spec helper, then:
#
#   expect(AppSchema).to have_safe_cache_declarations
#   expect(AppSchema).to have_safe_cache_declarations(own_checks: { Types::Product => { authorized?: "reads the class only" } })
#   expect(AppSchema).to have_safe_cache_declarations(strict: true)   # information (:directive) fails it too
RSpec::Matchers.define :have_safe_cache_declarations do |*positional, own_checks: {}, strict: false|
  raise ArgumentError, "have_safe_cache_declarations takes own_checks: and strict:" unless positional.empty?

  match do |schema|
    (@report = GraphQL::Armory::Caching::Audit.(schema, own_checks: own_checks, strict: strict)).ok?
  end

  failure_message do |schema|
    "expected #{schema} to have safe cache declarations, but the cache audit found:\n#{@report}"
  end

  failure_message_when_negated do |schema|
    "expected #{schema} not to have safe cache declarations, but the cache audit found no problems"
  end
end
