# frozen_string_literal: true

# Issue #37: a misconfiguration found while a type is checked raises the same ConfigurationError on every engine, and an
# app's rescue_from cannot turn it into an empty answer.
RSpec.describe "Authorization: a configuration error in a type's check" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:ran) { [] }
  let(:base_object) do
    plugin = armory
    field_class = Class.new(GraphQL::Schema::Field) { include plugin::Base }
    Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class field_class
    end
  end

  def touch_resolver
    log = ran
    Class.new(GraphQL::Schema::Resolver) do
      type String, null: true
      define_method(:resolve) do
        log << :body
        "ran"
      end
    end
  end

  def observed_query
    resolver = touch_resolver
    Class.new(base_object) do
      graphql_name "Query"
      authorize :read, model: Object, observe: "rollout"
      field :touch, resolver: resolver
    end
  end

  def schema_for(query, handler: false)
    plugin = armory
    Class.new(ArmoryEngine.base_schema) do
      query query
      use plugin, adapter: plugin::Adapters::Substitute.new(allow: false), sinks: []
      rescue_from(StandardError) { |_error| nil } if handler
    end
  end

  def execute(schema, document, root: Object.new)
    execute_query(schema, document, root_value: root, context: {})
  end

  it "raises the ConfigurationError itself on an observed root type holding a resolver" do
    expect { execute(schema_for(observed_query), "{ touch }") }.to raise_error(armory::ConfigurationError, /Query cannot be observed/)
    expect(ran).to eq([])
  end

  it "raises it past an app's rescue_from(StandardError)" do
    expect { execute(schema_for(observed_query, handler: true), "{ touch }") }.to raise_error(armory::ConfigurationError, /Query cannot be observed/)
    expect(ran).to eq([])
  end

  # Below the root, graphql-ruby hands it to rescue_from as before: the type is denied and nothing runs.
  it "keeps a nested type that cannot be observed failing closed under rescue_from" do
    resolver = touch_resolver
    doc = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: Object, observe: "rollout"
      field :touch, resolver: resolver
    end
    query = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :doc, doc, null: true, authorize: :none, reason: "x", hash_key: :doc
    end

    result = execute(schema_for(query, handler: true), "{ doc { touch } }", root: { doc: Object.new }).to_h

    expect(result.dig("data", "doc")).to be_nil
    expect(ran).to eq([])
  end

  it "keeps handing an error the policy raises in a type's check to the app's rescue_from, and denies the type" do
    boom = Class.new(StandardError)
    raising = Class.new(armory::Adapters::Substitute) { define_method(:authorized?) { |*| raise boom } }
    doc = Class.new(base_object) do
      graphql_name "Doc"
      authorize :read, model: Object
      field :name, String, null: true, hash_key: :name
    end
    query = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :doc, doc, null: true, authorize: :none, reason: "x", hash_key: :doc
    end
    handled = []
    plugin = armory
    schema = Class.new(ArmoryEngine.base_schema) do
      query query
      use plugin, adapter: raising.new, sinks: []
      rescue_from(boom) { |error| handled << error.class && nil }
    end

    result = execute(schema, "{ doc { name } }", root: { doc: { name: "secret" } }).to_h

    expect(handled).to eq([boom])
    expect(result.dig("data", "doc")).to be_nil
  end
end
