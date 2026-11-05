# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # Where answers live: `MemoryStore`, `RedisStore`, or any object answering the same four methods. Every key and
      # tag a store sees is a keyed hex digest; a store never sees a viewer, a variable or an operation in clear.
      #
      #   store.lookup(key_digest) -> Lookup                     # one round trip
      #   store.write(key_digest, blob, tags:, ttl:, seq:, epoch:, stored_at:) -> true | false
      #   store.purge(tag_digests) -> Integer                    # the new seq; raises on failure
      #   store.purge_all -> String                              # the new epoch; raises on failure
      #
      # The contract every store keeps (`spec/support/caching_store_contract.rb`):
      #
      # - One meta record holds `epoch` (a random String), `seq` (an Integer, 0 when created) and a purge mark per
      #   purged tag. It is never evicted on its own. `lookup` and `write` create it, with a new random epoch, when it
      #   is missing: a lost meta record is "everything purged".
      # - `lookup` answers the blob and its tag digests only while `now < stored_at + ttl * 1000`, with the marks of
      #   those tags, the current `seq` and `epoch`, and the store clock `now` (Integer milliseconds).
      # - `write` answers false and stores nothing when `epoch` is not the current one, when `seq` is greater than the
      #   current seq (a replica that lost increments), when any of `tags` has a mark greater than `seq` (a purge
      #   landed after the lookup), or when the entry is already expired at the store clock. Otherwise it stores the
      #   blob with its tags, expiring at `stored_at + ttl * 1000`, and answers true.
      # - `purge` increments `seq` and sets each tag's mark to the new value, atomically; `purge_all` replaces the
      #   epoch (every entry stored before fails the epoch check) and drops the marks.
      module Store
      end
    end
  end
end

require "graphql/armory/caching/store/null"
require "graphql/armory/caching/store/substitute"
