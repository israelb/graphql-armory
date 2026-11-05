# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      class Error < Armory::Error; end

      # A declaration, a `use` option or the schema is not set up the way caching needs. Raised at definition, at boot,
      # or on the first request for what can only be checked then (PersistedQueries installed, a viewer's id).
      class ConfigurationError < Error; end

      # The store failed during a purge. The app retries: a purge that silently failed serves stale data until the TTL.
      class PurgeError < Error; end
    end
  end
end
