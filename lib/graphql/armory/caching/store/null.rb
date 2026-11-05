# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      module Store
        # The store of a cache nobody wired: every lookup misses, every write is refused and purges change nothing.
        # It caches nothing, so `Gate.new` never serves an answer. `use` refuses it: a cache that stores nothing.
        class Null
          EPOCH = "null"

          def lookup(_key_digest)
            Lookup.miss(seq: 0, epoch: EPOCH, now: 0)
          end

          def write(_key_digest, _blob, tags:, ttl:, seq:, epoch:, stored_at:)
            false
          end

          def purge(_tag_digests)
            0
          end

          def purge_all
            EPOCH
          end
        end
      end
    end
  end
end
