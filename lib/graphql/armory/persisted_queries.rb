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

      # Validates nothing and answers the refusal, through the query's public `static_validator:` option.
      class Refusal < GraphQL::StaticValidation::Validator
        def initialize(schema, message)
          super(schema: schema)
          @message = message
        end

        def validate(_query, **)
          { errors: [GraphQL::StaticValidation::Error.new(@message)], remaining_timeout: nil }
        end
      end

      # `store:` answers `fetch(id)` with an operation (`body` and `document`) or nil: a Manifest, or your own.
      # `strict: true` refuses raw queries unless the context holds `armory_allow_raw_query: true`.
      def self.use(schema, store:, strict: false)
        if store.is_a?(Hash) || !store.respond_to?(:fetch)
          raise ConfigurationError, "store: must answer fetch(id) with an operation or nil, like a Manifest"
        end
        raise ConfigurationError, "strict: must be true or false, got #{strict.inspect}" unless strict == true || strict == false

        if schema.singleton_class.include?(Guard)
          raise ConfigurationError, "#{schema} already uses PersistedQueries (here or in a parent schema): use it once"
        end

        schema.instance_variable_set(:@armory_persisted_queries, [store, strict].freeze)
        schema.singleton_class.prepend(Guard)
        schema.query_class(schema.query_class)
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
      # Apollo's `extensions.persistedQuery.sha256Hash` (`extensions` may arrive as a JSON string on GET).
      # Answers nil when there is none, or when it is not a non-empty String.
      def self.operation_id(params)
        params = plain(params)
        extensions = params["extensions"]
        extensions = parse_json(extensions) if extensions.is_a?(String)
        extensions = plain(extensions)
        persisted_query = plain(extensions["persistedQuery"])

        [params["operationId"], extensions["operationId"], persisted_query["sha256Hash"]].find do |candidate|
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
          store, strict = schema.armory_persisted_queries
          context = options[:context]
          operation_id = context[:operation_id] if context.respond_to?(:[])
          text = query_string || options[:query]
          text = nil if text == ""

          refusal, document =
            if !operation_id.nil?
              operation = operation_id.is_a?(String) ? store.fetch(operation_id) : nil
              if operation.nil?
                UNKNOWN_OPERATION
              elsif options[:document] || (text && !same_query?(text, operation))
                MISMATCH
              else
                [nil, operation.document]
              end
            elsif strict && !(context.respond_to?(:[]) && context[:armory_allow_raw_query] == true)
              RAW_QUERY_REFUSED
            end

          return super if refusal.nil? && document.nil?
          return super(schema, nil, **options, query: nil, document: document) if refusal.nil?

          # A refused request fails validation with the refusal as its only error, so neither engine runs it. Its
          # text is never parsed; a document the app built itself is kept, for `Schema.validate`, which validates it
          # with its own validator.
          super(schema, nil, **options, query: nil, document: options[:document] || EMPTY_DOCUMENT, validate: true, static_validator: Refusal.new(schema, refusal))
        end

        private

        # Apollo's clients may send the query with its id; graphql-ruby's subscriptions resend it printed.
        def same_query?(text, operation)
          text == operation.body || text == operation.document.to_query_string
        end
      end
    end
  end
end

require "graphql/armory/persisted_queries/manifest"
