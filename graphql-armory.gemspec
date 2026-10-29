# frozen_string_literal: true

require_relative "lib/graphql/armory/version"

Gem::Specification.new do |s|
  s.name        = "graphql-armory"
  s.version     = GraphQL::Armory::VERSION
  s.authors     = ["Israel"]
  s.summary     = "Authorization for graphql-ruby: Pundit and CanCanCan, deny-by-default, with a schema audit."
  s.description = "Open-source extensions for graphql-ruby built on its public extension points. " \
                  "The first module is authorization: deny-by-default coverage, scoped lists and " \
                  "connections, IDOR-safe lookups, mutations, interfaces and unions, visibility driven by the policy, and a schema audit for CI."
  s.homepage    = "https://github.com/israelb/graphql-armory"
  s.license     = "MIT"
  s.required_ruby_version = ">= 3.1"

  s.metadata = {
    "homepage_uri" => s.homepage,
    "source_code_uri" => s.homepage,
    "changelog_uri" => "#{s.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{s.homepage}/issues",
    "rubygems_mfa_required" => "true",
  }

  s.files = Dir["lib/**/*.{rb,rake}"] + ["LICENSE", "README.md", "CHANGELOG.md", "MIGRATING.md"]
  s.require_paths = ["lib"]

  # Execution::Next is supported from graphql 2.6.2 (the integration refuses it earlier); everything else works from 2.4.
  s.add_dependency "graphql", ">= 2.4", "< 3"
end
