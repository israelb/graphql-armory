# frozen_string_literal: true

require "graphql"
require "graphql/armory/version"

module GraphQL
  # Open-source extensions for graphql-ruby, built on its public extension points.
  module Armory
    class Error < GraphQL::Error; end
  end
end
