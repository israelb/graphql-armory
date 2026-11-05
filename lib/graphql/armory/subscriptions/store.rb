# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      # Where subscriptions live: `MemoryStore`, `RedisStore`, or any object answering the same six methods. A store
      # sees sealed records, topic digests, viewer digests and ids, never a document, a variable or a viewer in clear.
      # Times are Integer milliseconds and always come from the caller (`now:`), so every store agrees on what is live.
      #
      #   store.write(id, sealed, topics:, viewer:, expires_at:, viewer_cap:, topic_cap:, now:)
      #     -> :ok | :viewer_cap | :topic_cap | :exists     (Store::Null answers :refused)
      #   store.read(id) -> String | nil                    # the sealed record
      #   store.ids(topic, now:) -> [id, ...]               # the live ids written under that topic digest
      #   store.delete(id) -> true | false                  # whether it was stored
      #   store.count(viewer, now:) -> Integer              # the viewer's live records
      #   store.cleanup(now:) -> Integer                    # how many expired records were removed
      #
      # The contract every store keeps (`spec/support/subscription_store_contract.rb`):
      #
      # - A record is live while `now < expires_at`. `ids` and `count` answer live records only.
      # - `write` is one atomic step: it answers `:exists` when `id` is already stored (it never replaces a record),
      #   `:viewer_cap` when `viewer` already has `viewer_cap` live records, `:topic_cap` when any of `topics` already has
      #   `topic_cap` live records (the viewer cap is checked first; a nil cap is no cap). Any of those writes nothing.
      #   Otherwise it stores `sealed` under `id`, adds `id` to each topic's index and to `viewer`'s count, and answers
      #   `:ok`. An expired record no longer counts against a cap, cleaned up or not.
      # - `read` answers the sealed record until it is deleted or cleaned up; a store may stop answering it any time
      #   after `expires_at` (a server-side TTL), never before. The core checks `expires_at` in the record itself.
      # - `delete` removes the record, its id from every topic it was written under and from its viewer's count.
      # - `cleanup` removes every record expired at `now`, with its index entries, and answers how many it removed.
      module Store
        ANSWERS = %i[ok viewer_cap topic_cap exists].freeze
      end
    end
  end
end

require "graphql/armory/subscriptions/store/null"
require "graphql/armory/subscriptions/store/substitute"
