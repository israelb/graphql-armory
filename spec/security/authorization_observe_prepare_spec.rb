# frozen_string_literal: true

# Issue #36: a resolver field that takes its rule from an observed owner (`authorize: true`) must be refused when the type
# that serves it is checked, before graphql-ruby coerces the field's arguments and runs their `prepare:`.
module ObsPrepare
  # Answers by action: what is not in `allow` is refused.
  class ByAction < GraphQL::Armory::Authorization::Adapters::Substitute
    def initialize(allow_actions)
      super()
      @allow_actions = allow_actions
    end

    def authorized?(actor, subject, rule)
      @asked << [actor, subject, rule]
      @allow_actions.include?(rule.action)
    end
  end
end

RSpec.describe "observe: a resolver's arguments are not prepared for an unobservable type" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:ran) { [] }
  let(:base_field) do
    plugin = armory
    Class.new(GraphQL::Schema::Field) { include plugin::Base }
  end
  let(:base_object) do
    plugin = armory
    field_class = base_field
    Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class field_class
    end
  end

  def touch_resolver
    log = ran
    Class.new(GraphQL::Schema::Resolver) do
      type String, null: true
      argument :input, String, prepare: ->(value, _context) { log << :prepare && value }
      define_method(:resolve) do |input:|
        log << :body
        input
      end
    end
  end

  def obj(name, parent: base_object, &block)
    Class.new(parent) do
      graphql_name name
      class_eval(&block)
    end
  end

  def schema_for(type)
    plugin = armory
    query = obj("Query") do
      authorize :none, reason: "root", covers_fields: true
      field :doc, type, null: true, authorize: :none, reason: "x", hash_key: :doc
    end
    Class.new(ArmoryEngine.base_schema) do
      query query
      use plugin, adapter: ObsPrepare::ByAction.new(%i[show]), sinks: []
    end
  end

  def run(schema, document)
    execute_query(schema, document, root_value: { doc: { title: "t" } }, context: {}).to_h
  rescue armory::ConfigurationError => error
    { "raised" => error.message }
  end

  def observed_parent(resolver)
    obj("Parent") do
      authorize :read, model: Object, observe: "rollout"
      field :title, String, null: true
      field :touch, resolver: resolver, authorize: true
    end
  end

  it "refuses before the argument's prepare runs, when the observed rule is a parent's" do
    doc = obj("Doc", parent: observed_parent(touch_resolver)) { authorize :show, model: Object }

    result = run(schema_for(doc), '{ doc { touch(input: "x") } }')

    expect(ran).to eq([])
    expect(result.fetch("raised")).to include("Doc", "touch", "rollout")
  end

  it "refuses the type even when the query selects only its plain fields" do
    doc = obj("Doc", parent: observed_parent(touch_resolver)) { authorize :show, model: Object }

    result = run(schema_for(doc), "{ doc { title } }")

    expect(result.fetch("raised")).to include("Doc", "touch")
  end

  # An interface has no rule, so `authorize: true` on its field is denied, as before; the check must not trip on it.
  it "keeps denying, without raising, a resolver field with authorize: true declared on an interface" do
    resolver = touch_resolver
    field_class = base_field
    interface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Touchable"
      field_class field_class
      field :touch, resolver: resolver, authorize: true
    end
    doc = obj("Doc") do
      implements interface
      authorize :show, model: Object
    end

    result = run(schema_for(doc), '{ doc { touch(input: "x") } }')

    expect(result).to eq("data" => { "doc" => { "touch" => nil } })
    expect(ran).not_to include(:body)
  end

  it "keeps serving a subclass of an observed parent whose fields have no resolver" do
    parent = obj("Parent") do
      authorize :read, model: Object, observe: "rollout"
      field :title, String, null: true, authorize: true, hash_key: :title
    end
    doc = obj("Doc", parent: parent) { authorize :show, model: Object }

    result = run(schema_for(doc), "{ doc { __typename } }")

    expect(result).to eq("data" => { "doc" => { "__typename" => "Doc" } })
  end
end
