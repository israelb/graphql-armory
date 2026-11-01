# frozen_string_literal: true

# Recheck of: a resolver or mutation field on an object observed through its type's rule.
# Each name starts with [security] or [preservation]. "ran" is what the bodies really did.
module ObsR
  Doc = Struct.new(:id, :secret)

  # Struct with a value == and hash: two records with the same id look equal.
  EqualDoc = Struct.new(:id, :secret) do
    def ==(other) = other.respond_to?(:id) && other.id == id
    alias_method :eql?, :==
    def hash = id.hash
  end

  class Decorator
    def initialize(inner) = @inner = inner
    def secret = @inner.secret
    def id = @inner.id
  end

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

RSpec.describe "observe: resolver fields on an observed object" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:signals) { [] }
  let(:sink) { ->(signal, data) { signals << [signal, data] } }
  let(:record) { ObsR::Doc.new("1", "SECRET") }
  let(:refuse) { armory::Adapters::Substitute.new(allow: false) }
  let(:allow_all) { armory::Adapters::Substitute.new(allow: true) }
  let(:ran) { [] }
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
  # Includes Base but no field_class: graphql's own Field.
  let(:base_object_plain_field) do
    plugin = armory
    Class.new(GraphQL::Schema::Object) { include plugin::Base }
  end

  def plain_resolver(tag = :body)
    log = ran
    Class.new(GraphQL::Schema::Resolver) do
      type String, null: true
      define_method(:resolve) do
        log << tag
        "ran"
      end
    end
  end

  def mutation_class
    log = ran
    Class.new(GraphQL::Schema::Mutation) do
      graphql_name "Touch"
      field :ok, GraphQL::Types::Boolean, null: true, hash_key: :ok
      define_method(:resolve) do
        log << :body
        { ok: true }
      end
    end
  end

  def armory_resolver(action, **options)
    log = ran
    plugin = armory
    Class.new(GraphQL::Schema::Resolver) do
      include plugin::Base
      type String, null: true
      authorize action, **options
      define_method(:resolve) do
        log << :body
        "ran"
      end
    end
  end

  def obj(name, parent: base_object, &block)
    Class.new(parent) do
      graphql_name name
      class_eval(&block)
    end
  end

  def observed(name = "Doc", parent: base_object, &block)
    obj(name, parent: parent) do
      authorize :read, model: Object, observe: "rollout"
      field :secret, String, null: true
      class_eval(&block) if block
    end
  end

  def root_of(fields)
    obj("Query") do
      authorize :none, reason: "root", covers_fields: true
      fields.each { |name, type| field name, type, null: true, authorize: :none, reason: "x", hash_key: name }
    end
  end

  def schema_for(query, adapter: refuse, orphans: [], resolve: nil)
    plugin = armory
    sinks = [sink]
    Class.new(ArmoryEngine.base_schema) do
      query query
      orphan_types(*orphans) unless orphans.empty?
      define_singleton_method(:resolve_type) { |_type, _object, _context| resolve } if resolve
      use plugin, adapter: adapter, sinks: sinks
    end
  end

  def run(schema, document, root: { doc: record })
    execute_query(schema, document, root_value: root, context: {}).to_h
  rescue GraphQL::Armory::Authorization::ConfigurationError => error
    { "raised" => error.message } # a type holding a resolver cannot be observed
  end

  # On a root type graphql-ruby's own rescue turns the error into a NoMethodError, whose cause it is.
  def execute_query(schema, document, **options)
    super
  rescue GraphQL::Armory::Authorization::ConfigurationError, NoMethodError => error
    raise unless error.is_a?(GraphQL::Armory::Authorization::ConfigurationError) || error.cause.is_a?(GraphQL::Armory::Authorization::ConfigurationError)

    { "raised" => error.message }
  end

  def kinds = signals.map(&:first)

  it "[env] reports versions" do
    STDOUT.puts "ENV graphql=#{GraphQL::VERSION} engine=#{ArmoryEngine.current} next_used=#{ArmoryEngine.next?}"
  end

  describe "required" do
    it "[security] R1 resolver: body not run for a refused user, others served" do
      r = plain_resolver
      response = run(schema_for(root_of(doc: observed { field :touch, resolver: r })), "{ doc { secret touch } }")
      expect(ran).to be_empty
      expect(response.dig("data", "doc", "touch")).to be_nil
    end

    it "[security] R2 mutation: body not run for a refused user, others served" do
      m = mutation_class
      response = run(schema_for(root_of(doc: observed { field :touch, mutation: m })), "{ doc { secret touch { ok } } }")
      expect(ran).to be_empty
    end

    it "[preservation] R4 an observed FIELD rule does not refuse a resolver of an allowed object" do
      r = plain_resolver
      type = obj("Doc") do
        authorize :show, model: Object
        field :secret, String, null: true, authorize: :read, observe: "rollout"
        field :touch, resolver: r
      end
      response = run(schema_for(root_of(doc: type), adapter: ObsR::ByAction.new([:show])), "{ doc { secret touch } }")
      expect(response.dig("data", "doc", "touch")).to eq("ran")
      expect(kinds).to include(:observed)
    end

    it "[preservation] R5 same, with the resolver selected first" do
      r = plain_resolver
      type = obj("Doc") do
        authorize :show, model: Object
        field :secret, String, null: true, authorize: :read, observe: "rollout"
        field :touch, resolver: r
      end
      response = run(schema_for(root_of(doc: type), adapter: ObsR::ByAction.new([:show])), "{ doc { touch secret } }")
      expect(response.dig("data", "doc", "touch")).to eq("ran")
    end
  end

  describe "where it is declared" do
    it "[security] V1 on a parent, the observed rule on the concrete type" do
      r = plain_resolver
      parent = obj("Parent") do
        authorize :read, model: Object
        field :touch, resolver: r
      end
      run(schema_for(root_of(doc: observed(parent: parent))), "{ doc { touch } }")
      expect(ran).to be_empty
    end

    it "[security] V2 on an interface with a Base field class" do
      r = plain_resolver
      fc = base_field
      iface = Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Thing"
        field_class fc
        field :touch, resolver: r
      end
      type = observed { implements iface }
      run(schema_for(root_of(doc: iface), orphans: [type], resolve: type), "{ doc { touch } }")
      expect(ran).to be_empty
    end

    it "[security] V3 on an interface with graphql's own field class" do
      r = plain_resolver
      iface = Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Thing"
        field :touch, resolver: r
      end
      type = observed { implements iface }
      response = run(schema_for(root_of(doc: iface), orphans: [type], resolve: type), "{ doc { touch } }")
      STDOUT.puts "CHAR V3 ran=#{ran.inspect} response=#{response.inspect}"
      expect(ran).to be_empty
    end

    it "[preservation] V3-control the same interface on an enforced type does not run" do
      r = plain_resolver
      iface = Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Thing"
        field :touch, resolver: r
      end
      type = obj("Doc") do
        authorize :read, model: Object
        implements iface
      end
      run(schema_for(root_of(doc: iface), orphans: [type], resolve: type), "{ doc { touch } }")
      expect(ran).to be_empty
    end

    it "[security] V4 on a type whose base has no Base field class" do
      r = plain_resolver
      type = observed(parent: base_object_plain_field) { field :touch, resolver: r }
      response = run(schema_for(root_of(doc: type)), "{ doc { touch } }")
      STDOUT.puts "CHAR V4 ran=#{ran.inspect} response=#{response.inspect}"
      expect(ran).to be_empty
    end

    it "[security] V5 on a parent with no Base at all" do
      r = plain_resolver
      plain_parent = Class.new(GraphQL::Schema::Object) do
        graphql_name "PlainParent"
        field :touch, resolver: r
      end
      plugin = armory
      type = Class.new(plain_parent) do
        include plugin::Base
        graphql_name "Doc"
        authorize :read, model: Object, observe: "rollout"
      end
      response = run(schema_for(root_of(doc: type)), "{ doc { touch } }")
      STDOUT.puts "CHAR V5 ran=#{ran.inspect} response=#{response.inspect}"
      expect(ran).to be_empty
    end

    it "[security] V6 a union member" do
      r = plain_resolver
      type = observed { field :touch, resolver: r }
      union = Class.new(GraphQL::Schema::Union) do
        graphql_name "U"
        possible_types type
      end
      run(schema_for(root_of(doc: union), resolve: type), "{ doc { ... on Doc { touch secret } } }")
      expect(ran).to be_empty
    end
  end

  describe "what the audit says" do
    def audit_of(label, schema)
      report = GraphQL::Armory::Authorization::Audit.call(schema)
      STDOUT.puts "CHAR AUDIT #{label} #{report.respond_to?(:problems) ? report.problems.map { |x| x.respond_to?(:to_h) ? x.to_h : x }.inspect : report.inspect}"
    end

    it "[env] the audit on the V3, V4 and A2 shapes" do
      r = plain_resolver
      iface = Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Thing"
        field :touch, resolver: r
      end
      v3 = observed { implements iface }
      audit_of("V3", schema_for(root_of(doc: iface), orphans: [v3], resolve: v3))
      v4 = observed(parent: base_object_plain_field) { field :touch, resolver: r }
      audit_of("V4", schema_for(root_of(doc: v4)))
      parent = obj("Parent") do
        authorize :read, model: Object, observe: "rollout"
        field :touch, resolver: r, authorize: true
      end
      child = obj("Doc", parent: parent) { authorize :show, model: Object }
      audit_of("A2", schema_for(root_of(doc: child), adapter: ObsR::ByAction.new([:show])))
    end
  end

  describe "the audit on a plain field" do
    it "[security] D1 a plain authorize: true field on an observed parent: served, and the audit must not be silent" do
      parent = obj("Parent") do
        authorize :read, model: Object, observe: "rollout"
        field :secret, String, null: true, authorize: true
      end
      child = obj("Doc", parent: parent) { authorize :show, model: Object }
      schema = schema_for(root_of(doc: child), adapter: ObsR::ByAction.new([:show]))
      response = run(schema, "{ doc { secret } }")
      report = GraphQL::Armory::Authorization::Audit.call(schema)
      STDOUT.puts "CHAR D1 response=#{response.inspect} kinds=#{kinds.inspect} ok=#{report.ok?} problems=#{report.problems.map(&:to_h).inspect}"
      expect(report.ok?).to eq(false)
    end
  end

  describe "the field's own rule" do
    it "[security] A1 authorize: true on the observed type itself" do
      r = plain_resolver
      run(schema_for(root_of(doc: observed { field :touch, resolver: r, authorize: true })), "{ doc { touch } }")
      expect(ran).to be_empty
    end

    it "[security] A2 authorize: true on an observed PARENT, the child allowed by its own rule" do
      r = plain_resolver
      parent = obj("Parent") do
        authorize :read, model: Object, observe: "rollout"
        field :touch, resolver: r, authorize: true
      end
      child = obj("Doc", parent: parent) { authorize :show, model: Object }
      response = run(schema_for(root_of(doc: child), adapter: ObsR::ByAction.new([:show])), "{ doc { touch } }")
      STDOUT.puts "CHAR A2 ran=#{ran.inspect} response=#{response.inspect} kinds=#{kinds.inspect}"
      expect(ran).to be_empty
    end

    it "[security] A2-mutation same with a mutation: field" do
      m = mutation_class
      parent = obj("Parent") do
        authorize :read, model: Object, observe: "rollout"
        field :touch, mutation: m, authorize: true
      end
      child = obj("Doc", parent: parent) { authorize :show, model: Object }
      run(schema_for(root_of(doc: child), adapter: ObsR::ByAction.new([:show])), "{ doc { touch { ok } } }")
      expect(ran).to be_empty
    end

    it "[preservation] A2-control the same parent with no observe: refuses" do
      r = plain_resolver
      parent = obj("Parent") do
        authorize :read, model: Object
        field :touch, resolver: r, authorize: true
      end
      child = obj("Doc", parent: parent) { authorize :show, model: Object }
      run(schema_for(root_of(doc: child), adapter: ObsR::ByAction.new([:show])), "{ doc { touch } }")
      expect(ran).to be_empty
    end

    it "[security] A3 authorize: true on an observed parent, child a bypass that covers its fields" do
      r = plain_resolver
      parent = obj("Parent") do
        authorize :read, model: Object, observe: "rollout"
        field :touch, resolver: r, authorize: true
      end
      child = obj("Doc", parent: parent) { authorize :none, reason: "x", covers_fields: true }
      run(schema_for(root_of(doc: child)), "{ doc { touch } }")
      expect(ran).to be_empty
    end

    it "[preservation] A3-control the same parent with no observe: refuses" do
      r = plain_resolver
      parent = obj("Parent") do
        authorize :read, model: Object
        field :touch, resolver: r, authorize: true
      end
      child = obj("Doc", parent: parent) { authorize :none, reason: "x", covers_fields: true }
      run(schema_for(root_of(doc: child)), "{ doc { touch } }")
      expect(ran).to be_empty
    end

    it "[preservation] A4-control the same rule with no observe: refuses" do
      r = plain_resolver
      type = obj("Doc") do
        authorize :read, model: Object, attribute: :whole
        field :touch, resolver: r
      end
      run(schema_for(root_of(doc: type)), "{ doc { touch } }")
      expect(ran).to be_empty
    end

    it "[security] A4 a type rule with attribute: is still a type rule" do
      r = plain_resolver
      type = obj("Doc") do
        authorize :read, model: Object, attribute: :whole, observe: "rollout"
        field :secret, String, null: true
        field :touch, resolver: r
      end
      response = run(schema_for(root_of(doc: type)), "{ doc { secret touch } }")
      STDOUT.puts "CHAR A4 ran=#{ran.inspect} response=#{response.inspect}"
      expect(ran).to be_empty
    end

    it "[security] A5 authorize: :manage with a resolver on an observed type" do
      r = plain_resolver
      run(schema_for(root_of(doc: observed { field :touch, resolver: r, authorize: :manage })), "{ doc { touch } }")
      expect(ran).to be_empty
    end

    it "[security] A6 authorize: :none with a resolver on an observed type" do
      r = plain_resolver
      run(schema_for(root_of(doc: observed { field :touch, resolver: r, authorize: :none, reason: "x" })), "{ doc { touch } }")
      expect(ran).to be_empty
    end

    it "[security] A7 a resolver with its own rule the policy allows, on an observed type" do
      r = armory_resolver(:show, model: Object)
      run(schema_for(root_of(doc: observed { field :touch, resolver: r }), adapter: ObsR::ByAction.new([:show])), "{ doc { touch } }")
      expect(ran).to be_empty
    end

    it "[security] A8 a resolver whose own rule is a bypass, on an observed type" do
      r = armory_resolver(:none, reason: "anyone")
      run(schema_for(root_of(doc: observed { field :touch, resolver: r })), "{ doc { touch } }")
      expect(ran).to be_empty
    end

    it "[preservation] A10 the plain authorize: true field of an observed parent does not refuse the allowed child's resolver" do
      r = plain_resolver
      parent = obj("Parent") do
        authorize :read, model: Object, observe: "rollout"
        field :secret, String, null: true, authorize: true
      end
      child = obj("Doc", parent: parent) do
        authorize :show, model: Object
        field :touch, resolver: r
      end
      response = run(schema_for(root_of(doc: child), adapter: ObsR::ByAction.new([:show])), "{ doc { secret touch } }")
      STDOUT.puts "CHAR A10 ran=#{ran.inspect} response=#{response.inspect}"
      expect(response.dig("data", "doc", "touch")).to eq("ran")
    end
  end

  describe "same object, memo" do
    it "[security] M1 aliases: reached twice, memo hit" do
      r = plain_resolver
      type = observed { field :touch, resolver: r }
      response = run(schema_for(root_of(doc: type)), "{ a: doc { touch secret } b: doc { touch secret } c: doc { x: touch y: touch } }")
      expect(ran).to be_empty
    end

    it "[security] M2 nested back to the same record" do
      r = plain_resolver
      inner = observed("Inner") { field :touch, resolver: r }
      outer = observed("Outer") { field :same, inner, null: true, method: :itself }
      response = run(schema_for(root_of(doc: outer)), "{ doc { secret same { secret touch } } }")
      expect(ran).to be_empty
    end

    it "[security] M3 enforced type first, observed second, same record" do
      r = plain_resolver
      enforced = obj("Enforced") do
        authorize :read, model: Object
        field :secret, String, null: true
        field :touch, resolver: r
      end
      seen = observed { field :touch, resolver: r }
      response = run(schema_for(root_of(e: enforced, o: seen)), "{ e { touch } o { touch secret } }", root: { e: record, o: record })
      expect(ran).to be_empty
      expect(response.dig("data", "e")).to be_nil
    end

    it "[security] M4 observed type first, enforced second, same record" do
      r = plain_resolver
      enforced = obj("Enforced") do
        authorize :read, model: Object
        field :secret, String, null: true
        field :touch, resolver: r
      end
      seen = observed { field :touch, resolver: r }
      response = run(schema_for(root_of(e: enforced, o: seen)), "{ o { touch secret } e { touch } }", root: { e: record, o: record })
      expect(ran).to be_empty
      expect(response.dig("data", "e")).to be_nil
    end

    %w[o a].permutation(2).each do |first, second|
      it "[preservation] M5 same record, observed type and a type the policy allows, order #{first} #{second}: the allowed type's resolver runs" do
        r = plain_resolver
        allowed = obj("Allowed") do
          authorize :show, model: Object
          field :touch, resolver: r
        end
        seen = observed
        document = { "o" => "o { secret }", "a" => "a { touch }" }
        response = run(schema_for(root_of(a: allowed, o: seen), adapter: ObsR::ByAction.new([:show])),
                       "{ #{document[first]} #{document[second]} }", root: { a: record, o: record })
        STDOUT.puts "CHAR M5 #{first},#{second} ran=#{ran.inspect} response=#{response.inspect}"
        expect(response.dig("data", "a", "touch")).to eq("ran")
      end
    end

    it "[security] M6 a list repeating one record and holding another" do
      r = plain_resolver
      type = observed { field :touch, resolver: r }
      other = ObsR::Doc.new("2", "OTHER")
      query = obj("Query") do
        authorize :none, reason: "root", covers_fields: true
        field :docs, [type], null: true, authorize: :none, reason: "x", hash_key: :docs, scope: false
      end
      response = run(schema_for(query), "{ docs { touch secret } }", root: { docs: [record, other, record] })
      expect(ran).to be_empty
    end

    it "[security] M7 a scoped list through the type" do
      r = plain_resolver
      type = observed { field :touch, resolver: r }
      query = obj("Query") do
        authorize :none, reason: "root", covers_fields: true
        field :docs, [type], null: true, authorize: :none, reason: "x", hash_key: :docs
      end
      run(schema_for(query), "{ docs { touch secret } }", root: { docs: [record] })
      expect(ran).to be_empty
    end

    it "[security] M8 two equal Structs with custom == and hash, both reached" do
      r = plain_resolver
      type = observed { field :touch, resolver: r }
      one = ObsR::EqualDoc.new("1", "A")
      two = ObsR::EqualDoc.new("1", "B")
      response = run(schema_for(root_of(x: type, y: type)), "{ x { touch secret } y { touch secret } }", root: { x: one, y: two })
      expect(ran).to be_empty
    end

    it "[security] M9 a Hash record, then mutated between fields, keeps its mark" do
      r = plain_resolver
      type = obj("Doc") do
        authorize :read, model: Object, observe: "rollout"
        field :secret, String, null: true, hash_key: :secret
        field :touch, resolver: r
      end
      run(schema_for(root_of(doc: type)), "{ doc { secret touch } }", root: { doc: { secret: "S" } })
      expect(ran).to be_empty
    end

    it "[security] M10 an Integer and a Symbol as the object" do
      r = plain_resolver
      type = obj("Doc") do
        authorize :read, model: Object, observe: "rollout"
        field :text, String, null: true, method: :to_s
        field :touch, resolver: r
      end
      response = run(schema_for(root_of(i: type, s: type)), "{ i { text touch } s { text touch } }", root: { i: 1, s: :sym })
      expect(ran).to be_empty
    end
  end

  describe "selection order" do
    ["{ doc { touch secret } }", "{ doc { secret touch } }", "{ doc { ... on Doc { touch } secret } }",
     "fragment F on Doc { touch } { doc { ...F secret } }"].each do |document|
      it "[security] O1 #{document}" do
        r = plain_resolver
        response = run(schema_for(root_of(doc: observed { field :touch, resolver: r })), document)
        expect(ran).to be_empty
      end
    end
  end

  describe "a root type observed" do
    def observed_root(&block)
      r = plain_resolver
      obj("Query") do
        authorize :read, model: Object, observe: "rollout"
        field :touch, resolver: r
        class_eval(&block) if block
      end
    end

  end

  describe "wrapped objects" do
    it "[security] W1 self.wrap decorates the object" do
      r = plain_resolver
      type = observed do
        field :touch, resolver: r
        define_singleton_method(:wrap) { |object, context| super(ObsR::Decorator.new(object), context) }
      end
      response = run(schema_for(root_of(doc: type)), "{ doc { secret touch } }")
      STDOUT.puts "CHAR W1 ran=#{ran.inspect} response=#{response.inspect}"
      expect(ran).to be_empty
    end

    it "[security] W2 authorized_new decorates after the check" do
      r = plain_resolver
      type = observed do
        field :touch, resolver: r
        define_singleton_method(:authorized_new) do |object, context|
          authorized = super(object, context)
          authorized.instance_variable_set(:@object, ObsR::Decorator.new(object)) if authorized.is_a?(GraphQL::Schema::Object)
          authorized
        end
      end
      response = run(schema_for(root_of(doc: type)), "{ doc { secret touch } }")
      STDOUT.puts "CHAR W2 ran=#{ran.inspect} response=#{response.inspect}"
      expect(ran).to be_empty
    end

    it "[security] W3 an initialize that decorates the object" do
      r = plain_resolver
      type = observed do
        field :touch, resolver: r
        define_method(:initialize) { |object, context| super(ObsR::Decorator.new(object), context) }
      end
      response = run(schema_for(root_of(doc: type)), "{ doc { secret touch } }")
      STDOUT.puts "CHAR W3 ran=#{ran.inspect} response=#{response.inspect}"
      expect(ran).to be_empty
    end

    it "[preservation] W3-control the same initialize on an enforced type does not run" do
      r = plain_resolver
      type = obj("Doc") do
        authorize :read, model: Object
        field :touch, resolver: r
        define_method(:initialize) { |object, context| super(ObsR::Decorator.new(object), context) }
      end
      run(schema_for(root_of(doc: type)), "{ doc { touch } }")
      expect(ran).to be_empty
    end

    [true, false].each do |seen|
      it "[security] W4 reauthorize_scoped_objects(false), a scoped list, observed=#{seen}" do
      skip "Next skips every check on this shape, enforced too: a documented limit the audit reports" if ArmoryEngine.next?
        r = plain_resolver
        rule_options = seen ? { model: Object, observe: "rollout" } : { model: Object }
        type = obj("Doc") do
          authorize :read, **rule_options
          reauthorize_scoped_objects(false)
          field :secret, String, null: true
          field :touch, resolver: r
        end
        query = obj("Query") do
          authorize :none, reason: "root", covers_fields: true
          field :docs, [type], null: true, authorize: :none, reason: "x", hash_key: :docs
        end
        response = run(schema_for(query), "{ docs { touch } }", root: { docs: [record] })
        STDOUT.puts "CHAR W4 observed=#{seen} ran=#{ran.inspect} response=#{response.inspect}"
        expect(ran).to be_empty
      end
    end
  end

  describe "partials" do
    before { skip "no Query::Partial" unless defined?(GraphQL::Query::Partial) }

    def query_of(schema, document, root)
      GraphQL::Query.new(schema, document, root_value: root, context: {})
    end

    it "[security] P2 a partial directly on the resolver field, with the record as its parent" do
      r = plain_resolver
      schema = schema_for(root_of(doc: observed { field :touch, resolver: r }))
      result = query_of(schema, "{ doc { secret touch } }", {}).run_partials([{ path: %w[doc touch], object: record }]).first.to_h
      STDOUT.puts "CHAR P2 ran=#{ran.inspect} result=#{result.inspect} kinds=#{kinds.inspect}"
      expect(ran).to be_empty
    end

  end

  describe "multiplex" do
    def multiplex(schema, queries)
      ArmoryEngine.next? ? schema.multiplex_next(queries) : schema.multiplex(queries)
    end

  end

  describe "stays served" do
    it "[preservation] K1 resolver_method:" do
      log = ran
      ext = Class.new(GraphQL::Schema::FieldExtension) do
        define_method(:resolve) do |**kw|
          log << :ext
          kw[:objects] ? kw[:objects].map { "ext" } : "ext"
        end
      end
      type = observed do
        field :viaext, String, null: true, method: :secret, extensions: [ext]
        field :meth, String, null: true, resolver_method: :custom_meth
        field :plain_hash, String, null: true, method: :id
        define_method(:custom_meth) { "meth" }
      end
      response = run(schema_for(root_of(doc: type)), ArmoryEngine.next? ? "{ doc { viaext plainHash } }" : "{ doc { viaext meth plainHash } }")
      expect(response.dig("data", "doc", "viaext")).to eq("ext")
      expect(response.dig("data", "doc", "meth")).to eq("meth") unless ArmoryEngine.next?
      expect(log).to eq([:ext])
    end

    it "[preservation] K2 an extension in a block" do
      ext = Class.new(GraphQL::Schema::FieldExtension) do
        def after_resolve(**kw) = kw.key?(:value) ? kw[:value].to_s.downcase : kw.fetch(:values).map { |v| v.to_s.downcase }
      end
      type = observed do
        field :low, String, null: true, method: :secret do
          extension ext
        end
      end
      response = run(schema_for(root_of(doc: type)), "{ doc { low } }")
      expect(response.dig("data", "doc", "low")).to eq("secret")
    end
  end

  describe "before the field check" do
    %i[observed enforced].each do |kind|
      it "[security] B1 a resolver argument's prepare: on an #{kind} type" do
        log = ran
        r = Class.new(GraphQL::Schema::Resolver) do
          type String, null: true
          argument :input, String, required: false, prepare: ->(value, _ctx) { log << :prepare; value }
          define_method(:resolve) { |**_kw| log << :body; "ran" }
        end
        rule_options = kind == :observed ? { model: Object, observe: "rollout" } : { model: Object }
        type = obj("Doc") do
          authorize :read, **rule_options
          field :touch, resolver: r
        end
        run(schema_for(root_of(doc: type)), '{ doc { touch(input: "x") } }')
        STDOUT.puts "CHAR B1 #{kind} ran=#{ran.inspect}"
        expect(ran).to be_empty
      end
    end

    it "[security] B2 a resolver's ready? and authorized? do not run" do
      log = ran
      r = Class.new(GraphQL::Schema::Resolver) do
        type String, null: true
        define_method(:ready?) { |**_kw| log << :ready; true }
        define_method(:authorized?) { |**_kw| log << :authorized; true }
        define_method(:resolve) { log << :body; "ran" }
      end
      run(schema_for(root_of(doc: observed { field :touch, resolver: r })), "{ doc { touch } }")
      expect(ran).to be_empty
    end

    it "[security] B3 Resolver.field_options" do
      r = plain_resolver
      skip "no field_options" unless r.respond_to?(:field_options)
      opts = r.field_options
      type = observed { field :touch, **opts }
      run(schema_for(root_of(doc: type)), "{ doc { touch } }")
      expect(ran).to be_empty
    end
  end
end
