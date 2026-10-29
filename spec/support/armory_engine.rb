# frozen_string_literal: true

# Selects which graphql-ruby execution engine the whole suite runs on.
#
#   GRAPHQL_ARMORY_ENGINE=interpreter (default) -- the legacy Interpreter
#   GRAPHQL_ARMORY_ENGINE=next                  -- Execution::Next (graphql >= 2.5.26)
#
# Both engines are first-class targets: CI runs the suite once per engine.
#
# A schema runs on Execution::Next only if it opted in with `use GraphQL::Execution::Next`,
# so specs build their schemas from `base_schema`, which does that when the engine exists.
module ArmoryEngine
  NAMES = %w[interpreter next].freeze

  def self.current
    name = ENV.fetch("GRAPHQL_ARMORY_ENGINE", "interpreter")
    return name if NAMES.include?(name)

    raise ArgumentError, "GRAPHQL_ARMORY_ENGINE must be one of #{NAMES.join(", ")}, got #{name.inspect}"
  end

  def self.next?
    current == "next"
  end

  # Execution::Next ships from graphql 2.5.26 (verified: absent in 2.5.20, present in 2.5.26 and 2.6.0).
  def self.available?
    defined?(GraphQL::Execution::Next) ? true : false
  end

  def self.base_schema
    Class.new(GraphQL::Schema) do
      use GraphQL::Execution::Next if ArmoryEngine.available?
    end
  end

  module Helpers
    # A GraphQL::Schema subclass that can run on either engine.
    def base_schema
      ArmoryEngine.base_schema
    end

    # Executes a query on the engine selected for this run.
    def execute_query(schema, query_string, **options)
      if ArmoryEngine.next?
        unless ArmoryEngine.available?
          raise "GRAPHQL_ARMORY_ENGINE=next needs graphql >= 2.5.26 (running #{GraphQL::VERSION})"
        end

        schema.execute_next(query_string, **options)
      else
        schema.execute(query_string, **options)
      end
    end
  end
end
