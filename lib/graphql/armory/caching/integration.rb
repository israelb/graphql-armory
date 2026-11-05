# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # graphql-ruby's hooks: the schema guard over `multiplex`/`multiplex_next`, the context and query class
      # wrappers, the `rescue_from` wrapper, the installer behind `use` and `purge` (unit U9). This stub only
      # reserves the two entry points `Caching.use` and `Caching.purge` delegate to.
      module Integration
        def self.install(schema, **_options)
          raise NotImplementedError, "#{schema}: GraphQL::Armory::Caching is not built yet (unit U9)"
        end

        def self.purge(schema, **_options)
          raise NotImplementedError, "#{schema}: GraphQL::Armory::Caching.purge is not built yet (unit U9)"
        end
      end
    end
  end
end
