# frozen_string_literal: true

class ArmoryPayloadThing
  def self.writes = (@writes ||= [])
end

class ArmoryPayloadThingPolicy
  def initialize(user, thing)
    @user = user
    @thing = thing
  end

  def move? = @user == :owner
  def read? = true

  class Scope
    def initialize(_user, scope)
      @scope = scope
    end

    def resolve = @scope
  end
end

# A payload field asks the class that declared it. When that denies it, the write has already run and the client reads null.
RSpec.describe "audit of a mutation's payload fields" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:base_field) do
    plugin = armory
    Class.new(GraphQL::Schema::Field) { include plugin::Base }
  end
  let(:base_object) do
    plugin = armory
    field = base_field
    Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class field
    end
  end
  let(:payload_base) do
    Class.new(base_object) { authorize :none, reason: "the mutation's rule covers its payload", covers_fields: true }
  end
  let(:base_mutation) do
    plugin = armory
    field = base_field
    payload = payload_base
    Class.new(GraphQL::Schema::RelayClassicMutation) do
      include plugin::Base
      field_class field
      object_class payload
    end
  end

  def mutation_named(name, parent, &block)
    Class.new(parent) do
      graphql_name name
      define_method(:resolve) do |**|
        ArmoryPayloadThing.writes << :written
        { done: "yes" }
      end
      class_eval(&block) if block
    end
  end

  def schema_with(mutation_class, query_fields: nil)
    plain_root = base_object
    query_root = Class.new(plain_root) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :ping, GraphQL::Types::String, null: true
      class_eval(&query_fields) if query_fields
    end
    mutation_root = Class.new(plain_root) do
      graphql_name "Mutation"
      authorize :none, reason: "root", covers_fields: true
      field :act, mutation: mutation_class
    end
    Class.new(ArmoryEngine.base_schema) do
      query query_root
      mutation mutation_root
      use GraphQL::Armory::Authorization, adapter: :pundit
    end
  end

  def act(schema, user: :owner)
    execute_query(schema, "mutation { act(input: {}) { done } }", context: { current_user: user }).to_h
  end

  def kinds(schema)
    armory::Audit.(schema).problems.map(&:kind)
  end

  before { ArmoryPayloadThing.writes.clear }

  shared_examples "a write that answers null" do
    it "writes and answers null, and the audit says so" do
      schema = schema_with(mutation_class)

      expect(act(schema).dig("data", "act", "done")).to be_nil
      expect(ArmoryPayloadThing.writes).to eq([:written])
      expect(kinds(schema)).to include(:field_without_rule)
    end
  end

  context "with the field on a parent with no rule" do
    let(:mutation_class) do
      parent = Class.new(base_mutation) do
        graphql_name "Parent"
        field :done, GraphQL::Types::String, null: true, hash_key: :done
      end
      mutation_named("Act", parent) { authorize :move, model: ArmoryPayloadThing }
    end

    it_behaves_like "a write that answers null"
  end

  context "with the field on a parent with authorize :none" do
    let(:mutation_class) do
      parent = Class.new(base_mutation) do
        graphql_name "Parent"
        authorize :none, reason: "public parent"
        field :done, GraphQL::Types::String, null: true, hash_key: :done
      end
      mutation_named("Act", parent) { authorize :move, model: ArmoryPayloadThing }
    end

    it_behaves_like "a write that answers null"
  end

  context "with its own field on a mutation with authorize :none" do
    let(:mutation_class) do
      mutation_named("Act", base_mutation) do
        authorize :none, reason: "public"
        field :done, GraphQL::Types::String, null: true, hash_key: :done
      end
    end

    it_behaves_like "a write that answers null"
  end

  describe "what stays clean" do
    it "a field on the mutation that holds the rule" do
      schema = schema_with(mutation_named("Act", base_mutation) do
        authorize :move, model: ArmoryPayloadThing
        field :done, GraphQL::Types::String, null: true, hash_key: :done
      end)

      expect(act(schema).dig("data", "act", "done")).to eq("yes")
      expect(kinds(schema)).not_to include(:field_without_rule)
    end

    it "a public mutation with covers_fields" do
      schema = schema_with(mutation_named("Act", base_mutation) do
        authorize :none, reason: "public", covers_fields: true
        field :done, GraphQL::Types::String, null: true, hash_key: :done
      end)

      expect(act(schema).dig("data", "act", "done")).to eq("yes")
      expect(kinds(schema)).not_to include(:field_without_rule)
    end

    it "a parent's field that declares authorize: :none, listed as a bypass" do
      parent = Class.new(base_mutation) do
        graphql_name "Parent"
        field :done, GraphQL::Types::String, null: true, hash_key: :done, authorize: :none, reason: "only says it worked"
      end
      schema = schema_with(mutation_named("Act", parent) { authorize :move, model: ArmoryPayloadThing })

      expect(act(schema).dig("data", "act", "done")).to eq("yes")
      expect(kinds(schema)).not_to include(:field_without_rule)
    end

    it "a shared payload_type on the child" do
      shared = Class.new(payload_base) do
        graphql_name "SharedPayload"
        field :done, GraphQL::Types::String, null: true, hash_key: :done
      end
      schema = schema_with(mutation_named("Act", base_mutation) do
        authorize :move, model: ArmoryPayloadThing
        payload_type shared
      end)

      expect(act(schema).dig("data", "act", "done")).to eq("yes")
      expect(kinds(schema)).not_to include(:field_without_rule)
    end
  end

  # A payload reached with no mutation having run: the user the mutation refuses asks for it on a query.
  describe "a payload type on a query field" do
    it "never says ok when a user the mutation refuses gets the data" do
      mutation_class = mutation_named("Act", base_mutation) do
        authorize :move, model: ArmoryPayloadThing
        field :done, GraphQL::Types::String, null: true, hash_key: :done
      end
      payload = mutation_class.payload_type
      schema = schema_with(mutation_class, query_fields: proc {
        field :leak, payload, null: true
      })
      data = execute_query(schema, "{ leak { done } }", root_value: Struct.new(:leak).new({ done: "SECRET" }), context: { current_user: :stranger }).to_h.dig("data", "leak", "done")

      expect(data).to eq("SECRET")
      expect(kinds(schema)).to eq([:payload_outside_mutation])
    end

    it "says nothing about the mutation's own field" do
      schema = schema_with(mutation_named("Act", base_mutation) do
        authorize :move, model: ArmoryPayloadThing
        field :done, GraphQL::Types::String, null: true, hash_key: :done
      end)

      expect(kinds(schema)).not_to include(:payload_outside_mutation)
    end

    it "reports it through a union too" do
      mutation_class = mutation_named("Act", base_mutation) do
        authorize :move, model: ArmoryPayloadThing
        field :done, GraphQL::Types::String, null: true, hash_key: :done
      end
      payload = mutation_class.payload_type
      union = Class.new(GraphQL::Schema::Union) do
        graphql_name "Either"
        possible_types payload
      end
      schema = schema_with(mutation_class, query_fields: proc { field :leak, union, null: true })

      expect(kinds(schema)).to include(:payload_outside_mutation)
    end

    it "says nothing about a public mutation's payload, which covers nothing" do
      mutation_class = mutation_named("Act", base_mutation) do
        authorize :none, reason: "public", covers_fields: true
        field :done, GraphQL::Types::String, null: true, hash_key: :done
      end
      payload = mutation_class.payload_type
      schema = schema_with(mutation_class, query_fields: proc { field :open, payload, null: true })

      expect(kinds(schema)).not_to include(:payload_outside_mutation)
    end
  end
end
