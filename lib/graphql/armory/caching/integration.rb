# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # graphql-ruby's hooks, through its public extension points only (docs/response-caching.md "Installing"):
      #
      # - `Guard`, prepended on the schema's singleton class: `multiplex` and `multiplex_next` (every request sent through
      #   `execute`, `execute_next`, `multiplex` and `multiplex_next`), `context_class`, `query_class` and `rescue_from`.
      # - `Query`, included in the schema's query class: `current_trace` before the multiplex and `result` on a hit.
      # - `Install`, behind `Caching.use`, and `Purge`, behind `Caching.purge`.
      module Integration
        def self.install(schema, **options)
          Install.(schema, **options)
        end

        def self.purge(schema, all: false, viewer: nil, tag: nil, type: nil)
          Purge.(schema, all: all, viewer: viewer, tag: tag, type: type)
        end

        # One `multiplex`/`multiplex_next` call (4.2): builds each options Hash into a query the way `run_all` would and
        # marks it, hands every query of the call to the gate in order, answers its hits, runs the misses and passes
        # together through `run` (the engine's `super`) and offers each miss's result to the gate. Results come back in
        # the order the queries were given.
        def self.call(schema, queries, engine:, &run)
          check_request(schema)
          settings = schema.armory_caching
          built = queries.map { |options| options.is_a?(Hash) ? build(schema, options) : options }
          decisions = settings.gate.(built, engine: engine)
          check_decisions(decisions, built)

          results = Array.new(built.size)
          runnable = []
          built.each_with_index do |query, index|
            answer = decisions[index].hit? ? hit_result(query) : nil
            answer ? results[index] = answer : runnable << index
          end
          unless runnable.empty?
            ran = run.call(runnable.map { |index| built[index] })
            runnable.each_with_index { |index, position| results[index] = ran[position] }
          end

          runnable.each { |index| settings.gate.store(built[index], decisions[index], results[index]) if decisions[index].miss? }
          results
        end

        # The Result the gate answered a hit with. Only for a query the guard built: the gate never decides on another,
        # and a hit whose Result is missing runs uncached rather than being answered from anything else.
        def self.hit_result(query)
          context = query.context
          RecordKeys.guard_built?(context) ? RecordKeys.hit_result(context) : nil
        end

        # Options that change what a query runs or sees in ways the gate cannot read back from the query through public
        # readers (a `warden:` on a schema without visibility profiles, an app validator, a root object). A query built
        # with any of them set is left unmarked, so the gate passes it through (`:built_query`). `execute_next` sends
        # `warden: nil` and `root_value: nil` on every request: only a value counts.
        UNMARKED_OPTIONS = %i[warden static_validator root_value use_visibility_profile].freeze

        # The same construction `run_all` makes for an options Hash, so PersistedQueries, Versioning and the recorder
        # decide here, before the gate looks at the query.
        def self.build(schema, options)
          query = schema.query_class.new(schema, nil, **options)
          RecordKeys.guard_built!(query.context) if markable?(options)
          query
        end

        def self.markable?(options)
          UNMARKED_OPTIONS.none? { |name| !options[name].nil? } && options[:validate] != false
        end

        def self.check_request(schema)
          unless schema.respond_to?(:armory_persisted_queries)
            raise ConfigurationError, "#{schema} uses GraphQL::Armory::Caching without GraphQL::Armory::PersistedQueries: only persisted " \
                                      "operations are cached. Add `use GraphQL::Armory::PersistedQueries` to the schema"
          end

          unwrapped = Handlers.unwrapped(schema)
          return unless unwrapped

          raise ConfigurationError, "#{unwrapped} registered a rescue_from handler after GraphQL::Armory::Caching was installed on #{schema}, " \
                                    "where caching cannot wrap it: a run that handler answered could be stored. Register it on #{schema}"
        end

        def self.check_decisions(decisions, queries)
          return if decisions.is_a?(Array) && decisions.size == queries.size && decisions.all?(Decision)

          raise Error, "the cache gate must answer one Decision per query, in order"
        end
        private_class_method :markable?, :check_request, :check_decisions

        # The `rescue_from` handlers: each one registered after `use` is wrapped, so a run a handler answered is flagged
        # (`RecordKeys.rescued!`) and never stored. A handler caching cannot wrap is refused: before `use` at boot, on a
        # parent after `use` at the first request.
        module Handlers
          MARK = :@armory_caching_rescue

          def self.wrap(handler)
            wrapper = proc do |*arguments|
              context = arguments.find { |argument| argument.is_a?(GraphQL::Query::Context) }
              RecordKeys.rescued!(context) if context
              handler.call(*arguments)
            end
            wrapper.instance_variable_set(MARK, true)
            wrapper
          end

          # Whether the schema or a parent registered any handler (read through the public `error_handlers`).
          def self.registered?(schema)
            hierarchy(schema).any? { |member| handlers_in(member.error_handlers).any? }
          end

          # The schema of the hierarchy holding a handler that is not a wrapper, or nil.
          def self.unwrapped(schema)
            hierarchy(schema).find { |member| handlers_in(member.error_handlers).any? { |handler| !handler.instance_variable_defined?(MARK) } }
          end

          def self.hierarchy(schema)
            members = []
            member = schema
            while member.respond_to?(:error_handlers)
              members << member
              member = member.superclass
            end
            members
          end

          def self.handlers_in(node)
            node[:subclass_handlers].each_value.flat_map { |entry| [entry[:handler], *handlers_in(entry)].compact }
          end
          private_class_method :hierarchy, :handlers_in
        end
      end
    end
  end
end

require "graphql/armory/caching/integration/install"
require "graphql/armory/caching/integration/guard"
require "graphql/armory/caching/integration/query"
require "graphql/armory/caching/purge"
