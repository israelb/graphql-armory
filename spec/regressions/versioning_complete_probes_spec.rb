# frozen_string_literal: true

# Independent verification probes for feat/versioning-complete (3b2, 3b3, 4, 5, 6).
# Each probe is one `it`, labelled [security] or [preservation]. Kept outside the repo; copied in to run.
require "spec_helper"
require "stringio"
require "tmpdir"
require "fileutils"

module VP
  V0 = "2024-01-15"
  V1 = "2024-06-01"
  V2 = "2025-01-01"
  VERSIONS = [V0, V1, V2].freeze
  NEW_API = GraphQL::Armory::Versioning.respond_to?(:profiles)

  module_function

  def obj(**values)
    Class.new do
      values.each { |name, value| define_method(name) { |**_args| value.respond_to?(:call) ? value.call : value } }
    end.new
  end

  def bases(authorization: false) = GraphQL::Armory::Versioning::Controls::Deprecations::Bases.example(authorization: authorization)

  def schema(query:, visibility: :visibility, default: :latest, profiles: false, preload: nil, dynamic: nil, own_checks: nil,
             subscription: nil, mutation: nil, sinks: [], retired: [V0], versions: VERSIONS, &extra)
    opts = { versions: versions, default: default, retired: retired, sinks: sinks }
    opts[:own_checks] = own_checks if own_checks
    opts[:profiles] = true if profiles
    Class.new(ArmoryEngine.base_schema) do
      query(query)
      mutation(mutation) if mutation
      subscription(subscription) if subscription
      use GraphQL::Armory::Versioning, **opts
      if visibility == :warden
        use GraphQL::Schema::Warden
      else
        vis = {}
        vis[:profiles] = GraphQL::Armory::Versioning.profiles(self) if profiles
        vis[:preload] = preload unless preload.nil?
        vis[:dynamic] = dynamic unless dynamic.nil?
        use GraphQL::Schema::Visibility, **vis
      end
      class_exec(&extra) if extra
    end
  end

  def audit(schema, **opts) = GraphQL::Armory::Versioning::Audit.(schema, **opts)

  def failing(report, kind = nil) = report.problems.reject(&:information?).select { |p| kind.nil? || p.kind == kind }

  def info(report, kind = nil) = report.problems.select(&:information?).select { |p| kind.nil? || p.kind == kind }

  def type_fields(result, type)
    result.dig("data", "__type", "fields")&.to_h { |f| [f["name"], f] }
  end
end

# Independent verification probes for PR #74 (versioning 3b2-6), kept as regressions.
RSpec.describe "Versioning verification probes" do
  include VP

  def run(schema, query, version, **opts)
    execute_query(schema, query, context: { armory_version: version }.merge(opts.delete(:context) || {}), **opts).to_h
  end

  def intro_fields(schema, type, version, include_deprecated: true)
    q = "{ __type(name: \"#{type}\") { fields(includeDeprecated: #{include_deprecated}) { name isDeprecated deprecationReason type { name kind ofType { name } } args { name } } } }"
    VP.type_fields(run(schema, q, version), type)
  end

  # ---------------------------------------------------------------------------------------------------------------
  # S1 :fallback and contract
  # ---------------------------------------------------------------------------------------------------------------
  def fallback_parent_schema(visibility)
    b = VP.bases
    parent = Class.new(b[:object]) do
      graphql_name "Parent"
      field :x, String, null: true
    end
    child = Class.new(parent) do
      graphql_name "Child"
      field :x, Integer, null: true, removed: VP::V2
    end
    query = Class.new(b[:object]) do
      graphql_name "Query"
      field :child, child, null: false
    end
    [VP.schema(query: query, visibility: visibility), VP.obj(child: VP.obj(x: 5))]
  end

  it "[security] F1 Warden: a parent's definition served when the child's is removed is reported as :fallback at Child.x" do
    schema, root = fallback_parent_schema(:warden)
    v2 = intro_fields(schema, "Child", VP::V2)
    v1 = intro_fields(schema, "Child", VP::V1)
    expect(v1["x"]["type"]["name"]).to eq("Int")
    expect(v2["x"]["type"]["name"]).to eq("String") # the hazard: V2 is served Parent's x
    expect(run(schema, "{ child { x } }", VP::V2, root_value: root).dig("data", "child", "x")).to eq("5")
    report = VP.audit(schema)
    expect(report.ok?).to be(false)
    expect(VP.failing(report, :fallback).map(&:path)).to include("Child.x")
  end

  it "[security] F1b Visibility: same shape, field dropped in V2; audit says what (records the verdict)" do
    schema, root = fallback_parent_schema(:visibility)
    v2 = intro_fields(schema, "Child", VP::V2)
    expect(v2).not_to have_key("x")
    report = VP.audit(schema)
    puts "\n[F1b] Visibility audit ok?=#{report.ok?} fallback=#{VP.failing(report, :fallback).map(&:message).inspect}"
    expect(run(schema, "{ child { x } }", VP::V2, root_value: root)["errors"]).not_to be_nil
  end

  def interface_first_schema(visibility, shape)
    b = VP.bases
    iface = Module.new do
      include b[:interface]
      graphql_name "Iface"
      field :x, String, null: true
    end
    iface2 = Module.new do
      include b[:interface]
      graphql_name "Iface2"
      implements iface
    end
    parent = Class.new(b[:object]) do
      graphql_name "Parent"
      field :x, GraphQL::Types::Boolean, null: true if shape == :interface_before_superclass
      implements iface if shape == :inherited_interface
    end
    child = Class.new(parent) do
      graphql_name "Child"
      implements iface if shape == :interface_before_superclass
      implements iface2 if shape == :interface_of_interface
      field :x, Integer, null: true, removed: VP::V2
      field :y, String, null: true
    end
    query = Class.new(b[:object]) do
      graphql_name "Query"
      field :child, child, null: false
    end
    s = VP.schema(query: query, visibility: visibility) { orphan_types(child) }
    [s, VP.obj(child: VP.obj(x: 5, y: "y"))]
  end

  %i[interface_before_superclass inherited_interface interface_of_interface].each do |shape|
    it "[security] F2 Warden #{shape}: the definition the Warden really serves in V2 is the one the audit names" do
      schema, root = interface_first_schema(:warden, shape)
      served = intro_fields(schema, "Child", VP::V2)["x"]
      expect(served["type"]["name"]).to eq("String") # Iface's
      data = run(schema, "{ child { x } }", VP::V2, root_value: root)
      expect(data.dig("data", "child", "x")).to eq("5")
      report = VP.audit(schema)
      fallback = VP.failing(report, :fallback).find { |p| p.path == "Child.x" }
      expect(fallback).not_to be_nil
      expect(fallback.message).to include("Iface")
    end

    it "[security] F2v Visibility #{shape}: V2 Child misses x that Iface declares; audit reports :fallback at Child.x" do
      schema, root = interface_first_schema(:visibility, shape)
      expect(intro_fields(schema, "Child", VP::V2) || {}).not_to have_key("x")
      res = begin
        run(schema, "{ child { ... on Iface { x } } }", VP::V2, root_value: root)
      rescue StandardError => e
        "#{e.class}: #{e.message}"
      end
      puts "\n[F2v #{shape}] V2 request: #{res.inspect[0, 300]}"
      report = VP.audit(schema)
      expect(VP.failing(report, :fallback).map(&:path)).to include("Child.x")
    end
  end

  def type_hidden_nearest_schema(visibility, via)
    b = VP.bases
    legacy = Class.new(b[:object]) do
      graphql_name "Legacy"
      lifecycle removed: VP::V2
      field :n, Integer, null: true
    end
    iface = Module.new do
      include b[:interface]
      graphql_name "Iface"
      field :x, String, null: true
    end
    parent = Class.new(b[:object]) do
      graphql_name "Parent"
      field :x, String, null: true if via == :parent
    end
    child = Class.new(parent) do
      graphql_name "Child"
      implements iface if via == :interface
      field :x, legacy, null: true # no lifecycle of its own: hidden in V2 only because Legacy is
      field :y, String, null: true
    end
    query = Class.new(b[:object]) do
      graphql_name "Query"
      field :child, child, null: false
    end
    [VP.schema(query: query, visibility: visibility), VP.obj(child: VP.obj(x: "s", y: "y"))]
  end

  %i[parent interface].each do |via|
    it "[security] F6 Warden (#{via}): nearest definition hidden by its type's lifecycle; the farther one is served in V2 and the audit must not be ok" do
      schema, root = type_hidden_nearest_schema(:warden, via)
      served = intro_fields(schema, "Child", VP::V2)["x"]
      expect(served["type"]["name"]).to eq("String") # hazard: a different definition, type and resolver in V2
      expect(run(schema, "{ child { x } }", VP::V2, root_value: root).dig("data", "child", "x")).to eq("s")
      report = VP.audit(schema)
      puts "\n[F6 #{via}] ok?=#{report.ok?}\n#{report}"
      expect(report.ok?).to be(false)
      expect(VP.failing(report, :fallback).map(&:path)).to include("Child.x")
    end
  end

  it "[security] F6v Visibility (interface): nearest hidden by its type; V2 Child no longer has Iface's x; audit must report it" do
    schema, = type_hidden_nearest_schema(:visibility, :interface)
    expect(intro_fields(schema, "Child", VP::V2) || {}).not_to have_key("x")
    res = begin
      run(schema, "{ child { ... on Iface { x } } }", VP::V2, root_value: VP.obj(child: VP.obj(x: "s", y: "y")))
    rescue StandardError => e
      "#{e.class}: #{e.message}"
    end
    puts "\n[F6v] V2 request: #{res.inspect[0, 200]}"
    report = VP.audit(schema)
    puts "\n[F6v] ok?=#{report.ok?}\n#{report}"
    expect(report.ok?).to be(false)
    expect(VP.failing(report).map(&:path)).to include("Child.x")
  end

  %i[warden visibility].each do |vis|
    it "[security] F6c #{vis} (covariant interface): Child.x returns Legacy (implements Shape) over Iface.x: Shape; Legacy removed in V2" do
      b = VP.bases
      shape = Module.new { include b[:interface]; graphql_name "Shape"; field :n, Integer, null: true }
      legacy = Class.new(b[:object]) { graphql_name "Legacy"; lifecycle removed: VP::V2; implements shape; field :n, Integer, null: true }
      square = Class.new(b[:object]) { graphql_name "Square"; implements shape; field :n, Integer, null: true }
      iface = Module.new { include b[:interface]; graphql_name "Iface"; field :x, shape, null: true }
      child = Class.new(b[:object]) do
        graphql_name "Child"
        implements iface
        field :x, legacy, null: true
        field :y, String, null: true
      end
      query = Class.new(b[:object]) { graphql_name "Query"; field :child, child, null: false }
      schema = VP.schema(query: query, visibility: vis) { orphan_types(square) }
      schema.define_singleton_method(:resolve_type) { |_t, _o, _c| square }
      root = VP.obj(child: VP.obj(x: VP.obj(n: 1), y: "y"))
      v2 = intro_fields(schema, "Child", VP::V2)
      res = begin
        run(schema, "{ child { ... on Iface { x { n } } } }", VP::V2, root_value: root)
      rescue StandardError => e
        "#{e.class}: #{e.message}"
      end
      puts "\n[F6c #{vis}] V2 Child.x=#{v2['x'].inspect} request=#{res.inspect[0, 200]}"
      report = VP.audit(schema)
      puts "[F6c #{vis}] ok?=#{report.ok?}\n#{report}"
      expect(report.ok?).to be(false)
    end
  end

  xit "[security] DROPPED-DUP F7 contract: an argument the object's field hides in V2 while the interface's field takes it" do
    b = VP.bases
    iface = Module.new do
      include b[:interface]
      graphql_name "Iface"
      field :x, String, null: true do
        argument :a, String, required: false
      end
    end
    thing = Class.new(b[:object]) do
      graphql_name "Thing"
      implements iface
      field :x, String, null: true do
        argument :a, String, required: false, removed: VP::V2
      end
    end
    query = Class.new(b[:object]) { graphql_name "Query"; field :thing, thing, null: false }
    %i[warden visibility].each do |vis|
      schema = VP.schema(query: query, visibility: vis)
      args = intro_fields(schema, "Thing", VP::V2)["x"]["args"].map { |a| a["name"] }
      expect(args).to eq([])
      report = VP.audit(schema)
      expect(VP.failing(report, :fallback).map(&:path)).to include("Thing.x.a"), "#{vis}: #{report}"
    end
  end

  it "[preservation] F8 a correct versioned schema (twins, deprecated:, field removed with its interface) stays ok in both modes" do
    b = VP.bases
    iface = Module.new do
      include b[:interface]
      graphql_name "Iface"
      field :id, String, null: true
      field :x, String, null: true, removed: VP::V2
    end
    parent = Class.new(b[:object]) { graphql_name "Parent"; field :y, String, null: true }
    child = Class.new(parent) do
      graphql_name "Child"
      implements iface
      field :x, String, null: true, removed: VP::V2
      field :y, String, null: true, deprecated: VP::V2, deprecation_reason: "old"
      field :z, Integer, null: true, removed: VP::V2
      field :z, String, null: true, added: VP::V2
    end
    query = Class.new(b[:object]) { graphql_name "Query"; field :child, child, null: false }
    %i[warden visibility].each do |vis|
      report = VP.audit(VP.schema(query: query, visibility: vis))
      expect(report.ok?).to be(true), "#{vis}: #{report}"
    end
  end

  it "[security] F5 / idea 1: deprecated: twins over a parent's definition give no :fallback, :duplicate, :implicit, :own_check or :retired_only problem" do
    b = VP.bases
    parent = Class.new(b[:object]) { graphql_name "Parent"; field :x, String, null: true }
    status = Class.new(b[:enum]) do
      graphql_name "Status"
      value "PAID"
      value "OLD", deprecated: VP::V1, deprecation_reason: "Use PAID" # V1 is the first served: before-twin lives only in retired V0
    end
    input = Class.new(b[:input]) do
      graphql_name "Filter"
      argument :code, String, required: false, deprecated: VP::V2, deprecation_reason: "Use number"
      argument :number, String, required: false
    end
    child = Class.new(parent) do
      graphql_name "Child"
      field :x, String, null: true, deprecated: VP::V2, deprecation_reason: "Use y"
      field :s, status, null: true, deprecated: VP::V2, deprecation_reason: "r" do
        argument :f, input, required: false, deprecated: VP::V2, deprecation_reason: "q"
      end
    end
    query = Class.new(b[:object]) { graphql_name "Query"; field :child, child, null: false }
    %i[warden visibility].each do |vis|
      report = VP.audit(VP.schema(query: query, visibility: vis))
      expect(report.ok?).to be(true), "#{vis}: #{report}"
      kinds = report.problems.map(&:kind)
      expect(kinds & %i[fallback duplicate own_check]).to eq([]), "#{vis}: #{report}"
      expect(VP.info(report, :retired_only).map(&:path)).to eq(["Status.OLD"]), "#{vis}: #{report}"
      strict = VP.audit(VP.schema(query: query, visibility: vis), strict: true)
      expect(VP.failing(strict, :retired_only).map(&:path)).to eq(["Status.OLD"])
    end
  end

  # ---------------------------------------------------------------------------------------------------------------
  # S2 :own_check
  # ---------------------------------------------------------------------------------------------------------------
  def own_check_world
    b = VP.bases
    app_object = Class.new(b[:object]) do
      def self.name = "AppObject"
      def self.visible?(context) = super
    end
    gone = Class.new(app_object) do
      graphql_name "Gone"
      lifecycle removed: VP::V2
      def self.name = "GoneType"
      def self.visible?(_context) = true # skips super: served in V2
      field :n, Integer, null: true
    end
    query = Class.new(b[:object]) do
      graphql_name "Query"
      field :gone, gone, null: true
      field :ok, String, null: true
    end
    [b, app_object, gone, query]
  end

  it "[security] O1 an undeclared visible? that skips super serves a type outside its lifecycle; audit reports :own_check at its holder" do
    _, _, _gone, query = own_check_world
    schema = VP.schema(query: query)
    res = run(schema, '{ __type(name: "Gone") { name } }', VP::V2)
    puts "\n[O1] V2 __type(Gone): #{res.inspect}"
    report = VP.audit(schema)
    expect(report.ok?).to be(false)
    expect(VP.failing(report, :own_check).map(&:path)).to include("Gone.visible?")
  end

  it "[security] O2 declaring the superclass never silences a subclass's own visible?" do
    _, app_object, _gone, query = own_check_world
    report = VP.audit(VP.schema(query: query, own_checks: { app_object => { visible?: "calls super" } }))
    expect(VP.failing(report, :own_check).map(&:path)).to include("Gone.visible?")
    expect(VP.info(report, :own_check).map(&:path)).to include("AppObject.visible?")
  end

  it "[security] O3 a visible? from a module extended on a base: declaring the class instead of the module silences nothing" do
    b = VP.bases
    vis = Module.new do
      def self.name = "VisMod"
      def visible?(_context) = true
    end
    base = Class.new(b[:object]) { def self.name = "ExtBase"; extend vis }
    gone = Class.new(base) { graphql_name "Gone"; lifecycle removed: VP::V2; field :n, Integer, null: true }
    query = Class.new(b[:object]) { graphql_name "Query"; field :gone, gone, null: true }
    report = VP.audit(VP.schema(query: query, own_checks: { base => { visible?: "wrong holder" } }))
    paths = VP.failing(report, :own_check).map(&:path)
    expect(paths).to include("VisMod.visible?")
    expect(paths.join(" ")).to include("ExtBase")
    declared = VP.audit(VP.schema(query: query, own_checks: { vis => { visible?: "the module" } }))
    expect(VP.failing(declared, :own_check)).to eq([])
    expect(VP.info(declared, :own_check).map(&:path)).to include("VisMod.visible?")
  end

  it "[security] O4 declaring a holder that only inherits the method silences nothing" do
    _, app_object, gone, query = own_check_world
    leaf = Class.new(app_object) { graphql_name "Leaf"; def self.name = "LeafType"; field :n, Integer, null: true }
    q = Class.new(query) { graphql_name "Query"; field :leaf, leaf, null: true }
    report = VP.audit(VP.schema(query: q, own_checks: { leaf => { visible?: "inherits" }, gone => { visible?: "declared" } }))
    paths = VP.failing(report, :own_check).map(&:path)
    expect(paths).to include("AppObject.visible?")
    expect(paths.join(" ")).to include("Leaf")
  end

  it "[security] O5 a field class's own visible? (instance) is reported, and only declared under that class" do
    b = VP.bases
    own_field = Class.new(b[:field]) do
      def self.name = "OwnField"
      def visible?(_context) = true
    end
    holder = Class.new(b[:object]) do
      graphql_name "Holder"
      field_class own_field
      field :n, Integer, null: true
      field :old, String, null: true, removed: VP::V2
    end
    query = Class.new(b[:object]) do
      graphql_name "Query"
      field :holder, holder, null: true
    end
    schema = VP.schema(query: query)
    expect(intro_fields(schema, "Holder", VP::V2)).to have_key("old") # hazard shown
    report = VP.audit(schema)
    expect(VP.failing(report, :own_check).map(&:path).join(" ")).to include("OwnField")
    declared = VP.audit(VP.schema(query: query, own_checks: { b[:field] => { visible?: "wrong one" } }))
    expect(VP.failing(declared, :own_check).map(&:path).join(" ")).to include("OwnField")
    right = VP.audit(VP.schema(query: query, own_checks: { own_field => { visible?: "right one" } }))
    expect(VP.failing(right, :own_check)).to eq([])
  end

  xit "[security] DROPPED-DUP O6 a schema self.visible? skipping super is reported at the schema" do
    b = VP.bases
    query = Class.new(b[:object]) { graphql_name "Query"; field :ok, String, null: true; field :old, String, null: true, removed: VP::V2 }
    schema = VP.schema(query: query) { def self.visible?(_member, _context) = true }
    expect(intro_fields(schema, "Query", VP::V2)).to have_key("old")
    report = VP.audit(schema)
    expect(VP.failing(report, :own_check).size).to be >= 1
    expect(report.ok?).to be(false)
  end

  xit "[security] DROPPED-DUP O7 a def self.visible? on one field is reported at that field and cannot be declared away" do
    b = VP.bases
    query = Class.new(b[:object]) do
      graphql_name "Query"
      field :ok, String, null: true
      field :old, String, null: true, removed: VP::V2 do
        def self.visible?(_context) = true
      end
    end
    schema = VP.schema(query: query, own_checks: { b[:field] => { visible?: "x" } })
    expect(intro_fields(schema, "Query", VP::V2)).to have_key("old")
    report = VP.audit(schema)
    expect(VP.failing(report, :own_check).map(&:path)).to include("Query.old")
  end

  it "[security] O8 an interface's definition_methods visible? is reported; declaring that interface lists it as information" do
    b = VP.bases
    iface = Module.new do
      include b[:interface]
      graphql_name "Iface"
      lifecycle removed: VP::V2
      definition_methods { def visible?(_context) = true }
      field :x, String, null: true
    end
    thing = Class.new(b[:object]) { graphql_name "Thing"; implements iface; field :y, String, null: true }
    query = Class.new(b[:object]) { graphql_name "Query"; field :thing, thing, null: true }
    report = VP.audit(VP.schema(query: query))
    expect(VP.failing(report, :own_check).map(&:path)).to include("Iface.visible?")
    declared = VP.audit(VP.schema(query: query, own_checks: { iface => { visible?: "r" } }))
    expect(VP.failing(declared, :own_check)).to eq([])
  end

  xit "[security] DROPPED-DUP O10 a resolver's self.visible? is reported" do
    b = VP.bases
    resolver = Class.new(b[:resolver]) do
      graphql_name "Finder"
      def self.name = "FinderResolver"
      type String, null: true
      lifecycle removed: VP::V2
      def self.visible?(_context) = true
      def resolve = "r"
    end
    query = Class.new(b[:object]) { graphql_name "Query"; field :ok, String, null: true; field :find, resolver: resolver }
    report = VP.audit(VP.schema(query: query))
    expect(VP.failing(report, :own_check).map(&:path).join(" ")).to include("visible?")
    expect(VP.failing(report, :own_check)).not_to be_empty
  end

  xit "[security] DROPPED-DUP O11 own_checks: refuses anything but { Module => { visible?: non-empty reason } }" do
    b = VP.bases
    query = Class.new(b[:object]) { graphql_name "Query"; field :ok, String, null: true }
    [{ b[:object] => { visible?: "" } }, { b[:object] => { authorized?: "r" } }, { b[:object] => {} }, { "Types::X" => { visible?: "r" } },
     { b[:object] => { visible?: "r", other: "r" } }, []].each do |bad|
      expect { VP.schema(query: query, own_checks: bad) }.to raise_error(GraphQL::Armory::Versioning::ConfigurationError), bad.inspect
    end
  end

  # ---------------------------------------------------------------------------------------------------------------
  # S2 :default_value
  # ---------------------------------------------------------------------------------------------------------------
  def default_world(plain_arg: true)
    b = VP.bases
    plain = Class.new(GraphQL::Schema::Argument)
    status = Class.new(b[:enum]) do
      graphql_name "Status"
      value "OLD"
      value "NEW", added: VP::V2
    end
    filter = Class.new(b[:input]) do
      graphql_name "Filter"
      argument :a, String, required: false
      argument :b, String, required: false, added: VP::V2
    end
    arg_class = plain_arg ? plain : b[:argument]
    field_class = Class.new(GraphQL::Schema::Field) { argument_class(arg_class) }
    query = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field_class(field_class)
      field :list, String, null: true do
        argument :status, status, required: false, default_value: "NEW"
      end
      field :search, String, null: true do
        argument :filter, filter, required: false, default_value: { b: "x" }
      end
    end
    query
  end

  it "[security] D1/D3 an argument without Base whose default is an enum value or input field outside V1 is :default_value for V1" do
    schema = VP.schema(query: default_world, versions: VP::VERSIONS)
    res = begin
      run(schema, '{ __type(name: "Query") { fields { name args { name defaultValue } } } }', VP::V1)
    rescue StandardError => e
      "#{e.class}: #{e.message[0, 120]}"
    end
    puts "\n[D1] V1 introspection: #{res.inspect[0, 400]}"
    sdl = begin
      schema.to_definition(context: { armory_version: VP::V1 })[/search.*\n/]
    rescue StandardError => e
      "#{e.class}: #{e.message[0, 120]}"
    end
    puts "[D1] V1 SDL: #{sdl.inspect}"
    report = VP.audit(schema)
    paths = VP.failing(report, :default_value).map(&:path)
    expect(paths).to include("Query.list.status", "Query.search.filter")
  end

  it "[preservation] D4 a default naming a deprecated: enum value (two twins) is no :default_value" do
    b = VP.bases
    status = Class.new(b[:enum]) do
      graphql_name "Status"
      value "PAID"
      value "CANCELLED", deprecated: VP::V2, deprecation_reason: "r"
    end
    plain = Class.new(GraphQL::Schema::Argument)
    fc = Class.new(GraphQL::Schema::Field) { argument_class(plain) }
    query = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field_class(fc)
      field :list, String, null: true do
        argument :status, status, required: false, default_value: "CANCELLED"
      end
    end
    report = VP.audit(VP.schema(query: query))
    expect(report.problems.select { |p| p.kind == :default_value }).to eq([])
    expect(report.ok?).to be(true), report.to_s
  end

  it "[security] D2 a Base argument defined after load whose default the latest version lacks: :default_value (to_definition raises in every version)" do
    b = VP.bases
    status = Class.new(b[:enum]) do
      graphql_name "Status"
      value "PAID"
      value "GONE", removed: VP::V2
    end
    query = Class.new(b[:object]) { graphql_name "Query"; field :ok, String, null: true }
    schema = VP.schema(query: query)
    run(schema, "{ ok }", VP::V1, root_value: VP.obj(ok: "o"))
    query.field :late, String, null: true do
      argument :s, status, required: false, default_value: "GONE", removed: VP::V2
    end
    sdl = begin
      schema.to_definition(context: { armory_version: VP::V1 })
      "printed"
    rescue StandardError => e
      e.class.name
    end
    puts "\n[D2] V1 to_definition after late arg: #{sdl}"
    report = VP.audit(schema)
    expect(VP.failing(report, :default_value).map(&:path)).to include("Query.late.s")
  end

  # ---------------------------------------------------------------------------------------------------------------
  # S2 :subscription_trigger
  # ---------------------------------------------------------------------------------------------------------------
  class MemSubs < GraphQL::Subscriptions
    attr_reader :subscribed, :triggered

    def initialize(**options)
      super
      @subscribed = []
      @triggered = []
    end

    def write_subscription(query, events)
      events.each { |event| @subscribed << [query.context[:armory_version], event.topic] }
    end

    def execute_all(event, _object)
      @triggered << event.topic
    end

    def delete_subscription(_id); end
  end

  def subscription_world(shape)
    b = VP.bases
    payload = Class.new(b[:object]) { graphql_name "Tick"; field :n, Integer, null: true }
    filter = Class.new(b[:input]) do
      graphql_name "TickFilter"
      argument :room, String, required: false
      argument :kind, String, required: false, default_value: "k", added: VP::V2 if shape == :nested_default
    end
    tick = Class.new(b[:subscription]) do
      graphql_name "Ticked"
      def self.name = "TickedSubscription"
      payload_type payload
      argument :room, String, required: false, default_value: "r", added: VP::V2 if shape == :default_added
      argument :filter, filter, required: false if shape == :nested_default
      argument :room, String, required: false if shape == :unchanged
      def subscribe(**_args) = :no_response
      def update(**_args) = object
    end
    sub = Class.new(b[:object]) { graphql_name "Subscription"; field :ticked, subscription: tick }
    query = Class.new(b[:object]) { graphql_name "Query"; field :ok, String, null: true }
    VP.schema(query: query, subscription: sub) { use MemSubs }
  end

  def subscribe_and_trigger(schema, sub_query, trigger_args)
    [VP::V1, VP::V2].each { |v| schema.execute(sub_query, context: { armory_version: v }) }
    reached = {}
    [VP::V1, VP::V2].each do |v|
      before = schema.subscriptions.triggered.size
      error = nil
      begin
        schema.subscriptions.trigger(:ticked, trigger_args, { n: 1 }, context: { armory_version: v })
      rescue StandardError => e
        error = e.class.name
      end
      topic = schema.subscriptions.triggered[before]
      subscribers = schema.subscriptions.subscribed.select { |_, t| t == topic }.map(&:first)
      reached[v] = error || subscribers
    end
    reached
  end

  it "[security] T1 a subscription argument with a default added in V2: V1 triggers miss V1 subscribers; audit reports :subscription_trigger there" do
    schema = subscription_world(:default_added)
    reached = subscribe_and_trigger(schema, "subscription { ticked { n } }", {})
    puts "\n[T1] subscribed=#{schema.subscriptions.subscribed.inspect} reached=#{reached.inspect}"
    report = VP.audit(schema)
    expect(VP.failing(report, :subscription_trigger).map(&:path).join(" ")).to include("room")
    expect(report.ok?).to be(false)
  end

  xit "[security] DROPPED-DUP T2 a nested input field with a default added in V2: audit reports :subscription_trigger at the nested field" do
    schema = subscription_world(:nested_default)
    reached = subscribe_and_trigger(schema, 'subscription { ticked(filter: { room: "a" }) { n } }', { filter: { room: "a" } })
    puts "\n[T2] subscribed=#{schema.subscriptions.subscribed.inspect} reached=#{reached.inspect}"
    report = VP.audit(schema)
    expect(VP.failing(report, :subscription_trigger).map(&:path).join(" ")).to include("kind")
  end

  it "[preservation] T3 an unchanged subscription argument: triggers reach both versions' subscribers, no :subscription_trigger problem" do
    schema = subscription_world(:unchanged)
    reached = subscribe_and_trigger(schema, 'subscription { ticked(room: "a") { n } }', { room: "a" })
    expect(reached[VP::V1]).to include(VP::V1)
    expect(reached[VP::V2]).to include(VP::V2)
    expect(VP.failing(VP.audit(schema), :subscription_trigger)).to eq([])
  end

  # ---------------------------------------------------------------------------------------------------------------
  # S3 deprecated:
  # ---------------------------------------------------------------------------------------------------------------
  def deprecations_schema(visibility)
    query = GraphQL::Armory::Versioning::Controls::Deprecations::Query.example
    VP.schema(query: query, visibility: visibility)
  end

  %i[visibility warden].each do |vis|
    it "[security] DP1 #{vis}: a client of V sees deprecated members exactly from D on (introspection, includeDeprecated, SDL, execution)" do
      skip "graphql 2.4 with json 3.x cannot print a deprecation String" unless ArmoryJsonPrinting.prints_strings?
      schema = deprecations_schema(vis)
      root = GraphQL::Armory::Versioning::Controls::Deprecations::Root.example
      v1 = intro_fields(schema, "Invoice", VP::V1)
      v2 = intro_fields(schema, "Invoice", VP::V2)
      expect(v1["tags"]["isDeprecated"]).to be(false)
      expect(v2["tags"]["isDeprecated"]).to be(true)
      expect(v1["amount"]["isDeprecated"]).to be(false) # interface field, inherited
      expect(v2["amount"]["isDeprecated"]).to be(true)
      expect(v1["tags"]["args"].map { |a| a["name"] }).to eq(["page"])
      expect(v2["tags"]["args"].map { |a| a["name"] }).to eq(["first"])
      expect(intro_fields(schema, "Invoice", VP::V1, include_deprecated: false)).to have_key("tags")
      expect(intro_fields(schema, "Invoice", VP::V2, include_deprecated: false)).not_to have_key("tags")
      enum_q = '{ __type(name: "Status") { enumValues(includeDeprecated: false) { name } } }'
      expect(run(schema, enum_q, VP::V1).dig("data", "__type", "enumValues").map { |e| e["name"] }).to include("CANCELLED")
      expect(run(schema, enum_q, VP::V2).dig("data", "__type", "enumValues").map { |e| e["name"] }).not_to include("CANCELLED")
      input_q = '{ __type(name: "InvoiceFilter") { inputFields(includeDeprecated: false) { name } } }'
      expect(run(schema, input_q, VP::V2).dig("data", "__type", "inputFields").map { |e| e["name"] }).to eq(["number"])
      args_q = '{ __type(name: "Query") { fields { name args(includeDeprecated: false) { name } } } }'
      inv = run(schema, args_q, VP::V2).dig("data", "__type", "fields").find { |f| f["name"] == "invoices" }
      expect(inv["args"].map { |a| a["name"] }).not_to include("page")
      sdl1 = schema.to_definition(context: { armory_version: VP::V1 })
      sdl2 = schema.to_definition(context: { armory_version: VP::V2 })
      expect(sdl1).not_to include("@deprecated")
      expect(sdl2.scan("@deprecated").size).to be >= 6
      q = '{ invoice { tags amount } status invoices(page: 1, filter: { code: "c" }) find(code: "x") }'
      r1 = run(schema, q, VP::V1, root_value: root)
      r2 = run(schema, q, VP::V2, root_value: root)
      expect(r1["errors"]).to be_nil
      expect(r2["errors"]).to be_nil # deprecated members still run in V2
      expect(r2.dig("data", "status")).to eq("CANCELLED")
      expect(run(schema, "{ invoice { tags(first: 1) } }", VP::V1, root_value: root)["errors"]).not_to be_nil
    end
  end

  it "[security] DP3 deprecated: where the module cannot make twins (implements, possible_types, lifecycle) is refused, never ignored" do
    b = VP.bases
    membership = Class.new(GraphQL::Schema::TypeMembership) { include GraphQL::Armory::Versioning::Base }
    plain_iface = Module.new { include b[:interface]; graphql_name "Iface"; field :x, String, null: true }
    base_iface = Module.new { include b[:interface]; graphql_name "Iface"; type_membership_class(membership); field :x, String, null: true }
    thing = Class.new(b[:object]) { graphql_name "Thing"; field :x, String, null: true }
    union_plain = Class.new(GraphQL::Schema::Union) { include GraphQL::Armory::Versioning::Base }
    union_base = Class.new(GraphQL::Schema::Union) { include GraphQL::Armory::Versioning::Base; type_membership_class(membership) }
    attempts = {
      implements_plain_membership: -> { Class.new(b[:object]) { graphql_name "T"; implements plain_iface, deprecated: VP::V2, deprecation_reason: "r" } },
      implements_base_membership: -> { Class.new(b[:object]) { graphql_name "T"; implements base_iface, deprecated: VP::V2, deprecation_reason: "r" } },
      possible_types_plain_membership: -> { Class.new(union_plain) { graphql_name "U"; possible_types thing, deprecated: VP::V2, deprecation_reason: "r" } },
      possible_types_base_membership: -> { Class.new(union_base) { graphql_name "U"; possible_types thing, deprecated: VP::V2, deprecation_reason: "r" } },
      lifecycle: -> { Class.new(b[:object]) { graphql_name "L"; lifecycle deprecated: VP::V2 } }
    }
    outcomes = attempts.transform_values do |attempt|
      attempt.call
      :accepted_silently
    rescue StandardError => e
      e.class.name
    end
    puts "\n[DP3] #{outcomes.inspect}"
    expect(outcomes.values).not_to include(:accepted_silently)
  end

  xit "[security] DROPPED-DUP DP4 deprecated: in an owner without Base is refused (field class with Base, and with neither)" do
    b = VP.bases
    expect { Class.new(GraphQL::Schema::Object) { graphql_name "A"; field_class b[:field]; field :x, String, null: true, deprecated: VP::V2, deprecation_reason: "r" } }
      .to raise_error(GraphQL::Armory::Versioning::ConfigurationError)
    expect { Class.new(GraphQL::Schema::Object) { graphql_name "B"; field :x, String, null: true, deprecated: VP::V2, deprecation_reason: "r" } }
      .to raise_error(ArgumentError)
    expect { Class.new(b[:object]) { graphql_name "C"; field :x, String, null: true, deprecated: VP::V2 } }
      .to raise_error(GraphQL::Armory::Versioning::ConfigurationError)
    plain_field = Class.new(GraphQL::Schema::Field) { argument_class(b[:argument]) }
    expect do
      Class.new(b[:object]) do
        graphql_name "D"
        field_class plain_field
        field :x, String, null: true do
          argument :a, String, required: false, deprecated: VP::V2, deprecation_reason: "r"
        end
      end
    end.to raise_error(GraphQL::Armory::Versioning::ConfigurationError)
  end

  it "[security] DP5 deprecated: before added: raises when queried, it does not serve" do
    b = VP.bases
    query = Class.new(b[:object]) do
      graphql_name "Query"
      field :ok, String, null: true
      field :x, String, null: true, added: VP::V2, deprecated: VP::V1, deprecation_reason: "r"
    end
    schema = VP.schema(query: query)
    expect { run(schema, "{ ok x }", VP::V2, root_value: VP.obj(ok: "o", x: "x")) }.to raise_error(GraphQL::Armory::Versioning::ConfigurationError)
  end

  it "[security] DP6 deprecated: on an argument of a field declared on the subscription root is refused before any trigger" do
    b = VP.bases
    payload = Class.new(b[:object]) { graphql_name "Tick"; field :n, Integer, null: true }
    sub = Class.new(b[:object]) do
      graphql_name "Subscription"
      field :ticked, payload, null: true do
        argument :room, String, required: false, deprecated: VP::V2, deprecation_reason: "r"
      end
    end
    query = Class.new(b[:object]) { graphql_name "Query"; field :ok, String, null: true }
    schema = VP.schema(query: query, subscription: sub) { use MemSubs }
    expect { run(schema, "{ ok }", VP::V1) }.to raise_error(GraphQL::Armory::Versioning::ConfigurationError)
  end

  it "[security] DP2 deprecated: under Authorization: the field's rule is judged in both versions (no bypass through the twin)" do
    b = VP.bases(authorization: true)
    thing = Class.new(b[:object]) do
      graphql_name "Thing"
      authorize :none, reason: "probe", covers_fields: true
      field :secret, String, null: true, authorize: :manage, deprecated: VP::V2, deprecation_reason: "r"
    end
    query = Class.new(b[:object]) do
      graphql_name "Query"
      authorize :none, reason: "probe", covers_fields: true
      field :thing, thing, null: false
    end
    adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: false)
    schema = VP.schema(query: query) { use GraphQL::Armory::Authorization, adapter: adapter }
    root = VP.obj(thing: VP.obj(secret: "s3cr3t"))
    [VP::V1, VP::V2].each do |v|
      res = run(schema, "{ thing { secret } }", v, root_value: root)
      expect(res.dig("data", "thing", "secret")).to be_nil, "#{v}: #{res.inspect}"
    end
    puts "\n[DP2] adapter asked: #{adapter.asked.map { |a| a.map { |x| x.is_a?(String) || x.is_a?(Symbol) ? x : x.class.name || x.inspect[0, 60] } }.inspect[0, 600]}"
    expect(adapter.asked.size).to be >= 2
    authz = GraphQL::Armory::Authorization::Audit.(schema)
    secret_problems = authz.problems.select { |p| p.path.to_s.include?("secret") }
    puts "\n[DP2] authorization audit problems on secret: #{secret_problems.map(&:to_s).inspect}"
    expect(secret_problems.map(&:to_s).uniq.size).to eq(secret_problems.size)
  end

  # ---------------------------------------------------------------------------------------------------------------
  # S4 Diff
  # ---------------------------------------------------------------------------------------------------------------
  def diff_schema
    b = VP.bases
    membership = Class.new(GraphQL::Schema::TypeMembership) { include GraphQL::Armory::Versioning::Base }
    iface = Module.new { include b[:interface]; graphql_name "Iface"; type_membership_class(membership); field :id, String, null: true }
    iface2 = Module.new { include b[:interface]; graphql_name "Iface2"; field :id, String, null: true }
    old_name = Class.new(b[:object]) { graphql_name "OldName"; lifecycle removed: VP::V2; field :a, String, null: true }
    new_name = Class.new(b[:object]) { graphql_name "NewName"; lifecycle added: VP::V2; field :a, String, null: true }
    other = Class.new(b[:object]) { graphql_name "Other"; lifecycle added: VP::V2; implements iface2; field :id, String, null: true }
    keeper = Class.new(b[:object]) { graphql_name "Keeper"; implements iface2; field :id, String, null: true }
    enum = Class.new(b[:enum]) do
      graphql_name "E"
      value "KEEP"
      value "GONE", removed: VP::V2
      value "DEP", deprecated: VP::V2, deprecation_reason: "r"
    end
    thing = Class.new(b[:object]) do
      graphql_name "Thing"
      implements iface, added: VP::V2
      field :id, String, null: true
      field :out_nn, String, null: true, removed: VP::V2
      field :out_nn, String, null: false, added: VP::V2
      field :out_null, String, null: false, removed: VP::V2
      field :out_null, String, null: true, added: VP::V2
      field :out_items_nn, [String, { null: true }], null: true, removed: VP::V2
      field :out_items_nn, [String], null: true, added: VP::V2
      field :out_items_null, [String], null: true, removed: VP::V2
      field :out_items_null, [String, { null: true }], null: true, added: VP::V2
      field :t, old_name, null: true, removed: VP::V2
      field :t, new_name, null: true, added: VP::V2
      field :e, enum, null: true
      field :f, String, null: true, removed: VP::V2 do
        argument :in_null, Integer, required: true
        argument :in_nn, Integer, required: false
        argument :in_items_null, [Integer], required: false
        argument :in_items_nn, [Integer, { null: true }], required: false
        argument :req_default_added, Integer, required: true
        argument :req_default_removed, Integer, required: true, default_value: 1
      end
      field :f, String, null: true, added: VP::V2 do
        argument :in_null, Integer, required: false
        argument :in_nn, Integer, required: true
        argument :in_items_null, [Integer, { null: true }], required: false
        argument :in_items_nn, [Integer], required: false
        argument :req_default_added, Integer, required: true, default_value: 1
        argument :req_default_removed, Integer, required: true
      end
      field :g, String, null: true, removed: VP::V2 do
        argument :a, Integer, required: false
        argument :b, String, required: false
      end
      field :g, String, null: true, added: VP::V2 do
        argument :b, String, required: false
        argument :a, Integer, required: false
      end
    end
    query = Class.new(b[:object]) do
      graphql_name "Query"
      field :thing, thing, null: true
      field :node, iface2, null: true
    end
    VP.schema(query: query) { orphan_types(other, keeper) }
  end

  it "[security] DF1 Diff buckets per the GraphQL spec (nullability per direction and in lists, defaults, enums, renames, interfaces, argument order)" do
    result = GraphQL::Armory::Versioning::Diff.(diff_schema, from: VP::V1, to: VP::V2)
    puts "\n[DF1]\n#{result}"
    by_path = result.changes.group_by(&:path).transform_values { |cs| cs.map(&:bucket) }
    expect(by_path["Thing.outNn"]).to eq([:dangerous])
    expect(by_path["Thing.outNull"]).to eq([:breaking])
    expect(by_path["Thing.outItemsNn"]).to eq([:dangerous])
    expect(by_path["Thing.outItemsNull"]).to eq([:breaking])
    expect(by_path["Thing.f.inNull"]).to eq([:safe])
    expect(by_path["Thing.f.inNn"]).to eq([:breaking])
    expect(by_path["Thing.f.inItemsNull"]).to eq([:safe])
    expect(by_path["Thing.f.inItemsNn"]).to eq([:breaking])
    expect(by_path["Thing.f.reqDefaultAdded"]).to eq([:dangerous])
    expect(by_path["Thing.f.reqDefaultRemoved"]).to eq([:breaking])
    expect(by_path["Thing.g"]).to be_nil
    expect(by_path.keys.grep(/\AThing\.g\./)).to eq([])
    expect(by_path["E.GONE"]).to eq([:breaking])
    expect(by_path["E.DEP"]).to eq([:dangerous])
    expect(by_path["OldName"]).to eq([:breaking])
    expect(by_path["NewName"]).to eq([:safe])
    expect(by_path["Thing.t"]).to eq([:breaking])
    expect(by_path["Thing"]).to eq([:dangerous])
    expect(result.breaking?).to be(true)
    puts "[DF1] new implementer of existing interface Iface2 (Other): #{by_path['Other'].inspect}"
  end

  it "[security] DF2 Diff refuses a retired or unknown version; a reversed range is answered (recorded)" do
    schema = diff_schema
    expect { GraphQL::Armory::Versioning::Diff.(schema, from: VP::V0, to: VP::V2) }.to raise_error(GraphQL::Armory::Versioning::ConfigurationError)
    expect { GraphQL::Armory::Versioning::Diff.(schema, from: "2099-01-01", to: VP::V2) }.to raise_error(GraphQL::Armory::Versioning::UnknownVersionError)
    reversed = GraphQL::Armory::Versioning::Diff.(schema, from: VP::V2, to: VP::V1)
    puts "\n[DF2] reversed breaking?=#{reversed.breaking?} (#{reversed.breaking.size} breaking)"
  end

  xit "[security] DROPPED-DUP DF3 diff and dump commands: exit codes" do
    schema = diff_schema
    Object.const_set(:VPDiffProbeSchema, schema)
    same = VP.schema(query: Class.new(VP.bases[:object]) { graphql_name "Query"; field :ok, String, null: true })
    Object.const_set(:VPSameProbeSchema, same)
    out = StringIO.new
    diff = GraphQL::Armory::Versioning::Diff::Command.new(out: out)
    expect(diff.("VPDiffProbeSchema", VP::V1, VP::V2)).to eq(1)
    expect(diff.("VPSameProbeSchema", VP::V1, VP::V2)).to eq(0)
    expect(diff.("VPDiffProbeSchema", VP::V1, nil)).to eq(1)
    expect(diff.("NoSuchSchemaXYZ", VP::V1, VP::V2)).to eq(1)
    expect(diff.("VPDiffProbeSchema", VP::V1, "2099-01-01")).to eq(1)
    expect(diff.("VPDiffProbeSchema", VP::V0, VP::V2)).to eq(1)
    Dir.mktmpdir do |dir|
      dump = GraphQL::Armory::Versioning::Dump::Command.new(out: StringIO.new)
      expect(dump.("VPSameProbeSchema", File.join(dir, "s"))).to eq(0)
      expect(dump.("", File.join(dir, "s"))).to eq(1)
      expect(dump.("NoSuchSchemaXYZ", File.join(dir, "s"))).to eq(1)
    end
  ensure
    Object.send(:remove_const, :VPDiffProbeSchema) if Object.const_defined?(:VPDiffProbeSchema)
    Object.send(:remove_const, :VPSameProbeSchema) if Object.const_defined?(:VPSameProbeSchema)
  end

  it "[security] DF4 idea 1: Diff over the boundary at D lists each deprecation added as dangerous, nothing breaking" do
    result = GraphQL::Armory::Versioning::Diff.(deprecations_schema(:visibility), from: VP::V1, to: VP::V2)
    puts "\n[DF4]\n#{result}"
    deprecated = result.changes.select { |c| c.message.start_with?("deprecated:") }
    expect(deprecated.map(&:bucket).uniq).to eq([:dangerous])
    expect(deprecated.map(&:path)).to include("Invoice.tags", "Status.CANCELLED", "InvoiceFilter.code", "Query.invoices.page")
    expect(result.breaking.map(&:path)).to eq(["Invoice.tags.page"]) # the field block's own removed: argument
  end

  # ---------------------------------------------------------------------------------------------------------------
  # S4 Dump
  # ---------------------------------------------------------------------------------------------------------------
  def label_schema(labels)
    query = Class.new(VP.bases[:object]) { graphql_name "Query"; field :ok, String, null: true }
    VP.schema(query: query, versions: labels, retired: [])
  end

  it "[security] DM1 Dump refuses labels that would leave the directory or collide, writing nothing" do
    ["../../evil", "/etc/evil", "a\\b", ".hidden", "..", "LATEST", "x\0y"].each do |bad|
      schema = begin
        label_schema([bad, "z"])
      rescue GraphQL::Armory::Versioning::ConfigurationError => e
        puts "\n[DM1] #{bad.inspect} refused by use: #{e.message[0, 80]}"
        next
      end
      Dir.mktmpdir do |root|
        dir = File.join(root, "schema")
        expect { GraphQL::Armory::Versioning::Dump.(schema, dir) }.to raise_error(GraphQL::Armory::Versioning::ConfigurationError), bad.inspect
        expect(Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).reject { |f| f.end_with?("/.") }).to eq([]), bad.inspect
      end
    end
    Dir.mktmpdir do |root|
      dir = File.join(root, "schema")
      expect { GraphQL::Armory::Versioning::Dump.(label_schema(%w[A a]), dir) }.to raise_error(GraphQL::Armory::Versioning::ConfigurationError)
      written = GraphQL::Armory::Versioning::Dump.(label_schema(["C:evil", "z"]), dir)
      expect(written.all? { |f| File.expand_path(f).start_with?(File.expand_path(dir) + "/") }).to be(true)
      puts "[DM1] C:evil wrote #{written.inspect}"
    end
  end

  it "[security] DM2 Dump through a symlinked file inside the directory (records where it writes)" do
    Dir.mktmpdir do |root|
      dir = File.join(root, "schema")
      FileUtils.mkdir_p(dir)
      outside = File.join(root, "outside.txt")
      File.write(outside, "precious")
      File.symlink(outside, File.join(dir, "z.graphql"))
      expect { GraphQL::Armory::Versioning::Dump.(label_schema(%w[y z]), dir) }
        .to raise_error(GraphQL::Armory::Versioning::ConfigurationError, /symbolic link/)
      expect(File.read(outside)).to eq("precious")
    end
  end

  it "[preservation] DM3 Dump rewrites served versions' files, leaves a retired version's file, and SDL per version differs" do
    skip "graphql 2.4 with json 3.x cannot print a deprecation String" unless ArmoryJsonPrinting.prints_strings?
    Dir.mktmpdir do |root|
      dir = File.join(root, "schema")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "#{VP::V0}.graphql"), "old")
      File.write(File.join(dir, "#{VP::V1}.graphql"), "stale")
      schema = deprecations_schema(:visibility)
      written = GraphQL::Armory::Versioning::Dump.(schema, dir)
      expect(written.map { |f| File.basename(f) }).to eq(["#{VP::V1}.graphql", "#{VP::V2}.graphql", "latest.graphql"])
      expect(File.read(File.join(dir, "#{VP::V0}.graphql"))).to eq("old")
      expect(File.read(File.join(dir, "#{VP::V1}.graphql"))).to eq(schema.to_definition(context: { armory_version: VP::V1 }))
      expect(File.read(File.join(dir, "latest.graphql"))).to eq(File.read(File.join(dir, "#{VP::V2}.graphql")))
    end
  end

  # ---------------------------------------------------------------------------------------------------------------
  # S5 profiles
  # ---------------------------------------------------------------------------------------------------------------
  def profile_world(**opts)
    b = VP.bases
    status = Class.new(b[:enum]) { graphql_name "Status"; value "OLD"; value "NEW", added: VP::V2 }
    newt = Class.new(b[:object]) { graphql_name "NewT"; lifecycle added: VP::V2; field :n, Integer, null: true }
    oldt = Class.new(b[:object]) { graphql_name "OldT"; field :n, Integer, null: true }
    union_base = Class.new(GraphQL::Schema::Union) do
      include GraphQL::Armory::Versioning::Base
      type_membership_class(Class.new(GraphQL::Schema::TypeMembership) { include GraphQL::Armory::Versioning::Base })
    end
    union = Class.new(union_base) do
      graphql_name "U"
      possible_types oldt
      possible_types newt, added: VP::V2
    end
    newt_ref = newt
    oldt_ref = oldt
    union.define_singleton_method(:resolve_type) { |_obj, _ctx| oldt_ref }
    query = Class.new(b[:object]) do
      graphql_name "Query"
      field :old, String, null: true do
        argument :x, Integer, required: false, added: VP::V2
      end
      field :newer, String, null: true, added: VP::V2
      field :status, status, null: true
      field :u, union, null: true
      field :nt, newt_ref, null: true
    end
    VP.schema(query: query, **opts)
  end

  def v1_view_probe(schema, version, **context)
    queries = {
      newer: "{ newer }",
      arg: "{ old(x: 1) }",
      type: '{ __type(name: "NewT") { name } }',
      fragment: "{ u { ... on NewT { n } } }",
      enum: '{ __type(name: "Status") { enumValues { name } } }',
      possible: '{ __type(name: "U") { possibleTypes { name } } }',
      schema_types: "{ __schema { types { name } } }"
    }
    queries.transform_values do |q|
      execute_query(schema, q, context: { armory_version: version }.merge(context), root_value: VP.obj(old: "o", newer: "n", status: "OLD", u: VP.obj(n: 1), nt: nil)).to_h
    end
  end

  def assert_v1(results)
    expect(results[:newer]["errors"]).not_to be_nil
    expect(results[:arg]["errors"]).not_to be_nil
    expect(results[:type].dig("data", "__type")).to be_nil
    expect(results[:fragment]["errors"]).not_to be_nil
    expect(results[:enum].dig("data", "__type", "enumValues").map { |e| e["name"] }).to eq(["OLD"])
    expect(results[:possible].dig("data", "__type", "possibleTypes").map { |e| e["name"] }).to eq(["OldT"])
    expect(results[:schema_types].dig("data", "__schema", "types").map { |t| t["name"] }).not_to include("NewT")
  end

  def assert_v2(results)
    expect(results[:newer]["errors"]).to be_nil
    expect(results[:arg]["errors"]).to be_nil
    expect(results[:type].dig("data", "__type", "name")).to eq("NewT")
    expect(results[:enum].dig("data", "__type", "enumValues").map { |e| e["name"] }).to eq(%w[OLD NEW])
    expect(results[:possible].dig("data", "__type", "possibleTypes").map { |e| e["name"] }.sort).to eq(%w[NewT OldT])
  end

  [true, false].each do |preload|
    it "[security] PR1 profiles: true (preload: #{preload}): interleaved V1/V2/V1 clients each get exactly their version on every path" do
      schema = profile_world(profiles: true, preload: preload)
      assert_v1(v1_view_probe(schema, VP::V1))
      assert_v2(v1_view_probe(schema, VP::V2))
      assert_v1(v1_view_probe(schema, VP::V1))
      assert_v2(v1_view_probe(schema, nil)) # default: :latest
      expect(schema.visibility.cached_profiles.keys).to include(:"armory_v_#{VP::V1}", :"armory_v_#{VP::V2}")
    end
  end

  it "[security] PR1b default: a label under profiles: a request with no version gets that label's profile" do
    schema = profile_world(profiles: true, default: VP::V1)
    assert_v1(v1_view_probe(schema, nil))
    assert_v2(v1_view_probe(schema, VP::V2))
  end

  it "[security] PR2 foreign, crafted, retired or unknown visibility_profile never runs another version's schema" do
    schema = profile_world(profiles: true)
    root = VP.obj(newer: -> { raise "resolved newer" }, old: "o")
    attempts = [
      [VP::V1, { visibility_profile: :"armory_v_#{VP::V2}" }, {}],
      [VP::V1, {}, { visibility_profile: :"armory_v_#{VP::V2}" }],
      [VP::V0, { visibility_profile: :"armory_v_#{VP::V0}" }, {}],
      [VP::V0, { visibility_profile: :"armory_v_#{VP::V2}" }, {}],
      ["2099-01-01", { visibility_profile: :"armory_v_#{VP::V2}" }, {}],
      [VP::V2, { visibility_profile: "armory_v_#{VP::V2}" }, {}],
      [VP::V1, { visibility_profile: :admin }, {}]
    ]
    attempts.each do |version, ctx, kwargs|
      outcome = begin
        res = execute_query(schema, "{ newer }", context: { armory_version: version }.merge(ctx), root_value: root, **kwargs).to_h
        res
      rescue StandardError => e
        e.class
      end
      puts "\n[PR2] #{version} #{ctx.inspect} #{kwargs.inspect} -> #{outcome.inspect[0, 160]}"
      expect(outcome).not_to eq(RuntimeError) # RuntimeError = `newer` resolved
      next if outcome.is_a?(Class)

      expect(outcome.dig("data", "newer")).to be_nil
      expect(outcome["errors"]).not_to be_nil
    end
  end

  xit "[security] DROPPED-DUP PR3 a version a custom context_class sets after the profile was picked is refused, never served under the other profile" do
    changer = Class.new(GraphQL::Query::Context) do
      def initialize(**kwargs)
        super
        self[:armory_version] = VP::V1
      end
    end
    schema = profile_world(profiles: true) { context_class(changer) }
    outcome = begin
      execute_query(schema, "{ newer }", context: { armory_version: VP::V2 }, root_value: VP.obj(newer: "n")).to_h
    rescue StandardError => e
      e.class
    end
    puts "\n[PR3] context_class V2->V1: #{outcome.inspect[0, 200]}"
    expect(outcome).to eq(GraphQL::Armory::Versioning::ConfigurationError).or(satisfy { |o| o.is_a?(Hash) && o["errors"] })
  end

  xit "[security] DROPPED-DUP PR4 multiplex under profiles: each query sees its own version" do
    schema = profile_world(profiles: true)
    queries = [{ query: "{ newer }", context: { armory_version: VP::V1 } }, { query: "{ newer }", context: { armory_version: VP::V2 } },
               { query: '{ __type(name: "NewT") { name } }', context: { armory_version: VP::V1 } }]
    root = VP.obj(newer: "n")
    results = if ArmoryEngine.next?
                schema.multiplex_next(queries.map { |q| q.merge(root_value: root) })
              else
                schema.multiplex(queries.map { |q| q.merge(root_value: root) })
              end.map(&:to_h)
    expect(results[0]["errors"]).not_to be_nil
    expect(results[1].dig("data", "newer")).to eq("n")
    expect(results[2].dig("data", "__type")).to be_nil
  end

  it "[security] PR5 profiles + preload with Authorization visible_when: fails closed (raises), never a user-less visibility; audit reports :profiles" do
    b = VP.bases(authorization: true)
    model = Class.new { def self.name = "Doc" }
    doc = Class.new(b[:object]) do
      graphql_name "Doc"
      authorize :read, model: model, visible_when: :export
      field :n, Integer, null: true
    end
    query = Class.new(b[:object]) { graphql_name "Query"; authorize :none, reason: "p", covers_fields: true; field :doc, doc, null: true; field :ok, String, null: true }
    adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: true)
    built = begin
      s = VP.schema(query: query, profiles: true, preload: true) { use GraphQL::Armory::Authorization, adapter: adapter }
      res = execute_query(s, '{ __type(name: "Doc") { name } }', context: { armory_version: VP::V2 }).to_h
      [:built, res, s]
    rescue StandardError => e
      [:raised, e.class]
    end
    puts "\n[PR5] #{built[0, 2].inspect[0, 200]}"
    expect(built.first == :raised || built[1]["errors"] || built[1].dig("data", "__type").nil?).to be_truthy
    schema = VP.schema(query: query, profiles: true, preload: false) { use GraphQL::Armory::Authorization, adapter: adapter }
    report = VP.audit(schema)
    expect(VP.failing(report, :profiles)).not_to be_empty
  end

  it "[security] PR6 Versioning.types, to_definition and requests agree per version under profiles" do
    schema = profile_world(profiles: true)
    [VP::V1, VP::V2].each do |v|
      view = GraphQL::Armory::Versioning.types(schema, v)
      from_view = view.fields(view.type("Query")).map(&:graphql_name).sort
      from_request = intro_fields(schema, "Query", v).keys.sort
      expect(from_view).to eq(from_request)
      sdl = schema.to_definition(context: { armory_version: v })
      expect(sdl.include?("newer")).to eq(v == VP::V2)
    end
  end

  it "[security] PR8 the audit under profiles (with and without dynamic: true) is ok for a correct schema and reports an app visible? as :profiles" do
    [nil, true].each do |dynamic|
      expect(VP.audit(profile_world(profiles: true, dynamic: dynamic)).ok?).to be(true)
    end
    b = VP.bases
    own = Class.new(b[:object]) { def self.name = "OwnVis"; def self.visible?(context) = super }
    thing = Class.new(own) { graphql_name "Thing"; field :n, Integer, null: true }
    other = Class.new(b[:object]) { def self.name = "OtherVis"; def self.visible?(context) = super }
    thing2 = Class.new(other) { graphql_name "Thing2"; field :n, Integer, null: true }
    query = Class.new(b[:object]) { graphql_name "Query"; field :thing, thing, null: true; field :thing2, thing2, null: true }
    report = VP.audit(VP.schema(query: query, profiles: true, own_checks: { own => { visible?: "reads only the version" } }))
    paths = VP.failing(report, :profiles).map(&:path)
    expect(paths.join(" ")).to include("OtherVis")
    expect(paths.join(" ")).not_to include("OwnVis")
  end

  it "[security] PR9 profiles: false with an app's own named profile: queries of two versions never share one visibility (2.4.0-2.4.9 leak)" do
    query = profile_world.query
    schema = Class.new(ArmoryEngine.base_schema) do
      query(query)
      use GraphQL::Armory::Versioning, versions: VP::VERSIONS, retired: [VP::V0], default: :latest
      use GraphQL::Schema::Visibility, profiles: { app: {} }
    end
    outcomes = [VP::V2, VP::V1].map do |v|
      res = execute_query(schema, '{ __type(name: "NewT") { name } }', context: { armory_version: v }, visibility_profile: :app).to_h
      res.dig("data", "__type", "name")
    rescue StandardError => e
      e.class
    end
    puts "\n[PR9] graphql #{GraphQL::VERSION}: V2 then V1 under :app -> #{outcomes.inspect}"
    expect(outcomes[1]).not_to eq("NewT") # V1 must never see V2's NewT
  end

  xit "[security] DROPPED-DUP PR10 profiles: true needs graphql >= 2.4.10 (refused below)" do
    if Gem::Version.new(GraphQL::VERSION) < Gem::Version.new("2.4.10")
      expect { profile_world(profiles: true) }.to raise_error(ArgumentError, /2\.4\.10/)
    else
      expect { profile_world(profiles: true) }.not_to raise_error
      expect { GraphQL::Armory::Versioning::Profiles.build(GraphQL::Armory::Versioning::Controls::Versions.example, enabled: true, graphql_version: "2.4.9") }
        .to raise_error(ArgumentError)
    end
  end

  xit "[security] DROPPED-DUP PR11 profiles: true without Versioning.profiles in Schema::Visibility, or with the Warden, refuses rather than running unversioned" do
    b = VP.bases
    query = Class.new(b[:object]) { graphql_name "Query"; field :ok, String, null: true; field :newer, String, null: true, added: VP::V2 }
    plain = Class.new(ArmoryEngine.base_schema) do
      query(query)
      use GraphQL::Armory::Versioning, versions: VP::VERSIONS, retired: [VP::V0], default: :latest, profiles: true
      use GraphQL::Schema::Visibility
    end
    warden = Class.new(ArmoryEngine.base_schema) do
      query(query)
      use GraphQL::Armory::Versioning, versions: VP::VERSIONS, retired: [VP::V0], default: :latest, profiles: true
      use GraphQL::Schema::Warden
    end
    [plain, warden].each do |schema|
      outcome = begin
        execute_query(schema, "{ newer }", context: { armory_version: VP::V1 }, root_value: VP.obj(newer: "n", ok: "o")).to_h
      rescue StandardError => e
        e.class
      end
      puts "\n[PR11] #{outcome.inspect[0, 160]}"
      expect(outcome.is_a?(Class) || outcome.dig("data", "newer").nil?).to be(true)
    end
  end

  it "[security] PR12 a refused version under profiles is refused with its code and runs nothing" do
    schema = profile_world(profiles: true)
    res = execute_query(schema, "{ old }", context: { armory_version: VP::V0 }, root_value: VP.obj(old: -> { raise "ran" })).to_h
    expect(res["errors"].map { |e| e.dig("extensions", "code") }).to eq(["RETIRED_API_VERSION"])
    expect(res["data"]).to be_nil
  end

  # ---------------------------------------------------------------------------------------------------------------
  # Telemetry (idea 8)
  # ---------------------------------------------------------------------------------------------------------------
  it "[security] TL1 Diff, Audit (also under profiles) and Versioning.types record no signal; Dump's to_definition signals are recorded (as docs' limit says)" do
    signals = []
    sink = ->(signal, data) { signals << [signal, data] }
    plain = profile_world(sinks: [sink])
    profiled = profile_world(sinks: [sink], profiles: true)
    GraphQL::Armory::Versioning::Diff.(plain, from: VP::V1, to: VP::V2)
    GraphQL::Armory::Versioning::Diff.(profiled, from: VP::V1, to: VP::V2)
    VP.audit(plain)
    VP.audit(profiled)
    GraphQL::Armory::Versioning.types(profiled, VP::V1)
    expect(signals).to eq([])
    Dir.mktmpdir { |dir| GraphQL::Armory::Versioning::Dump.(plain, dir) }
    puts "\n[TL1] Dump signals: #{signals.inspect}"
  end

  # ---------------------------------------------------------------------------------------------------------------
  # Preservation
  # ---------------------------------------------------------------------------------------------------------------
  it "[preservation] PV1 graphql-ruby's install-template base classes with Base (connections, Node, RelayClassicMutation) still work" do
    base_arg = Class.new(GraphQL::Schema::Argument) { include GraphQL::Armory::Versioning::Base }
    base_field = Class.new(GraphQL::Schema::Field) { include GraphQL::Armory::Versioning::Base; argument_class(base_arg) }
    base_iface = Module.new do
      include GraphQL::Schema::Interface
      include GraphQL::Armory::Versioning::Base
      graphql_name "BaseInterface"
      field_class(base_field)
    end
    base_input = Class.new(GraphQL::Schema::InputObject) { def self.name = "BaseInputObject"; include GraphQL::Armory::Versioning::Base; argument_class(base_arg) }
    base_edge = Class.new(GraphQL::Schema::Object) do
      def self.name = "BaseEdge"
      include GraphQL::Armory::Versioning::Base
      include GraphQL::Types::Relay::EdgeBehaviors
      field_class(base_field)
    end
    base_connection = Class.new(GraphQL::Schema::Object) do
      def self.name = "BaseConnection"
      include GraphQL::Armory::Versioning::Base
      include GraphQL::Types::Relay::ConnectionBehaviors
      field_class(base_field)
    end
    base_object = Class.new(GraphQL::Schema::Object) do
      def self.name = "BaseObject"
      include GraphQL::Armory::Versioning::Base
      edge_type_class(base_edge)
      connection_type_class(base_connection)
      field_class(base_field)
    end
    node = Module.new do
      include base_iface
      include GraphQL::Types::Relay::NodeBehaviors
      graphql_name "Node"
    end
    item = Class.new(base_object) do
      graphql_name "Item"
      implements node
      field :name, String, null: true
      field :label, String, null: true, deprecated: VP::V2, deprecation_reason: "Use name"
    end
    base_mutation = Class.new(GraphQL::Schema::RelayClassicMutation) do
      def self.name = "BaseMutation"
      include GraphQL::Armory::Versioning::Base
      argument_class(base_arg)
      field_class(base_field)
      input_object_class(base_input)
      object_class(base_object)
    end
    rename = Class.new(base_mutation) do
      graphql_name "Rename"
      argument :name, String, required: true
      argument :label, String, required: false, deprecated: VP::V2, deprecation_reason: "Use name"
      argument :extra, String, required: false, added: VP::V2
      field :item, item, null: true
      def resolve(name:, label: nil, extra: nil) = { item: { id: "1", name: [name, label, extra].compact.join("/"), label: label } }
    end
    mutation = Class.new(base_object) { graphql_name "Mutation"; field :rename, mutation: rename }
    query = Class.new(base_object) do
      graphql_name "Query"
      field :items, item.connection_type, null: false
      def items = [{ id: "1", name: "a", label: "l" }]
    end
    item.class_eval do
      def id = object[:id]
      def name = object[:name]
      def label = object[:label]
    end
    schema = VP.schema(query: query, mutation: mutation) do
      def self.object_from_id(_id, _c) = nil
      def self.id_from_object(_o, _t, _c) = "1"
    end
    schema.define_singleton_method(:resolve_type) { |_t, _o, _c| item }
    [VP::V1, VP::V2].each do |v|
      r = schema.execute("{ items(first: 1) { edges { node { id name label } } pageInfo { hasNextPage } } }", context: { armory_version: v }).to_h
      expect(r["errors"]).to be_nil, "#{v}: #{r.inspect}"
      m = schema.execute('mutation { rename(input: { name: "n", label: "l" }) { item { name } } }', context: { armory_version: v }).to_h
      expect(m["errors"]).to be_nil, "#{v}: #{m.inspect}"
    end
    input_q = '{ __type(name: "RenameInput") { inputFields(includeDeprecated: true) { name isDeprecated } } }'
    v1_in = schema.execute(input_q, context: { armory_version: VP::V1 }).to_h.dig("data", "__type", "inputFields").to_h { |f| [f["name"], f["isDeprecated"]] }
    v2_in = schema.execute(input_q, context: { armory_version: VP::V2 }).to_h.dig("data", "__type", "inputFields").to_h { |f| [f["name"], f["isDeprecated"]] }
    expect(v1_in).to eq("name" => false, "label" => false, "clientMutationId" => false)
    expect(v2_in).to include("label" => true, "extra" => false)
    expect(VP.audit(schema).ok?).to be(true), VP.audit(schema).to_s
    puts "\n[PV1] owners: field=#{base_object.method(:field).owner} argument=#{rename.method(:argument).owner} " \
         "iface_field=#{node.method(:field).owner} mutation_field=#{rename.method(:field).owner}"
  end

  it "[preservation] PV2 an existing 3a/3b1 schema's versioning audit and Authorization's audit print (compare A vs B)" do
    controls = GraphQL::Armory::Versioning::Controls::Schema.example
    puts "\n[PV2-versioning]\n#{VP.audit(controls)}[PV2-end]"
    authz = GraphQL::Armory::Authorization::Audit.(IntegrationSchema.build)
    puts "\n[PV2-authorization]\n#{authz}[PV2-end]"
    expect(true).to be(true)
  end
end
