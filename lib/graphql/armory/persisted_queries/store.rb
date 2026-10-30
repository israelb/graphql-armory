# frozen_string_literal: true

require "digest"

module GraphQL
  module Armory
    module PersistedQueries
      # What the plugin fetches operations from: a `Manifest`, or any object answering `fetch(id)`. `Null` and
      # `Substitute` are the inert and the test stand-ins.
      module Store
        # The store of a plugin nobody wired: it holds no operation, so every id is unknown.
        class Null
          def fetch(_id)
            nil
          end
        end

        # Holds the given queries under the SHA-256 of each, like an Apollo manifest, and records the ids it was
        # asked for: for tests, instead of hand-written stores.
        class Substitute
          attr_reader :fetched

          def initialize(*queries)
            @manifest = Manifest.new(queries.to_h { |query| [Digest::SHA256.hexdigest(query), query] })
            @fetched = []
          end

          def fetch(id)
            @fetched << id
            @manifest.fetch(id)
          end
        end
      end
    end
  end
end
