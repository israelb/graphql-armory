# frozen_string_literal: true

module GraphQL
  module Armory
    # Whole-response caching for persisted operations, declared per field and type.
    #
    #   class AppSchema < GraphQL::Schema
    #     use GraphQL::Armory::PersistedQueries, store: PERSISTED, strict: true
    #     use GraphQL::Armory::Caching, store: GraphQL::Armory::Caching::MemoryStore.new, release: ENV.fetch("GIT_SHA")
    #   end
    #
    # Nothing is cached that is not declared, and a run whose answer depended on an input the key does not hold is
    # not stored. See docs/response-caching.md.
    module Caching
      # Caching's telemetry is the gem's: one Telemetry for every module.
      Telemetry = Armory::Telemetry
      Location = Armory::Location

      # The schema plugin. Every option is checked at boot; see docs/response-caching.md "Installing".
      def self.use(schema, **options)
        Integration.install(schema, **options)
      end

      # Purges answers: `all: true`, `viewer: principal` (or `:anonymous`), `tag: "pricing"`, or `type: Types::Invoice`
      # (best effort). Raises `PurgeError` when the store fails: a purge that silently failed serves stale data.
      def self.purge(schema, all: false, viewer: nil, tag: nil, type: nil)
        Integration.purge(schema, all: all, viewer: viewer, tag: tag, type: type)
      end

      # Runs the block without recording the context reads it makes, for readers whose reads do not change the
      # answer: a tracer, a logger, a limiter's key. A read outside the block is checked as usual. On a context
      # without a recorder (no caching installed, a plain Hash) it simply yields.
      def self.neutral(context, &block)
        recorder = RecordKeys.recorder(context)
        recorder ? recorder.neutral(&block) : yield
      end
    end
  end
end

require "graphql/armory/caching/errors"
require "graphql/armory/caching/record_keys"
require "graphql/armory/caching/tags"
require "graphql/armory/caching/values/declaration"
require "graphql/armory/caching/values/policy"
require "graphql/armory/caching/values/key"
require "graphql/armory/caching/values/entry"
require "graphql/armory/caching/values/lookup"
require "graphql/armory/caching/values/decision"
require "graphql/armory/caching/store"
require "graphql/armory/caching/memory_store"
require "graphql/armory/caching/redis_store"
require "graphql/armory/caching/recorder"
require "graphql/armory/caching/context_methods"
require "graphql/armory/caching/digester"
require "graphql/armory/caching/nulls"
require "graphql/armory/caching/codec"
require "graphql/armory/caching/walk"
require "graphql/armory/caching/canonical"
require "graphql/armory/caching/schema_identity"
require "graphql/armory/caching/viewer"
require "graphql/armory/caching/keyer"
require "graphql/armory/caching/charge"
require "graphql/armory/caching/gate/substitute"
require "graphql/armory/caching/gate"
require "graphql/armory/caching/base"
require "graphql/armory/caching/integration"
require "graphql/armory/caching/controls"
require "graphql/armory/caching/audit"
