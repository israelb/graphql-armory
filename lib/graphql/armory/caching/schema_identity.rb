# frozen_string_literal: true

require "digest"

module GraphQL
  module Armory
    module Caching
      # What a query runs against, as two SHA-256 digests the keyer puts in every key:
      #
      #   identity = SchemaIdentity.new
      #   identity.schema_digest(AppSchema, "2025-06-01", :"armory_v_2025-06-01")  # to_definition of what that version sees
      #   identity.document_digest(query.document)                                # the printed document
      #
      # The schema digest is computed on the first request that needs it, never when `use` runs (the schema is not
      # finished then), once per schema, version label and visibility profile. A schema reloaded in development, or two
      # deploys that share a `release:` by mistake, never share answers across definitions. The document digest is
      # memoized per document object: PersistedQueries' stored documents are shared, so each is printed once per process.
      #
      # Both memos compare by identity (two equal documents are two entries, never one digest for two objects) and are
      # bounded: past `limit` entries a memo starts over, so raw documents or reloaded schemas cannot grow it without end.
      # They are not `ObjectSpace::WeakMap`s: a WeakMap holds its values weakly too, so a digest String held only there is
      # collected at the next GC. Two threads computing the same first digest compute the same value; the first stored
      # wins. `computed` records each computation, for specs.
      class SchemaIdentity
        LIMIT = 10_000
        # `computed` keeps the latest computations only.
        RECORDED = 100

        # graphql-ruby could not print the schema (graphql 2.4 with json 3.x raises on a deprecation reason). The
        # failure is memoized like a digest: the schema is not printed again on every request.
        class Unprintable < StandardError; end
        UNPRINTABLE = :unprintable

        attr_reader :computed

        def initialize(limit: LIMIT)
          raise ArgumentError, "limit: must be a positive Integer" unless limit.is_a?(Integer) && limit.positive?

          @limit = limit
          @schemas = {}.compare_by_identity
          @documents = {}.compare_by_identity
          @lock = Mutex.new
          @computed = []
        end

        # SHA-256 of `schema.to_definition(context: { armory_full_schema: true, armory_version: label })`, with
        # `visibility_profile: profile` when the query runs under a named profile (Versioning's `profiles: true` names
        # the same one from the label). `armory_full_schema` lets Authorization's `visible_when:` show every member, so the
        # digest is the schema's and not one viewer's view of it.
        def schema_digest(schema, label, profile)
          found = @lock.synchronize { @schemas[schema]&.[]([label, profile]) }
          found ||= compute_schema_digest(schema, label, profile)
          raise Unprintable, "#{schema.name || "the schema"} cannot be printed by this graphql-ruby" if found == UNPRINTABLE

          found
        end

        def compute_schema_digest(schema, label, profile)
          context = { armory_full_schema: true }
          context[:armory_version] = label unless label.nil?
          context[:visibility_profile] = profile unless profile.nil?
          digest = begin
            Digest::SHA256.hexdigest(schema.to_definition(context: context)).freeze
          rescue Versioning::RefusedVersionError
            raise
          rescue StandardError
            UNPRINTABLE
          end

          @lock.synchronize do
            record([:schema, label, profile])
            @schemas.clear if @schemas.size >= @limit && !@schemas.key?(schema)
            (@schemas[schema] ||= {})[[label, profile]] ||= digest
          end
        end
        private :compute_schema_digest

        # SHA-256 of `document.to_query_string`.
        def document_digest(document)
          found = @lock.synchronize { @documents[document] }
          return found if found

          digest = Digest::SHA256.hexdigest(document.to_query_string).freeze
          @lock.synchronize do
            record([:document])
            @documents.clear if @documents.size >= @limit
            @documents[document] ||= digest
          end
        end

        def inspect = "#<#{self.class.name}>"

        private

        def record(computation)
          @computed.shift if @computed.size >= RECORDED
          @computed << computation
        end
      end
    end
  end
end
