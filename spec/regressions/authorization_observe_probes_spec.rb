# frozen_string_literal: true

require "tmpdir"
require "json"
require "stringio"
require "graphql/armory/authorization/rspec"

# Independent probes of `observe:`. Each name starts with [security] or [preservation].
module ObsProbe
  Doc = Struct.new(:id, :secret, :notes)
  NoPolicyDoc = Struct.new(:id, :secret)

  class DocPolicy
    attr_reader :user, :record

    def initialize(user, record)
      @user = user
      @record = record
    end

    def read? = false
    def manage? = nil
    def weird? = "yes"
    def boom? = raise("policy failed")
    def allow? = true

    class Scope
      def initialize(_user, scope) = @scope = scope
      def resolve = @scope.none
    end
  end

  class EmptyAbility
    include CanCan::Ability
    def initialize(_user); end
  end
end

# Execution::Next does not call a type's instance methods, so a probe's resolver runs through an extension, as FindBy does.
class ObsAnswer < GraphQL::Schema::FieldExtension
  def resolve(arguments:, context:, object: nil, objects: nil)
    answer = lambda do |one|
      instance = field.owner.allocate
      instance.instance_variable_set(:@object, one)
      instance.instance_variable_set(:@context, context)
      instance.method(options[:name]).arity.zero? ? instance.public_send(options[:name]) : instance.public_send(options[:name], **arguments)
    end
    objects ? objects.map(&answer) : answer.(object)
  end
end

RSpec.describe "observe: independent probes" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:signals) { [] }
  let(:sink) { ->(signal, data) { signals << [signal, data] } }
  let(:record) { ObsProbe::Doc.new("1", "SECRET", "NOTES") }
  let(:refuse) { armory::Adapters::Substitute.new(allow: false) }
  let(:base_field) do
    plugin = armory
    Class.new(GraphQL::Schema::Field) { include plugin::Base }
  end
  let(:base_object) do
    plugin = armory
    bf = base_field
    Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class bf
    end
  end
  let(:base_resolver) do
    plugin = armory
    Class.new(GraphQL::Schema::Resolver) { include plugin::Base }
  end
  let(:base_mutation) do
    plugin = armory
    obj = base_object
    bf = base_field
    Class.new(GraphQL::Schema::Mutation) do
      include plugin::Base
      field_class bf
      object_class obj
    end
  end

  def obj(name, parent: base_object, &blk)
    type = Class.new(parent) do
      graphql_name name
      class_eval(&blk) if blk
    end
    wire(type)
  end

  def wire(type)
    return type unless ArmoryEngine.next?

    type.own_fields.each_value do |field|
      next unless field.respond_to?(:extension) && !field.resolver && type.public_method_defined?(field.method_sym, false)

      field.extension(ObsAnswer, name: field.method_sym)
    end
    type
  end

  def observed_doc(name = "Doc", model: ObsProbe::Doc, why: "rollout")
    obj(name) do
      authorize :read, model: model, observe: why
      field :secret, String, null: true
    end
  end

  def enforced_doc(name = "Doc", model: ObsProbe::Doc)
    obj(name) do
      authorize :read, model: model
      field :secret, String, null: true
    end
  end

  # A root with one field answering the record from the context.
  def root_with(name, type)
    obj(name) do
      authorize :none, reason: "root", covers_fields: true
      field :doc, type, null: true, authorize: :none, reason: "x"
      def doc = context[:record]
    end
  end

  def iface(name = "Thing", &blk)
    bf = base_field
    Module.new do
      include GraphQL::Schema::Interface
      graphql_name name
      field_class bf
      module_eval(&blk) if blk
    end
  end

  def schema_for(query:, mutation: nil, subscription: nil, adapter: refuse, sinks: :default, orphans: [], resolve: nil, on_unauthorized: :null, parent: ArmoryEngine.base_schema, &blk)
    plugin = armory
    sinks = [sink] if sinks == :default
    Class.new(parent) do
      self.query(query) if query
      self.mutation(mutation) if mutation
      self.subscription(subscription) if subscription
      orphan_types(*orphans) unless orphans.empty?
      use plugin, adapter: adapter, sinks: sinks, on_unauthorized: on_unauthorized
      define_singleton_method(:resolve_type) { |_type, object, _context| resolve.call(object) } if resolve
      class_eval(&blk) if blk
    end
  end

  def run(schema, doc, context: {}, **options)
    execute_query(schema, doc, context: { record: record, current_user: :someone }.merge(context), **options).to_h
  end

  def multiplex(schema, queries)
    if ArmoryEngine.next?
      schema.multiplex_next(queries)
    else
      schema.multiplex(queries)
    end.map(&:to_h)
  end

  def kinds(signal_list = signals) = signal_list.map(&:first) - [:bypassed]
  def audit(schema) = armory::Audit.(schema)
  def observed_problems(schema) = audit(schema).problems.select { |problem| problem.kind == :observed }.map(&:path)

  # Answers what really came out, turning an exception into :raised: never treat a raise as served.
  def served?(schema, doc, **options)
    run(schema, doc, **options).to_s.include?("SECRET")
  rescue StandardError
    false
  end

  # ---- Operation selection

  it "[security] control: a query serves, the same document with no observe refuses (S01)" do
    expect(run(schema_for(query: root_with("Query", observed_doc)), "{ doc { secret } }").dig("data", "doc", "secret")).to eq("SECRET")
    expect(kinds).to eq([:observed])
    expect(run(schema_for(query: root_with("Query", enforced_doc)), "{ doc { secret } }").dig("data", "doc")).to be_nil
  end

  it "[security] several operations: operationName decides, query serves and mutation refuses (S02)" do
    type = observed_doc
    schema = schema_for(query: root_with("Query", type), mutation: root_with("Mutation", type))
    doc = "query Q { doc { secret } } mutation M { doc { secret } }"
    expect(served?(schema, doc, operation_name: "M")).to be(false)
    expect(kinds).to eq([:denied])
    signals.clear
    expect(served?(schema, doc, operation_name: "Q")).to be(true)
    expect(kinds).to eq([:observed])
  end

  it "[security] a mutation reaching the type through fragments refuses (S03)" do
    type = observed_doc
    schema = schema_for(query: root_with("Query", type), mutation: root_with("Mutation", type))
    doc = "mutation { doc { ...F ... on Doc { secret } } } fragment F on Doc { secret }"
    expect(served?(schema, doc)).to be(false)
    expect(kinds).not_to include(:observed)
    expect(served?(schema, "query { doc { ...F } } fragment F on Doc { secret }")).to be(true)
  end

  it "[security] multiplex: each operation answers for itself, both orders (S04, S12)" do
    type = observed_doc
    schema = schema_for(query: root_with("Query", type), mutation: root_with("Mutation", type))
    shared = { record: record, current_user: :x }
    query = { query: "{ doc { secret } }", context: shared.dup }
    mutation = { query: "mutation { doc { secret } }", context: shared.dup }

    first = multiplex(schema, [query, mutation])
    expect(first[0].to_s).to include("SECRET")
    expect(first[1].to_s).not_to include("SECRET")
    second = multiplex(schema, [{ query: mutation[:query], context: shared.dup }, { query: query[:query], context: shared.dup }])
    expect(second[0].to_s).not_to include("SECRET")
    expect(second[1].to_s).to include("SECRET")
  end

  def with_subscriptions
    plugin = Class.new(GraphQL::Subscriptions) do
      def write_subscription(_query, _events) = nil
      def execute_all(_event, _object) = nil
    end
    proc { use plugin }
  end

  it "[security] multiplex sharing one context Hash: each still answers for itself (S04b)" do
    type = observed_doc
    schema = schema_for(query: root_with("Query", type), mutation: root_with("Mutation", type))
    shared = { record: record, current_user: :x }
    results = multiplex(schema, [{ query: "mutation { doc { secret } }", context: shared }, { query: "{ doc { secret } }", context: shared }, { query: "mutation { doc { secret } }", context: shared }])
    expect(results.map { |result| result.to_s.include?("SECRET") }).to eq([false, true, false])
  end

  it "[security] a subscription operation refuses (S05)" do
    type = observed_doc
    schema = schema_for(query: root_with("Query", type), subscription: root_with("Subscription", type), &with_subscriptions)
    expect(served?(schema, "{ doc { secret } }")).to be(true)
    signals.clear
    response = run(schema, "subscription { doc { secret } }")
    expect(response.to_s).not_to include("SECRET")
    expect(response.dig("data", "doc")).to be_nil
    expect(kinds).to eq([:denied])
  end

  def partial_root(name, type)
    obj(name) do
      authorize :none, reason: "root", covers_fields: true
      field :doc, type, null: true, authorize: :none, reason: "x"
      define_method(:doc) do
        context[:captured] << context.query.run_partials([{ path: ["doc"], object: context[:record] }]).first.to_h
        nil
      end
    end
  end

  it "[security] a Partial run from a MUTATION resolver refuses a type rule (S06)" do
    skip "no Query::Partial" unless defined?(GraphQL::Query::Partial)
    type = observed_doc
    schema = schema_for(query: root_with("Query", type), mutation: partial_root("Mutation", type))
    captured = []
    run(schema, "mutation { doc { secret } }", context: { captured: captured })
    expect(captured.to_s).not_to include("SECRET")
    expect(kinds).not_to include(:observed)
  end

  it "[security] a Partial run from a MUTATION resolver refuses a field rule (S06b)" do
    skip "no Query::Partial" unless defined?(GraphQL::Query::Partial)
    type = obj("Doc") do
      authorize :none, reason: "x", covers_fields: true
      field :secret, String, null: true, authorize: :manage, observe: "rollout"
    end
    schema = schema_for(query: root_with("Query", type), mutation: partial_root("Mutation", type))
    captured = []
    run(schema, "mutation { doc { secret } }", context: { captured: captured })
    expect(captured.to_s).not_to include("SECRET")
    expect(kinds).not_to include(:observed)
  end

  it "[security] a Partial run from a SUBSCRIPTION refuses (S07)" do
    skip "no Query::Partial" unless defined?(GraphQL::Query::Partial)
    type = obj("Doc") do
      authorize :none, reason: "x", covers_fields: true
      field :secret, String, null: true, authorize: :manage, observe: "rollout"
    end
    schema = schema_for(query: root_with("Query", type), subscription: partial_root("Subscription", type), &with_subscriptions)
    captured = []
    begin
      run(schema, "subscription { doc { secret } }", context: { captured: captured })
    rescue NoMethodError => error
      raise unless error.message.include?("subscription_update?")
    end
    expect(captured.to_s).not_to include("SECRET")
  end

  it "[preservation] a Partial from a query serves and records (K08)" do
    skip "no Query::Partial" unless defined?(GraphQL::Query::Partial)
    type = obj("Doc") do
      authorize :none, reason: "x", covers_fields: true
      field :secret, String, null: true, authorize: :manage, observe: "rollout"
    end
    schema = schema_for(query: partial_root("Query", type))
    captured = []
    run(schema, "{ doc { secret } }", context: { captured: captured })
    expect(captured.to_s).to include("SECRET")
    expect(kinds).to include(:observed)
  end

  it "[security] a hand-built GraphQL::Query selecting the mutation refuses (S09)" do
    type = observed_doc
    schema = schema_for(query: root_with("Query", type), mutation: root_with("Mutation", type))
    doc = "query Q { doc { secret } } mutation M { doc { secret } }"
    query = GraphQL::Query.new(schema, doc, operation_name: "M", context: { record: record })
    result = ArmoryEngine.next? ? schema.multiplex_next([query]).first : schema.multiplex([query]).first
    expect(query.query?).to be(false)
    expect(result.to_h.to_s).not_to include("SECRET")
  end

  # ---- Memo

  it "[security] the same record through an observed type then an enforced one still refuses, both orders (S10)" do
    observed = observed_doc("ObservedDoc")
    enforced = enforced_doc("EnforcedDoc")
    query = obj("Query") do
      authorize :none, reason: "root", covers_fields: true
      field :open, observed, null: true, authorize: :none, reason: "x"
      field :closed, enforced, null: true, authorize: :none, reason: "x"
      def open = context[:record]
      def closed = context[:record]
    end
    schema = schema_for(query: query)
    [%w[open closed], %w[closed open]].each do |one, two|
      data = run(schema, "{ #{one} { secret } #{two} { secret } }")["data"]
      expect(data["open"]["secret"]).to eq("SECRET")
      expect(data["closed"]).to be_nil
    end
  end

  it "[security] Rule equality tells observed from enforced, and enforced keeps every other member (S11, S57)" do
    rule = armory::Rule.new(:read, policy: String, subject: :s, attribute: :a, model: Integer, scope: :in_memory, visible_when: :v, reason: "r", observe: "why")
    plain = armory::Rule.new(:read, policy: String, subject: :s, attribute: :a, model: Integer, scope: :in_memory, visible_when: :v, reason: "r")
    expect(rule).not_to eq(plain)
    expect(rule.hash).not_to eq(plain.hash)
    expect(rule.enforced).to eq(plain)
    expect(rule.with_model(Float).observe).to eq("why")
    expect(rule.with_model(Float).enforced.model).to eq(Float)
  end

  # ---- Rule copies

  it "[preservation] authorize: true inherits the observed rule and is reported; its own action without observe refuses (S18)" do
    type = obj("Doc") do
      authorize :read, model: ObsProbe::Doc, observe: "rollout"
      field :secret, String, null: true, authorize: true
      field :notes, String, null: true, authorize: :manage
    end
    schema = schema_for(query: root_with("Query", type))
    data = run(schema, "{ doc { secret notes } }")["data"]["doc"]
    expect(data).to eq("secret" => "SECRET", "notes" => nil)
    expect(observed_problems(schema)).to include("Doc")
  end

  it "[security] an argument's rule stays enforced under an observed field and type (S19)" do
    ran = []
    bf = base_field
    plugin = armory
    base_argument = Class.new(GraphQL::Schema::Argument) { include plugin::Base }
    bf.argument_class(base_argument)
    type = obj("Doc") do
      authorize :read, model: ObsProbe::Doc, observe: "rollout"
      field :secret, String, null: true, authorize: :manage, observe: "why" do
        argument :full, GraphQL::Types::Boolean, required: false, authorize: :manage, model: ObsProbe::Doc
      end
      define_method(:secret) do |full: false|
        ran << full
        object.secret
      end
    end
    schema = schema_for(query: root_with("Query", type))
    expect(run(schema, "{ doc { secret } }").to_s).to include("SECRET")
    ran.clear
    expect(run(schema, "{ doc { secret(full: true) } }").to_s).not_to include("SECRET")
    expect(ran).to be_empty
  end

  # ---- Lists

  def list_query(field_type)
    obj("Query") do
      authorize :none, reason: "root", covers_fields: true
      field :docs, field_type, null: true, authorize: :none, reason: "x"
      def docs = [context[:record]]
    end
  end

  it "[security] control: a list of the object type goes through the scope (S22)" do
    adapter = armory::Adapters::Substitute.new(allow: false, scoped: ->(_items) { [] })
    schema = schema_for(query: list_query([observed_doc]), adapter: adapter)
    expect(run(schema, "{ docs { secret } }").dig("data", "docs")).to eq([])
    expect(kinds).not_to include(:observed)
  end

  it "[preservation] control: with no observe, the interface, union and scope: false lists refuse every row (S23-S25 control)" do
    thing = iface("Thing") { field :secret, String, null: true }
    type = enforced_doc
    type.implements(thing)
    union = Class.new(GraphQL::Schema::Union) do
      graphql_name "Anything"
      possible_types type
    end
    query = obj("Query") do
      authorize :none, reason: "root", covers_fields: true
      field :i, [thing, { null: true }], null: true, authorize: :none, reason: "x"
      field :u, [union, { null: true }], null: true, authorize: :none, reason: "x"
      field :s, [type, { null: true }], null: true, authorize: :none, reason: "x", scope: false
      def i = [context[:record]]
      def u = [context[:record]]
      def s = [context[:record]]
    end
    schema = schema_for(query: query, resolve: ->(_o) { type }, orphans: [type])
    expect(run(schema, "{ i { secret } u { ... on Doc { secret } } s { secret } }")["data"]).to eq("i" => [nil], "u" => [nil], "s" => [nil])
  end

  describe "on real records" do
    let(:world) { Dummy::World.build }

    def invoice_type(**rule)
      obj("Invoice") do
        authorize :read, model: Invoice, **rule
        field :number, String, null: true
      end
    end

    def invoice_query(type)
      obj("Query") do
        authorize :none, reason: "root", covers_fields: true
        field :by_id, type, null: true, authorize: :none, reason: "x", find_by: :id do
          argument :id, GraphQL::Types::ID
        end
        field :list, [type], null: true, authorize: :none, reason: "x"
        field :conn, type.connection_type, null: true, authorize: :none, reason: "x"
        field :loaded, String, null: true, authorize: :none, reason: "x" do
          argument :invoice_id, GraphQL::Types::ID, loads: type
        end
        def list = Invoice.all
        def conn = Invoice.all
        def loaded(invoice:) = invoice.number
      end
    end

    let(:alice) { world.alice }

    def pundit_schema(type)
      query = invoice_query(type)
      schema_for(query: query, adapter: :pundit)
    end

    [{ observe: "rollout" }, { observe: "rollout", scope: :in_memory }].each do |rule|
      it "[security] find_by and loads: a foreign id looks missing, list and connection lose it (S13, S15, #{rule.keys.join('+')})" do
        schema = pundit_schema(invoice_type(**rule))
        b1 = world.b1
        user = { current_user: alice }
        expect(run(schema, "{ byId(id: \"#{b1.id}\") { number } }", context: user).dig("data", "byId")).to be_nil

        foreign = run(schema, "{ loaded(invoiceId: \"#{b1.id}\") }", context: user)
        missing = run(schema, "{ loaded(invoiceId: \"99999\") }", context: user)
        expect(foreign.to_s).not_to include("B-1")
        expect(foreign.to_s.gsub(b1.id.to_s, "ID")).to eq(missing.to_s.gsub("99999", "ID"))

        unless rule[:scope] == :in_memory
          expect(run(schema, "{ list { number } }", context: user).dig("data", "list").map { |row| row["number"] }).to contain_exactly("A-1", "A-2")
          expect(run(schema, "{ conn { nodes { number } } }", context: user).dig("data", "conn", "nodes").map { |row| row["number"] }).to contain_exactly("A-1", "A-2")
        end
      end
    end

    it "[security] an in-memory scope with loads: on a resolver stays enforced (S16)" do
      type = invoice_type(observe: "rollout", scope: :in_memory)
      resolver = Class.new(base_resolver) do
        graphql_name "PeekInvoice"
        type String, null: true
        authorize :none, reason: "x"
        argument :invoice_id, GraphQL::Types::ID, loads: type
        def resolve(invoice:) = invoice.number
      end
      query = obj("Query") do
        authorize :none, reason: "root", covers_fields: true
        field :peek, resolver: resolver
      end
      schema = schema_for(query: query, adapter: :pundit)
      expect(run(schema, "{ peek(invoiceId: \"#{world.b1.id}\") }", context: { current_user: alice }).to_s).not_to include("B-1")
    end

    it "[security] an input object's loads: stays in the scope (S16b)" do
      type = invoice_type(observe: "rollout")
      plugin = armory
      input = Class.new(GraphQL::Schema::InputObject) do
        include plugin::Base
        graphql_name "PickInput"
        argument :invoice_id, GraphQL::Types::ID, loads: type
      end
      query = obj("Query") do
        authorize :none, reason: "root", covers_fields: true
        field :pick, String, null: true, authorize: :none, reason: "x" do
          argument :input, input
        end
        def pick(input:) = input[:invoice].number
      end
      schema = schema_for(query: query, adapter: :pundit)
      expect(run(schema, "{ pick(input: {invoiceId: \"#{world.b1.id}\"}) }", context: { current_user: alice }).to_s).not_to include("B-1")
    end

    it "[security] a mutation with loads: under observe refuses a foreign id and runs nothing (S16c)" do
      type = invoice_type(observe: "rollout")
      ran = []
      mutation_class = Class.new(base_mutation) do
        graphql_name "Approve"
        authorize :approve, model: Invoice
        argument :invoice_id, GraphQL::Types::ID, loads: type
        field :ok, GraphQL::Types::Boolean, null: true, authorize: :none, reason: "x"
        define_method(:resolve) do |invoice:|
          ran << invoice
          { ok: true }
        end
      end
      root = obj("Mutation") do
        authorize :none, reason: "root", covers_fields: true
        field :approve, mutation: mutation_class
      end
      schema = schema_for(query: invoice_query(type), mutation: root, adapter: :pundit)
      run(schema, "mutation { approve(invoiceId: \"#{world.b1.id}\") { ok } }", context: { current_user: alice })
      run(schema, "mutation { approve(invoiceId: \"#{world.a1.id}\") { ok } }", context: { current_user: alice })
      expect(ran).to be_empty
    end

    it "[preservation] relay node(id:) is a single read: served and recorded (S26b)" do
      type = invoice_type(observe: "rollout")
      type.implements(GraphQL::Types::Relay::Node)
      query = obj("Query") do
        authorize :none, reason: "root", covers_fields: true
        include GraphQL::Types::Relay::HasNodeField
      end
      schema = schema_for(query: query, adapter: :pundit, resolve: ->(_o) { type }, orphans: [type]) do
        define_singleton_method(:object_from_id) { |id, _context| Invoice.find_by(id: id) }
        define_singleton_method(:id_from_object) { |o, _t, _c| o.id.to_s }
      end
      response = run(schema, "{ node(id: \"#{world.b1.id}\") { ... on Invoice { number } } }", context: { current_user: alice })
      expect(response.to_s).to include("B-1")
      expect(kinds).to include(:observed)
    end

    it "[security] visible_when: on an observed type and field still hides (S34b)" do
      adapter = armory::Adapters::Substitute.new(allow: false, scoped: ->(_items) { [] })
      type = obj("Doc") do
        authorize :read, model: ObsProbe::Doc, observe: "rollout"
        field :secret, String, null: true, authorize: :manage, observe: "why", visible_when: :export
        field :plain, String, null: true
        def plain = "plain"
      end
      hidden = obj("Hidden") do
        authorize :read, model: ObsProbe::Doc, observe: "rollout", visible_when: :export
        field :secret, String, null: true
      end
      query = obj("Query") do
        authorize :none, reason: "root", covers_fields: true
        field :doc, type, null: true, authorize: :none, reason: "x"
        field :hidden, hidden, null: true, authorize: :none, reason: "x"
        def doc = context[:record]
        def hidden = context[:record]
      end
      schema = schema_for(query: query, adapter: adapter)
      expect(run(schema, "{ doc { secret } }").to_s).not_to include("SECRET")
      expect(run(schema, "{ hidden { secret } }").to_s).not_to include("SECRET")
    end

    it "[preservation] CanCan real ability: list scope via accessible_by, read of an in-scope row on a manage field observed (S46)" do
      type = obj("Invoice") do
        authorize :read, model: Invoice, observe: "rollout"
        field :number, String, null: true
        field :internal_notes, String, null: true, authorize: :manage, observe: "why"
      end
      query = obj("Query") do
        authorize :none, reason: "root", covers_fields: true
        field :list, [type], null: true, authorize: :none, reason: "x"
        def list = Invoice.all
      end
      schema = schema_for(query: query, adapter: :cancan)
      response = run(schema, "{ list { number internalNotes } }", context: { current_user: alice })
      expect(response.dig("data", "list").map { |row| row["number"] }).to contain_exactly("A-1", "A-2")
      expect(response.to_s).to include("secret A-1")
      expect(kinds).to include(:observed)
    end
  end

  # ---- Placement in the audit

  def plain_query(type = nil, &blk)
    t = type
    obj("Query") do
      authorize :none, reason: "root", covers_fields: true
      field :doc, t, null: true, authorize: :none, reason: "x" if t
      class_eval(&blk) if blk
      def doc = context[:record]
    end
  end

  it "[security] inherited rule reported, subclass override enforces (S29)" do
    parent = observed_doc("Parent")
    child = Class.new(parent) { graphql_name "Child" }
    overriding = Class.new(parent) do
      graphql_name "Overriding"
      authorize :read, model: ObsProbe::Doc
    end
    query = obj("Query") do
      authorize :none, reason: "root", covers_fields: true
      field :child, child, null: true, authorize: :none, reason: "x"
      field :overriding, overriding, null: true, authorize: :none, reason: "x"
      def child = context[:record]
      def overriding = context[:record]
    end
    schema = schema_for(query: query)
    expect(run(schema, "{ child { secret } overriding { secret } }")["data"]).to eq("child" => { "secret" => "SECRET" }, "overriding" => nil)
    expect(observed_problems(schema)).to include("Child")
    expect(observed_problems(schema)).not_to include("Overriding")
  end

  it "[security] an interface field with observe is reported and served by the implementer (S30)" do
    thing = iface("Thing") { field :secret, String, null: true, authorize: :manage, observe: "why" }
    type = obj("Doc") do
      authorize :read, model: ObsProbe::Doc
      implements thing
    end
    allow_type = armory::Adapters::Substitute.new(allow: false)
    schema = schema_for(query: plain_query(type), adapter: allow_type)
    expect(observed_problems(schema)).to include("Thing.secret", "Doc.secret")
    open_type = obj("Open") do
      authorize :none, reason: "x", covers_fields: true
      implements thing
    end
    open_schema = schema_for(query: plain_query(open_type))
    expect(run(open_schema, "{ doc { secret } }").dig("data", "doc", "secret")).to eq("SECRET")
    expect(kinds).to include(:observed)
  end

  it "[security] an overriding redefinition without observe enforces; the shadowed parent stays reported (S31)" do
    parent = obj("Parent") do
      authorize :read, model: ObsProbe::Doc, observe: "x"
      field :secret, String, null: true, authorize: :manage, observe: "why"
    end
    child = Class.new(parent) do
      graphql_name "Child"
      field :secret, String, null: true, authorize: :manage, override_reason: "stricter"
    end
    schema = schema_for(query: plain_query(child))
    expect(run(schema, "{ doc { secret } }").dig("data", "doc", "secret")).to be_nil
    expect(observed_problems(schema)).to include("Child.secret")
  end

  it "[security] edge, connection and PageInfo holding a rule or a field are reported (S32)" do
    bf = base_field
    plugin = armory
    edge = Class.new(GraphQL::Types::Relay::BaseEdge) do
      include plugin::Base
      field_class bf
      graphql_name "BaseThingEdge"
      authorize :read, model: ObsProbe::Doc, observe: "edge"
      field :weight, String, null: true, authorize: :manage, observe: "edgefield"
    end
    connection = Class.new(GraphQL::Types::Relay::BaseConnection) do
      include plugin::Base
      field_class bf
      graphql_name "BaseThingConnection"
      authorize :read, model: ObsProbe::Doc, observe: "conn"
      field :total, String, null: true, authorize: :manage, observe: "connfield"
    end
    page_info = Class.new(GraphQL::Types::Relay::PageInfo) do
      field_class bf
      graphql_name "MyPageInfo"
      field :extra, String, null: true, authorize: :manage, observe: "pageinfo"
    end
    type = enforced_doc
    edge.node_type(type)
    connection.edge_type(edge)
    query = obj("Query") do
      authorize :none, reason: "root", covers_fields: true
      field :docs, connection, null: true, authorize: :none, reason: "x"
      field :info, page_info, null: true, authorize: :none, reason: "x"
    end
    schema = schema_for(query: query)
    expect(observed_problems(schema)).to include("BaseThingEdge", "BaseThingEdge.weight", "BaseThingConnection", "BaseThingConnection.total", "MyPageInfo.extra")
  end

  it "[security] install-template shape: an observed BaseObject reaches its own edge and connection, all reported (S32b)" do
    bo = Class.new(base_object) { authorize :read, model: ObsProbe::Doc, observe: "everything" }
    base_edge = Class.new(bo) do
      graphql_name "BaseEdge"
      include GraphQL::Types::Relay::EdgeBehaviors
    end
    base_connection = Class.new(bo) do
      graphql_name "BaseConnection"
      include GraphQL::Types::Relay::ConnectionBehaviors
    end
    bo.edge_type_class(base_edge)
    bo.connection_type_class(base_connection)
    type = Class.new(bo) do
      graphql_name "Doc"
      field :secret, String, null: true
    end
    query = obj("Query") do
      authorize :none, reason: "root", covers_fields: true
      field :docs, type.connection_type, null: true, authorize: :none, reason: "x"
      def docs = [context[:record]]
    end
    adapter = armory::Adapters::Substitute.new(allow: false, scoped: ->(_items) { [] })
    schema = schema_for(query: query, adapter: adapter)
    expect(observed_problems(schema)).to include("Doc", "DocConnection", "DocEdge")
    expect(run(schema, "{ docs { nodes { secret } edges { node { secret } } } }").to_s).not_to include("SECRET")
  end

  it "[security] a field on a bypassed type, a __ named type and introspection(true) type are reported (S33)" do
    bypassed = obj("Bypassed") do
      authorize :none, reason: "x"
      field :secret, String, null: true, authorize: :manage, observe: "why"
    end
    dunder = obj("__Hidden") do
      authorize :read, model: ObsProbe::Doc, observe: "dunder"
      introspection(true)
      field :secret, String, null: true
    end
    flagged = obj("Flagged") do
      authorize :read, model: ObsProbe::Doc, observe: "flag"
      introspection(true)
      field :secret, String, null: true
    end
    query = obj("Query") do
      authorize :none, reason: "root", covers_fields: true
      field :a, bypassed, null: true, authorize: :none, reason: "x"
      field :b, dunder, null: true, authorize: :none, reason: "x"
      field :c, flagged, null: true, authorize: :none, reason: "x"
      def a = context[:record]
      def b = context[:record]
      def c = context[:record]
    end
    schema = schema_for(query: query)
    expect(observed_problems(schema)).to include("Bypassed.secret", "__Hidden", "Flagged")
  end

  it "[security] hidden, orphan, union-only, interface-only and loads-only types are reported (S34)" do
    hidden = observed_doc("HiddenDoc")
    hidden.define_singleton_method(:visible?) { |_context| false }
    hidden_field_type = obj("HiddenField") do
      authorize :none, reason: "x"
      field :secret, String, null: true, authorize: :manage, observe: "why"
    end
    hidden_field_type.fields["secret"].define_singleton_method(:visible?) { |_context| false }
    orphan = observed_doc("OrphanDoc")
    in_union = observed_doc("UnionDoc")
    union = Class.new(GraphQL::Schema::Union) do
      graphql_name "U"
      possible_types in_union
    end
    thing = iface("OnlyThing") { field :id, String, null: true }
    implementer = observed_doc("ImplDoc")
    implementer.implements(thing)
    loads_only = observed_doc("LoadsDoc")
    query = obj("Query") do
      authorize :none, reason: "root", covers_fields: true
      field :hidden, hidden, null: true, authorize: :none, reason: "x"
      field :hf, hidden_field_type, null: true, authorize: :none, reason: "x"
      field :u, union, null: true, authorize: :none, reason: "x"
      field :i, thing, null: true, authorize: :none, reason: "x"
      field :l, String, null: true, authorize: :none, reason: "x" do
        argument :doc_id, GraphQL::Types::ID, loads: loads_only
      end
    end
    schema = schema_for(query: query, orphans: [orphan, implementer])
    expect(observed_problems(schema)).to include("HiddenDoc", "HiddenField.secret", "OrphanDoc", "UnionDoc", "ImplDoc", "LoadsDoc")
  end

  it "[security] a type reached only by a directive argument's loads: is reported (S34c)" do
    loads_only = observed_doc("DirDoc")
    input = Class.new(GraphQL::Schema::InputObject) do
      graphql_name "DirInput"
      argument :doc_id, GraphQL::Types::ID, loads: loads_only, required: false
    end
    directive_class = Class.new(GraphQL::Schema::Directive) do
      graphql_name "dir"
      locations GraphQL::Schema::Directive::FIELD
      argument :input, input, required: false
    end
    schema = schema_for(query: plain_query(enforced_doc)) { directive(directive_class) }
    expect(observed_problems(schema)).to include("DirDoc")
  end

  def custom_introspection(holder, field_name)
    bf = base_field
    Module.new.tap do |mod|
      built_in = GraphQL::Introspection.const_get(holder)
      mod.const_set(holder, wire(Class.new(built_in) do
        field_class bf
        graphql_name holder.to_s
        field field_name, String, null: true, camelize: false, authorize: :manage, observe: "custom"
        define_method(field_name) { "SECRET" }
      end))
    end
  end

  it "[security] a custom EntryPoints field with observe has audit kind :observed (S35)" do
    mod = custom_introspection(:EntryPoints, :__secret_entry)
    schema = schema_for(query: plain_query(enforced_doc)) { introspection(mod) }
    response = run(schema, "{ __secret_entry }")
    expect(response.to_s).to include("SECRET")
    report = audit(schema)
    expect(report.ok?).to be(false)
    aggregate_failures do
      expect(report.problems.map(&:kind)).to include(:observed)
      # A baseline must not be able to accept it.
      expect { armory::Audit::Baseline.from(report) }.to raise_error(armory::ConfigurationError)
    end
  end

  it "[security] a custom DynamicFields field with observe has audit kind :observed (S36)" do
    mod = custom_introspection(:DynamicFields, :__secret_dynamic)
    schema = schema_for(query: plain_query(enforced_doc)) { introspection(mod) }
    response = run(schema, "{ __secret_dynamic }")
    expect(response.to_s).to include("SECRET")
    report = audit(schema)
    expect(report.ok?).to be(false)
    aggregate_failures do
      expect(report.problems.map(&:kind)).to include(:observed)
      expect { armory::Audit::Baseline.from(report) }.to raise_error(armory::ConfigurationError)
    end
  end

  it "[security] the demonstration: a baseline accepts a custom entry point under observe, and the refused user is served (S35b)" do
    mod = custom_introspection(:EntryPoints, :__secret_entry)
    schema = schema_for(query: plain_query(enforced_doc)) { introspection(mod) }
    report = audit(schema)
    baseline = begin
      armory::Audit::Baseline.from(report)
    rescue armory::ConfigurationError
      nil
    end
    expect(baseline&.(report)&.passes?).not_to be(true)
  end

  it "[security] a field with observe on a custom introspection TYPE is reported (S36b)" do
    bf = base_field
    mod = Module.new
    mod.const_set(:TypeType, wire(Class.new(GraphQL::Introspection::TypeType) do
      field_class bf
      graphql_name "__Type"
      field :__secret, String, null: true, camelize: false, authorize: :manage, observe: "custom"
      define_method(:__secret) { "SECRET" }
    end))
    schema = schema_for(query: plain_query(enforced_doc)) { introspection(mod) }
    expect(run(schema, '{ __type(name: "Doc") { __secret } }').to_s).to include("SECRET")
    expect(audit(schema).problems.map(&:kind)).to include(:observed)
  end

  it "[security] a mutation's payload field and a subscription root field are reported (S37)" do
    mutation_class = Class.new(base_mutation) do
      graphql_name "Pay"
      authorize :none, reason: "x"
      field :secret, String, null: true, authorize: :manage, observe: "payload"
    end
    root = obj("Mutation") do
      authorize :none, reason: "root", covers_fields: true
      field :pay, mutation: mutation_class
    end
    sub = obj("Subscription") do
      authorize :none, reason: "root", covers_fields: true
      field :tick, String, null: true, authorize: :manage, observe: "sub"
    end
    schema = schema_for(query: plain_query(enforced_doc), mutation: root, subscription: sub)
    expect(observed_problems(schema)).to include("PayPayload.secret", "Subscription.tick")
  end

  it "[security] no plugin: reported as both, and the query raises (S38)" do
    type = observed_doc
    query = root_with("Query", type)
    schema = Class.new(ArmoryEngine.base_schema) { self.query(query) }
    kinds = audit(schema).problems.map(&:kind)
    expect(kinds).to include(:plugin, :observed)
    expect(served?(schema, "{ doc { secret } }")).to be(false)
  end

  it "[security] a listing error does not hide an observed rule (S39)" do
    observed = observed_doc
    broken = obj("Broken") do
      authorize :read, visible_when: :export
      field :x, String, null: true
    end
    query = obj("Query") do
      authorize :none, reason: "root", covers_fields: true
      field :doc, observed, null: true, authorize: :none, reason: "x"
      field :broken, broken, null: true, authorize: :none, reason: "x"
    end
    schema = schema_for(query: query)
    report = audit(schema)
    expect(report.ok?).to be(false)
    expect(report.problems.map(&:kind)).to include(:observed)
  end

  it "[security] a schema subclass inherits sinks and adapter, its own `use` wins (S40, S49)" do
    query = root_with("Query", observed_doc)
    parent = schema_for(query: query)
    child = Class.new(parent)
    expect(served?(child, "{ doc { secret } }")).to be(true)
    expect(observed_problems(child)).to include("Doc")
    plugin = armory
    adapter = refuse
    muted = Class.new(parent) { use plugin, adapter: adapter, sinks: [] }
    expect(served?(muted, "{ doc { secret } }")).to be(false)
    null_child = Class.new(parent) { use plugin, adapter: plugin::Adapters::Null.new, sinks: [->(_s, _d) {}] }
    expect(served?(null_child, "{ doc { secret } }")).to be(false)
    expect(observed_problems(muted)).to include("Doc")
  end

  # ---- Adapters

  def pundit_type(action: :read, model: ObsProbe::Doc)
    obj("Doc") do
      authorize action, model: model, observe: "rollout"
      field :secret, String, null: true
    end
  end

  it "[security] Pundit: a false and a nil policy are observed, with a nil user (S44)" do
    schema = schema_for(query: root_with("Query", pundit_type), adapter: :pundit)
    expect(served?(schema, "{ doc { secret } }", context: { current_user: nil })).to be(true)
    expect(kinds).to eq([:observed])
    signals.clear
    schema2 = schema_for(query: root_with("Query", pundit_type(action: :manage)), adapter: :pundit)
    expect(served?(schema2, "{ doc { secret } }")).to be(true)
  end

  it "[security] Pundit: missing policy, missing method, non-boolean, raising policy do not serve (S41-S43)" do
    aggregate_failures do
      schema = schema_for(query: root_with("Query", pundit_type(model: ObsProbe::NoPolicyDoc)), adapter: :pundit)
      expect(served?(schema, "{ doc { secret } }", context: { record: ObsProbe::NoPolicyDoc.new("1", "SECRET") })).to be(false)
      %i[missing_action weird boom].each do |action|
        schema = schema_for(query: root_with("Query", pundit_type(action: action)), adapter: :pundit)
        expect(served?(schema, "{ doc { secret } }")).to be(false)
      end
      expect(kinds).not_to include(:observed)
    end
  end

  it "[security] Pundit: a field rule with a raising policy, an unknown policy or a weird answer does not serve (S41b)" do
    aggregate_failures do
      %i[missing_action weird boom].each do |action|
        type = obj("Doc") do
          authorize :allow, model: ObsProbe::Doc
          field :secret, String, null: true, authorize: action, observe: "why"
        end
        schema = schema_for(query: root_with("Query", type), adapter: :pundit)
        expect(served?(schema, "{ doc { secret } }")).to be(false)
      end
    end
  end

  it "[security] Pundit: a Symbol subject (client text) does not serve (S45)" do
    type = obj("Tag") do
      authorize :read, model: ObsProbe::Doc, observe: "rollout"
      field :text, String, null: true
      def text = "SECRET"
    end
    query = obj("Query") do
      authorize :none, reason: "root", covers_fields: true
      field :tag, type, null: true, authorize: :none, reason: "x"
      def tag = :doc
    end
    schema = schema_for(query: query, adapter: :pundit)
    expect(served?(schema, "{ tag { text } }")).to be(false)
  end

  it "[security] CanCan: an ability that cannot build, and a Pundit-only option, do not serve (S46b)" do
    failing = Class.new { def initialize(_user) = raise("no ability") }
    schema = schema_for(query: root_with("Query", observed_doc), adapter: armory::Adapters::CanCan.new(ability_class: failing))
    expect(served?(schema, "{ doc { secret } }")).to be(false)
    type = obj("Doc") do
      authorize :read, model: ObsProbe::Doc, observe: "rollout", policy: ObsProbe::DocPolicy
      field :secret, String, null: true
    end
    schema = schema_for(query: root_with("Query", type), adapter: armory::Adapters::CanCan.new(ability_class: ObsProbe::EmptyAbility))
    expect(served?(schema, "{ doc { secret } }")).to be(false)
  end

  it "[security] Authorize used directly: inert new, no sinks, a context with no query (S50)" do
    rule = armory::Rule.new(:read, observe: "why")
    query = root_with("Query", observed_doc)
    schema = schema_for(query: query)
    ctx = GraphQL::Query.new(schema, "{ __typename }", context: {}).context
    expect(armory::Authorize.new.(record, rule, ctx)).to be(false)
    expect(armory::Authorize.new(adapter: refuse).(record, rule, ctx)).to be(false)
    expect(armory::Authorize.call(record, rule, ctx, adapter: refuse, sinks: [])).to be(false)
    telemetry = GraphQL::Armory::Telemetry::Substitute.new
    expect(armory::Authorize.new(adapter: refuse, telemetry: telemetry).(record, rule, {})).to be(false)
    expect(armory::Authorize.new(adapter: refuse, telemetry: telemetry).(record, rule, nil)).to be(false)
    expect(telemetry.recorded?(:observed)).to be(false)
    expect(armory::Authorize.new(adapter: armory::Adapters::Null.new, telemetry: telemetry).(record, rule, ctx)).to be(false)
    expect(armory::Authorize.new(adapter: refuse, telemetry: telemetry).(record, rule, ctx)).to be(true)
    expect(telemetry.recorded?(:observed)).to be(true)
  end

  it "[preservation] an allowed read records :allowed, not :observed (S51)" do
    adapter = armory::Adapters::Substitute.new(allow: true)
    expect(served?(schema_for(query: root_with("Query", observed_doc), adapter: adapter), "{ doc { secret } }")).to be(true)
    expect(kinds).to eq([:allowed])
  end

  # ---- Declaration

  it "[security] declaration: false, symbol, number refuse on type and field (S52)" do
    [false, :rollout, 1, [], "   ", ""].each do |bad|
      expect { armory::Rule.new(:read, observe: bad) }.to raise_error(ArgumentError)
      bf = base_field
      expect { obj("X") { field :a, String, authorize: :manage, observe: bad, null: true } }.to raise_error(ArgumentError), "field with #{bad.inspect}"
      expect(bf).to be_a(Class)
    end
  end

  it "[preservation] observe: nil is the same as absent on a type and a field, and on a resolver raises (S54)" do
    type = obj("Doc") do
      authorize :read, model: ObsProbe::Doc, observe: nil
      field :secret, String, null: true
      field :notes, String, null: true, observe: nil
      field :other, String, null: true, authorize: :manage, observe: nil
    end
    schema = schema_for(query: root_with("Query", type))
    expect(served?(schema, "{ doc { secret } }")).to be(false)
    expect(audit(schema).problems.map(&:kind)).not_to include(:observed)
    resolver = base_resolver
    expect { Class.new(resolver) { authorize :read, model: ObsProbe::Doc, observe: nil } }.to raise_error(ArgumentError)
  end

  it "[security] declaration: authorize forms that cannot hold it raise on a field (S55)" do
    [true, :none, nil, "manage", "none", false].each do |form|
      expect { obj("X") { field :a, String, null: true, authorize: form, reason: "r", observe: "why" } }.to raise_error(ArgumentError), "accepted authorize: #{form.inspect}"
    end
    expect { obj("X") { authorize :none, reason: "x", observe: "why" } }.to raise_error(ArgumentError)
    expect { obj("X") { authorize :none, reason: "x", covers_fields: true, observe: "why" } }.to raise_error(ArgumentError)
    expect { armory::Rule.none(reason: "r").enforced }.not_to raise_error
  end

  it "[security] declaration: an input object has no authorize; a resolver subclass cannot get it from a parent type (S56)" do
    plugin = armory
    expect { Class.new(GraphQL::Schema::InputObject) { include plugin::Base; authorize :read, observe: "x" } }.to raise_error(NoMethodError)
    resolver = base_resolver
    expect { Class.new(resolver) { authorize :read, model: ObsProbe::Doc, observe: "why" } }.to raise_error(ArgumentError)
    mutation = base_mutation
    expect { Class.new(mutation) { authorize :read, model: ObsProbe::Doc, observe: "why" } }.to raise_error(ArgumentError)
  end

  # ---- Field checks

  it "[security] the app's own authorized? still decides: type and field (S58)" do
    type = obj("Doc") do
      authorize :read, model: ObsProbe::Doc, observe: "rollout"
      field :secret, String, null: true
      def self.authorized?(_object, _context) = false
    end
    bf = Class.new(base_field) do
      def authorized?(_object, _args, _context) = false
    end
    field_type = Class.new(base_object) do
      field_class bf
      graphql_name "FieldDoc"
      authorize :none, reason: "x", covers_fields: true
      field :secret, String, null: true, authorize: :manage, observe: "why"
    end
    expect(served?(schema_for(query: root_with("Query", type)), "{ doc { secret } }")).to be(false)
    expect(served?(schema_for(query: root_with("Query", field_type)), "{ doc { secret } }")).to be(false)

    guarded = Class.new(base_field) do
      def authorized?(object, args, context)
        super && false
      end
    end
    guarded_type = Class.new(base_object) do
      field_class guarded
      graphql_name "GuardedDoc"
      authorize :none, reason: "x", covers_fields: true
      field :secret, String, null: true, authorize: :manage, observe: "why"
    end
    expect(served?(schema_for(query: root_with("Query", guarded_type)), "{ doc { secret } }")).to be(false)
    expect(type.method(:authorized?).owner).to eq(type.singleton_class)
    expect(observed_doc.method(:authorized?).owner).to eq(armory::Integration::Object)
    expect(base_field.instance_method(:authorized?).owner).to eq(armory::Integration::Field)
  end

  it "[security] on_unauthorized :error and :raise: query serves, mutation answers by its mode (S59)" do
    type = observed_doc
    %i[error raise].each do |mode|
      schema = schema_for(query: root_with("Query", type), mutation: root_with("Mutation", type), on_unauthorized: mode)
      expect(served?(schema, "{ doc { secret } }")).to be(true)
      expect(served?(schema, "mutation { doc { secret } }")).to be(false)
    end
    schema = schema_for(query: root_with("Query", type), mutation: root_with("Mutation", type), on_unauthorized: :error)
    expect(run(schema, "mutation { doc { secret } }")["errors"].first["message"]).to eq("Not found")
    schema = schema_for(query: root_with("Query", type), mutation: root_with("Mutation", type), on_unauthorized: :raise)
    expect { run(schema, "mutation { doc { secret } }") }.to raise_error(armory::NotAuthorizedError)
  end

  it "[security] a non-null field: query serves, mutation fails without the value (S60)" do
    type = obj("Doc") do
      authorize :none, reason: "x", covers_fields: true
      field :secret, String, null: false, authorize: :manage, observe: "why"
    end
    schema = schema_for(query: root_with("Query", type), mutation: root_with("Mutation", type))
    expect(run(schema, "{ doc { secret } }").dig("data", "doc", "secret")).to eq("SECRET")
    response = run(schema, "mutation { doc { secret } }")
    expect(response.to_s).not_to include("SECRET")
    expect(response["errors"].first["message"]).to eq("Not found")
  end

  it "[security] rescue_from answering true does not serve on an adapter failure (S61)" do
    raising = armory::Adapters::Substitute.new(raises: RuntimeError.new("boom"))
    schema = schema_for(query: root_with("Query", observed_doc), adapter: raising) do
      rescue_from(RuntimeError) { |_error, *_rest| true }
    end
    expect(served?(schema, "{ doc { secret } }")).to be(false)
  end

  # ---- Telemetry

  it "[security] the signal holds a class name, the action and the reason, and no record data (S63)" do
    schema = schema_for(query: root_with("Query", observed_doc))
    run(schema, "query($unused: String) { doc { secret @include(if: true) ... on Doc { __typename } } __typename @skip(if: false) ok: __typename } ", variables: { "unused" => "CLIENT-VAR" }, validate: false)
    signal, data = signals.reject { |s, _| s == :bypassed }.first
    expect(signal).to eq(:observed)
    expect(data).to eq(type: "ObsProbe::Doc", action: :read, reason: "rollout")
    expect(signals.to_s).not_to include("SECRET", "CLIENT-VAR")

    # A record whose `class` is a data member: only the real class is named.
    hostile = Struct.new(:class, :secret).new("CLIENT-TEXT", "SECRET")
    telemetry = GraphQL::Armory::Telemetry::Substitute.new
    ctx = GraphQL::Query.new(schema, "{ __typename }", context: {}).context
    expect(armory::Authorize.new(adapter: refuse, telemetry: telemetry).(hostile, armory::Rule.new(:read, observe: "why"), ctx)).to be(true)
    expect(telemetry.recorded.to_s).not_to include("CLIENT-TEXT", "SECRET")
  end

  it "[security] a sink cannot change what the next sink or the rule sees (S64)" do
    reason = +"rollout"
    type = obj("Doc") do
      authorize :read, model: ObsProbe::Doc, observe: reason
      field :secret, String, null: true
    end
    errors = []
    second = []
    mutator = ->(_signal, data) { data[:reason] << "x" }
    schema = Class.new(ArmoryEngine.base_schema)
    query = root_with("Query", type)
    adapter = refuse
    plugin = armory
    schema.class_eval do
      self.query(query)
      use plugin, adapter: adapter, sinks: [mutator, ->(_s, d) { second << d }], on_sink_error: ->(error, _signal) { errors << error.class }
    end
    expect(served?(schema, "{ doc { secret } }")).to be(true)
    expect(errors.uniq).to eq([FrozenError])
    observed = second.find { |data| data[:action] }
    expect(observed[:reason]).to eq("rollout")
    expect(reason).to eq("rollout")
    expect(observed).to be_frozen
  end

  it "[security] an on_sink_error that raises does not serve (S65)" do
    plugin = armory
    adapter = refuse
    query = root_with("Query", observed_doc)
    schema = Class.new(ArmoryEngine.base_schema) do
      self.query(query)
      use plugin, adapter: adapter, sinks: [->(_s, _d) { raise "sink" }], on_sink_error: ->(_e, _s) { raise "handler" }
    end
    expect(served?(schema, "{ doc { secret } }")).to be(false)
  end

  it "[preservation] one :observed per subject and rule, no :denied next to it (S66)" do
    schema = schema_for(query: root_with("Query", observed_doc))
    run(schema, "{ a: doc { secret } b: doc { secret } }")
    expect(kinds).to eq([:observed])
  end

  # ---- Baseline

  it "[security] a baseline from before observe: fails after it (S67, S70)" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "baseline.json")
      enforced = schema_for(query: root_with("Query", enforced_doc))
      armory::Audit::Baseline.write(audit(enforced), path)
      observed = schema_for(query: root_with("Query", observed_doc))
      expect(armory::Audit::Baseline.load(path).(audit(observed)).passes?).to be(false)
      expect(observed).not_to be_fully_authorized
      expect(observed).not_to be_fully_authorized(baseline: path)
    end
  end

  it "[security] a hand-edited entry raises at load; rake answers 1 (S68)" do
    Dir.mktmpdir do |dir|
      schema = schema_for(query: root_with("Query", observed_doc))
      problem = audit(schema).problems.find { |item| item.kind == :observed }
      path = File.join(dir, "baseline.json")
      File.write(path, JSON.generate("version" => 1, "problems" => [{ "kind" => "observed", "path" => problem.path, "message" => problem.message }]))
      expect { armory::Audit::Baseline.load(path) }.to raise_error(armory::ConfigurationError)

      ObsProbe.send(:remove_const, :Sch) if ObsProbe.const_defined?(:Sch)
      ObsProbe.const_set(:Sch, schema)
      out = StringIO.new
      expect(armory::Audit::Command.new(out: out).("ObsProbe::Sch", path)).to eq(1)
      expect(armory::Audit::Command.new(out: StringIO.new).("ObsProbe::Sch")).to eq(1)
    end
  end

  it "[security] writing a baseline with an observed rule refuses and leaves the file alone (S69)" do
    Dir.mktmpdir do |dir|
      schema = schema_for(query: root_with("Query", observed_doc))
      path = File.join(dir, "baseline.json")
      expect { armory::Audit::Baseline.write(audit(schema), path) }.to raise_error(armory::ConfigurationError)
      expect(File.exist?(path)).to be(false)

      File.write(path, "{\"version\":1,\"problems\":[]}")
      ObsProbe.send(:remove_const, :Sch2) if ObsProbe.const_defined?(:Sch2)
      ObsProbe.const_set(:Sch2, schema)
      expect(armory::Audit::Command.new(out: StringIO.new).write_baseline("ObsProbe::Sch2", path)).to eq(1)
      expect(File.read(path)).to eq("{\"version\":1,\"problems\":[]}")
    end
  end

  it "[security] Baseline.new with an entry kind as a Symbol cannot accept it (S71)" do
    schema = schema_for(query: root_with("Query", observed_doc))
    report = audit(schema)
    problem = report.problems.find { |item| item.kind == :observed }
    entry = armory::Audit::Baseline::Entry.new(:observed, problem.path, problem.message, 1, report.reach_of(problem))
    expect(armory::Audit::Baseline.new([entry]).(report).passes?).to be(false)
  end

  # ---- Preservation

  it "[preservation] a schema with no observe refuses as before and records :denied (K72)" do
    type = enforced_doc
    schema = schema_for(query: root_with("Query", type), mutation: root_with("Mutation", type))
    expect(run(schema, "{ doc { secret } }").dig("data", "doc")).to be_nil
    expect(kinds).to eq([:denied])
    expect(audit(schema).problems.map(&:kind)).not_to include(:observed)
    expect(signals.reject { |s, _| s == :bypassed }.first.last.keys).to contain_exactly(:type, :action)
  end

  it "[preservation] a Telemetry with no sinks is not listening, one with sinks is (K74)" do
    expect(GraphQL::Armory::Telemetry.new.listening?).to be(false)
    expect(GraphQL::Armory::Telemetry.new(sinks: [->(_s, _d) {}]).listening?).to be(true)
  end
end
