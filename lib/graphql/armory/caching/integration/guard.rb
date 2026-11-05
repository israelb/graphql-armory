# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      module Integration
        # Prepended on the schema's singleton class by `use`. Every request funnels through `multiplex` or
        # `multiplex_next` (2.1); the class readers keep the recorder and the query hooks in whatever class the schema
        # uses, set before or after `use`; `rescue_from` wraps each handler so a rescued run is flagged.
        module Guard
          UNSET = Object.new.freeze

          # A Next-default schema's `multiplex` is routed by graphql-ruby to `multiplex_next` (on the same condition,
          # `schema.rb` `multiplex`), where the gate runs once, labelled `:next`: running it here too would decide twice.
          def multiplex(queries, **kwargs)
            return super if @default_execution_next

            Integration.(self, queries, engine: :interpreter) { |runnable| super(runnable, **kwargs) }
          end

          # Exists only with `use GraphQL::Execution::Next`, which defines the method this calls.
          def multiplex_next(queries, **kwargs)
            raise NoMethodError, "undefined method 'multiplex_next' for #{self}: it needs `use GraphQL::Execution::Next`" unless defined?(super)

            Integration.(self, queries, engine: :next) { |runnable| super(runnable, **kwargs) }
          end

          # Reads and writes always answer a recording class (`Recorder::Context.wrap`, the same wrapper per class).
          def context_class(new_context_class = nil)
            return Recorder::Context.wrap(super()) if new_context_class.nil?

            super(Recorder::Context.wrap(new_context_class))
          end

          def query_class(new_query_class = UNSET)
            return super() if UNSET.equal?(new_query_class)

            super(Query.wrap(new_query_class))
          end

          def rescue_from(*error_classes, &handler)
            return super unless handler

            super(*error_classes, &Handlers.wrap(handler))
          end

          # The installed settings (`Integration::Settings`), from this schema or the parent that used Caching.
          def armory_caching
            @armory_caching || superclass.armory_caching
          end
        end
      end
    end
  end
end
