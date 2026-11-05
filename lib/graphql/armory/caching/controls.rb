# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # Test data for response caching, reusable by apps and other gems. Units that need more shapes (interfaces,
      # unions, connections, directives) add their own files under `caching/controls/`.
      module Controls
      end
    end
  end
end

require "graphql/armory/caching/controls/operations"
require "graphql/armory/caching/controls/context"
require "graphql/armory/caching/controls/store"
require "graphql/armory/caching/controls/schema"
require "graphql/armory/caching/controls/walk_schema"
