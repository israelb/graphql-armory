# frozen_string_literal: true

# Probes of the audit of reauthorize_scoped_objects and own scope_items.
# Each `it` starts with [security] or [preservation]. PROBE lines record what really ran for a refused user.
module ScopedProbe
  Thing = Struct.new(:id, :secret, keyword_init: true)
  Root = Struct.new(:things, :others, :conn, :docs, :tags, :ping, :thing, keyword_init: true)
  SECRET = "s3cret"
  FLAG = :reauthorize_scoped_objects

  def self.things
    [Thing.new(id: 1, secret: SECRET)]
  end

  def self.root
    Root.new(things: things, others: things, conn: things, docs: things, tags: %w[a], ping: "pong", thing: things.first)
  end

  def self.refusing_adapter
    GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: false, scoped: ->(items) { items.to_a.dup })
  end
end

RSpec.describe "audit of reauthorize_scoped_objects: probes" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:flag_reason) { { ScopedProbe::FLAG => "the scope is as strict as the rule" } }

  def base_field
    @base_field ||= begin
      plugin = armory
      Class.new(GraphQL::Schema::Field) { include plugin::Base }
    end
  end

  def base_object
    @base_object ||= begin
      plugin = armory
      field = base_field
      Class.new(GraphQL::Schema::Object) do
        include plugin::Base
        field_class field
        default_action :read
      end
    end
  end

  def thing_type(parent = base_object, name = "Thing", &block)
    Class.new(parent) do
      graphql_name name
      authorize :read, model: ScopedProbe::Thing
      field :secret, String, null: false
      class_eval(&block) if block
    end
  end

  def query_type(&block)
    Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      class_eval(&block)
    end
  end

  def interface(name = "Doc", &block)
    field_klass = base_field
    Module.new do
      include GraphQL::Schema::Interface
      graphql_name name
      field_class field_klass
      field :secret, String, null: false
      module_eval(&block) if block
    end
  end

  def template_connection
    base = base_object
    Class.new(base) do
      include GraphQL::Types::Relay::ConnectionBehaviors
      authorize :none, reason: "a connection", covers_fields: true
    end
  end

  def template_edge
    base = base_object
    Class.new(base) do
      include GraphQL::Types::Relay::EdgeBehaviors
      authorize :none, reason: "an edge", covers_fields: true
    end
  end

  def named_connection(node, name: "ThingConnection", parent: template_connection, edge_parent: template_edge, &block)
    edge_name = name.sub("Connection", "Edge")
    edge = Class.new(edge_parent) do
      graphql_name edge_name
      node_type(node)
    end
    Class.new(parent) do
      graphql_name name
      edge_type(edge)
      class_eval(&block) if block
    end
  end

  def schema_for(query_class, own_checks: {}, orphans: [], resolved: nil, setup: nil)
    plugin = armory
    adapter = ScopedProbe.refusing_adapter
    Class.new(base_schema) do
      use plugin, adapter: adapter, own_checks: own_checks
      query query_class
      orphan_types(*orphans) unless orphans.empty?
      class_eval(&setup) if setup
      define_singleton_method(:resolve_type) { |_abstract, _object, _context| resolved } if resolved
    end
  end

  def flag_paths(report)
    report.problems.select { |problem| problem.kind == :own_check && problem.path.include?("reauthorize_scoped_objects") }.map(&:path)
  end

  def path_of(holder)
    "#{holder.name || holder.inspect}.reauthorize_scoped_objects"
  end

  def run_refused(schema, query, context: {})
    result = execute_query(schema, query, root_value: ScopedProbe.root, context: context)
    result.to_h.to_s.include?(ScopedProbe::SECRET) ? "LEAK" : "refused"
  rescue StandardError, NotImplementedError => error
    "raised #{error.class}: #{error.message[0, 90]}"
  end

  def record(id, schema, query, context: {})
    outcome = run_refused(schema, query, context: context)
    puts "PROBE|#{id}|#{ArmoryEngine.current}|#{GraphQL::VERSION}|#{outcome}|audit=#{flag_paths(armory::Audit.(schema))}"
    outcome
  end

  # The report must name the holder, and a declaration on that holder must clear the finding and leave a bypass.
  def expect_named_and_cleared(holder, build)
    report = armory::Audit.(build.call({}))
    expect(flag_paths(report)).to include(path_of(holder))
    declared = armory::Audit.(build.call({ holder => flag_reason }))
    expect(flag_paths(declared)).to be_empty
    expect(declared.bypasses.map(&:path)).to include(path_of(holder))
    expect(declared.problems.map(&:path)).not_to include("#{holder.name || holder.inspect} reauthorize_scoped_objects")
  end

  def expect_no_silent_leak(outcome, schema, holder)
    named = flag_paths(armory::Audit.(schema)).include?(path_of(holder))
    expect("#{outcome} named=#{named}").not_to eq("LEAK named=false")
  end

  describe "flag shapes" do
    it "[security] S3 own method answering nil" do
      thing = thing_type { def self.reauthorize_scoped_objects(_value = nil) = nil }
      query = query_type { field :things, [thing, { null: true }], null: false }
      record("S3", schema_for(query), "{ things { secret } }")
      expect_named_and_cleared(thing, ->(checks) { schema_for(query, own_checks: checks) })
    end

    it "[security] S4 method on a module extended into the class: declaring the class does not clear" do
      mod = Module.new { def reauthorize_scoped_objects(_value = nil) = false }
      thing = thing_type { extend mod }
      query = query_type { field :things, [thing, { null: true }], null: false }
      record("S4", schema_for(query), "{ things { secret } }")
      expect_named_and_cleared(mod, ->(checks) { schema_for(query, own_checks: checks) })
      wrong = armory::Audit.(schema_for(query, own_checks: { thing => flag_reason }))
      expect(flag_paths(wrong)).to include(path_of(mod))
    end

    it "[security] S5 inherited from a base class not in the schema" do
      base = Class.new(base_object) { reauthorize_scoped_objects(false) }
      thing = thing_type(base)
      query = query_type { field :things, [thing, { null: true }], null: false }
      record("S5", schema_for(query), "{ things { secret } }")
      expect_named_and_cleared(base, ->(checks) { schema_for(query, own_checks: checks) })
    end

    it "[security] S6 own method inherited from a base class" do
      base = Class.new(base_object) { def self.reauthorize_scoped_objects(_value = nil) = false }
      thing = thing_type(base)
      query = query_type { field :things, [thing, { null: true }], null: false }
      record("S6", schema_for(query), "{ things { secret } }")
      expect_named_and_cleared(base, ->(checks) { schema_for(query, own_checks: checks) })
    end

    it "[security] S7 interface ivar with its own scope" do
      doc = interface { reauthorize_scoped_objects(false) }
      doc.define_singleton_method(:scope_items) { |items, _ctx| items.to_a.dup }
      thing = thing_type { implements doc }
      query = query_type { field :docs, [doc, { null: true }], null: false }
      build = ->(checks) { schema_for(query, own_checks: checks, orphans: [thing], resolved: thing) }
      record("S7", build.call({}), "{ docs { secret } }")
      expect_named_and_cleared(doc, build)
    end

    it "[security] S8 implementer ivar under a list of interface" do
      doc = interface
      thing = thing_type do
        implements doc
        reauthorize_scoped_objects(false)
      end
      query = query_type { field :docs, [doc, { null: true }], null: false }
      build = ->(checks) { schema_for(query, own_checks: checks, orphans: [thing], resolved: thing) }
      record("S8", build.call({}), "{ docs { secret } }")
      expect_named_and_cleared(thing, build)
    end

    it "[security] S10 interface definition_methods method" do
      doc = interface do
        definition_methods do
          def reauthorize_scoped_objects(_value = nil) = false
        end
      end
      thing = thing_type { implements doc }
      query = query_type { field :docs, [doc, { null: true }], null: false }
      build = ->(checks) { schema_for(query, own_checks: checks, orphans: [thing], resolved: thing) }
      holder = doc.method(:reauthorize_scoped_objects).owner
      puts "PROBE|S10|holder=#{holder.inspect}|thing_owner=#{thing.method(:reauthorize_scoped_objects).owner}|thing_value=#{thing.reauthorize_scoped_objects.inspect}"
      expect_named_and_cleared(holder, build)
    end

    it "[security] S12 union member ivar under a list of union" do
      thing = thing_type { reauthorize_scoped_objects(false) }
      union = Class.new(GraphQL::Schema::Union) do
        graphql_name "U"
        possible_types thing
      end
      query = query_type { field :docs, [union, { null: true }], null: false }
      build = ->(checks) { schema_for(query, own_checks: checks, resolved: thing) }
      record("S12", build.call({}), "{ docs { ... on Thing { secret } } }")
      expect_named_and_cleared(thing, build)
    end

    it "[security] S13b named connection ivar over a clean node, template shape" do
      thing = thing_type
      conn = named_connection(thing) { reauthorize_scoped_objects(false) }
      query = query_type { field :conn, conn, null: false, connection: true }
      build = ->(checks) { schema_for(query, own_checks: checks) }
      record("S13b", build.call({}), "{ conn { nodes { secret } edges { node { secret } } } }")
      expect_named_and_cleared(conn, build)
    end

    it "[security] S14 connection flag from its node reports the node once" do
      thing = thing_type { reauthorize_scoped_objects(false) }
      conn = named_connection(thing)
      query = query_type { field :conn, conn, null: false, connection: true }
      build = ->(checks) { schema_for(query, own_checks: checks) }
      record("S14", build.call({}), "{ conn { nodes { secret } edges { node { secret } } } }")
      expect(flag_paths(armory::Audit.(build.call({})))).to eq([path_of(thing)])
      expect_named_and_cleared(thing, build)
    end

    it "[security] S15a named edge ivar over a clean node" do
      thing = thing_type
      edge_parent = template_edge
      conn = named_connection(thing, edge_parent: edge_parent)
      edge = conn.edge_type_class_for_probe if conn.respond_to?(:edge_type_class_for_probe)
      edge ||= conn.fields["edges"].type.unwrap
      edge.reauthorize_scoped_objects(false)
      query = query_type { field :conn, conn, null: false, connection: true }
      build = ->(checks) { schema_for(query, own_checks: checks) }
      record("S15a", build.call({}), "{ conn { edges { node { secret } } } }")
      expect_named_and_cleared(edge, build)
    end

    it "[security] S15b generated edge_type ivar" do
      base_object.connection_type_class(template_connection)
      base_object.edge_type_class(template_edge)
      thing = thing_type
      thing.edge_type.reauthorize_scoped_objects(false)
      generated = thing.connection_type
      query = query_type { field :conn, generated, null: false, connection: true }
      build = ->(checks) { schema_for(query, own_checks: checks) }
      record("S15b", build.call({}), "{ conn { edges { node { secret } } } }")
      expect_named_and_cleared(thing.edge_type, build)
    end

    it "[security] S16a base edge ivar inherited by generated edges" do
      edge_base = template_edge
      edge_base.reauthorize_scoped_objects(false)
      base_object.connection_type_class(template_connection)
      base_object.edge_type_class(edge_base)
      generated = thing_type.connection_type
      query = query_type { field :conn, generated, null: false, connection: true }
      build = ->(checks) { schema_for(query, own_checks: checks) }
      record("S16a", build.call({}), "{ conn { edges { node { secret } } } }")
      expect_named_and_cleared(edge_base, build)
    end

    it "[security] S16b base connection own method inherited by generated connections" do
      conn_base = template_connection
      conn_base.define_singleton_method(:reauthorize_scoped_objects) { |_value = nil| false }
      base_object.connection_type_class(conn_base)
      base_object.edge_type_class(template_edge)
      generated = thing_type.connection_type
      query = query_type { field :conn, generated, null: false, connection: true }
      build = ->(checks) { schema_for(query, own_checks: checks) }
      record("S16b", build.call({}), "{ conn { nodes { secret } edges { node { secret } } } }")
      expect_named_and_cleared(conn_base, build)
    end

    it "[preservation] S17 base connection ivar is not inherited: no finding and the rule runs" do
      conn_base = template_connection
      conn_base.reauthorize_scoped_objects(false)
      base_object.connection_type_class(conn_base)
      base_object.edge_type_class(template_edge)
      generated = thing_type.connection_type
      query = query_type { field :conn, generated, null: false, connection: true }
      schema = schema_for(query)
      expect(record("S17", schema, "{ conn { nodes { secret } edges { node { secret } } } }")).to eq("refused")
      expect(flag_paths(armory::Audit.(schema))).to be_empty
    end

    it "[security] S18 named connection subclass with no edge type, own method and extended module" do
      parent = named_connection(thing_type)
      mod = Module.new { def reauthorize_scoped_objects(_value = nil) = false }
      with_method = Class.new(parent) do
        graphql_name "AConnection"
        def self.reauthorize_scoped_objects(_value = nil) = false
      end
      with_module = Class.new(parent) do
        graphql_name "BConnection"
        extend mod
      end
      query = query_type do
        field :a, with_method, null: true, connection: true
        field :b, with_module, null: true, connection: true
      end
      report = armory::Audit.(schema_for(query))
      expect(flag_paths(report)).to include(path_of(with_method), path_of(mod))
    end

    it "[security] S20 type only in orphan_types" do
      doc = interface
      thing = thing_type do
        implements doc
        reauthorize_scoped_objects(false)
      end
      query = query_type { field :docs, [doc, { null: true }], null: false }
      expect_named_and_cleared(thing, ->(checks) { schema_for(query, own_checks: checks, orphans: [thing], resolved: thing) })
    end

    it "[security] S21 implementer absent from orphan_types and schema.types" do
      doc = interface
      thing = thing_type do
        implements doc
        reauthorize_scoped_objects(false)
      end
      query = query_type { field :docs, [doc, { null: true }], null: false }
      schema = schema_for(query, resolved: thing)
      puts "PROBE|S21|in_types=#{schema.types.value?(thing)}"
      outcome = record("S21", schema, "{ docs { secret } }")
      expect_no_silent_leak(outcome, schema, thing)
    end

    it "[security] S22 Visibility dynamic: type hidden by visible? at audit (documented limit)" do
      thing = thing_type do
        reauthorize_scoped_objects(false)
        def self.visible?(context) = super && context[:beta] == true
      end
      query = query_type do
        field :ping, String
        field :things, [thing, { null: true }], null: false
      end
      schema = schema_for(query, setup: proc { use GraphQL::Schema::Visibility, dynamic: true })
      puts "PROBE|S22|in_types=#{schema.types.value?(thing)}"
      outcome = record("S22", schema, "{ things { secret } }", context: { beta: true })
      expect_no_silent_leak(outcome, schema, thing)
    end

    it "[security] S23 Visibility dynamic: type visible, reachable only through a field hidden at audit" do
      thing = thing_type { reauthorize_scoped_objects(false) }
      beta = Class.new(base_field) { def visible?(context) = super && context[:beta] == true }
      query = query_type do
        field :ping, String
        field_class beta
        field :things, [thing, { null: true }], null: false
      end
      schema = schema_for(query, setup: proc { use GraphQL::Schema::Visibility, dynamic: true })
      puts "PROBE|S23|in_types=#{schema.types.value?(thing)}"
      outcome = record("S23", schema, "{ things { secret } }", context: { beta: true })
      expect_no_silent_leak(outcome, schema, thing)
    end

    it "[security] S24 no Visibility plugin: second definition of a name, hidden at audit" do
      v1 = thing_type { def self.visible?(context) = super && context[:v2] != true }
      v2 = thing_type do
        reauthorize_scoped_objects(false)
        def self.visible?(context) = super && context[:v2] == true
      end
      query = query_type do
        field :things, [v1, { null: true }], null: false
        field :things, [v2, { null: true }], null: false
      end
      schema = schema_for(query)
      puts "PROBE|S24|types_entry_is_v2=#{schema.types['Thing'].equal?(v2)}"
      outcome = record("S24", schema, "{ things { secret } }", context: { v2: true })
      expect_no_silent_leak(outcome, schema, v2)
    end


    it "[security] S26 roots and a mutation payload" do
      base = base_object
      mutation_class = Class.new(GraphQL::Schema::Mutation) do
        graphql_name "Do"
        object_class base
        field :ok, String
      end
      mutation_class.payload_type.reauthorize_scoped_objects(false)
      root_mutation = Class.new(base_object) do
        graphql_name "Mutation"
        authorize :none, reason: "root", covers_fields: true
        field :do, mutation: mutation_class
      end
      query = query_type do
        reauthorize_scoped_objects(false)
        field :ping, String
      end
      schema = schema_for(query, setup: proc { mutation root_mutation })
      expect(flag_paths(armory::Audit.(schema))).to include(path_of(query), path_of(mutation_class.payload_type))
    end

    it "[security] S27 list returned by a resolver" do
      thing = thing_type { reauthorize_scoped_objects(false) }
      resolver = Class.new(GraphQL::Schema::Resolver) do
        type [thing, { null: true }], null: false
        def resolve = ScopedProbe.things
      end
      query = query_type { field :things, resolver: resolver }
      build = ->(checks) { schema_for(query, own_checks: checks) }
      record("S27", build.call({}), "{ things { secret } }")
      expect_named_and_cleared(thing, build)
    end

    it "[security] S28 the flag set on GraphQL::Schema::Object itself" do
      GraphQL::Schema::Object.reauthorize_scoped_objects(false)
      thing = thing_type
      query = query_type { field :things, [thing, { null: true }], null: false }
      build = ->(checks) { schema_for(query, own_checks: checks) }
      record("S28", build.call({}), "{ things { secret } }")
      expect_named_and_cleared(GraphQL::Schema::Object, build)
    ensure
      GraphQL::Schema::Object.instance_variable_set(:@reauthorize_scoped_objects, nil)
    end

    it "[security] S29 a child schema of a schema carrying the type" do
      thing = thing_type { reauthorize_scoped_objects(false) }
      query = query_type { field :things, [thing, { null: true }], null: false }
      child = Class.new(schema_for(query))
      expect(flag_paths(armory::Audit.(child))).to eq([path_of(thing)])
    end

    it "[security] S30 this finding alone fails the report and the command's exit" do
      thing = thing_type { reauthorize_scoped_objects(false) }
      query = query_type { field :things, [thing, { null: true }], null: false }
      report = armory::Audit.(schema_for(query))
      expect(report.ok?).to be(false)
      expect(report.problems.map(&:kind).uniq).to eq([:own_check])
    end

    it "[security] S31 own scope_items on an extended module and on a connection" do
      mod = Module.new { def scope_items(items, _context) = items.to_a.dup }
      thing = thing_type { extend mod }
      conn = named_connection(thing_type(base_object, "Other")) { def self.scope_items(items, _context) = items.to_a.dup }
      query = query_type do
        field :things, [thing, { null: true }], null: false
        field :conn, conn, null: false, connection: true
      end
      schema = schema_for(query)
      paths = armory::Audit.(schema).problems.map(&:path)
      expect(paths).to include("#{mod.inspect}.scope_items", "#{conn.inspect}.scope_items")
      expect(record("S31-flag-on", schema, "{ things { secret } conn { nodes { secret } } }")).to eq("refused")
    end

    it "[security] S32 a plain object without Base carrying the flag" do
      thing = Class.new(GraphQL::Schema::Object) do
        graphql_name "Thing"
        field :secret, String, null: false
        reauthorize_scoped_objects(false)
      end
      query = query_type { field :things, [thing, { null: true }], null: false }
      expect(flag_paths(armory::Audit.(schema_for(query)))).to eq([path_of(thing)])
    end

    it "[security] S33 own method calling super over a parent's false: each level is reported, as docs say" do
      base = Class.new(base_object) { def self.reauthorize_scoped_objects(_value = nil) = false }
      thing = thing_type(base) { def self.reauthorize_scoped_objects(value = nil) = super }
      query = query_type { field :things, [thing, { null: true }], null: false }
      paths = flag_paths(armory::Audit.(schema_for(query)))
      puts "PROBE|S33|paths=#{paths}|base=#{path_of(base)}"
      expect(paths).to include(path_of(thing), path_of(base))
    end

    it "[security] S34 a base passthrough method: a declaration on the base must not clear a child that sets its own" do
      base = Class.new(base_object) { def self.reauthorize_scoped_objects(value = nil) = super }
      first = thing_type(base, "First") { reauthorize_scoped_objects(false) }
      second = thing_type(base, "Second") { reauthorize_scoped_objects(false) }
      query = query_type do
        field :things, [first, { null: true }], null: false
        field :others, [second, { null: true }], null: false
      end
      report = armory::Audit.(schema_for(query))
      puts "PROBE|S34|paths=#{flag_paths(report)}|first=#{path_of(first)}|base=#{path_of(base)}"
      declared = armory::Audit.(schema_for(query, own_checks: { base => flag_reason }))
      record("S34", schema_for(query, own_checks: { base => flag_reason }), "{ others { secret } }")
      expect(flag_paths(declared)).to include(path_of(second))
    end
  end

  describe "types and schema.types" do
    it "[security] S35 no Visibility plugin, one definition hidden at audit: still in schema.types and named" do
      thing = thing_type do
        reauthorize_scoped_objects(false)
        def self.visible?(context) = super && context[:beta] == true
      end
      query = query_type do
        field :ping, String
        field :things, [thing, { null: true }], null: false
      end
      schema = schema_for(query)
      record("S35", schema, "{ things { secret } }", context: { beta: true })
      expect(flag_paths(armory::Audit.(schema))).to eq([path_of(thing)])
    end

    it "[security] S36 Visibility dynamic with the plugin's visible_when: visible at audit and named" do
      thing = Class.new(base_object) do
        graphql_name "Thing"
        authorize :read, model: ScopedProbe::Thing, visible_when: :export
        field :secret, String, null: false
        reauthorize_scoped_objects(false)
      end
      query = query_type do
        field :ping, String
        field :things, [thing, { null: true }], null: false
      end
      schema = schema_for(query, setup: proc { use GraphQL::Schema::Visibility, dynamic: true })
      expect(flag_paths(armory::Audit.(schema))).to eq([path_of(thing)])
    end

    it "[security] S21c interface with a known implementer; resolve_type answers another class outside schema.types" do
      doc = interface
      known = thing_type(base_object, "Known") { implements doc }
      thing = thing_type do
        implements doc
        reauthorize_scoped_objects(false)
      end
      query = query_type { field :docs, [doc, { null: true }], null: false }
      schema = schema_for(query, orphans: [known], resolved: thing)
      puts "PROBE|S21c|in_types=#{schema.types.value?(thing)}"
      outcome = record("S21c", schema, "{ docs { secret } }")
      expect_no_silent_leak(outcome, schema, thing)
    end

    it "[security] S21b what the engine really answers for an implementer outside the schema" do
      doc = interface
      thing = thing_type do
        implements doc
        reauthorize_scoped_objects(false)
      end
      query = query_type { field :docs, [doc, { null: true }], null: false }
      schema = schema_for(query, resolved: thing)
      begin
        result = execute_query(schema, "{ docs { secret } }", root_value: ScopedProbe.root)
        puts "PROBE|S21b|#{ArmoryEngine.current}|#{result.to_h.to_s[0, 160]}"
      rescue StandardError => error
        puts "PROBE|S21b|#{ArmoryEngine.current}|raised #{error.class}: #{error.message[0, 120]}"
      end
    end
  end

  describe "the guard for a connection with no node" do
    it "[security] S19a own scope_items and library reader: what really runs" do
      thing = thing_type
      conn = Class.new(template_connection) do
        graphql_name "HandConnection"
        def self.scope_items(items, _context) = items.to_a.dup
      end
      conn.field :nodes, [thing, { null: true }], null: false, scope: false
      query = query_type { field :things, conn, null: false, connection: true }
      schema = schema_for(query)
      outcome = record("S19a", schema, "{ things { nodes { secret } } }")
      expect(outcome).not_to eq("LEAK")
    end

    it "[security] S19b parent connection ivar false, child no node: the runtime does not skip silently" do
      parent = named_connection(thing_type) { reauthorize_scoped_objects(false) }
      child = Class.new(parent) { graphql_name "ChildConnection" }
      query = query_type { field :conn, child, null: false, connection: true }
      schema = schema_for(query)
      outcome = record("S19b", schema, "{ conn { pageInfo { hasNextPage } } }")
      puts "PROBE|S19b|parent_in_types=#{schema.types.value?(parent)}"
      expect(outcome).not_to eq("LEAK")
    end

    it "[security] S19c node_type answered by an own method" do
      thing = thing_type { reauthorize_scoped_objects(false) }
      conn = Class.new(template_connection) do
        graphql_name "LazyConnection"
        define_singleton_method(:node_type) { thing }
      end
      query = query_type do
        field :conn, conn, null: false, connection: true
        field :things, [thing, { null: true }], null: false
      end
      expect(flag_paths(armory::Audit.(schema_for(query)))).to eq([path_of(thing)])
    end

    it "[security] S19d own node-less connection whose reader is a module method calling super" do
      mod = Module.new { def reauthorize_scoped_objects(value = nil) = value.nil? ? false : super }
      conn = Class.new(template_connection) do
        graphql_name "ModConnection"
        extend mod
      end
      query = query_type { field :conn, conn, null: false, connection: true }
      expect(flag_paths(armory::Audit.(schema_for(query)))).to eq([path_of(mod)])
    end

    it "[preservation] S19e node-less connection with scope: false stays clean, rule runs on nodes" do
      thing = thing_type
      conn = Class.new(template_connection) { graphql_name "HandConnection" }
      conn.field :nodes, [thing, { null: true }], null: false, scope: false
      query = query_type { field :things, conn, null: false, connection: true, scope: false }
      schema = schema_for(query)
      expect(record("S19e", schema, "{ things { nodes { secret } } }")).to eq("refused")
      expect(flag_paths(armory::Audit.(schema))).to be_empty
    end
  end

  describe "the reader raises" do
    def audit_outcome(schema)
      armory::Audit.(schema)
      "reported"
    rescue StandardError, ScriptError => error
      "raised #{error.class}: #{error.message[0, 90]}"
    end

    it "[security] X1 node-less connection with an own method that calls super" do
      conn = Class.new(template_connection) do
        graphql_name "SuperConnection"
        def self.reauthorize_scoped_objects(value = nil) = super
      end
      query = query_type { field :conn, conn, null: true, connection: true }
      outcome = audit_outcome(schema_for(query))
      puts "PROBE|X1|#{outcome}"
      expect(outcome).to eq("reported")
    end

    it "[security] X2 connection whose node is a node-less connection" do
      inner = Class.new(template_connection) { graphql_name "InnerConnection" }
      edge = Class.new(template_edge) do
        graphql_name "OuterEdge"
        node_type(inner)
      end
      outer = Class.new(template_connection) do
        graphql_name "OuterConnection"
        edge_type(edge)
      end
      query = query_type { field :conn, outer, null: true, connection: true }
      outcome = audit_outcome(schema_for(query))
      puts "PROBE|X2|#{outcome}"
      expect(outcome).to eq("reported")
    end

    it "[security] X3 own method that raises at audit time" do
      thing = thing_type do
        def self.reauthorize_scoped_objects(_value = nil) = nil.strict?
      end
      query = query_type { field :things, [thing, { null: true }], null: false }
      outcome = audit_outcome(schema_for(query))
      puts "PROBE|X3|#{outcome}"
      expect(outcome).to eq("reported")
    end

    it "[security] X4 own method with a required argument" do
      thing = thing_type do
        def self.reauthorize_scoped_objects(_value) = false
      end
      query = query_type { field :things, [thing, { null: true }], null: false }
      outcome = audit_outcome(schema_for(query))
      puts "PROBE|X4|#{outcome}"
      expect(outcome).to eq("reported")
    end

    it "[security] X5 private own method" do
      thing = thing_type do
        def self.reauthorize_scoped_objects(_value = nil) = false
        private_class_method :reauthorize_scoped_objects
      end
      query = query_type { field :things, [thing, { null: true }], null: false }
      schema = schema_for(query)
      outcome = audit_outcome(schema)
      puts "PROBE|X5|#{outcome}|runtime=#{run_refused(schema, '{ things { secret } }')}"
      expect(outcome).to eq("reported")
    end

    it "[security] X6 two definitions of a name, both hidden at audit: nil in schema.types" do
      v1 = thing_type { def self.visible?(context) = super && context[:v] == 1 }
      v2 = thing_type do
        reauthorize_scoped_objects(false)
        def self.visible?(context) = super && context[:v] == 2
      end
      query = query_type do
        field :ping, String
        field :things, [v1, { null: true }], null: false
        field :things, [v2, { null: true }], null: false
      end
      outcome = audit_outcome(schema_for(query))
      puts "PROBE|X6|#{outcome}"
      expect(outcome).to eq("reported")
    end
  end

  describe "kinds the filter leaves out" do
    it "[preservation] F1 scalar and enum carrying the flag do not bleed to a sibling list" do
      scalar = Class.new(GraphQL::Schema::Scalar) do
        graphql_name "Tag"
        reauthorize_scoped_objects(false)
        def self.scope_items(items, _context) = items.to_a.dup
      end
      thing = thing_type
      query = query_type do
        field :tags, [scalar], null: false
        field :things, [thing, { null: true }], null: false
      end
      schema = schema_for(query)
      expect(record("F1a", schema, "{ tags things { secret } }")).to eq("refused")
      expect(record("F1b", schema, "{ things { secret } tags }")).to eq("refused")
    end
  end

  describe "holder" do
    it "[security] H1 anonymous class: the report's path identifies it and the declaration clears" do
      base = Class.new(base_object) { reauthorize_scoped_objects(false) }
      thing = thing_type(base)
      query = query_type { field :things, [thing, { null: true }], null: false }
      paths = flag_paths(armory::Audit.(schema_for(query)))
      puts "PROBE|H1|paths=#{paths}"
      expect_named_and_cleared(base, ->(checks) { schema_for(query, own_checks: checks) })
    end

  end

  describe "declarations" do
    it "[security] D1 stale declaration on a type whose flag is on" do
      thing = thing_type
      query = query_type { field :things, [thing, { null: true }], null: false }
      report = armory::Audit.(schema_for(query, own_checks: { thing => flag_reason }))
      expect(report.ok?).to be(false)
      expect(report.problems.map(&:message).join).to include("named in own_checks")
    end

    it "[security] D2 a parent's declaration does not clear a child that sets its own flag" do
      base = Class.new(base_object) { reauthorize_scoped_objects(false) }
      child = thing_type(base) { reauthorize_scoped_objects(false) }
      other = thing_type(base, "Other")
      query = query_type do
        field :things, [child, { null: true }], null: false
        field :others, [other, { null: true }], null: false
      end
      report = armory::Audit.(schema_for(query, own_checks: { base => flag_reason }))
      expect(flag_paths(report)).to eq([path_of(child)])
    end

    it "[security] D3 blank, empty and non-string reasons are refused at boot" do
      thing = thing_type
      query = query_type { field :things, [thing, { null: true }], null: false }
      ["", "   ", nil, :symbol, true].each do |reason|
        expect { schema_for(query, own_checks: { thing => { ScopedProbe::FLAG => reason } }) }.to raise_error(ArgumentError)
      end
    end

    it "[security] D4 a declaration on the child when the holder is the parent clears nothing" do
      base = Class.new(base_object) { reauthorize_scoped_objects(false) }
      thing = thing_type(base)
      query = query_type { field :things, [thing, { null: true }], null: false }
      report = armory::Audit.(schema_for(query, own_checks: { thing => flag_reason }))
      expect(flag_paths(report)).to include(path_of(base))
      expect(report.problems.map(&:message).join).to include("named in own_checks")
    end

    it "[security] D6 a declaration on a connection whose flag comes from the node clears nothing" do
      thing = thing_type { reauthorize_scoped_objects(false) }
      conn = named_connection(thing)
      query = query_type { field :conn, conn, null: false, connection: true }
      report = armory::Audit.(schema_for(query, own_checks: { conn => flag_reason }))
      expect(flag_paths(report)).to include(path_of(thing))
    end

    it "[security] D8 stale declaration on a module" do
      mod = Module.new
      thing = thing_type
      query = query_type { field :things, [thing, { null: true }], null: false }
      report = armory::Audit.(schema_for(query, own_checks: { mod => flag_reason }))
      expect(report.problems.map(&:message).join).to include("named in own_checks")
    end
  end

  describe "regression" do
    it "[preservation] R1 broad schema, install template, Node, union, interface, connections, mutation: no flag finding" do
      base_object.connection_type_class(template_connection)
      base_object.edge_type_class(template_edge)
      doc = interface
      thing = thing_type { implements doc }
      other = thing_type(base_object, "Other")
      union = Class.new(GraphQL::Schema::Union) do
        graphql_name "U"
        possible_types thing, other
      end
      base = base_object
      named = named_connection(other, name: "NamedOtherConnection")
      generated = thing.connection_type
      mutation_class = Class.new(GraphQL::Schema::Mutation) do
        graphql_name "Do"
        object_class base
        field :thing, thing
      end
      root_mutation = Class.new(base_object) do
        graphql_name "Mutation"
        authorize :none, reason: "root", covers_fields: true
        field :do, mutation: mutation_class
      end
      query = query_type do
        field :docs, [doc, { null: true }], null: false
        field :us, [union, { null: true }], null: false
        field :conn, generated, null: false, connection: true
        field :named, named, null: false, connection: true
        include GraphQL::Types::Relay::HasNodeField
      end
      schema = schema_for(query, resolved: thing, setup: proc { mutation root_mutation })
      report = armory::Audit.(schema)
      own = report.problems.select { |problem| problem.kind == :own_check }
      expect(own.map(&:path)).to eq([])
    end

    it "[preservation] R4 the plugin's scope_items and graphql-ruby's are not reported" do
      thing = thing_type
      conn = named_connection(thing)
      query = query_type do
        field :things, [thing, { null: true }], null: false
        field :conn, conn, null: false, connection: true
      end
      own = armory::Audit.(schema_for(query)).problems.select { |problem| problem.kind == :own_check }
      expect(own.map(&:path)).to eq([])
    end

    it "[preservation] R5 who really answers on the template classes" do
      thing = thing_type
      conn = named_connection(thing)
      edge = conn.fields["edges"].type.unwrap
      doc = interface
      owners = { thing: thing, conn: conn, edge: edge, doc: doc }.map do |key, klass|
        "#{key}: #{klass.method(:reauthorize_scoped_objects).owner}/#{klass.method(:scope_items).owner}"
      end
      puts "PROBE|R5|#{owners.join(' ; ')}"
      expect(conn.method(:reauthorize_scoped_objects).owner).to eq(GraphQL::Types::Relay::ConnectionBehaviors::ClassMethods)
      expect(thing.method(:reauthorize_scoped_objects).owner).to eq(GraphQL::Schema::Member::Scoped)
    end

    it "[preservation] R6 with scope: false the rule runs even with the flag off" do
      thing = thing_type { reauthorize_scoped_objects(false) }
      query = query_type { field :things, [thing, { null: true }], null: false, scope: false }
      schema = schema_for(query)
      expect(record("R6", schema, "{ things { secret } }")).to eq("refused")
    end
  end
end
