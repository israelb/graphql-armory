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

RSpec.describe "observe: recheck B1 B3 B4 B2-docs" do
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
  rescue GraphQL::Armory::Authorization::ConfigurationError => error
    { "raised" => error.message } # a type holding a resolver cannot be observed
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

  def with_subscriptions
    plugin = Class.new(GraphQL::Subscriptions) do
      def write_subscription(_query, _events) = nil
      def execute_all(_event, _object) = nil
    end
    proc { use plugin }
  end
  def list_query(field_type)
    obj("Query") do
      authorize :none, reason: "root", covers_fields: true
      field :docs, field_type, null: true, authorize: :none, reason: "x"
      def docs = [context[:record]]
    end
  end
  def plain_query(type = nil, &blk)
    t = type
    obj("Query") do
      authorize :none, reason: "root", covers_fields: true
      field :doc, t, null: true, authorize: :none, reason: "x" if t
      class_eval(&blk) if blk
      def doc = context[:record]
    end
  end

  # ---- Environment
  it "[env] reports versions" do
    puts "\nENV graphql=#{GraphQL::VERSION} next=#{ArmoryEngine.next?} partial=#{defined?(GraphQL::Query::Partial).inspect} partial_query=#{defined?(GraphQL::Query::Partial) && GraphQL::Query::Partial.method_defined?(:query)} field_options=#{GraphQL::Schema::Resolver.respond_to?(:field_options)}"
  end

  # ---- B1: Query::Partial
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

  def field_rule_doc
    obj("Doc") do
      authorize :none, reason: "x", covers_fields: true
      field :secret, String, null: true, authorize: :manage, observe: "rollout"
    end
  end

  def partial!
    skip "no Query::Partial" unless defined?(GraphQL::Query::Partial)
  end

  it "[security] B1 partial from a mutation refuses a type rule" do
    partial!
    type = observed_doc
    captured = []
    run(schema_for(query: root_with("Query", type), mutation: partial_root("Mutation", type)), "mutation { doc { secret } }", context: { captured: captured })
    expect(captured).not_to be_empty
    expect(captured.to_s).not_to include("SECRET")
    expect(kinds).to include(:denied)
    expect(kinds).not_to include(:observed)
  end

  it "[security] B1 partial from a mutation refuses a field rule" do
    partial!
    type = field_rule_doc
    captured = []
    run(schema_for(query: root_with("Query", type), mutation: partial_root("Mutation", type)), "mutation { doc { secret } }", context: { captured: captured })
    expect(captured).not_to be_empty
    expect(captured.to_s).not_to include("SECRET")
    expect(kinds).not_to include(:observed)
  end

  it "[security] B1 partial from a subscription refuses" do
    partial!
    type = field_rule_doc
    captured = []
    raised = false
    begin
      run(schema_for(query: root_with("Query", type), subscription: partial_root("Subscription", type), &with_subscriptions), "subscription { doc { secret } }", context: { captured: captured })
    rescue NoMethodError => error
      raise unless error.message.include?("subscription_update?")

      raised = true # graphql-ruby's interpreter raises on a Partial here, so nothing ran.
    end
    puts "
CHAR subscription-partial raised=#{raised} captured=#{captured.size} kinds=#{kinds.inspect}"
    expect(captured).not_to be_empty unless raised
    expect(captured.to_s).not_to include("SECRET")
    expect(kinds).not_to include(:observed)
  end

  it "[preservation] B1 partial from a real query serves and records" do
    partial!
    type = field_rule_doc
    captured = []
    run(schema_for(query: partial_root("Query", type)), "{ doc { secret } }", context: { captured: captured })
    expect(captured.to_s).to include("SECRET")
    expect(kinds).to include(:observed)
  end

  # A partial started inside a partial, through the public run_partials, which goes back to the parent.
  def nesting_root(name, type)
    wrap = obj("Wrap") do
      authorize :none, reason: "x", covers_fields: true
      field :inner, type, null: true, authorize: :none, reason: "x"
      define_method(:inner) do
        context[:captured] << context.query.run_partials([{ path: ["wrap", "inner"], object: context[:record] }]).first.to_h
        nil
      end
    end
    obj(name) do
      authorize :none, reason: "root", covers_fields: true
      field :wrap, wrap, null: true, authorize: :none, reason: "x"
      define_method(:wrap) do
        context[:outer] << context.query.run_partials([{ path: ["wrap"], object: :wrapped }]).first.to_h
        nil
      end
    end
  end

  it "[security] B1 run_partials inside a partial, from a mutation, refuses" do
    partial!
    type = field_rule_doc
    captured = []
    outer = []
    response = run(schema_for(query: root_with("Query", type), mutation: nesting_root("Mutation", type)), "mutation { wrap { inner { secret } } }", context: { captured: captured, outer: outer })
    expect(captured).not_to be_empty
    expect([captured, outer, response].to_s).not_to include("SECRET")
    expect(kinds).not_to include(:observed)
  end

  it "[preservation] B1 run_partials inside a partial, from a query, serves and records" do
    partial!
    type = field_rule_doc
    captured = []
    run(schema_for(query: nesting_root("Query", type)), "{ wrap { inner { secret } } }", context: { captured: captured, outer: [] })
    expect(captured.to_s).to include("SECRET")
    expect(kinds).to include(:observed)
  end

  # Depth two for real: a Partial whose parent is a Partial.
  def deep_partial_root(name, type)
    obj(name) do
      authorize :none, reason: "root", covers_fields: true
      field :doc, type, null: true, authorize: :none, reason: "x"
      define_method(:doc) do
        first = GraphQL::Query::Partial.new(query: context.query, path: ["doc"], object: context[:record])
        second = GraphQL::Query::Partial.new(query: first, object: context[:record], fragment_node: context.query.fragments["F"], type: type)
        context[:depth] << second.query.is_a?(GraphQL::Query::Partial)
        GraphQL::Execution::Interpreter.run_all(context.schema, [second], context: context)
        context[:captured] << second.result.to_h
        nil
      end
    end
  end

  it "[security] B1 a Partial whose parent is a Partial, from a mutation, refuses" do
    partial!
    type = field_rule_doc
    captured = []
    depth = []
    response = run(schema_for(query: root_with("Query", type), mutation: deep_partial_root("Mutation", type)), "mutation { doc { ...F } } fragment F on Doc { secret }", context: { captured: captured, depth: depth })
    expect(depth).to eq([true]), response.to_s
    expect(captured).not_to be_empty
    expect(captured.to_s).not_to include("SECRET")
    expect(kinds).not_to include(:observed)
  end

  it "[preservation] B1 a Partial whose parent is a Partial, from a query, serves" do
    partial!
    type = field_rule_doc
    captured = []
    depth = []
    response = run(schema_for(query: deep_partial_root("Query", type)), "{ doc { ...F } } fragment F on Doc { secret }", context: { captured: captured, depth: depth })
    expect(depth).to eq([true]), response.to_s
    expect(captured.to_s).to include("SECRET")
  end

  it "[security] B1 a fragment_node partial from a mutation refuses" do
    partial!
    type = field_rule_doc
    root = obj("Mutation") do
      authorize :none, reason: "root", covers_fields: true
      field :doc, type, null: true, authorize: :none, reason: "x"
      define_method(:doc) do
        context[:captured] << context.query.run_partials([{ fragment_node: context.query.fragments["F"], type: type, object: context[:record] }]).first.to_h
        nil
      end
    end
    captured = []
    run(schema_for(query: root_with("Query", type), mutation: root), "mutation { doc { ...F } } fragment F on Doc { secret }", context: { captured: captured })
    expect(captured).not_to be_empty
    expect(captured.to_s).not_to include("SECRET")
    expect(kinds).not_to include(:observed)
  end

  def built_query(schema, doc, **options)
    GraphQL::Query.new(schema, doc, context: { record: record, current_user: :x }, **options)
  end

  it "[security] B1 Query.new of a mutation, then run_partials, refuses" do
    partial!
    type = field_rule_doc
    schema = schema_for(query: root_with("Query", type), mutation: root_with("Mutation", type))
    out = built_query(schema, "mutation { doc { secret } }").run_partials([{ path: ["doc"], object: record }]).first.to_h
    expect(out.to_s).not_to include("SECRET")
    expect(kinds).not_to include(:observed)
  end

  it "[security] B1 Query.new of a multi-operation document selecting the mutation, then run_partials, refuses" do
    partial!
    type = field_rule_doc
    schema = schema_for(query: root_with("Query", type), mutation: root_with("Mutation", type))
    out = built_query(schema, "query Q { doc { secret } } mutation M { doc { secret } }", operation_name: "M").run_partials([{ path: ["doc"], object: record }]).first.to_h
    expect(out.to_s).not_to include("SECRET")
    expect(kinds).not_to include(:observed)
  end

  it "[preservation] B1 Query.new of a query, then run_partials, serves and records" do
    partial!
    type = field_rule_doc
    schema = schema_for(query: root_with("Query", type))
    out = built_query(schema, "{ doc { secret } }").run_partials([{ path: ["doc"], object: record }]).first.to_h
    expect(out.to_s).to include("SECRET")
    expect(kinds).to include(:observed)
  end

  it "[preservation] B1 Query.new of a mutation, executed whole, refuses" do
    type = field_rule_doc
    schema = schema_for(query: root_with("Query", type), mutation: root_with("Mutation", type))
    query = built_query(schema, "mutation { doc { secret } }")
    expect(query.result.to_h.to_s).not_to include("SECRET")
    expect(kinds).not_to include(:observed)
  end

  # Not a partial: a resolver running a whole new query of its own. Pins what happens today, for the report.
  it "[characterization] B1 a mutation resolver that runs its own Query.new of a query document" do
    type = field_rule_doc
    root = obj("Mutation") do
      authorize :none, reason: "root", covers_fields: true
      field :doc, type, null: true, authorize: :none, reason: "x"
      define_method(:doc) do
        context[:captured] << GraphQL::Query.new(context.schema, "{ doc { secret } }", context: { record: context[:record], current_user: :x }).result.to_h
        nil
      end
    end
    captured = []
    run(schema_for(query: root_with("Query", type), mutation: root), "mutation { doc { secret } }", context: { captured: captured })
    puts "\nCHAR nested-query served=#{captured.to_s.include?("SECRET")} kinds=#{kinds.inspect}"
  end

  # ---- B3: custom introspection
  def holder_class(holder, field_name, observe: "custom")
    bf = base_field
    built_in = GraphQL::Introspection.const_get(holder)
    options = { authorize: :manage }
    options[:observe] = observe if observe
    wire(Class.new(built_in) do
      field_class bf
      graphql_name holder.to_s
      field field_name, String, null: true, camelize: false, **options
      define_method(field_name) { "SECRET" }
    end)
  end

  def namespace(holder, klass) = Module.new.tap { |mod| mod.const_set(holder, klass) }

  def expect_observed(schema, path)
    report = audit(schema)
    expect(report.ok?).to be(false)
    expect(report.problems.select { |p| p.kind == :observed }.map(&:path)).to eq([path])
    expect { armory::Audit::Baseline.from(report) }.to raise_error(armory::ConfigurationError, /observe/)
  end

  { EntryPoints: :__secret_entry, DynamicFields: :__secret_dynamic }.each do |holder, name|
    it "[security] B3 #{holder} field: :observed exactly once, baseline refuses, field reachable" do
      mod = namespace(holder, holder_class(holder, name))
      schema = schema_for(query: plain_query(enforced_doc)) { introspection(mod) }
      expect(run(schema, "{ #{name} }").to_s).to include("SECRET")
      expect(kinds).to include(:observed)
      expect_observed(schema, "#{holder}.#{name}")
    end

    it "[security] B3 #{holder} subclass inheriting the field: :observed, baseline refuses" do
      parent = holder_class(holder, name)
      sub = Class.new(parent)
      mod = namespace(holder, sub)
      schema = schema_for(query: plain_query(enforced_doc)) { introspection(mod) }
      expect(run(schema, "{ #{name} }").to_s).to include("SECRET")
      expect_observed(schema, "#{holder}.#{name}")
    end

    it "[security] B3 #{holder} a baseline written before observe: was added stops passing" do
      plain = namespace(holder, holder_class(holder, name, observe: nil))
      now = namespace(holder, holder_class(holder, name))
      before_schema = schema_for(query: plain_query(enforced_doc)) { introspection(plain) }
      after_schema = schema_for(query: plain_query(enforced_doc)) { introspection(now) }
      baseline = armory::Audit::Baseline.from(audit(before_schema))
      expect(baseline.(audit(before_schema)).passes?).to be(true)
      expect(baseline.(audit(after_schema)).passes?).to be(false)
    end

    it "[preservation] B3 #{holder} field with no observe: is not :observed" do
      mod = namespace(holder, holder_class(holder, name, observe: nil))
      schema = schema_for(query: plain_query(enforced_doc)) { introspection(mod) }
      expect(observed_problems(schema)).to eq([])
    end

    it "[security] B3 #{holder} a subclass of the schema still reports it" do
      mod = namespace(holder, holder_class(holder, name))
      parent = schema_for(query: plain_query(enforced_doc)) { introspection(mod) }
      expect_observed(Class.new(parent), "#{holder}.#{name}")
    end

    it "[security] B3 #{holder} under Schema::Visibility still reports it" do
      mod = namespace(holder, holder_class(holder, name))
      schema = schema_for(query: plain_query(enforced_doc)) do
        use GraphQL::Schema::Visibility
        introspection(mod)
      end
      expect_observed(schema, "#{holder}.#{name}")
    end
  end

  it "[preservation] B3 no custom introspection: nothing observed, the report stays ok" do
    report = audit(schema_for(query: plain_query(enforced_doc)))
    expect(report.problems.map(&:kind)).not_to include(:observed)
    expect(report.ok?).to be(true), report.problems.map(&:to_a).inspect
  end

  it "[preservation] B3 entry points disabled: unreachable and not reported, no crash" do
    mod = namespace(:EntryPoints, holder_class(:EntryPoints, :__secret_entry))
    schema = schema_for(query: plain_query(enforced_doc)) do
      introspection(mod)
      disable_introspection_entry_points
    end
    expect(observed_problems(schema)).to eq([])
    expect(run(schema, "{ __secret_entry }").to_s).not_to include("SECRET")
  end

  it "[security] B3 a custom introspection TYPE's observed field is reported once" do
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
    puts "
CHAR custom-type-paths #{observed_problems(schema).inspect}"
    expect(observed_problems(schema).uniq).to eq(["__Type.__secret"])
  end

  # ---- B4: resolver-holding fields
  def plain_resolver(ran = [])
    Class.new(GraphQL::Schema::Resolver) do
      graphql_name "Plain"
      type String, null: true
      define_method(:resolve) do
        ran << :side_effect
        "SECRET"
      end
    end
  end

  def mutation_class(ran = [])
    Class.new(base_mutation) do
      graphql_name "Pay"
      authorize :none, reason: "the field decides"
      field :ok, GraphQL::Types::Boolean, null: true, authorize: :none, reason: "x"
      define_method(:resolve) do
        ran << :side_effect
        { ok: true }
      end
    end
  end

  def subscription_class
    Class.new(GraphQL::Schema::Subscription) do
      graphql_name "Tick"
      type String, null: true
    end
  end

  def refuses_declaration(&declaration)
    expect(&declaration).to raise_error(ArgumentError, /resolver or a mutation/)
  end

  it "[security] B4 resolver: raises" do
    r = plain_resolver
    refuses_declaration { obj("Query") { field :x, resolver: r, authorize: :manage, observe: "y" } }
  end

  it "[security] B4 mutation: raises" do
    m = mutation_class
    refuses_declaration { obj("Query") { field :x, mutation: m, authorize: :manage, observe: "y" } }
  end

  it "[security] B4 subscription: raises" do
    s = subscription_class
    refuses_declaration { obj("Query") { field :x, subscription: s, authorize: :manage, observe: "y" } }
  end

  it "[security] B4 resolver: with a positional description raises" do
    r = plain_resolver
    refuses_declaration { obj("Query") { field :x, "desc", resolver: r, authorize: :manage, observe: "y" } }
  end

  it "[security] B4 resolver_class: as a keyword raises" do
    r = plain_resolver
    refuses_declaration { obj("Query") { field :x, resolver_class: r, authorize: :manage, observe: "y" } }
  end

  it "[security] B4 resolver: with a block raises, and the block never runs" do
    r = plain_resolver
    block_ran = []
    refuses_declaration do
      obj("Query") do
        field(:x, resolver: r, authorize: :manage, observe: "y") { block_ran << :ran }
      end
    end
    expect(block_ran).to be_empty
  end

  it "[security] B4 Field.new with resolver_class: and add_field raises" do
    r = plain_resolver
    klass = base_field
    owner = obj("Query")
    refuses_declaration { owner.add_field(klass.new(name: :x, owner: owner, resolver_class: r, authorize: :manage, observe: "y")) }
  end

  it "[security] B4 Resolver.field_options, when graphql has it, raises" do
    skip "graphql has no Resolver.field_options" unless GraphQL::Schema::Resolver.respond_to?(:field_options)
    r = plain_resolver
    refuses_declaration { obj("Query") { field :x, **r.field_options, authorize: :manage, observe: "y" } }
  end

  it "[security] B4 a subclass of the field class raises" do
    r = plain_resolver
    sub = Class.new(base_field)
    refuses_declaration do
      obj("Query") do
        field_class sub
        field :x, resolver: r, authorize: :manage, observe: "y"
      end
    end
  end

  it "[security] B4 a field class that injects the resolver in its own initialize raises" do
    r = plain_resolver
    sub = Class.new(base_field) do
      define_method(:initialize) { |*args, **kwargs, &block| super(*args, resolver_class: r, **kwargs, &block) }
    end
    refuses_declaration do
      obj("Query") do
        field_class sub
        field :x, authorize: :manage, observe: "y"
      end
    end
  end

  it "[security] B4 a field class that renames the keyword raises" do
    r = plain_resolver
    sub = Class.new(GraphQL::Schema::Field) do
      include GraphQL::Armory::Authorization::Base
      define_method(:initialize) { |*args, runs: nil, **kwargs, &block| super(*args, resolver_class: runs, **kwargs, &block) }
    end
    refuses_declaration do
      obj("Query") do
        field_class sub
        field :x, runs: r, authorize: :manage, observe: "y"
      end
    end
  end

  it "[security] B4 an interface field with resolver: raises" do
    r = plain_resolver
    refuses_declaration { iface("Thing") { field :x, resolver: r, authorize: :manage, observe: "y" } }
  end

  it "[preservation] B4 resolver: without observe: still declares, and refuses a refused user" do
    ran = []
    r = plain_resolver(ran)
    query = obj("Query") do
      authorize :none, reason: "root", covers_fields: true
      field :x, resolver: r, authorize: :manage
    end
    expect(run(schema_for(query: query), "{ x }").to_s).not_to include("SECRET")
    expect(ran).to be_empty
  end

  it "[preservation] B4 observe: with a plain resolver_method: declares, serves and records" do
    doc = obj("Doc") do
      authorize :none, reason: "x", covers_fields: true
      field :secret, String, null: true, authorize: :manage, observe: "y", resolver_method: :compute do
        extension(ObsAnswer, name: :compute) if ArmoryEngine.next?
      end
      def compute = "SECRET"
    end
    expect(run(schema_for(query: root_with("Query", doc)), "{ doc { secret } }").to_s).to include("SECRET")
    expect(kinds).to include(:observed)
  end

  it "[preservation] B4 observe: with a block and no resolver declares, serves and records" do
    doc = obj("Doc") do
      authorize :none, reason: "x", covers_fields: true
      field :secret, String, null: true, authorize: :manage, observe: "y" do
        description "d"
        argument :a, String, required: false
      end
    end
    expect(run(schema_for(query: root_with("Query", doc)), "{ doc { secret } }").to_s).to include("SECRET")
    expect(kinds).to include(:observed)
  end

  # Same effect as B4, reached through the rule on the type instead of the field's own.
  { "a plain resolver" => :plain_resolver, "a bypassed mutation class" => :mutation_class }.each do |label, maker|
    it "[security] B4-type a resolver field on a type under observe: #{label} does not run for a refused user" do
      ran = []
      r = send(maker, ran)
      option = maker == :plain_resolver ? { resolver: r } : { mutation: r }
      doc = obj("Doc") do
        authorize :read, model: ObsProbe::Doc, observe: "rollout"
        field :touch, **option
      end
      selection = maker == :plain_resolver ? "touch" : "touch { ok }"
      schema = schema_for(query: root_with("Query", doc))
      response = run(schema, "{ doc { #{selection} } }")
      puts "\nCHAR type-observed #{label} ran=#{ran.inspect} response=#{response.inspect} kinds=#{kinds.inspect}"
      expect(ran).to be_empty
    end

    it "[preservation] B4-type control: #{label} on an enforced type does not run" do
      ran = []
      r = send(maker, ran)
      option = maker == :plain_resolver ? { resolver: r } : { mutation: r }
      doc = obj("Doc") do
        authorize :read, model: ObsProbe::Doc
        field :touch, **option
      end
      selection = maker == :plain_resolver ? "touch" : "touch { ok }"
      run(schema_for(query: root_with("Query", doc)), "{ doc { #{selection} } }")
      expect(ran).to be_empty
    end
  end

  it "[preservation] B4-type a resolver with its own enforced rule on a type under observe does not run" do
    ran = []
    resolver = Class.new(base_resolver) do
      graphql_name "Own"
      type String, null: true
      authorize :read, model: ObsProbe::Doc
      define_method(:resolve) do
        ran << :side_effect
        "SECRET"
      end
    end
    doc = obj("Doc") do
      authorize :read, model: ObsProbe::Doc, observe: "rollout"
      field :touch, resolver: resolver
    end
    expect(run(schema_for(query: root_with("Query", doc)), "{ doc { touch } }").to_s).not_to include("SECRET")
    expect(ran).to be_empty
  end

  # ---- B2: what docs/authorization.md says
  let(:scoped_empty) { armory::Adapters::Substitute.new(allow: false, scoped: ->(_items) { [] }) }

  it "[docs] B2 a list of an interface: served row by row and recorded" do
    thing = iface("Thing") { field :secret, String, null: true }
    type = observed_doc
    type.implements(thing)
    schema = schema_for(query: list_query([thing, { null: true }]), adapter: scoped_empty, resolve: ->(_o) { type }, orphans: [type])
    expect(run(schema, "{ docs { secret } }").to_s).to include("SECRET")
    expect(kinds).to include(:observed)
  end

  it "[docs] B2 a list of a union: served row by row and recorded" do
    type = observed_doc
    other = enforced_doc("Other", model: ObsProbe::NoPolicyDoc)
    union = Class.new(GraphQL::Schema::Union) do
      graphql_name "Anything"
      possible_types type, other
    end
    schema = schema_for(query: list_query([union, { null: true }]), adapter: scoped_empty, resolve: ->(_o) { type })
    expect(run(schema, "{ docs { ... on Doc { secret } } }").to_s).to include("SECRET")
    expect(kinds).to include(:observed)
  end

  it "[docs] B2 a list with scope: false: served row by row and recorded" do
    type = observed_doc
    query = obj("Query") do
      authorize :none, reason: "root", covers_fields: true
      field :docs, [type], null: true, authorize: :none, reason: "x", scope: false
      def docs = [context[:record]]
    end
    expect(run(schema_for(query: query, adapter: scoped_empty), "{ docs { secret } }").to_s).to include("SECRET")
    expect(kinds).to include(:observed)
  end

  it "[docs] B2 Relay nodes(ids:): served row by row and recorded" do
    type = observed_doc
    type.implements(GraphQL::Types::Relay::Node)
    query = obj("Query") do
      authorize :none, reason: "root", covers_fields: true
      include GraphQL::Types::Relay::HasNodesField
    end
    rec = record
    schema = schema_for(query: query, adapter: scoped_empty, resolve: ->(_o) { type }, orphans: [type]) do
      define_singleton_method(:object_from_id) { |_id, _context| rec }
      define_singleton_method(:id_from_object) { |o, _t, _c| o.id.to_s }
    end
    expect(run(schema, '{ nodes(ids: ["1"]) { ... on Doc { secret } } }').to_s).to include("SECRET")
    expect(kinds).to include(:observed)
  end

  it "[docs] B2 a list of the object type: through the scope, rows lost, nothing recorded" do
    schema = schema_for(query: list_query([observed_doc]), adapter: scoped_empty)
    expect(run(schema, "{ docs { secret } }").dig("data", "docs")).to eq([])
    expect(kinds).not_to include(:observed)
  end
end
