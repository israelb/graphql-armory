# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      # One subscription, as the store keeps it (sealed). Built when the subscription is created, read on every
      # delivery. Nothing else from the request's context is kept: the viewer is reloaded from `viewer_id`, and only
      # the `context_keys:` values are stored, already dumped.
      #
      #   id                  the server-made id: 32 random bytes, urlsafe base64 (also the transport's channel id)
      #   document            the query string
      #   operation_name      String or nil
      #   variables           `GraphQL::Subscriptions::Serialize.dump` of the variables (a JSON String)
      #   operation_id        the persisted operation's id, or nil
      #   raw_query           whether the request ran with `armory_allow_raw_query: true`
      #   version             the label Versioning decided for the request, or nil
      #   visibility_profile  String or nil
      #   engine              :interpreter or :next
      #   viewer_id           what `viewer: { dump: }` answered, nil when anonymous
      #   viewer_digest       64 hex characters (the keyed digest of viewer_id), or ANONYMOUS
      #   context             { "key" => dumped value } for each stored context key
      #   events              one Event per root field: graphql-ruby's own `event.topic` and our topic digest
      #   created_at          Integer milliseconds
      #   expires_at          Integer milliseconds, after created_at
      #
      # `to_h` answers JSON values under String keys; `from_h` takes exactly that shape back and refuses anything
      # else with ArgumentError (a record that does not parse is never loaded).
      class Record
        FORMAT = 1
        ANONYMOUS = "anonymous"
        ENGINES = %i[interpreter next].freeze
        ID = /\A[A-Za-z0-9_-]{22,128}\z/
        HEX = /\A[0-9a-f]{64}\z/
        FIELDS = %i[id document operation_name variables operation_id raw_query version visibility_profile engine viewer_id
                    viewer_digest context events created_at expires_at].freeze
        KEYS = (["v"] + FIELDS.map(&:to_s)).freeze

        # One root field of the subscription: graphql-ruby's topic String, passed back as `subscription_topic:` on a
        # delivery so its field extension fires, and our digest, the store's topic index key.
        Event = Struct.new(:graphql_topic, :digest, keyword_init: true) do
          def initialize(graphql_topic:, digest:)
            raise ArgumentError, "Record events: each graphql_topic must be a non-empty String" unless graphql_topic.is_a?(String) && !graphql_topic.empty?
            raise ArgumentError, "Record events: each digest must be 64 hex characters" unless digest.is_a?(String) && HEX.match?(digest)

            super(graphql_topic: graphql_topic.dup.freeze, digest: digest.dup.freeze)
            freeze
          end

          def inspect = "#<#{self.class.name}>"
        end

        attr_reader(*FIELDS)

        def initialize(id:, document:, operation_name:, variables:, operation_id:, raw_query:, version:, visibility_profile:, engine:,
                       viewer_id:, viewer_digest:, context:, events:, created_at:, expires_at:)
          raise ArgumentError, "Record id: must be 22 to 128 urlsafe base64 characters" unless id.is_a?(String) && ID.match?(id)
          raise ArgumentError, "Record document: must be a non-empty String" unless text?(document)
          raise ArgumentError, "Record operation_name: must be a non-empty String or nil" unless operation_name.nil? || text?(operation_name)
          raise ArgumentError, "Record variables: must be the String Serialize.dump answered" unless variables.is_a?(String)
          raise ArgumentError, "Record operation_id: must be a non-empty String or nil" unless operation_id.nil? || text?(operation_id)
          raise ArgumentError, "Record raw_query: must be true or false" unless raw_query == true || raw_query == false
          raise ArgumentError, "Record version: must be a non-empty String or nil" unless version.nil? || text?(version)
          raise ArgumentError, "Record visibility_profile: must be a non-empty String or nil" unless visibility_profile.nil? || text?(visibility_profile)
          raise ArgumentError, "Record engine: must be one of #{ENGINES.inspect}" unless ENGINES.include?(engine)
          raise ArgumentError, "Record viewer_id: must be a non-empty String or nil" unless viewer_id.nil? || text?(viewer_id)
          raise ArgumentError, "Record viewer_digest: must be 64 hex characters or #{ANONYMOUS.inspect}" unless viewer_digest == ANONYMOUS || (viewer_digest.is_a?(String) && HEX.match?(viewer_digest))
          raise ArgumentError, "Record viewer_id: must be nil exactly when viewer_digest is #{ANONYMOUS.inspect}" unless viewer_id.nil? == (viewer_digest == ANONYMOUS)
          raise ArgumentError, "Record context: must be a Hash of String keys to dumped String values" unless context.is_a?(Hash) && context.all? { |key, value| text?(key) && value.is_a?(String) }
          raise ArgumentError, "Record created_at: must be non-negative Integer milliseconds" unless created_at.is_a?(Integer) && created_at >= 0
          raise ArgumentError, "Record expires_at: must be Integer milliseconds after created_at" unless expires_at.is_a?(Integer) && expires_at > created_at

          @id = id.dup.freeze
          @document = document.dup.freeze
          @operation_name = operation_name&.dup&.freeze
          @variables = variables.dup.freeze
          @operation_id = operation_id&.dup&.freeze
          @raw_query = raw_query
          @version = version&.dup&.freeze
          @visibility_profile = visibility_profile&.dup&.freeze
          @engine = engine
          @viewer_id = viewer_id&.dup&.freeze
          @viewer_digest = viewer_digest.dup.freeze
          @context = context.to_h { |key, value| [key.dup.freeze, value.dup.freeze] }.freeze
          @events = build_events(events)
          @created_at = created_at
          @expires_at = expires_at
          freeze
        end

        # Takes back what `to_h` answered (after a JSON round trip): exactly its keys, as Strings, with the same
        # types. Raises ArgumentError for anything else.
        def self.from_h(hash)
          raise ArgumentError, "Record.from_h: needs a Hash, got #{hash.class}" unless hash.is_a?(Hash)
          raise ArgumentError, "Record.from_h: needs exactly the keys #{KEYS.inspect}" unless hash.keys.sort == KEYS.sort
          raise ArgumentError, "Record.from_h: format #{FORMAT} only" unless hash["v"] == FORMAT

          engine = ENGINES.find { |name| name.to_s == hash["engine"] }
          raise ArgumentError, "Record engine: must be one of #{ENGINES.map(&:to_s).inspect}" unless engine

          events = hash["events"]
          unless events.is_a?(Array) && events.all? { |event| event.is_a?(Hash) && event.keys.sort == %w[digest graphql_topic] }
            raise ArgumentError, "Record events: must be an Array of { \"graphql_topic\", \"digest\" } objects"
          end

          new(**(FIELDS - %i[engine events]).to_h { |field| [field, hash[field.to_s]] },
              engine: engine, events: events.map { |event| { graphql_topic: event["graphql_topic"], digest: event["digest"] } })
        end

        def to_h
          {
            "v" => FORMAT, "id" => id, "document" => document, "operation_name" => operation_name, "variables" => variables,
            "operation_id" => operation_id, "raw_query" => raw_query, "version" => version, "visibility_profile" => visibility_profile,
            "engine" => engine.to_s, "viewer_id" => viewer_id, "viewer_digest" => viewer_digest, "context" => context,
            "events" => events.map { |event| { "graphql_topic" => event.graphql_topic, "digest" => event.digest } },
            "created_at" => created_at, "expires_at" => expires_at
          }
        end

        # The topic digests, the store's index keys.
        def topics
          events.map(&:digest)
        end

        # graphql-ruby's topic stored beside `digest`, or nil when this record was not written under that digest
        # (the index and the record drifted: never execute it for that topic).
        def graphql_topic(digest)
          events.find { |event| event.digest == digest }&.graphql_topic
        end

        def expired?(now)
          now >= expires_at
        end

        def anonymous?
          viewer_digest == ANONYMOUS
        end

        def ==(other)
          other.is_a?(Record) && other.to_h == to_h
        end
        alias_method :eql?, :==

        def hash = to_h.hash

        # No document, variables, viewer or id: a record may end up in a log.
        def inspect = "#<#{self.class.name} engine=#{engine.inspect} events=#{events.size}>"
        alias_method :to_s, :inspect

        private

        def text?(value)
          value.is_a?(String) && !value.empty?
        end

        def build_events(events)
          raise ArgumentError, "Record events: must be a non-empty Array" unless events.is_a?(Array) && !events.empty?

          built = events.map do |event|
            case event
            when Event then event
            when Hash then Event.new(**event.transform_keys(&:to_sym))
            else raise ArgumentError, "Record events: each must be a Record::Event or a Hash"
            end
          rescue ArgumentError => error
            raise error if error.message.start_with?("Record events")

            raise ArgumentError, "Record events: each must have graphql_topic: and digest: only"
          end
          raise ArgumentError, "Record events: each digest at most once" unless built.map(&:digest).uniq.size == built.size

          built.freeze
        end
      end
    end
  end
end
