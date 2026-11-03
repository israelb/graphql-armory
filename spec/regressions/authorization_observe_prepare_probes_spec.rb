# frozen_string_literal: true

# Probes of the verification of PR #56 (refuse an inherited observed resolver field at the type check), kept as
# regressions. Each example is labelled [security] or [preservation]. "ran" is what really ran: :prepare, :load, :body.
# `emit` printed values to diff the branch with main during the verification; it prints nothing here.
module VP
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

RSpec.describe "PR56 verification probes" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:ran) { [] }
  let(:signals) { [] }
  let(:sink) { ->(signal, data) { signals << [signal, data[:type], data[:action]] } }
  let(:adapter) { VP::ByAction.new(%i[show view]) }

  let(:base_argument) do
    plugin = armory
    Class.new(GraphQL::Schema::Argument) { include plugin::Base }
  end
  let(:base_field) do
    plugin = armory
    arg = base_argument
    Class.new(GraphQL::Schema::Field) do
      include plugin::Base
      argument_class arg
    end
  end
  let(:base_object) do
    plugin = armory
    bf = base_field
    Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class bf
    end
  end
  let(:base_object_plain_field) do
    plugin = armory
    Class.new(GraphQL::Schema::Object) { include plugin::Base }
  end

  def emit(tag, value)
    [tag, value]
  end

  def touch_resolver(base: GraphQL::Schema::Resolver, &block)
    log = ran
    Class.new(base) do
      type String, null: true
      argument :input, String, required: false, prepare: ->(value, _context) { log << :prepare && value }
      define_method(:resolve) do |**_kw|
        log << :body
        "ran"
      end
      class_eval(&block) if block
    end
  end

  def obj(name, parent: base_object, &block)
    Class.new(parent) do
      graphql_name name
      class_eval(&block) if block
    end
  end

  def observed_parent(name = "Parent", parent: base_object, &block)
    obj(name, parent: parent) do
      authorize :read, model: Object, observe: "rollout"
      field :title, String, null: true, hash_key: :title
      class_eval(&block) if block
    end
  end

  def doc_type(resolver = touch_resolver, name: "Doc", **field_opts)
    parent = observed_parent { field :touch, resolver: resolver, authorize: true, **field_opts }
    obj(name, parent: parent) { authorize :show, model: Object }
  end

  def root_of(fields)
    obj("Query") do
      authorize :none, reason: "root", covers_fields: true
      fields.each { |fname, type| field fname, type, null: true, authorize: :none, reason: "x", hash_key: fname }
    end
  end

  def schema_for(query, mutation: nil, orphans: [], max_complexity: nil, rescue_all: false, visibility: false, from_id: nil, adapter: self.adapter)
    plugin = armory
    sinks = [sink]
    log = ran
    Class.new(ArmoryEngine.base_schema) do
      use GraphQL::Schema::Visibility if visibility
      query query
      mutation mutation if mutation
      orphan_types(*orphans) unless orphans.empty?
      max_complexity max_complexity if max_complexity
      default_max_page_size 10
      rescue_from(StandardError) { |_err, *_rest| "handled" } if rescue_all
      if from_id
        define_singleton_method(:object_from_id) do |id, _ctx|
          log << :load
          from_id.call(id)
        end
      end
      define_singleton_method(:resolve_type) { |_t, obj, _c| obj[:__type] } if orphans.any?
      use plugin, adapter: adapter, sinks: sinks
    end
  end

  def run(schema, document, root: { doc: { title: "t" } }, variables: {})
    execute_query(schema, document, root_value: root, context: {}, variables: variables).to_h
  rescue GraphQL::Armory::Authorization::ConfigurationError, NoMethodError => error
    root = error
    root = root.cause while root.cause
    raise unless root.is_a?(GraphQL::Armory::Authorization::ConfigurationError)

    { "raised" => root.message, "via" => error.class.name }
  end

  def multiplex(schema, queries)
    ArmoryEngine.next? ? schema.multiplex_next(queries) : schema.multiplex(queries)
  end

  describe "issue #36 shapes" do
    it "[security] S2 loads: on the inherited resolver does not load for a refused user" do
      thing = obj("Thing") { authorize :view, model: Object; field :title, String, null: true, hash_key: :title }
      log = ran
      r = Class.new(GraphQL::Schema::Resolver) do
        type String, null: true
        argument :thing_id, GraphQL::Types::ID, required: false, loads: thing
        define_method(:resolve) { |**_kw| log << :body; "ran" }
      end
      doc = doc_type(r)
      schema = schema_for(root_of(doc: doc), orphans: [thing], from_id: ->(_id) { { title: "x", __type: thing } })
      result = run(schema, '{ doc { touch(thingId: "1") } }')
      emit("S2", [ran, result])
      expect(ran).to eq([])
    end

    it "[security] S3 an inherited RelayClassicMutation field, input prepare does not run" do
      log = ran
      m = Class.new(GraphQL::Schema::RelayClassicMutation) do
        graphql_name "Act"
        argument :note, String, required: false, prepare: ->(v, _c) { log << :prepare && v }
        field :ok, GraphQL::Types::Boolean, null: true
        define_method(:resolve) { |**_kw| log << :body; { ok: true } }
      end
      parent = observed_parent { field :act, mutation: m, authorize: true }
      doc = obj("Doc", parent: parent) { authorize :show, model: Object }
      result = run(schema_for(root_of(doc: doc)), '{ doc { act(input: { note: "x" }) { ok } } }')
      emit("S3", [ran, result])
      expect(ran).to eq([])
    end

    it "[security] S3b root Mutation type inheriting a mutation: field from an observed parent" do
      log = ran
      m = Class.new(GraphQL::Schema::RelayClassicMutation) do
        graphql_name "Act"
        argument :note, String, required: false, prepare: ->(v, _c) { log << :prepare && v }
        field :ok, GraphQL::Types::Boolean, null: true
        define_method(:resolve) { |**_kw| log << :body; { ok: true } }
      end
      root_parent = observed_parent("MutationParent") { field :act, mutation: m, authorize: true }
      mutation = obj("Mutation", parent: root_parent) { authorize :show, model: Object }
      result = run(schema_for(root_of(doc: doc_type), mutation: mutation), 'mutation { act(input: { note: "x" }) { ok } }', root: {})
      emit("S3b", [ran, result])
      expect(ran).to eq([])
    end

    ['{ doc { title a: touch(input: "x") } }',
     '{ doc { ... on Doc { b: touch(input: "y") } title } }',
     'fragment F on Doc { touch(input: "x") } { doc { ...F } }',
     '{ x: doc { title } y: doc { touch(input: "z") } }'].each_with_index do |document, i|
      it "[security] S5.#{i} order/alias/fragment: #{document}" do
        result = run(schema_for(root_of(doc: doc_type)), document)
        emit("S5.#{i}", [ran, result.keys])
        expect(ran).to eq([])
        expect(result).to have_key("raised")
      end
    end

    it "[security] S5.v the input through a variable" do
      result = run(schema_for(root_of(doc: doc_type)), "query($v: String) { doc { touch(input: $v) } }", variables: { "v" => "x" })
      expect(ran).to eq([])
      expect(result).to have_key("raised")
    end

    it "[security] S6 a resolver that includes Base with its own rule, declared authorize: true" do
      plugin = armory
      r = touch_resolver do
        include plugin::Base
        authorize :show, model: Object
      end
      result = run(schema_for(root_of(doc: doc_type(r))), '{ doc { touch(input: "x") } }')
      emit("S6", [ran, result])
      expect(ran).to eq([])
    end

    it "[security] S6b a resolver that includes Base with a bypass, declared authorize: true" do
      plugin = armory
      r = touch_resolver do
        include plugin::Base
        authorize :none, reason: "free"
      end
      run(schema_for(root_of(doc: doc_type(r))), '{ doc { touch(input: "x") } }')
      expect(ran).to eq([])
    end
  end

  describe "field classes and owners" do
    it "[preservation] S7 graphql's own field class on an observed parent, enforced child allowed: same as main" do
      r = touch_resolver
      parent = observed_parent("Parent", parent: base_object_plain_field) { field :touch, resolver: r }
      doc = obj("Doc", parent: parent) { authorize :show, model: Object }
      result = run(schema_for(root_of(doc: doc)), '{ doc { touch(input: "x") } }')
      emit("S7", [ran, result, signals])
      expect(result).to eq("data" => { "doc" => { "touch" => "ran" } })
    end

    it "[security] S7b graphql's own field class on an observed parent, child refused: nothing runs" do
      r = touch_resolver
      parent = observed_parent("Parent", parent: base_object_plain_field) { field :touch, resolver: r }
      doc = obj("Doc", parent: parent) { authorize :show, model: Object }
      result = run(schema_for(root_of(doc: doc), adapter: VP::ByAction.new([])), '{ doc { touch(input: "x") } }')
      emit("S7b", [ran, result])
      expect(ran).to eq([])
      expect(result.dig("data", "doc")).to be_nil
    end

    it "[security] S14 a field moved with add_field from an observed class to an enforced type" do
      r = touch_resolver
      parent = observed_parent { field :touch, resolver: r, authorize: true }
      moved = parent.get_field("touch")
      doc = obj("Doc") { authorize :show, model: Object }
      doc.add_field(moved)
      result = run(schema_for(root_of(doc: doc)), '{ doc { touch(input: "x") } }')
      emit("S14", [ran, result])
      expect(ran).to eq([])
    end

    it "[preservation] S14b a type with no rule holding that field: denied, nothing runs, no raise" do
      r = touch_resolver
      parent = observed_parent { field :touch, resolver: r, authorize: true }
      doc = obj("Doc")
      doc.add_field(parent.get_field("touch"))
      result = run(schema_for(root_of(doc: doc)), '{ doc { touch(input: "x") } }')
      emit("S14b", [ran, result, signals])
      expect(ran).to eq([])
      expect(result).to eq("data" => { "doc" => nil })
    end

    it "[security] S24 install-template shape: Base argument/field/object/input, RelayClassicMutation with classes" do
      plugin = armory
      arg = base_argument
      bf = base_field
      bo = base_object
      input = Class.new(GraphQL::Schema::InputObject) do
        include plugin::Base
        argument_class arg
      end
      log = ran
      m = Class.new(GraphQL::Schema::RelayClassicMutation) do
        graphql_name "Act"
        argument_class arg
        field_class bf
        input_object_class input
        object_class bo
        argument :note, String, required: false, prepare: ->(v, _c) { log << :prepare && v }
        field :ok, GraphQL::Types::Boolean, null: true, authorize: :none, reason: "x"
        define_method(:resolve) { |**_kw| log << :body; { ok: true } }
      end
      parent = observed_parent { field :act, mutation: m, authorize: true }
      doc = obj("Doc", parent: parent) { authorize :show, model: Object }
      emit("S24 owners", [doc.method(:authorized?).owner, bf.instance_method(:authorized?).owner, parent.get_field("act").class.ancestors.take(4)])
      result = run(schema_for(root_of(doc: doc)), '{ doc { act(input: { note: "x" }) { ok } } }')
      emit("S24", [ran, result])
      expect(ran).to eq([])
    end
  end

  describe "where the type is reached" do
    it "[security] S8 root Query inheriting the field from an observed parent" do
      r = touch_resolver
      root_parent = observed_parent("QueryParent") { field :touch, resolver: r, authorize: true }
      query = obj("Query", parent: root_parent) { authorize :show, model: Object }
      result = run(schema_for(query), '{ touch(input: "x") }', root: {})
      emit("S8", [ran, result])
      expect(ran).to eq([])
    end

    it "[security] S9a a union member" do
      doc = doc_type
      union = Class.new(GraphQL::Schema::Union) do
        graphql_name "U"
        possible_types doc
      end
      result = run(schema_for(root_of(u: union), orphans: [doc]), '{ u { ... on Doc { touch(input: "x") } } }', root: { u: { __type: doc } })
      emit("S9a", [ran, result])
      expect(ran).to eq([])
    end

    it "[security] S9b an interface-typed field resolving to the subclass" do
      iface = Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Node"
        field :title, String, null: true, hash_key: :title
      end
      tr = touch_resolver
      parent = observed_parent { field :touch, resolver: tr, authorize: true }
      doc = obj("Doc", parent: parent) do
        implements iface
        authorize :show, model: Object
      end
      result = run(schema_for(root_of(node: iface), orphans: [doc]), '{ node { title ... on Doc { touch(input: "x") } } }', root: { node: { __type: doc, title: "t" } })
      emit("S9b", [ran, result])
      expect(ran).to eq([])
    end

    it "[security] S10a a list of many items" do
      doc = doc_type
      result = run(schema_for(root_of(docs: [doc])), '{ docs { touch(input: "x") } }', root: { docs: Array.new(30) { { title: "t" } } })
      emit("S10a", [ran, result.keys])
      expect(ran).to eq([])
    end

    it "[security] S10b a connection" do
      doc = doc_type
      result = run(schema_for(root_of(docs_conn: doc.connection_type)), '{ docsConn(first: 5) { nodes { touch(input: "x") } } }', root: { docs_conn: Array.new(8) { { title: "t" } } })
      emit("S10b", [ran, result.keys])
      expect(ran).to eq([])
    end

    it "[preservation] S10c the field-scan cost does not grow with list size (non-observed type with a resolver field)" do
      counts = {}
      [5, 50].each do |n|
        calls = []
        r = touch_resolver
        plain = obj("Plain") do
          authorize :show, model: Object
          field :title, String, null: true, hash_key: :title
          field :touch, resolver: r, authorize: true
        end
        plain.define_singleton_method(:all_field_definitions) do
          calls << 1
          super()
        end
        schema = schema_for(root_of(plains: [plain]))
        result = run(schema, "{ plains { title } }", root: { plains: Array.new(n) { { title: "t" } } })
        expect(result.dig("data", "plains").size).to eq(n)
        counts[n] = calls.size
      end
      emit("S10c", counts)
      expect(counts[50]).to eq(counts[5])
    end

    it "[security] S12 rescue_from(StandardError) answering a value serves nothing" do
      result = run(schema_for(root_of(doc: doc_type), rescue_all: true), '{ doc { title touch(input: "x") } }')
      emit("S12", [ran, result])
      expect(ran).to eq([])
      expect(result.dig("data", "doc")).to be_nil
    end

    it "[security] S13 a bypassed child inheriting the field" do
      tr = touch_resolver
      parent = observed_parent { field :touch, resolver: tr, authorize: true }
      doc = obj("Doc", parent: parent) { authorize :none, reason: "public" }
      result = run(schema_for(root_of(doc: doc)), '{ doc { touch(input: "x") } }')
      emit("S13", [ran, result])
      expect(ran).to eq([])
    end

    it "[security] S13b a bypassed child that covers its fields" do
      tr = touch_resolver
      parent = observed_parent { field :touch, resolver: tr, authorize: true }
      doc = obj("Doc", parent: parent) { authorize :none, reason: "public", covers_fields: true }
      result = run(schema_for(root_of(doc: doc)), '{ doc { touch(input: "x") } }')
      emit("S13b", [ran, result])
      expect(ran).to eq([])
    end

    it "[security] S29 the same shape with Schema::Visibility" do
      result = run(schema_for(root_of(doc: doc_type), visibility: true), '{ doc { touch(input: "x") } }')
      emit("S29", [ran, result.keys])
      expect(ran).to eq([])
    end
  end

  describe "analysis before execution" do
    # Documented limit: graphql-ruby's complexity analysis coerces these arguments before any authorization.
    xit "[security] S17 max_complexity with an inherited connection resolver field" do
      item = obj("Item") { authorize :show, model: Object; field :title, String, null: true, hash_key: :title }
      log = ran
      r = Class.new(GraphQL::Schema::Resolver) do
        type item.connection_type, null: true
        argument :input, String, required: false, prepare: ->(v, _c) { log << :prepare && v }
        define_method(:resolve) { |**_kw| log << :body; [] }
      end
      parent = observed_parent { field :items, resolver: r, authorize: true }
      doc = obj("Doc", parent: parent) { authorize :show, model: Object }
      result = run(schema_for(root_of(doc: doc), max_complexity: 1000), '{ doc { items(input: "x", first: 2) { nodes { title } } } }')
      emit("S17", [ran, result])
      expect(ran).to eq([])
    end

    xit "[security] S17b max_complexity with a Proc complexity on the inherited resolver field" do
      r = touch_resolver
      parent = observed_parent { field :touch, resolver: r, authorize: true, complexity: ->(_c, _a, child) { child + 1 } }
      doc = obj("Doc", parent: parent) { authorize :show, model: Object }
      result = run(schema_for(root_of(doc: doc), max_complexity: 1000), '{ doc { touch(input: "x") } }')
      emit("S17b", [ran, result])
      expect(ran).to eq([])
    end
  end

  describe "multiplex" do
    it "[security] S11 each query has its own cache: refused queries refuse, the plain one is served" do
      r = touch_resolver
      doc = doc_type(r)
      plain = obj("Plain") { authorize :show, model: Object; field :title, String, null: true, hash_key: :title }
      schema = schema_for(root_of(doc: doc, plain: plain), rescue_all: true)
      root = { doc: { title: "t" }, plain: { title: "p" } }
      results = multiplex(schema, [
        { query: "{ plain { title } }", root_value: root, context: {} },
        { query: '{ doc { touch(input: "x") } }', root_value: root, context: {} },
        { query: "{ plain { title } doc { title } }", root_value: root, context: {} }
      ]).map(&:to_h)
      emit("S11", [ran, results.map { |res| res["data"] }])
      expect(ran).to eq([])
      expect(results[0]["data"]).to eq("plain" => { "title" => "p" })
      expect(results[1]["data"]).to eq("doc" => nil)
      expect(results[2]["data"]).to eq("plain" => { "title" => "p" }, "doc" => nil)
    end
  end

  describe "preservation" do
    it "[preservation] S19 a subclass overriding the resolver field with a plain one is served" do
      tr = touch_resolver
      parent = observed_parent { field :touch, resolver: tr, authorize: true }
      doc = obj("Doc", parent: parent) do
        authorize :show, model: Object
        field :touch, String, null: true, hash_key: :title
      end
      result = run(schema_for(root_of(doc: doc)), "{ doc { touch title } }")
      emit("S19", [ran, result, signals])
      expect(result).to eq("data" => { "doc" => { "touch" => "t", "title" => "t" } })
    end

    it "[preservation] S20 a subclass overriding it with a resolver field of its own rule is served" do
      tr = touch_resolver
      parent = observed_parent { field :touch, resolver: tr, authorize: true }
      r = touch_resolver
      doc = obj("Doc", parent: parent) do
        authorize :show, model: Object
        field :touch, resolver: r, authorize: :show
      end
      result = run(schema_for(root_of(doc: doc)), '{ doc { touch(input: "x") } }')
      emit("S20", [ran, result, signals])
      expect(result).to eq("data" => { "doc" => { "touch" => "ran" } })
    end

    it "[preservation] S21 the observed type's own message is unchanged" do
      r = touch_resolver
      doc = observed_parent("Doc") { field :touch, resolver: r }
      result = run(schema_for(root_of(doc: doc)), "{ doc { title } }")
      expect(result["raised"]).to eq("Doc cannot be observed: its field touch has a resolver or a mutation, which can write. Remove observe:, or put it on its plain fields")
    end

    [%i[show view], []].each do |allowed|
      it "[preservation] S22 non-observed types: results and signals as on main (allowed=#{allowed})" do
        r = touch_resolver
        parent = obj("Parent") do
          authorize :read, model: Object
          field :touch, resolver: r, authorize: true
          field :title, String, null: true, hash_key: :title
        end
        doc = obj("Doc", parent: parent) { authorize :show, model: Object }
        plain = obj("Plain") do
          authorize :show, model: Object
          field :title, String, null: true, hash_key: :title
          field :note, String, null: true, authorize: :view, hash_key: :title
        end
        schema = schema_for(root_of(doc: doc, plain: plain, plains: [plain]), adapter: VP::ByAction.new(allowed))
        result = run(schema, '{ doc { title touch(input: "x") } plain { title note } plains { title } }', root: { doc: { title: "t" }, plain: { title: "p" }, plains: [{ title: "a" }, { title: "b" }] })
        emit("S22 #{allowed}", [ran, result, signals])
        expect(result).not_to have_key("raised")
      end
    end

    it "[preservation] S28 a plain authorize: true field of an observed parent is still served and recorded" do
      parent = observed_parent { field :plainy, String, null: true, authorize: true, hash_key: :title }
      doc = obj("Doc", parent: parent) { authorize :show, model: Object }
      result = run(schema_for(root_of(doc: doc)), "{ doc { plainy } }")
      emit("S28", [result, signals])
      expect(result).to eq("data" => { "doc" => { "plainy" => "t" } })
      expect(signals.map(&:first)).to include(:observed)
    end

    it "[preservation] S16 loads: of such a type as a mutation argument (documented break: every query that reaches it)" do
      doc = doc_type
      log = ran
      save = Class.new(GraphQL::Schema::Mutation) do
        graphql_name "Save"
        argument :doc_id, GraphQL::Types::ID, loads: doc
        field :ok, GraphQL::Types::Boolean, null: true
        define_method(:resolve) { |**_kw| log << :body; { ok: true } }
      end
      mutation = obj("Mutation") do
        authorize :none, reason: "root", covers_fields: true
        field :save, mutation: save, authorize: :none, reason: "x"
      end
      schema = schema_for(root_of(doc: doc), mutation: mutation, from_id: ->(_id) { { title: "t" } })
      result = run(schema, 'mutation { save(docId: "1") { ok } }', root: {})
      emit("S16", [ran, result])
      expect(ran).not_to include(:body)
    end
  end

  describe "documented limits, characterised only" do
    it "[security] S18 an override hidden by visible? false, legacy lookup: refused at the type, nothing prepared" do
      tr = touch_resolver
      parent = observed_parent { field :touch, resolver: tr, authorize: true }
      hidden_field = Class.new(base_field) { def visible?(_ctx) = false }
      doc = obj("Doc", parent: parent) do
        authorize :show, model: Object
        field_class hidden_field
        field :touch, String, null: true, hash_key: :title
      end
      result = run(schema_for(root_of(doc: doc)), '{ doc { touch(input: "x") } }')
      emit("S18", [ran, result])

      expect(ran).to eq([])
      expect(result.to_s).to include("Doc.touch")
    end
  end

  describe "audit text" do
    it "[preservation] S23 audit problems for each shape (diffed A vs B)" do
      shapes = {}
      r = touch_resolver
      shapes[:own] = observed_parent("Doc") { field :touch, resolver: r }
      shapes[:inherited] = doc_type(r)
      p2 = observed_parent { field :plainy, String, null: true, authorize: true }
      shapes[:plain_inherited] = obj("Doc", parent: p2) { authorize :show, model: Object }
      shapes[:field_observe] = obj("Doc") do
        authorize :show, model: Object
        field :mine, String, null: true, authorize: :manage, observe: "rollout"
      end
      fc = base_field
      iface = Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Touchable"
        field_class fc
        field :touch, resolver: r, authorize: true
      end
      shapes[:interface] = obj("Doc") { implements iface; authorize :show, model: Object }
      p3 = observed_parent { field :touch, resolver: r, authorize: true }
      moved = obj("Doc") { authorize :show, model: Object }
      moved.add_field(p3.get_field("touch"))
      shapes[:moved] = moved
      shapes.each do |name, type|
        report = armory::Audit.(schema_for(root_of(doc: type)))
        emit("S23 #{name}", report.problems.select { |pr| pr.kind == :observed }.map { |pr| [pr.kind, pr.path, pr.message] }.sort)
      end
    end
  end
end
