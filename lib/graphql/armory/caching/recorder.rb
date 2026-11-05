# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # Records which context keys a query read and wrote, from its context's construction on, so the gate refuses to
      # store an answer that depended on a key the cache key does not hold. A tripwire, not a proof: it sees only
      # reads through the context's public methods (docs/response-caching.md "Inputs you must declare").
      #
      # Each query's recorder lives in `context.namespace(:armory_cache)[:recorder]` (`RecordKeys.recorder`). Every
      # recorder answers:
      #
      #   recorder.read(key)                  # a key read through [], fetch, dig or key?, present or absent
      #   recorder.read_all                   # to_h, namespace(nil), scoped_context: the whole Hash was read
      #   recorder.write(key)                 # []=, delete, scoped_merge!, scoped_set!
      #   recorder.neutral { }                # records nothing for the block's duration
      #   recorder.uncovered(covered) -> []   # keys read and not covered, :all when the whole Hash was read; a key
      #                                       # this query wrote before reading it is not an input
      #   recorder.forbidden_writes(covered) -> []  # keys written that are covered or that this query read earlier
      #
      # `Null` (no recorder: report everything uncovered, so nothing is stored), `Substitute` (records, for specs) and
      # `Substitute::Context` (a context class that records through a Substitute) stand in for the real one (`Log`).
      module Recorder
        ALL = :all
      end
    end
  end
end

require "graphql/armory/caching/recorder/null"
require "graphql/armory/caching/recorder/substitute"
require "graphql/armory/caching/recorder/shared_writes"
require "graphql/armory/caching/recorder/log"
require "graphql/armory/caching/recorder/context"
