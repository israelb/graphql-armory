# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# Pick the graphql version under test, e.g. GRAPHQL_VERSION="~> 2.4.0".
gem "graphql", ENV["GRAPHQL_VERSION"] unless ENV.fetch("GRAPHQL_VERSION", "").empty?

gem "pundit", "~> 2.3"
gem "rake", "~> 13.0"
gem "rspec", "~> 3.13"
