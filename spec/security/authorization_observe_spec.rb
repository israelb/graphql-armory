# frozen_string_literal: true

# Observing a rule serves what it would refuse and records it, to learn who a new rule would refuse before enforcing it.
# It opens one thing only: a clear "no" to a read, on a rule that names it, with someone listening.
RSpec.describe "Authorization: observing a rule" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:error) { armory::ConfigurationError }
  let(:reason) { "rollout of invoices" }
  let(:signals) { [] }
  let(:sink) { ->(signal, data) { signals << [signal, data] } }
  let(:record) { Struct.new(:id, :secret).new("1", "SECRET") }
  let(:root) { Struct.new(:invoice, :invoices, :pay).new(record, [record], record) }

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

  def observed_type(observe: reason)
    Class.new(base_object) do
      graphql_name "Invoice"
      authorize :read, model: Object, observe: observe
      field :secret, String
    end
  end

  def query_of(type)
    Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :invoice, type, null: true, authorize: :none, reason: "x"
    end
  end

  def schema_of(type, adapter: armory::Adapters::Substitute.new(allow: false), sinks: [sink], query_type: query_of(type), mutation_type: nil)
    plugin = armory
    Class.new(ArmoryEngine.base_schema) do
      query query_type
      mutation mutation_type if mutation_type
      use plugin, adapter: adapter, sinks: sinks
    end
  end

  def run(schema, document = "{ invoice { secret } }")
    execute_query(schema, document, root_value: root, context: {})
  end

  describe "a read the policy refuses" do
    it "serves the data and records who it would have refused, with the reason" do
      response = run(schema_of(observed_type))

      expect(response.dig("data", "invoice", "secret")).to eq("SECRET")
      expect(signals.map(&:first)).to include(:observed)
      expect(signals.map(&:first)).not_to include(:denied)
      expect(signals.find { |signal, _| signal == :observed }.last).to include(action: :read, reason: reason)
    end

    it "records nothing as observed when the policy allows it" do
      response = run(schema_of(observed_type, adapter: armory::Adapters::Substitute.new(allow: true)))

      expect(response.dig("data", "invoice", "secret")).to eq("SECRET")
      expect(signals.map(&:first)).to include(:allowed)
      expect(signals.map(&:first)).not_to include(:observed)
    end

    it "works on a field's own rule, and leaves the rest of the type enforced" do
      type = Class.new(base_object) do
        graphql_name "Invoice"
        authorize :none, reason: "x", covers_fields: true
        field :secret, String, authorize: :manage, observe: "rollout"
        field :other, String, authorize: :manage, method: :secret
      end
      response = run(schema_of(type), "{ invoice { secret other } }")

      expect(response.dig("data", "invoice", "secret")).to eq("SECRET")
      expect(response.dig("data", "invoice", "other")).to be_nil
      expect(signals.count { |signal, _| signal == :observed }).to eq(1)
      expect(signals.map(&:first)).to include(:denied)
    end
  end

  describe "what keeps refusing" do
    it "refuses with no sinks: observing with nobody listening is only an open door" do
      response = run(schema_of(observed_type, sinks: []))

      expect(response.dig("data", "invoice")).to be_nil
    end

    it "refuses with the null adapter: a misconfigured object never lets anything through" do
      response = run(schema_of(observed_type, adapter: armory::Adapters::Null.new))

      expect(response.dig("data", "invoice")).to be_nil
      expect(signals.map(&:first)).not_to include(:observed)
    end

    it "does not turn a raising adapter into a pass" do
      schema = schema_of(observed_type, adapter: armory::Adapters::Substitute.new(raises: armory::AdapterError.new("boom")))

      expect { run(schema) }.to raise_error(armory::AdapterError)
    end

    it "refuses an answer that is not true, false or nil" do
      schema = schema_of(observed_type, adapter: armory::Adapters::Substitute.new(allow: "yes"))

      expect { run(schema) }.to raise_error(armory::AdapterError)
    end

    it "leaves a type with no rule denied" do
      type = Class.new(base_object) do
        graphql_name "Invoice"
        field :secret, String
      end

      expect(run(schema_of(type)).dig("data", "invoice")).to be_nil
    end

    it "enforces in a mutation: an observed read in a write's response is still refused" do
      type = observed_type
      plugin_field = base_field
      mutation_type = Class.new(base_object) do
        graphql_name "Mutation"
        field_class plugin_field
        authorize :none, reason: "root", covers_fields: true
        field :pay, type, null: true, authorize: :none, reason: "x"
      end
      response = run(schema_of(type, mutation_type: mutation_type), "mutation { pay { secret } }")

      expect(response.dig("data", "pay")).to be_nil
      expect(signals.map(&:first)).not_to include(:observed)
    end

    it "enforces a field rule on the mutation root: it would run a write" do
      plugin_field = base_field
      mutation_type = Class.new(base_object) do
        graphql_name "Mutation"
        field_class plugin_field
        authorize :none, reason: "root", covers_fields: true
        field :pay, String, null: true, authorize: :manage, observe: "rollout", method: :secret
      end
      type = observed_type
      schema = schema_of(type, mutation_type: mutation_type)
      response = execute_query(schema, "mutation { pay }", root_value: record, context: {})

      expect(response.dig("data", "pay")).to be_nil
    end

    def resolver_counting(ran)
      Class.new(GraphQL::Schema::Resolver) do
        type String, null: true
        define_method(:resolve) { ran << :body; "ran" }
      end
    end

    it "raises on a type holding a resolver, inherited or not, and runs nothing: observing would open the only check before it" do
      ran = []
      plain = resolver_counting(ran)
      parent = Class.new(base_object) do
        graphql_name "Parent"
        authorize :read, model: Object
        field :touch, resolver: plain
      end
      type = Class.new(parent) do
        graphql_name "Invoice"
        authorize :read, model: Object, observe: "rollout"
        field :secret, String
      end

      expect { run(schema_of(type), "{ invoice { secret touch } }") }.to raise_error(error, /Invoice cannot be observed: its field touch/)
      expect(ran).to be_empty
    end

    it "raises whatever the field's class, and for an allowed user too: the schema is wrong, not the user" do
      ran = []
      plain = resolver_counting(ran)
      type = Class.new(base_object) do
        graphql_name "Invoice"
        authorize :read, model: Object, observe: "rollout"
        field_class GraphQL::Schema::Field
        field :touch, resolver: plain
      end
      schema = schema_of(type, adapter: armory::Adapters::Substitute.new(allow: true))

      expect { run(schema, "{ invoice { touch } }") }.to raise_error(error, /cannot be observed/)
      expect(ran).to be_empty
    end

    it "raises on authorize: true with a resolver, where only the parent's rule is observed" do
      ran = []
      plain = resolver_counting(ran)
      klass = base_field
      parent = Class.new(base_object) do
        graphql_name "Parent"
        field_class klass
        authorize :read, model: Object, observe: "rollout"
        field :touch, resolver: plain, authorize: true
      end
      child = Class.new(parent) do
        graphql_name "Invoice"
        authorize :show, model: Object
      end

      expect { run(schema_of(child, adapter: armory::Adapters::Substitute.new(allow: true)), "{ invoice { touch } }") }.to raise_error(error, /touch has a resolver/)
      expect(ran).to be_empty
    end

    it "runs nothing on an observed root type holding a resolver, though graphql-ruby's rescue changes the error" do
      ran = []
      plain = resolver_counting(ran)
      query_type = Class.new(base_object) do
        graphql_name "Query"
        authorize :read, model: Object, observe: "rollout"
        field :touch, resolver: plain
      end

      expect { run(schema_of(nil, query_type: query_type), "{ touch }") }.to raise_error(StandardError)
      expect(ran).to be_empty
    end

    it "reads only what can run: a shadowed field neither breaks the type nor stops it being observed" do
      ran = []
      plain = resolver_counting(ran)
      klass = base_field
      parent = Class.new(base_object) do
        graphql_name "Parent"
        field_class klass
        authorize :read, model: Object
        field(:gone, String, null: true) { argument :x, ThisConstantDoesNotExist }
        field :touch, resolver: plain
      end
      type = Class.new(parent) do
        graphql_name "Invoice"
        authorize :read, model: Object, observe: "rollout"
        field :gone, String, null: true, hash_key: :secret
        field :touch, String, null: true, hash_key: :secret
        field :secret, String
      end
      response = run(schema_of(type), "{ invoice { secret } }")

      expect(response.dig("data", "invoice", "secret")).to eq("SECRET")
      expect(ran).to be_empty
    end

    it "still narrows a list through the scope" do
      type = observed_type
      query_type = Class.new(base_object) do
        graphql_name "Query"
        authorize :none, reason: "root", covers_fields: true
        field :invoices, [type], null: true, authorize: :none, reason: "x"
      end
      adapter = armory::Adapters::Substitute.new(allow: false, scoped: ->(_items) { [] })
      response = run(schema_of(type, adapter: adapter, query_type: query_type), "{ invoices { secret } }")

      expect(response.dig("data", "invoices")).to eq([])
    end

    it "serves a list with no scope row by row, and records each: the check on each object cannot tell it is inside a list" do
      type = observed_type
      query_type = Class.new(base_object) do
        graphql_name "Query"
        authorize :none, reason: "root", covers_fields: true
        field :invoices, [type], null: true, authorize: :none, reason: "x", scope: false
      end
      response = run(schema_of(type, query_type: query_type), "{ invoices { secret } }")

      expect(response.dig("data", "invoices")).to eq([{ "secret" => "SECRET" }])
      expect(signals.map(&:first)).to include(:observed)
    end

    it "still refuses an in-memory lookup outside what the policy allows" do
      model = Class.new do
        def self.primary_key = "id"
        def self.find_by(_conditions) = Struct.new(:secret).new("SECRET")
      end
      type = Class.new(base_object) do
        graphql_name "Invoice"
        authorize :read, model: model, scope: :in_memory, observe: "rollout"
        field :secret, String
      end
      query_type = Class.new(base_object) do
        graphql_name "Query"
        authorize :none, reason: "root", covers_fields: true
        field :invoice, type, null: true, authorize: :none, reason: "x", find_by: :id do
          argument :id, GraphQL::Types::ID
        end
      end
      response = run(schema_of(type, query_type: query_type), '{ invoice(id: "1") { secret } }')

      expect(response.dig("data", "invoice")).to be_nil
    end
  end

  describe "declaring it" do
    it "refuses an empty or non-text reason" do
      ["", "  ", true, :x].each do |bad|
        expect { armory::Rule.new(:read, observe: bad) }.to raise_error(ArgumentError, /observe/)
      end
    end

    it "refuses it on a bypass, which refuses nothing" do
      expect { armory::Rule.new(:none, reason: "x", observe: "y") }.to raise_error(ArgumentError, /observe/)
    end

    it "keeps it when the rule learns its model, and drops it when enforced" do
      rule = armory::Rule.new(:read, observe: "y")

      expect(rule.with_model(Object).observe).to eq("y")
      expect(rule.enforced.observe).to be_nil
      expect(rule).not_to eq(rule.enforced)
    end

    it "refuses it on a field with no action of its own" do
      [nil, true, :none].each do |declared|
        options = declared == :none ? { authorize: :none, reason: "x" } : { authorize: declared }
        field_klass = base_field
        expect do
          Class.new(base_object) do
            graphql_name "Invoice"
            field_class field_klass
            field :secret, String, observe: "y", **options.compact
          end
        end.to raise_error(ArgumentError, /observe/)
      end
    end

    it "refuses it on a mutation or a resolver: a write cannot be undone" do
      plugin = armory
      expect do
        Class.new(GraphQL::Schema::RelayClassicMutation) do
          include plugin::Base
          authorize :approve, model: Object, observe: "y"
        end
      end.to raise_error(ArgumentError, /observe/)
    end

    it "refuses it on a field that holds a resolver or a mutation: the field's rule would be all that stops its body" do
      plain = Class.new(GraphQL::Schema::Resolver) do
        type String, null: true
        def resolve = "ran"
      end
      field_klass = base_field

      expect do
        Class.new(base_object) do
          graphql_name "Query"
          field_class field_klass
          field :touch, resolver: plain, authorize: :manage, observe: "y"
        end
      end.to raise_error(ArgumentError, /observe/)

      write = Class.new(GraphQL::Schema::Mutation) do
        graphql_name "Pay"
        field :ok, String, null: true
      end
      expect do
        Class.new(base_object) do
          graphql_name "Mutation"
          field_class field_klass
          field :pay, mutation: write, authorize: :manage, observe: "y"
        end
      end.to raise_error(ArgumentError, /observe/)
    end

    it "refuses it on an argument" do
      plugin = armory
      argument = Class.new(GraphQL::Schema::Argument) { include plugin::Base }

      expect { argument.new(:tag, String, required: false, authorize: :manage, observe: "y", owner: base_object) }.to raise_error(ArgumentError)
    end
  end

  describe "the audit" do
    it "reports an observed type, with its reason, so it is never ok" do
      report = armory::Audit.(schema_of(observed_type))

      observed = report.problems.select { |problem| problem.kind == :observed }
      expect(report.ok?).to be(false)
      expect(observed.map(&:path)).to eq(["Invoice"])
      expect(observed.first.message).to include(reason)
    end

    it "reports an observed field, and a subclass that inherits the rule" do
      field_klass = base_field
      type = Class.new(base_object) do
        graphql_name "Invoice"
        field_class field_klass
        authorize :none, reason: "x", covers_fields: true
        field :secret, String, authorize: :manage, observe: "rollout"
      end
      child = Class.new(observed_type) { graphql_name "Child" }
      query_type = Class.new(base_object) do
        graphql_name "Query"
        authorize :none, reason: "root", covers_fields: true
        field :invoice, type, null: true, authorize: :none, reason: "x"
        field :child, child, null: true, authorize: :none, reason: "x"
      end

      paths = armory::Audit.(schema_of(type, query_type: query_type)).problems.select { |problem| problem.kind == :observed }.map(&:path)

      expect(paths).to contain_exactly("Invoice.secret", "Child")
    end

    it "reports authorize: true on a parent whose rule is observed, and says when a resolver makes the type raise" do
      klass = base_field
      plain = Class.new(GraphQL::Schema::Resolver) do
        type String, null: true
        def resolve = "ran"
      end
      parent = Class.new(base_object) do
        graphql_name "Parent"
        field_class klass
        authorize :read, model: Object, observe: "rollout"
        field :secret, String, authorize: true
      end
      child = Class.new(parent) do
        graphql_name "Invoice"
        authorize :show, model: Object
      end
      raising = Class.new(base_object) do
        graphql_name "Raising"
        authorize :read, model: Object, observe: "rollout"
        field :touch, resolver: plain
      end
      query_type = Class.new(base_object) do
        graphql_name "Query"
        authorize :none, reason: "root", covers_fields: true
        field :invoice, child, null: true, authorize: :none, reason: "x"
        field :raising, raising, null: true, authorize: :none, reason: "x"
      end

      report = armory::Audit.(schema_of(child, query_type: query_type))
      observed = report.problems.select { |problem| problem.kind == :observed }

      expect(report.ok?).to be(false)
      expect(observed.map(&:path)).to include("Invoice.secret", "Raising")
      expect(observed.find { |problem| problem.path == "Raising" }.message).to include("raises on every query", "touch")
    end

    it "cannot be accepted in a baseline: it has its declaration, and it serves refused users" do
      report = armory::Audit.(schema_of(observed_type))

      expect { armory::Audit::Baseline.from(report) }.to raise_error(error, /observe/)
    end

    it "does not report an enforced schema" do
      type = Class.new(base_object) do
        graphql_name "Invoice"
        authorize :read, model: Object
        field :secret, String
      end

      expect(armory::Audit.(schema_of(type)).problems.map(&:kind)).not_to include(:observed)
    end
  end
end
