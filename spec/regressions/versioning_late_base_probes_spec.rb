# frozen_string_literal: true

# Verifier probes for PR #80 (Versioning: Base included late), kept as regressions. Each `it` is labelled security or preservation.
module LateBaseProbeFixtures
  BASE = GraphQL::Armory::Versioning::Base

  # A union member named by a String: graphql-ruby resolves it only when the schema loads the type.
  Cat = Class.new(GraphQL::Schema::Object) do
    graphql_name "Cat"
    field :name, String, null: true
  end

  # Seven late fields on a named class, for the message's "and N more" and file:line.
  MsgField = Class.new(GraphQL::Schema::Field)
  class MsgQuery < GraphQL::Schema::Object
    graphql_name "Query"
    field_class MsgField
    field :f1, String, null: true
    field :f2, String, null: true
    field :f3, String, null: true
    field :f4, String, null: true
    field :f5, String, null: true
    field :f6, String, null: true
    field :f7, String, null: true
  end
  MsgField.include(BASE)

  MsgValue = Class.new(GraphQL::Schema::EnumValue)
  class MsgColor < GraphQL::Schema::Enum
    graphql_name "Color"
    enum_value_class MsgValue
    value "RED" # RED_LINE
  end
  MsgValue.include(BASE)

  class MsgColorQuery < GraphQL::Schema::Object
    graphql_name "Query"
    field :color, MsgColor, null: true
  end
end

RSpec.describe "verifier probes: Versioning Base included late" do
  let(:v) { GraphQL::Armory::Versioning }
  let(:ce) { GraphQL::Armory::Versioning::ConfigurationError }
  let(:base) { GraphQL::Armory::Versioning::Base }
  let(:labels) { GraphQL::Armory::Versioning::Controls::Versions::LABELS }
  let(:late_message) { /included GraphQL::Armory::Versioning::Base after/ }

  def schema_for(query_type, plugin: :visibility, mutation: nil, subscription: nil, directives: [], orphans: [], profiles: false, preload: false, resolve: nil)
    labels = self.labels
    Class.new(ArmoryEngine.base_schema) do
      query(query_type)
      mutation(mutation) if mutation
      subscription(subscription) if subscription
      directives(*directives) unless directives.empty?
      orphan_types(*orphans) unless orphans.empty?
      define_singleton_method(:resolve_type) { |_abstract, obj, _ctx| resolve.(obj) } if resolve
      define_singleton_method(:id_from_object) { |obj, _t, _ctx| obj.id }
      define_singleton_method(:object_from_id) { |id, _ctx| ItemS.new(id, "one", "s1") }
      use GraphQL::Schema::Warden if plugin == :warden
      use GraphQL::Schema::Visibility, preload: preload if plugin == :visibility && !profiles
      use GraphQL::Armory::Versioning, versions: labels, default: :latest, profiles: profiles
      use GraphQL::Schema::Visibility, profiles: GraphQL::Armory::Versioning.profiles(self), preload: preload if plugin == :visibility && profiles
    end
  end

  def run(schema, query, version: nil, root: nil, variables: {})
    context = version ? { armory_version: version } : {}
    execute_query(schema, query, context: context, root_value: root, variables: variables).to_h
  end

  def hi_root = Struct.new(:hi).new("hi")

  def late_field_query
    fc = Class.new(GraphQL::Schema::Field)
    q = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field_class fc
      field :hi, String, null: true
    end
    fc.include(base)
    q
  end

  def ok_field_class = Class.new(GraphQL::Schema::Field).tap { |fc| fc.include(base) }

  # The error a block raised, or nil.
  def error_of
    yield
    nil
  rescue StandardError => e
    e
  end

  def expect_late(error, pattern)
    expect(error).to be_a(ce), "expected ConfigurationError, got #{error.class}: #{error&.message&.slice(0, 300)}
#{error&.backtrace&.grep_v(/rspec|bundler|activerecord|activesupport|dummy.rb/)&.first(14)&.join("
")}"
    expect(error.message).to match(pattern)
    expect(error.message).to match(late_message)
  end

  # Install-template base classes, Base first everywhere.
  def template
    b = base
    arg = Class.new(GraphQL::Schema::Argument) { include b }
    fld = Class.new(GraphQL::Schema::Field) { include b; argument_class arg }
    val = Class.new(GraphQL::Schema::EnumValue) { include b }
    mem = Class.new(GraphQL::Schema::TypeMembership) { include b }
    obj = Class.new(GraphQL::Schema::Object) { include b; graphql_name "BaseObject"; field_class fld }
    edge = Class.new(obj) { graphql_name "BaseEdge"; include GraphQL::Types::Relay::EdgeBehaviors }
    conn = Class.new(obj) { graphql_name "BaseConnection"; include GraphQL::Types::Relay::ConnectionBehaviors }
    obj.edge_type_class(edge)
    obj.connection_type_class(conn)
    iface = Module.new do
      include GraphQL::Schema::Interface
      include b
      graphql_name "BaseInterface"
      field_class fld
      type_membership_class mem
    end
    union = Class.new(GraphQL::Schema::Union) { include b; graphql_name "BaseUnion"; type_membership_class mem }
    enum = Class.new(GraphQL::Schema::Enum) { include b; graphql_name "BaseEnum"; enum_value_class val }
    input = Class.new(GraphQL::Schema::InputObject) { include b; graphql_name "BaseInputObject"; argument_class arg }
    resolver = Class.new(GraphQL::Schema::Resolver) { include b; graphql_name "BaseResolver"; argument_class arg }
    mutation = Class.new(GraphQL::Schema::RelayClassicMutation) do
      include b
      graphql_name "BaseMutation"
      argument_class arg
      field_class fld
      input_object_class input
      object_class obj
    end
    { arg: arg, fld: fld, val: val, mem: mem, obj: obj, edge: edge, conn: conn, iface: iface, union: union, enum: enum,
      input: input, resolver: resolver, mutation: mutation }
  end

  ItemS = Struct.new(:id, :title, :sku)
  CatS = Struct.new(:id, :name)

  class TemplateRoot
    def hi = "hi"
    def fresh = "fresh"
    def items = [ItemS.new("1", "one", "s1"), ItemS.new("2", "two", "s2")]
    def pet = ItemS.new("1", "one", "s1")
    def named = CatS.new("c", "tom")
    def status = "PAID"
    def search(filter: nil) = filter ? filter[:text] : nil
    def node(id:) = ItemS.new(id, "one", "s1")
    def nodes(ids:) = ids.map { |id| ItemS.new(id, "x", "s") }
  end

  def template_schema(plugin: :visibility, profiles: false, preload: false)
    t = template
    node_iface = Module.new { include t[:iface]; include GraphQL::Types::Relay::NodeBehaviors; graphql_name "Node" }
    named = Module.new { include t[:iface]; graphql_name "Named"; field :name, String, null: true }
    item = Class.new(t[:obj]) do
      graphql_name "Item"
      implements node_iface
      field :title, String, null: true
      field :sku, String, null: true, added: "2025-01-01"
    end
    cat = Class.new(t[:obj]) do
      graphql_name "CatT"
      implements named
      implements node_iface
    end
    pet = Class.new(t[:union]) do
      graphql_name "Pet"
      possible_types item
      possible_types cat, added: "2025-01-01"
    end
    status = Class.new(t[:enum]) do
      graphql_name "Status"
      value "PAID"
      value "VOID", added: "2025-01-01"
    end
    filter = Class.new(t[:input]) do
      graphql_name "Filter"
      argument :text, String, required: false
      argument :tag, String, required: false, added: "2025-01-01"
    end
    find = Class.new(t[:resolver]) do
      graphql_name "Find"
      type String, null: true
      argument :id, GraphQL::Types::ID, required: false
      argument :newer, String, required: false, added: "2025-01-01"
      def resolve(id: nil, newer: nil) = "found #{id}#{newer}"
    end
    create = Class.new(t[:mutation]) do
      graphql_name "CreateItem"
      argument :title, String, required: false
      argument :sku, String, required: false, added: "2025-01-01"
      field :item_title, String, null: true
      def resolve(title: nil, sku: nil) = Struct.new(:item_title).new([title, sku].compact.join("/"))
    end
    mroot = Class.new(t[:obj]) do
      graphql_name "Mutation"
      field :create_item, mutation: create
    end
    tag = Class.new(GraphQL::Schema::Directive) do
      graphql_name "tag"
      locations(GraphQL::Schema::Directive::FIELD)
      argument_class t[:arg]
      argument :label, String, required: false
      argument :weight, Integer, required: false, added: "2025-01-01"
    end
    query = Class.new(t[:obj]) do
      graphql_name "Query"
      field :hi, String, null: true
      field :fresh, String, null: true, added: "2025-01-01"
      field :items, item.connection_type, null: true
      field :pet, pet, null: true
      field :named, named, null: true
      field :status, status, null: true
      field :search, String, null: true do
        argument :filter, filter, required: false
      end
      field :find, resolver: find
      field :node, node_iface, null: true do
        argument :id, GraphQL::Types::ID, required: true
      end
      field :nodes, [node_iface, null: true], null: true do
        argument :ids, [GraphQL::Types::ID], required: true
      end
    end
    resolve = ->(obj) { obj.is_a?(CatS) ? cat : item }
    schema_for(query, plugin: plugin, mutation: mroot, directives: [tag], orphans: [cat], profiles: profiles, preload: preload, resolve: resolve)
  end

  # String values travel as variables: graphql 2.4 with json 3.1 cannot serialize a String literal in FieldsWillMerge.
  TEMPLATE_VARS = { "l" => "x", "t" => "t", "id" => "9" }.freeze
  TEMPLATE_BODY = <<~GRAPHQL
      hi @tag(label: $l)
      a: hi @skip(if: true)
      b: hi @include(if: true)
      items(first: 1) { edges { cursor node { id title } } nodes { id } pageInfo { hasNextPage } }
      pet { __typename ... on Item { title } }
      named { name }
      status
      search(filter: { text: $t })
      node(id: $id) { id }
  GRAPHQL
  TEMPLATE_QUERY = "query($l: String, $t: String, $id: ID!) {\n#{TEMPLATE_BODY}}".freeze

  def expect_template_ok(schema)
    skip "environment: graphql 2.4 with json 3.1 cannot serialize argument values in validation" unless ArmoryJsonPrinting.prints_strings?
    old = run(schema, TEMPLATE_QUERY, version: "2024-06-01", root: TemplateRoot.new, variables: TEMPLATE_VARS)
    expect(old["errors"]).to be_nil, old["errors"].inspect
    expect(old["data"].slice("hi", "b", "status", "search", "named")).to eq("hi" => "hi", "b" => "hi", "status" => "PAID", "search" => "t", "named" => { "name" => "tom" })
    expect(old["data"]["items"]["pageInfo"]).to eq("hasNextPage" => true)
    fresh_old = run(schema, "{ fresh }", version: "2024-06-01", root: TemplateRoot.new)
    expect(fresh_old["errors"].to_a.map { |e| e["message"] }.join).to include("fresh")
    newer = run(schema, "query($l: String, $t: String, $id: ID!) {\n#{TEMPLATE_BODY} fresh items(first: 1) { nodes { sku } } }", version: "2025-01-01", root: TemplateRoot.new, variables: TEMPLATE_VARS)
    expect(newer["errors"]).to be_nil, newer["errors"].inspect
    expect(newer["data"]["fresh"]).to eq("fresh")
  end

  # ---------------------------------------------------------------- R1 / R3 entry points

  it "S1 security: a late field under Schema::Visibility refuses the first query with ConfigurationError" do
    schema = schema_for(late_field_query, plugin: :visibility)
    expect_late(error_of { run(schema, "{ hi }", root: hi_root) }, /Query\.hi/)
  end

  it "S3 security: a field-block argument loaded before Base on its argument class is refused" do
    ac = Class.new(GraphQL::Schema::Argument)
    fc = Class.new(GraphQL::Schema::Field) { include GraphQL::Armory::Versioning::Base; argument_class ac }
    q = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field_class fc
      field :echo, String, null: true do
        argument :text, String, required: false
      end
    end
    q.own_fields["echo"].ensure_loaded
    ac.include(base)
    schema = schema_for(q, plugin: :visibility)
    root = Class.new { def echo(text: nil) = text }.new
    expect_late(error_of { run(schema, '{ echo(text: "a") }', root: root) }, /Query\.echo\.text/)
  end

  it "S5 security: a union membership built before its membership class included Base is refused, named" do
    mc = Class.new(GraphQL::Schema::TypeMembership)
    fc = ok_field_class
    cat = Class.new(GraphQL::Schema::Object) { include GraphQL::Armory::Versioning::Base; graphql_name "Kitty"; field_class fc; field :name, String, null: true }
    pet = Class.new(GraphQL::Schema::Union) { include GraphQL::Armory::Versioning::Base; graphql_name "Pet"; type_membership_class mc; possible_types cat }
    mc.include(base)
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field_class fc; field :pet, pet, null: true }
    schema = schema_for(q, plugin: :visibility, resolve: ->(_) { cat })
    expect_late(error_of { run(schema, "{ pet { __typename } }", root: Struct.new(:pet).new(Struct.new(:name).new("x"))) }, /Pet membership of Kitty/)
  end

  it "S6 security: an interface membership (implements) built before the membership class included Base is refused, named" do
    mc = Class.new(GraphQL::Schema::TypeMembership)
    fc = ok_field_class
    named = Module.new { include GraphQL::Schema::Interface; include GraphQL::Armory::Versioning::Base; graphql_name "Named"; field_class fc; type_membership_class mc; field :name, String, null: true }
    cat = Class.new(GraphQL::Schema::Object) { include GraphQL::Armory::Versioning::Base; graphql_name "Kitty"; field_class fc; implements named }
    mc.include(base)
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field_class fc; field :named, named, null: true }
    schema = schema_for(q, plugin: :warden, orphans: [cat], resolve: ->(_) { cat })
    expect_late(error_of { run(schema, "{ named { name } }", root: Struct.new(:named).new(Struct.new(:name).new("x"))) }, /Named membership of Kitty/)
  end

  it "S9 security: an introspection query on a schema with a late field raises the ConfigurationError" do
    schema = schema_for(late_field_query, plugin: :visibility)
    expect_late(error_of { run(schema, "{ __schema { types { name fields { name } } } }") }, /Query\.hi/)
  end

  it "S10 security: to_definition (with and without a version) raises the ConfigurationError" do
    schema = schema_for(late_field_query, plugin: :visibility)
    expect_late(error_of { schema.to_definition }, /Query\.hi/)
    expect_late(error_of { schema.to_definition(context: { armory_version: "2025-01-01" }) }, /Query\.hi/)
  end

  it "S11 security: Versioning::Diff raises the ConfigurationError" do
    schema = schema_for(late_field_query, plugin: :visibility)
    expect_late(error_of { v::Diff.(schema, from: "2024-06-01", to: "2025-01-01") }, /Query\.hi/)
  end

  it "S12 security: profiles: true (no preload) refuses the first query with the ConfigurationError" do
    skip "profiles: true needs graphql 2.4.10" if Gem::Version.new(GraphQL::VERSION) < Gem::Version.new("2.4.10")
    schema = schema_for(late_field_query, plugin: :visibility, profiles: true, preload: false)
    expect_late(error_of { run(schema, "{ hi }", root: hi_root) }, /Query\.hi/)
  end

  it "S13 security: profiles: true with preload: true (the documented setup) raises the ConfigurationError, not NoMethodError" do
    skip "profiles: true needs graphql 2.4.10" if Gem::Version.new(GraphQL::VERSION) < Gem::Version.new("2.4.10")
    q = late_field_query
    expect_late(error_of { run(schema_for(q, plugin: :visibility, profiles: true, preload: true), "{ hi }", root: hi_root) }, /Query\.hi/)
  end

  it "S13b security: Versioning.profiles' Hash used by Visibility preload without the plugin check: Versioning.types still refuses" do
    skip "profiles: true needs graphql 2.4.10" if Gem::Version.new(GraphQL::VERSION) < Gem::Version.new("2.4.10")
    schema = schema_for(late_field_query, plugin: :visibility, profiles: true, preload: false)
    expect_late(error_of { v.types(schema, "2025-01-01") }, /Query\.hi/)
  end

  it "S25 security: Schema::Visibility with preload: true (no profiles) refuses the first query with the ConfigurationError" do
    q = late_field_query
    expect_late(error_of { run(schema_for(q, plugin: :visibility, preload: true), "{ hi }", root: hi_root) }, /Query\.hi/)
  end

  it "S14 security: Base included in the field class after the first query (memoized check) still refuses" do
    fc = Class.new(GraphQL::Schema::Field)
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field_class fc; field :hi, String, null: true }
    schema = schema_for(q, plugin: :visibility)
    expect(run(schema, "{ hi }", root: hi_root)).to eq("data" => { "hi" => "hi" })
    fc.include(base)
    expect_late(error_of { run(schema, "{ hi }", root: hi_root) }, /Query\.hi/)
  end

  it "S14w security: the same under the legacy Warden" do
    fc = Class.new(GraphQL::Schema::Field)
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field_class fc; field :hi, String, null: true }
    schema = schema_for(q, plugin: :warden)
    expect(run(schema, "{ hi }", root: hi_root)).to eq("data" => { "hi" => "hi" })
    fc.include(base)
    expect_late(error_of { run(schema, "{ hi }", root: hi_root) }, /Query\.hi/)
  end

  # Documented limit: a named profile caches what it already answered, so a member it served keeps being served in every
  # version, as before Base was included (it could not carry `added:` or `removed:` without Base).
  it "S14p preservation (documented limit): under profiles: true, a field class given Base after the field was served keeps being served" do
    skip "profiles: true needs graphql 2.4.10" if Gem::Version.new(GraphQL::VERSION) < Gem::Version.new("2.4.10")
    fc = Class.new(GraphQL::Schema::Field)
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field_class fc; field :hi, String, null: true }
    schema = schema_for(q, plugin: :visibility, profiles: true, preload: false)
    expect(run(schema, "{ hi }", version: "2025-01-01", root: hi_root)).to eq("data" => { "hi" => "hi" })
    fc.include(base)
    expect(run(schema, "{ hi }", version: "2025-01-01", root: hi_root)).to eq("data" => { "hi" => "hi" })
  end

  it "S15 security: a type with late fields reached through a field added after the first query is refused" do
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field_class Class.new(GraphQL::Schema::Field).tap { |c| c.include(GraphQL::Armory::Versioning::Base) }; field :hi, String, null: true }
    schema = schema_for(q, plugin: :visibility)
    expect(run(schema, "{ hi }", root: hi_root)).to eq("data" => { "hi" => "hi" })
    late = Class.new(GraphQL::Schema::Field)
    thing = Class.new(GraphQL::Schema::Object) { graphql_name "Thing"; field_class late; field :name, String, null: true }
    late.include(base)
    q.field :thing, thing, null: true
    root = Struct.new(:hi, :thing).new("hi", Struct.new(:name).new("n"))
    expect_late(error_of { run(schema, "{ thing { name } }", root: root) }, /Thing\.name/)
  end

  it "S16 security: Base included late in a parent field class while a subclass's fields exist is refused" do
    parent = Class.new(GraphQL::Schema::Field)
    child = Class.new(parent)
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field_class child; field :hi, String, null: true }
    parent.include(base)
    expect_late(error_of { run(schema_for(q), "{ hi }", root: hi_root) }, /Query\.hi/)
  end

  it "S17 security: Base included late in a subclass field class only names that subclass's members, not the parent's" do
    parent = Class.new(GraphQL::Schema::Field)
    child = Class.new(parent)
    thing = Class.new(GraphQL::Schema::Object) { graphql_name "Thing"; field_class child; field :name, String, null: true }
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field_class parent; field :plain, String, null: true; field :thing, thing, null: true }
    child.include(base)
    error = error_of { run(schema_for(q), "{ plain }", root: Struct.new(:plain).new("p")) }
    expect_late(error, /Thing\.name/)
    expect(error.message).not_to include("Query.plain")
  end

  it "S18 security: a late interface field is listed once (uniq), with no 'and N more'" do
    fc = Class.new(GraphQL::Schema::Field)
    named = Module.new { include GraphQL::Schema::Interface; graphql_name "Named"; field_class fc; field :name, String, null: true }
    ok = ok_field_class
    a = Class.new(GraphQL::Schema::Object) { graphql_name "A"; field_class ok; implements named }
    b = Class.new(GraphQL::Schema::Object) { graphql_name "B"; field_class ok; implements named }
    fc.include(base)
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field_class ok; field :named, named, null: true }
    error = error_of { run(schema_for(q, orphans: [a, b], resolve: ->(_) { a }), "{ named { name } }") }
    expect_late(error, /Named\.name/)
    listed = error.message.split(": the class of").first
    expect(listed.scan("Named.name").size).to eq(1)
    expect(listed).not_to include("more")
  end

  it "S20 security: a directive argument built before Base is refused, naming it" do
    ac = Class.new(GraphQL::Schema::Argument)
    tag = Class.new(GraphQL::Schema::Directive) do
      graphql_name "tag"
      locations(GraphQL::Schema::Directive::FIELD)
      argument_class ac
      argument :label, String, required: false
    end
    ac.include(base)
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field_class Class.new(GraphQL::Schema::Field).tap { |c| c.include(GraphQL::Armory::Versioning::Base) }; field :hi, String, null: true }
    expect_late(error_of { run(schema_for(q, directives: [tag]), '{ hi @tag(label: "x") }', root: hi_root) }, /tag\.label/)
  end

  it "S21 security: a resolver's argument built before Base is refused" do
    ac = Class.new(GraphQL::Schema::Argument)
    find = Class.new(GraphQL::Schema::Resolver) do
      graphql_name "Find"
      argument_class ac
      type String, null: true
      argument :id, GraphQL::Types::ID, required: false
      def resolve(id: nil) = id
    end
    ac.include(base)
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field_class Class.new(GraphQL::Schema::Field).tap { |c| c.include(GraphQL::Armory::Versioning::Base) }; field :find, resolver: find }
    expect_late(error_of { run(schema_for(q), '{ find(id: "1") }') }, /\bid\b/)
  end

  it "S21m security: a RelayClassicMutation argument built before Base is refused" do
    ac = Class.new(GraphQL::Schema::Argument)
    create = Class.new(GraphQL::Schema::RelayClassicMutation) do
      graphql_name "Create"
      argument_class ac
      argument :title, String, required: false
      field :ok, GraphQL::Types::Boolean, null: true
      def resolve(**) = { ok: true }
    end
    ac.include(base)
    ok = ok_field_class
    m = Class.new(GraphQL::Schema::Object) { graphql_name "Mutation"; field_class ok; field :create, mutation: create }
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field_class ok; field :hi, String, null: true }
    expect_late(error_of { run(schema_for(q, mutation: m), "mutation { create(input: { title: \"t\" }) { ok } }") }, /title/)
  end

  # A field's location is its owner class's line unless Authorization recorded the field's own.
  it "S23 security: more than five late members: the first five listed with file:line of their class, then 'and 2 more'" do
    error = error_of { run(schema_for(LateBaseProbeFixtures::MsgQuery), "{ f1 }") }
    expect(error).to be_a(ce), error.inspect
    listed = error.message.split(": the class of").first
    expect(listed).to end_with("and 2 more")
    expect(listed.scan(/Query\.f\d \([^)]*late_base_probes_spec\.rb:\d+\)/).size).to eq(5)
    class_line = File.readlines(__FILE__).index { |line| line.include?("class MsgQuery") } + 1
    expect(listed).to include("late_base_probes_spec.rb:#{class_line})")
  end

  it "S23e security: a late enum value is named (without a location: none is recorded for enum values)" do
    error = error_of { run(schema_for(LateBaseProbeFixtures::MsgColorQuery), "{ color }") }
    expect_late(error, /Color\.RED/)
  end

  it "S24 security: a late union membership whose member is still a String raises ConfigurationError, not NoMethodError" do
    mc = Class.new(GraphQL::Schema::TypeMembership)
    pet = Class.new(GraphQL::Schema::Union) { graphql_name "Pet"; type_membership_class mc; possible_types "LateBaseProbeFixtures::Cat" }
    mc.include(base)
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :pet, pet, null: true }
    expect_late(error_of { run(schema_for(q, plugin: :visibility, resolve: ->(_) { LateBaseProbeFixtures::Cat }), "{ pet { __typename } }") }, /Pet membership/)
  end

  it "S24w security: the same under the legacy Warden" do
    mc = Class.new(GraphQL::Schema::TypeMembership)
    pet = Class.new(GraphQL::Schema::Union) { graphql_name "Pet"; type_membership_class mc; possible_types "LateBaseProbeFixtures::Cat" }
    mc.include(base)
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :pet, pet, null: true }
    expect_late(error_of { run(schema_for(q, plugin: :warden, resolve: ->(_) { LateBaseProbeFixtures::Cat }), "{ pet { __typename } }") }, /Pet membership/)
  end

  it "S27 security: the audit reports late membership, enum value and argument instead of raising" do
    mc = Class.new(GraphQL::Schema::TypeMembership)
    vc = Class.new(GraphQL::Schema::EnumValue)
    ac = Class.new(GraphQL::Schema::Argument)
    ok = ok_field_class
    cat = Class.new(GraphQL::Schema::Object) { include GraphQL::Armory::Versioning::Base; graphql_name "Kitty"; field_class ok; field :name, String, null: true }
    pet = Class.new(GraphQL::Schema::Union) { include GraphQL::Armory::Versioning::Base; graphql_name "Pet"; type_membership_class mc; possible_types cat }
    color = Class.new(GraphQL::Schema::Enum) { graphql_name "Color"; enum_value_class vc; value "RED" }
    filter = Class.new(GraphQL::Schema::InputObject) { graphql_name "Filter"; argument_class ac; argument :text, String, required: false }
    [mc, vc, ac].each { |c| c.include(base) }
    q = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field_class ok
      field :pet, pet, null: true
      field :color, color, null: true
      field :search, String, null: true do
        argument :filter, filter, required: false
      end
    end
    report = nil
    error = error_of { report = v::Audit.(schema_for(q, resolve: ->(_) { cat })) }
    expect(error).to be_nil, "audit raised #{error.class}: #{error&.message}"
    refusals = report.problems.select { |p| p.kind == :refused && p.path == "Schema" }.map(&:message).join
    expect(refusals).to include("Pet membership of Kitty").and include("Color.RED").and include("Filter.text")
  end

  it "S28 security: the audit with a late subscription argument reports, does not raise" do
    ac = Class.new(GraphQL::Schema::Argument)
    fc = Class.new(GraphQL::Schema::Field) { include GraphQL::Armory::Versioning::Base; argument_class ac }
    sub = Class.new(GraphQL::Schema::Object) do
      graphql_name "Subscription"
      field_class fc
      field :updated, String, null: true, arguments: {}
      field :changed, String, null: true do
        argument :id, GraphQL::Types::ID, required: false, default_value: "1"
      end
    end
    sub.own_fields["changed"].ensure_loaded
    ac.include(base)
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field_class fc; field :hi, String, null: true }
    report = nil
    error = error_of { report = v::Audit.(schema_for(q, subscription: sub)) }
    expect(error).to be_nil, "audit raised #{error.class}: #{error&.message}"
    expect(report.problems.map(&:message).join).to include("Subscription.changed.id")
  end

  it "N1 security (documented limit): a lookup with no context on a late field" do
    q = late_field_query
    schema_for(q, plugin: :warden)
    error = error_of { q.fields }
    expect(error).to be_nil.or(be_a(ce)), "got #{error.class}: #{error&.message}"
  end

  # Pre-existing (on main before PR #80), in the backlog: `implements X, added:` without Base on the membership class is ignored.
  xit "X1 security (pre-existing hunt): implements with added: through a membership class without Base never serves it outside" do
    named = Module.new { include GraphQL::Schema::Interface; graphql_name "Named"; field :name, String, null: true }
    error = error_of do
      cat = Class.new(GraphQL::Schema::Object) { graphql_name "Kitty"; implements named, added: "2025-01-01"; field :name, String, null: true }
      q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :kitty, cat, null: true }
      schema = schema_for(q)
      result = run(schema, '{ __type(name: "Kitty") { interfaces { name } } }', version: "2024-06-01")
      raise "served outside: #{result.inspect}" if result.dig("data", "__type", "interfaces").to_a.any?
    end
    expect(error).to be_a(ce), "got #{error.class}: #{error&.message}"
  end

  # ---------------------------------------------------------------- R2 preservation

  it "P1s preservation: install-template schema, argument-free query (runs on every configuration)" do
    %i[visibility warden].each do |plugin|
      schema = template_schema(plugin: plugin)
      result = run(schema, "{ hi status named { name } pet { __typename } __schema { types { name } } }", version: "2024-06-01", root: TemplateRoot.new)
      expect(result["errors"]).to be_nil, "#{plugin}: #{result['errors'].inspect}"
      expect(result["data"].slice("hi", "status", "named", "pet")).to eq("hi" => "hi", "status" => "PAID", "named" => { "name" => "tom" }, "pet" => { "__typename" => "Item" })
      expect { v.types(schema, "2025-01-01") }.not_to raise_error
      expect(v::Audit.(schema).problems.select { |p| p.kind == :refused }).to be_empty
    end
  end

  it "P1 preservation: install-template schema with Base first runs both versions under Schema::Visibility" do
    expect_template_ok(template_schema(plugin: :visibility))
  end

  it "P1w preservation: install-template schema with Base first runs both versions under the legacy Warden" do
    expect_template_ok(template_schema(plugin: :warden))
  end

  it "P1m preservation: the template's RelayClassicMutation (generated input and payload) runs" do
    schema = template_schema
    older = run(schema, 'mutation { createItem(input: { title: "t", clientMutationId: "c" }) { itemTitle } }', version: "2024-06-01")
    newer = run(schema, 'mutation { createItem(input: { title: "t", sku: "s" }) { itemTitle } }', version: "2025-01-01")
    expect([older, newer]).to eq([{ "data" => { "createItem" => { "itemTitle" => "t" } } },
                                  { "data" => { "createItem" => { "itemTitle" => "t/s" } } }])
  end

  it "P1r preservation: the template's resolver arguments run" do
    schema = template_schema
    older = run(schema, '{ find(id: "1") }', version: "2024-06-01", root: TemplateRoot.new)
    newer = run(schema, '{ find(id: "1", newer: "n") }', version: "2025-01-01", root: TemplateRoot.new)
    expect([older, newer]).to eq([{ "data" => { "find" => "found 1" } }, { "data" => { "find" => "found 1n" } }])
  end

  it "P2 preservation: template schema: introspection, to_definition, Versioning.types, Diff and the audit raise nothing" do
    skip "environment: graphql 2.4 with json 3.1 cannot serialize argument values in validation" unless ArmoryJsonPrinting.prints_strings?
    schema = template_schema
    intro = run(schema, GraphQL::Introspection::INTROSPECTION_QUERY, version: "2024-06-01")
    expect(intro["errors"]).to be_nil, intro["errors"].inspect
    directives = intro["data"]["__schema"]["directives"].map { |d| d["name"] }
    expect(directives).to include("skip", "include", "deprecated", "tag")
    sdl = schema.to_definition(context: { armory_version: "2025-01-01" })
    expect(sdl).to include("fresh").and include("PageInfo").and include("clientMutationId")
    expect { v.types(schema, "2024-06-01") }.not_to raise_error
    diff = v::Diff.(schema, from: "2024-06-01", to: "2025-01-01")
    expect(diff.changes.map(&:path)).to include("Query.fresh")
    report = v::Audit.(schema)
    refused = report.problems.select { |p| p.kind == :refused }
    expect(refused).to be_empty, refused.map(&:message).inspect
  end

  it "P1n preservation: graphql-ruby's own Relay Node interface, NodeField and NodesField with Base-first classes" do
    t = template
    item = Class.new(t[:obj]) { graphql_name "Item"; implements GraphQL::Types::Relay::Node; field :title, String, null: true }
    q = Class.new(t[:obj]) do
      graphql_name "Query"
      include GraphQL::Types::Relay::HasNodeField
      include GraphQL::Types::Relay::HasNodesField
      field :hi, String, null: true
    end
    schema = schema_for(q, orphans: [item], resolve: ->(_) { item })
    schema.define_singleton_method(:object_from_id) { |id, _ctx| ItemS.new(id, "t", "s") }
    schema.define_singleton_method(:id_from_object) { |obj, _t, _ctx| obj.id }
    result = run(schema, '{ hi node(id: "1") { id ... on Item { title } } nodes(ids: ["2"]) { id } }', version: "2024-06-01", root: TemplateRoot.new)
    expect(result).to eq("data" => { "hi" => "hi", "node" => { "id" => "1", "title" => "t" }, "nodes" => [{ "id" => "2" }] })
    refused = v::Audit.(schema).problems.select { |p| p.kind == :refused }
    expect(refused).to be_empty, refused.map(&:message).inspect
  end

  it "P3 preservation: a schema whose classes never include Base runs, and the audit refuses nothing" do
    q = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :hi, String, null: true do
        argument :x, String, required: false
      end
    end
    schema = schema_for(q)
    root = Class.new { def hi(x: nil) = "hi#{x}" }.new
    expect(run(schema, '{ hi(x: "!") }', root: root)).to eq("data" => { "hi" => "hi!" })
    expect(v::Audit.(schema).problems.select { |p| p.kind == :refused }).to be_empty
  end

  it "P4 preservation: template schema with profiles: true and preload: true runs both versions" do
    skip "profiles: true needs graphql 2.4.10" if Gem::Version.new(GraphQL::VERSION) < Gem::Version.new("2.4.10")
    expect_template_ok(template_schema(plugin: :visibility, profiles: true, preload: true))
  end

  it "P5 preservation: field-block arguments defined before Base, loaded after it, are not refused" do
    ac = Class.new(GraphQL::Schema::Argument)
    fc = Class.new(GraphQL::Schema::Field) { include GraphQL::Armory::Versioning::Base; argument_class ac }
    q = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field_class fc
      field :echo, String, null: true do
        argument :text, String, required: false
        argument :newer, String, required: false, added: "2025-01-01"
      end
    end
    ac.include(base)
    schema = schema_for(q)
    root = Class.new { def echo(text: nil, newer: nil) = "#{text}#{newer}" }.new
    expect(run(schema, '{ echo(text: "a") }', version: "2024-06-01", root: root)).to eq("data" => { "echo" => "a" })
    expect(run(schema, '{ echo(text: "a", newer: "b") }', version: "2025-01-01", root: root)).to eq("data" => { "echo" => "ab" })
  end

  it "P6 preservation: Base included late on type classes (object, interface, union, enum, input) is not refused" do
    ok = ok_field_class
    named = Module.new { include GraphQL::Schema::Interface; graphql_name "Named"; field_class ok; field :name, String, null: true }
    cat = Class.new(GraphQL::Schema::Object) { graphql_name "Kitty"; field_class ok; implements named }
    pet = Class.new(GraphQL::Schema::Union) { graphql_name "Pet"; possible_types cat }
    color = Class.new(GraphQL::Schema::Enum) { graphql_name "Color"; value "RED" }
    filter = Class.new(GraphQL::Schema::InputObject) { graphql_name "Filter"; argument :text, String, required: false }
    q = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field_class ok
      field :pet, pet, null: true
      field :named, named, null: true
      field :color, color, null: true
      field :search, String, null: true do
        argument :filter, filter, required: false
      end
    end
    named.include(base)
    [cat, pet, color, filter, q].each { |c| c.include(base) }
    root = Class.new do
      def color = "RED"
      def search(filter: nil) = filter && filter[:text]
      def pet = Struct.new(:name).new("tom")
    end.new
    schema = schema_for(q, orphans: [cat], resolve: ->(_) { cat })
    result = run(schema, '{ color search(filter: { text: "t" }) pet { ... on Kitty { name } } }', root: root)
    expect(result).to eq("data" => { "color" => "RED", "search" => "t", "pet" => { "name" => "tom" } })
  end

  it "P10 preservation: an interface named by a String in implements (bare membership) causes no refusal or crash" do
    t = template
    named = Module.new { include t[:iface]; graphql_name "Named"; field :name, String, null: true }
    stub_named = named
    LateBaseProbeFixtures.const_set(:StringNamed, stub_named) unless LateBaseProbeFixtures.const_defined?(:StringNamed, false)
    cat = Class.new(t[:obj]) { graphql_name "Kitty"; implements "LateBaseProbeFixtures::StringNamed"; field :name, String, null: true }
    q = Class.new(t[:obj]) { graphql_name "Query"; field :kitty, cat, null: true }
    schema = schema_for(q, orphans: [cat])
    result = run(schema, "{ kitty { name } }", root: Struct.new(:kitty).new(Struct.new(:name).new("tom")))
    expect(result).to eq("data" => { "kitty" => { "name" => "tom" } })
  end
end
