# frozen_string_literal: true

# Guards the CI matrix: a leg that claims to run on Execution::Next must really run on it,
# otherwise the whole security suite would silently pass on the wrong engine.
#
# The engine is observed from a trace hook rather than from a field method, because the two
# engines resolve fields differently: Execution::Next calls the application object (`direct_send`),
# not instance methods of the type class, unless a field opts in to `resolve_legacy_instance_method`.
# Specs that must pass on both engines therefore resolve fields from the application object.
RSpec.describe "execution engine selection" do
  let(:engines_seen) { [] }

  let(:schema) do
    seen = engines_seen

    tracer = Module.new do
      define_method(:execute_query) do |query:, &block|
        # `__graphql_execute_next` is an internal marker set by Execution::Next.
        seen << (query.context[:__graphql_execute_next] ? "next" : "interpreter")
        super(query: query, &block)
      end
    end

    query_type = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :hello, String, null: false
    end

    Class.new(base_schema) do
      query(query_type)
      trace_with(tracer)
    end
  end

  let(:root) { Struct.new(:hello).new("world") }

  it "runs the queries on the engine named by GRAPHQL_ARMORY_ENGINE" do
    result = execute_query(schema, "{ hello }", root_value: root)

    expect(result.to_h).to eq("data" => { "hello" => "world" })
    expect(engines_seen).to eq([ArmoryEngine.current])
  end

  it "rejects an unknown engine name" do
    original = ENV["GRAPHQL_ARMORY_ENGINE"]
    ENV["GRAPHQL_ARMORY_ENGINE"] = "turbo"

    expect { ArmoryEngine.current }.to raise_error(ArgumentError, /must be one of interpreter, next/)
  ensure
    ENV["GRAPHQL_ARMORY_ENGINE"] = original
  end
end
