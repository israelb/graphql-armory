# frozen_string_literal: true

require "json"

module GraphQL
  module Armory
    # Persisted queries: clients send the id of an operation their build produced, and the server runs the
    # stored query. With strict mode on, it refuses queries it does not hold.
    #
    #   class AppSchema < GraphQL::Schema
    #     use GraphQL::Armory::PersistedQueries, store: Manifest.load("persisted-queries.json"), strict: true
    #   end
    #
    #   AppSchema.execute(params[:query], context: { operation_id: PersistedQueries.operation_id(params) })
    #
    # Hooks only `Schema.query_class`: the stored document goes to the query as `document:`, so it is parsed once,
    # at boot, and runs the same on both engines.
    module PersistedQueries
      class ConfigurationError < Armory::Error; end

      UNKNOWN_OPERATION = "Unknown operation id"
      MISMATCH = "The operation id and the query do not match"
      RAW_QUERY_REFUSED = "Only persisted operations are allowed: send an operation id"

      # What a refused request holds: nothing to run.
      EMPTY_DOCUMENT = GraphQL::Language::Nodes::Document.new(definitions: [])

      # What a client reads in `extensions.code`, so an app can tell a refusal from a query that failed for another reason.
      REFUSAL_CODES = { UNKNOWN_OPERATION => "UNKNOWN_OPERATION", MISMATCH => "OPERATION_MISMATCH", RAW_QUERY_REFUSED => "RAW_QUERY_REFUSED" }.freeze

      # A validation error with its code.
      class RefusalError < GraphQL::StaticValidation::Error
        def to_h
          super.merge("extensions" => { "code" => REFUSAL_CODES.fetch(message, "OPERATION_REFUSED") })
        end
      end

      # Validates nothing and answers the refusal, through the query's public `static_validator:` option.
      class Refusal < GraphQL::StaticValidation::Validator
        def initialize(schema, message)
          super(schema: schema)
          @message = message
        end

        def validate(_query, **)
          { errors: [RefusalError.new(@message)], remaining_timeout: nil }
        end
      end

      # `store:` answers `fetch(id)` with an operation (`body` and `document`) or nil: a Manifest, or your own.
      # `strict: true` refuses raw queries unless the context holds `armory_allow_raw_query: true`.
      def self.use(schema, store:, strict: false, sinks: [], on_sink_error: nil)
        gate = Gate.build(store: store, strict: strict, sinks: sinks, on_sink_error: on_sink_error)

        if schema.singleton_class.include?(Guard)
          raise ConfigurationError, "#{schema} already uses PersistedQueries (here or in a parent schema): use it once"
        end

        schema.instance_variable_set(:@armory_persisted_queries, gate)
        schema.singleton_class.prepend(Guard)
        schema.query_class(schema.query_class)
      end

      # Decides what a request runs: answers `[refusal, document]`, where a refusal is the error message, a
      # document is the stored operation to run instead of the request's text, and `[nil, nil]` runs the request
      # as it came.
      class Gate
        # Wires the app's store with `use`'s defaults; `use` goes through here.
        def self.build(store:, strict: false, sinks: [], on_sink_error: nil)
          new(store: store, strict: strict, telemetry: Telemetry.build(sinks: sinks, on_sink_error: on_sink_error))
        end

        # `new` is inert: with no store wired it refuses every request. It checks what it is given, so it never
        # lets raw queries through without a store either.
        def initialize(store: Store::Null.new, strict: true, telemetry: Telemetry.new)
          if store.is_a?(Hash) || !store.respond_to?(:fetch)
            raise ConfigurationError, "store: must answer fetch(id) with an operation or nil, like a Manifest"
          end
          raise ConfigurationError, "strict: must be true or false, got #{strict.inspect}" unless strict == true || strict == false
          raise ConfigurationError, "strict: false needs a store: with the Null store only raw queries would run" if !strict && store.is_a?(Store::Null)

          @store = store
          @strict = strict
          @telemetry = telemetry
        end

        def call(context, text, document)
          operation_id = context[:operation_id] if context.respond_to?(:[])
          sink_context = context.respond_to?(:[]) ? context : {}

          if !operation_id.nil?
            operation = operation_id.is_a?(String) ? @store.fetch(operation_id) : nil
            if operation.nil?
              refuse(UNKNOWN_OPERATION, :unknown_operation, sink_context)
            elsif document || (text && !same_query?(text, operation))
              refuse(MISMATCH, :mismatch, sink_context)
            else
              @telemetry.record(:operation_persisted, context: sink_context)
              [nil, operation.document]
            end
          elsif @strict && !(context.respond_to?(:[]) && context[:armory_allow_raw_query] == true)
            refuse(RAW_QUERY_REFUSED, :raw_query, sink_context)
          else
            @telemetry.record(@strict ? :raw_query_allowed : :raw_query_run, context: sink_context) if text || document
            [nil, nil]
          end
        end

        private

        # The signal says why, never which operation id or query: a client chooses those.
        def refuse(message, reason, context)
          @telemetry.record(:operation_refused, context: context, reason: reason)
          [message, nil]
        end

        # Apollo's clients may send the query with its id; graphql-ruby's subscriptions resend it printed.
        def same_query?(text, operation)
          text == operation.body || text == operation.document.to_query_string
        end
      end

      # Keeps the lookup in every query class the schema uses, including one set after `use` or by a child schema.
      module Guard
        UNSET = Object.new.freeze

        def query_class(new_query_class = UNSET)
          return super() if UNSET.equal?(new_query_class)
          return super(new_query_class) if new_query_class.include?(Lookup)

          super(Class.new(new_query_class) { include Lookup })
        end

        def armory_persisted_queries
          @armory_persisted_queries || superclass.armory_persisted_queries
        end
      end

      # The operation id a request sent, from Rack or Rails params: `operationId`, `extensions.operationId` or
      # Apollo's `extensions.persistedQuery.sha256Hash`, or Relay's `doc_id` (`extensions` may arrive as a JSON string on GET).
      # Answers nil when there is none, or when it is not a non-empty String.
      def self.operation_id(params)
        params = plain(params)
        extensions = params["extensions"]
        extensions = parse_json(extensions) if extensions.is_a?(String)
        extensions = plain(extensions)
        persisted_query = plain(extensions["persistedQuery"])

        [params["operationId"], extensions["operationId"], persisted_query["sha256Hash"], params["doc_id"]].find do |candidate|
          candidate.is_a?(String) && !candidate.empty?
        end
      end

      def self.plain(value)
        value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
        value.is_a?(Hash) ? value : {}
      end
      private_class_method :plain

      def self.parse_json(text)
        JSON.parse(text)
      rescue JSON::ParserError
        nil
      end
      private_class_method :parse_json

      # Swaps the request's query for the stored document, or for nothing with an error when it is refused.
      module Lookup
        def initialize(schema, query_string = nil, **options)
          text = query_string || options[:query]
          text = nil if text == ""
          refusal, document = schema.armory_persisted_queries.(options[:context], text, options[:document])

          return super if refusal.nil? && document.nil?
          return super(schema, nil, **options, query: nil, document: document) if refusal.nil?

          # A refused request fails validation with the refusal as its only error, so neither engine runs it. Its
          # text is never parsed; a document the app built itself is kept, for `Schema.validate`, which validates it
          # with its own validator.
          super(schema, nil, **options, query: nil, document: options[:document] || EMPTY_DOCUMENT, validate: true, static_validator: Refusal.new(schema, refusal))
        end
      end
    end
  end
end

require "graphql/armory/persisted_queries/manifest"
require "graphql/armory/persisted_queries/store"
require "graphql/armory/persisted_queries/controls"
