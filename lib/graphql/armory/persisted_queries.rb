# frozen_string_literal: true

module GraphQL
  module Armory
    # Persisted queries: clients send the id of an operation their build produced, and the server runs the
    # stored query. With strict mode on, it refuses queries it does not hold.
    module PersistedQueries
      class ConfigurationError < Armory::Error; end
    end
  end
end

require "graphql/armory/persisted_queries/manifest"
