# frozen_string_literal: true

module GraphQL
  module Armory
    # Makes `rake graphql_armory:audit[YourSchema]` available in a Rails app. Rails is not a dependency: this loads only when it is there.
    class Railtie < ::Rails::Railtie
      rake_tasks { load "tasks/graphql_armory.rake" }
    end
  end
end
