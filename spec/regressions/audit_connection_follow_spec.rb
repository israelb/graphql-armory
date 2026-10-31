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

  def compare(id, schema, query, context: {})
    report = armory::Audit.(schema)
    outcome = run_refused(schema, query, context: context)
    paths = flag_paths(report)
    puts "PROBE|#{id}|#{ArmoryEngine.current}|#{GraphQL::VERSION}|#{outcome}|ok=#{report.ok?}|flag=#{paths}"
    expect("#{outcome} named=#{!paths.empty?}").not_to eq("LEAK named=false")
    [outcome, paths]
  end

  def edge_of(node, name)
    Class.new(template_edge) do
      graphql_name name
      node_type(node)
    end
  end

  def child_interface(parent, name = "ChildDoc", &block)
    interface(name) do
      include parent
      module_eval(&block) if block
    end
  end

  # --- Recheck of the connection-to-node walk (commit 5031b67) ---

  def conn_over(node, name: "ThingConnection", other: "Thing", &block)
    served = thing_type(base_object, other)
    edge = edge_of(served, "#{other}Edge")
    Class.new(template_connection) do
      graphql_name name
      edge_type(edge)
      define_singleton_method(:node_type) { node }
      class_eval(&block) if block
    end
  end

  def query_over(conn, second = nil)
    query_type do
      field :conn, conn, null: false, connection: true
      field :things, second, null: false, connection: true if second
    end
  end

  # What really reached a refused user, and what the audit said: neither may hide the other's crash.
  def observe(id, build, query = "{ conn { nodes { secret } } }")
    schema = build.call({})
    audit = begin
      report = armory::Audit.(schema)
      "ok=#{report.ok?} flag=#{flag_paths(report)}"
    rescue StandardError, NotImplementedError, SystemStackError => error
      "audit raised #{error.class}: #{error.message[0, 80]}"
    end
    outcome = begin
      run_refused(schema, query)
    rescue SystemStackError => error
      "raised #{error.class}"
    end
    puts "PROBE|#{id}|#{ArmoryEngine.current}|#{GraphQL::VERSION}|#{outcome}|#{audit}"
    [outcome, audit]
  end

  def off_hidden(name = "Hidden")
    thing_type(base_object, name) { reauthorize_scoped_objects(false) }
  end

  describe "the three fixed shapes" do
    it "[security] R1 N1 is named and a declaration on the node clears it" do
      hidden = off_hidden
      other_edge = edge_of(thing_type(base_object, "Thing"), "ThingEdge")
      hidden_edge = edge_of(hidden, "HiddenEdge")
      conn = Class.new(template_connection) do
        graphql_name "ThingConnection"
        edge_type(hidden_edge, nodes_field: false)
        own_fields.delete("edges")
        field :edges, [other_edge, { null: true }], null: true
      end
      build = ->(own) { schema_for(query_over(conn), own_checks: own) }
      observe("R1", build, "{ conn { edges { node { secret } } } }")
      expect_named_and_cleared(hidden, build)
    end

    it "[security] R2 N2 is named on the module and a declaration clears it" do
      mod = Module.new { def reauthorize_scoped_objects(_value = nil) = false }
      parent = Class.new(base_object) { extend mod }
      hidden = thing_type(parent, "Hidden")
      other_edge = edge_of(thing_type(base_object, "Thing"), "ThingEdge")
      hidden_edge = edge_of(hidden, "HiddenEdge")
      conn = Class.new(template_connection) do
        graphql_name "ThingConnection"
        edge_type(hidden_edge, nodes_field: false)
        own_fields.delete("edges")
        field :edges, [other_edge, { null: true }], null: true
      end
      build = ->(own) { schema_for(query_over(conn), own_checks: own) }
      observe("R2", build, "{ conn { edges { node { secret } } } }")
      expect_named_and_cleared(mod, build)
    end

    it "[security] R3 N3 is named and a declaration clears it" do
      hidden = off_hidden
      conn = conn_over(hidden)
      build = ->(own) { schema_for(query_over(conn), own_checks: own) }
      observe("R3", build)
      expect_named_and_cleared(hidden, build)
    end

    it "[security] R4 public keyword: edge_type(edge, node_type: hidden, nodes_field: false)" do
      hidden = off_hidden
      other_edge = edge_of(thing_type(base_object, "Thing"), "ThingEdge")
      conn = Class.new(template_connection) do
        graphql_name "ThingConnection"
        edge_type(other_edge, node_type: hidden, nodes_field: false)
      end
      build = ->(own) { schema_for(query_over(conn), own_checks: own) }
      puts "PROBE|R4|hidden_in_types=#{build.call({}).types.value?(hidden)}"
      observe("R4", build, "{ conn { edges { node { secret } } } }")
      expect_named_and_cleared(hidden, build)
    end

    it "[security] R5 off on a superclass of the absent node: the superclass is named" do
      parent = Class.new(base_object) { reauthorize_scoped_objects(false) }
      hidden = thing_type(parent, "Hidden")
      conn = conn_over(hidden)
      build = ->(own) { schema_for(query_over(conn), own_checks: own) }
      observe("R5", build)
      expect_named_and_cleared(parent, build)
    end
  end

  describe "chains of connections" do
    it "[security] R6 connection over a connection over an absent off node" do
      hidden = off_hidden
      inner = conn_over(hidden, name: "InnerConnection", other: "Inner")
      outer = conn_over(inner)
      build = ->(own) { schema_for(query_over(outer), own_checks: own) }
      observe("R6", build)
      expect_named_and_cleared(hidden, build)
    end

    it "[security] R7 three connections deep" do
      hidden = off_hidden
      c3 = conn_over(hidden, name: "C3Connection", other: "C3")
      c2 = conn_over(c3, name: "C2Connection", other: "C2")
      outer = conn_over(c2)
      build = ->(own) { schema_for(query_over(outer), own_checks: own) }
      observe("R7", build)
      expect_named_and_cleared(hidden, build)
    end



    it "[preservation] R10 a connection that is its own node does not hang the audit" do
      conn = nil
      conn = conn_over(Class.new) { define_singleton_method(:node_type) { conn } }
      _outcome, audit = observe("R10", ->(own) { schema_for(query_over(conn), own_checks: own) })
      expect(audit).not_to include("audit raised")
    end

    it "[preservation] R11 two connections in a cycle do not hang the audit" do
      second = nil
      first = conn_over(Class.new) { define_singleton_method(:node_type) { second } }
      second = conn_over(first, name: "SecondConnection", other: "Second")
      _outcome, audit = observe("R11", ->(own) { schema_for(query_over(first), own_checks: own) })
      expect(audit).not_to include("audit raised")
    end
  end

  describe "an own node_type" do
    it "[security] R12 raises: the audit must not call the schema clean" do
      conn = conn_over(Class.new) { define_singleton_method(:node_type) { raise ArgumentError, "app node_type" } }
      outcome, audit = observe("R12", ->(own) { schema_for(query_over(conn), own_checks: own) })
      expect("#{outcome} #{audit}").not_to match(/LEAK.*ok=true/)
    end


    it "[security] R14 returns nil: compare with the query" do
      conn = conn_over(nil)
      outcome, audit = observe("R14", ->(own) { schema_for(query_over(conn), own_checks: own) })
      expect("#{outcome} #{audit}").not_to match(/LEAK.*ok=true/)
      expect(audit).not_to include("audit raised")
    end

    it "[security] R15 returns a non-null wrapper of an off type" do
      hidden = off_hidden
      conn = conn_over(hidden.to_non_null_type)
      outcome, audit = observe("R15", ->(own) { schema_for(query_over(conn), own_checks: own) })
      expect("#{outcome} #{audit}").not_to match(/LEAK.*ok=true/)
    end

    it "[preservation] R16 subclass of a concrete connection has nil node_type: audit does not raise" do
      served_edge = edge_of(thing_type(base_object, "Parent"), "ParentEdge"); parent = Class.new(template_connection) { graphql_name "ParentConnection"; edge_type(served_edge) }
      child = Class.new(parent) { graphql_name "ChildConnection" }
      child_node = child.node_type
      outcome, audit = observe("R16", ->(own) { schema_for(query_over(child), own_checks: own) })
      puts "PROBE|R16|child_node_type=#{child_node.inspect}"
      expect("#{outcome} #{audit}").not_to match(/LEAK.*ok=true/)
      expect(audit).not_to include("audit raised")
    end

    it "[security] R17 connection with an own reader answering true over an absent off node" do
      hidden = off_hidden
      conn = conn_over(hidden) { define_singleton_method(:reauthorize_scoped_objects) { |_value = nil| true } }
      build = ->(own) { schema_for(query_over(conn), own_checks: own) }
      observe("R17", build)
      paths = flag_paths(armory::Audit.(build.call({})))
      expect(paths).to include(path_of(hidden))
      expect(paths).to include(path_of(conn))
    end
  end

  describe "a node that is an interface or a union" do
    it "[security] R18 absent interface with an own reader in definition_methods answering false" do
      doc = interface("Doc") { definition_methods { def reauthorize_scoped_objects(_value = nil) = false } }
      conn = conn_over(doc)
      build = ->(own) { schema_for(query_over(conn), own_checks: own) }
      outcome, audit = observe("R18", build)
      puts "PROBE|R18|in_types=#{build.call({}).types.value?(doc)}"
      expect(audit).to include("reauthorize_scoped_objects")
      expect("#{outcome} #{audit}").not_to match(/LEAK.*flag=\[\]/)
    end

    it "[security] R19 absent interface with a singleton reader answering false" do
      doc = interface("Doc") { define_singleton_method(:reauthorize_scoped_objects) { |_value = nil| false } }
      conn = conn_over(doc)
      build = ->(own) { schema_for(query_over(conn), own_checks: own) }
      observe("R19", build)
      expect_named_and_cleared(doc, build)
    end

    it "[security] R20 absent interface off by ivar" do
      doc = interface("Doc") { reauthorize_scoped_objects(false) }
      conn = conn_over(doc)
      build = ->(own) { schema_for(query_over(conn), own_checks: own) }
      observe("R20", build)
      expect_named_and_cleared(doc, build)
    end

    it "[security] R21 absent child interface whose parent has the own reader" do
      parent = interface("ParentDoc") { define_singleton_method(:reauthorize_scoped_objects) { |_value = nil| false } }
      child = child_interface(parent)
      conn = conn_over(child)
      build = ->(own) { schema_for(query_over(conn), own_checks: own) }
      observe("R21", build)
      expect_named_and_cleared(parent, build)
    end

    it "[security] R22 absent union off by ivar" do
      member = thing_type(base_object, "Member")
      union = Class.new(GraphQL::Schema::Union) do
        graphql_name "Pick"
        possible_types member
        reauthorize_scoped_objects(false)
      end
      conn = conn_over(union)
      build = ->(own) { schema_for(query_over(conn), own_checks: own) }
      observe("R22", build)
      expect_named_and_cleared(union, build)
    end

    it "[security] R23 absent union with an own reader" do
      member = thing_type(base_object, "Member")
      union = Class.new(GraphQL::Schema::Union) do
        graphql_name "Pick"
        possible_types member
        define_singleton_method(:reauthorize_scoped_objects) { |_value = nil| false }
      end
      conn = conn_over(union)
      build = ->(own) { schema_for(query_over(conn), own_checks: own) }
      observe("R23", build)
      expect_named_and_cleared(union, build)
    end
  end

  describe "the seen guard" do
    it "[security] R24 a connection true over a node does not hide a second one that reads the node" do
      hidden = off_hidden
      on = conn_over(hidden, name: "OnConnection", other: "OnServed") { reauthorize_scoped_objects(true) }
      plain = conn_over(hidden)
      build = ->(own) { schema_for(query_over(on, plain), own_checks: own) }
      observe("R24", build, "{ things { nodes { secret } } }")
      expect_named_and_cleared(hidden, build)
    end

    it "[security] R25 two connections with one absent node report it once and one declaration clears both" do
      hidden = off_hidden
      first = conn_over(hidden)
      second = conn_over(hidden, name: "SecondConnection", other: "Second")
      build = ->(own) { schema_for(query_over(first, second), own_checks: own) }
      paths = flag_paths(armory::Audit.(build.call({})))
      puts "PROBE|R25|#{paths}"
      expect(paths).to eq([path_of(hidden)])
      expect_named_and_cleared(hidden, build)
    end

    it "[security] R26 a cycle does not hide another connection's absent node" do
      hidden = off_hidden
      second = nil
      first = conn_over(Class.new) { define_singleton_method(:node_type) { second } }
      second = conn_over(first, name: "SecondConnection", other: "Second")
      other = conn_over(hidden, name: "OtherConnection", other: "OtherServed")
      build = ->(own) { schema_for(query_over(first, other), own_checks: own) }
      expect_named_and_cleared(hidden, build)
    end

    it "[security] R27 a chain reaching a connection already walked as a type of its own still reaches its node" do
      hidden = off_hidden
      inner = conn_over(hidden, name: "InnerConnection", other: "Inner")
      outer = conn_over(inner)
      build = ->(own) { schema_for(query_over(inner, outer), own_checks: own) }
      expect_named_and_cleared(hidden, build)
    end

    it "[security] R28 two distinct absent nodes are both named" do
      one = off_hidden("HiddenOne")
      two = off_hidden("HiddenTwo")
      first = conn_over(one)
      second = conn_over(two, name: "SecondConnection", other: "Second")
      paths = flag_paths(armory::Audit.(schema_for(query_over(first, second))))
      expect(paths).to contain_exactly(path_of(one), path_of(two))
    end
  end

  describe "the sibling of the flag on the same walk" do
    def scoping_schema(query_class, own_checks: {})
      plugin = armory
      adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: true, scoped: ->(_items) { [] })
      Class.new(base_schema) do
        use plugin, adapter: adapter, own_checks: own_checks
        query query_class
      end
    end

    it "[security] R29 absent node with an own scope_items replaces the user's scope, audit must name it" do
      hidden = thing_type(base_object, "Hidden") { define_singleton_method(:scope_items) { |items, _context| items } }
      schema = scoping_schema(query_over(conn_over(hidden)))
      report = armory::Audit.(schema)
      scope_paths = report.problems.select { |problem| problem.path.include?("scope_items") }.map(&:path)
      outcome = run_refused(schema, "{ conn { nodes { secret } } }")
      puts "PROBE|R29|#{ArmoryEngine.current}|#{GraphQL::VERSION}|#{outcome}|ok=#{report.ok?}|scope=#{scope_paths}|in_types=#{schema.types.value?(hidden)}"
      expect("#{outcome} named=#{!scope_paths.empty?}").not_to eq("LEAK named=false")
    end

    it "[preservation] R30 control for R29: the same node with the plugin's scope gives the user nothing" do
      hidden = thing_type(base_object, "Hidden")
      schema = scoping_schema(query_over(conn_over(hidden)))
      outcome = run_refused(schema, "{ conn { nodes { secret } } }")
      puts "PROBE|R30|#{ArmoryEngine.current}|#{GraphQL::VERSION}|#{outcome}"
      expect(outcome).to eq("refused")
    end
  end

  describe "ordinary schemas stay clean" do
    it "[preservation] R31 generated connections over an object, interface, union, scalar and enum" do
      thing = thing_type
      doc = interface("Doc")
      member = thing_type(base_object, "Member")
      union = Class.new(GraphQL::Schema::Union) do
        graphql_name "Pick"
        possible_types member
      end
      enum = Class.new(GraphQL::Schema::Enum) do
        graphql_name "Color"
        value "RED"
      end
      query = query_type do
        field :things, thing.connection_type, null: false
        field :docs, doc.connection_type, null: false
        field :picks, union.connection_type, null: false
        field :tags, GraphQL::Types::String.connection_type, null: false
        field :colors, enum.connection_type, null: false
      end
      report = armory::Audit.(schema_for(query, orphans: [thing]))
      own = report.problems.select { |problem| problem.kind == :own_check }.map(&:path)
      puts "PROBE|R31|own_check=#{own}"
      expect(own).to be_empty
    end

    it "[preservation] R32 node with the flag on, absent, is not reported" do
      hidden = thing_type(base_object, "Hidden") { reauthorize_scoped_objects(true) }
      conn = conn_over(hidden)
      report = armory::Audit.(schema_for(query_over(conn)))
      expect(flag_paths(report)).to be_empty
    end

    it "[preservation] R33 a declaration on a clean absent node is still called stale" do
      hidden = thing_type(base_object, "Hidden")
      conn = conn_over(hidden)
      report = armory::Audit.(schema_for(query_over(conn), own_checks: { hidden => flag_reason }))
      expect(report.problems.map(&:path)).to include("#{hidden.inspect} reauthorize_scoped_objects")
    end
  end
end
