# frozen_string_literal: true

require "stringio"

# Verification probes for API versioning increment 3b1, kept as regressions (Versioning::Audit :implicit, :empty,
# :orphan_interface, severity). Each `it` is labelled "security" or "preservation". Observations go to stderr ("OBS").
module Verify3b1Schemas; end

RSpec.describe "Versioning audit 3b1: verification probes" do
  VMM_V1 = "2024-06-01"
  VMM_V2 = "2025-01-01"

  def vv = GraphQL::Armory::Versioning

  def audit!(schema)
    skip "Versioning::Audit does not exist here" unless defined?(GraphQL::Armory::Versioning::Audit)
    GraphQL::Armory::Versioning::Audit.(schema)
  end

  def kinds(report) = report.problems.map { |problem| [problem.kind, problem.path] }.uniq

  def failing(report) = report.problems.reject { |problem| problem.respond_to?(:information?) && problem.information? }.map { |problem| [problem.kind, problem.path] }.uniq

  def info(report) = report.problems.select { |problem| problem.respond_to?(:information?) && problem.information? }.map { |problem| [problem.kind, problem.path] }.uniq

  def obs(label, report) = warn("OBS #{label}: ok?=#{report.ok?} failing=#{failing(report).inspect} info=#{info(report).inspect}")

  def run(schema, text, version, root: nil, variables: {})
    execute_query(schema, text, root_value: root, variables: variables, context: { armory_version: version }).to_h
  rescue StandardError => error
    { "raised" => "#{error.class}: #{error.message}" }
  end

  def obj(**values)
    Class.new do
      values.each { |name, value| define_method(name) { |**_args| value } }
    end.new
  end

  def schema_over(query_type, visibility, mutation_type: nil, dirs: [], sinks: [], adapter: nil, extra: [])
    plugin = { visibility: GraphQL::Schema::Visibility, warden: GraphQL::Schema::Warden }.fetch(visibility)
    labels = vv::Controls::Versions::LABELS
    retired = vv::Controls::Versions::RETIRED
    Class.new(ArmoryEngine.base_schema) do
      query(query_type)
      mutation(mutation_type) if mutation_type
      directives(*dirs) unless dirs.empty?
      extra_types(*extra) unless extra.empty?
      use plugin
      use GraphQL::Armory::Versioning, versions: labels, retired: retired, default: :latest, sinks: sinks
      use GraphQL::Armory::Authorization, adapter: adapter if adapter
      def self.resolve_type(_abstract, object, _context) = object.type
      def self.object_from_id(id, _context) = id
    end
  end

  def bases(authorization: false, anonymous_interface: false)
    mods = authorization ? [GraphQL::Armory::Versioning::Base, GraphQL::Armory::Authorization::Base] : [GraphQL::Armory::Versioning::Base]
    mod = GraphQL::Armory::Versioning::Base
    membership = Class.new(GraphQL::Schema::TypeMembership) { include mod }
    argument = Class.new(GraphQL::Schema::Argument) { mods.each { |m| include m } }
    field = Class.new(GraphQL::Schema::Field) { mods.each { |m| include m }; argument_class(argument) }
    object = Class.new(GraphQL::Schema::Object) { mods.each { |m| include m }; field_class(field) }
    interface = Module.new do
      include GraphQL::Schema::Interface
      include mod
      graphql_name "BaseInterface" unless anonymous_interface
      field_class(field)
      type_membership_class(membership)
    end
    union = Class.new(GraphQL::Schema::Union) { include mod; type_membership_class(membership) }
    value = Class.new(GraphQL::Schema::EnumValue) { include mod }
    enum = Class.new(GraphQL::Schema::Enum) { include mod; enum_value_class(value) }
    input = Class.new(GraphQL::Schema::InputObject) { include mod; argument_class(argument) }
    mutation = Class.new(GraphQL::Schema::RelayClassicMutation) do
      include mod
      argument_class(argument)
      field_class(field)
      object_class(object)
      input_object_class(input)
    end
    { membership: membership, argument: argument, field: field, object: object, interface: interface, union: union,
      value: value, enum: enum, input: input, mutation: mutation }
  end

  %i[visibility warden].each do |vis|
    context "with #{vis}" do
      # ------------------------------------------------------------------ :implicit
      it "security S01: a required argument typed by a type twin outside the version is :implicit" do
        b = bases
        twin_a = Class.new(b[:input]) { graphql_name "Filter"; lifecycle removed: VMM_V2; argument :q, String, required: false }
        twin_b = Class.new(b[:input]) { graphql_name "Filter"; lifecycle added: VMM_V2; argument :r, String, required: false }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :g, String, null: true do
            argument :filter, twin_a, required: true
          end
          field :h, String, null: true do
            argument :filter, twin_b, required: false
          end
        end
        schema = schema_over(query, vis)
        seen = run(schema, "{ g }", VMM_V2, root: obj(g: "ran", h: "h"))
        report = audit!(schema)
        obs("S01 #{vis} request=#{seen.inspect}", report)
        expect(seen).to eq("data" => { "g" => "ran" })
        expect(failing(report)).to include([:implicit, "Query.g.filter"])
        expect(report.ok?).to be(false)
      end

      it "security S02: a required nested input field hidden by its type is :implicit" do
        b = bases
        old = Class.new(b[:input]) { graphql_name "Old"; lifecycle removed: VMM_V2; argument :q, String, required: false }
        inner = Class.new(b[:input]) { graphql_name "Inner"; argument :x, old, required: true; argument :y, String, required: false }
        outer = Class.new(b[:input]) { graphql_name "Outer"; argument :inner, inner, required: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :f, String, null: true do
            argument :outer, outer, required: true
          end
        end
        schema = schema_over(query, vis)
        seen = run(schema, '{ f(outer: { inner: { y: "a" } }) }', VMM_V2, root: obj(f: "ran"))
        report = audit!(schema)
        obs("S02 #{vis} request=#{seen.inspect}", report)
        expect(seen).to eq("data" => { "f" => "ran" })
        expect(failing(report)).to include([:implicit, "Inner.x"])
      end

      it "security S02b: a required argument of a RelayClassicMutation hidden by its type is :implicit on the generated input" do
        b = bases
        old = Class.new(b[:input]) { graphql_name "OldIn"; lifecycle removed: VMM_V2; argument :q, String, required: false }
        mutation = Class.new(b[:mutation]) do
          graphql_name "DoThing"
          argument :filter, old, required: true
          argument :name, String, required: false
          field :ok, String, null: true
          define_method(:resolve) { |**args| Struct.new(:ok).new("ran:#{args.keys.sort.join(',')}") }
        end
        mutation_type = Class.new(b[:object]) { graphql_name "Mutation"; field :do_thing, mutation: mutation }
        query = Class.new(b[:object]) { graphql_name "Query"; field :ping, String, null: true }
        schema = schema_over(query, vis, mutation_type: mutation_type)
        seen = run(schema, 'mutation { doThing(input: { name: "a" }) { ok } }', VMM_V2)
        report = audit!(schema)
        obs("S02b #{vis} request=#{seen.inspect}", report)
        expect(seen.dig("data", "doThing", "ok")).to start_with("ran")
        expect(failing(report).map(&:first)).to include(:implicit)
        expect(report.ok?).to be(false)
      end

      it "security S03: a required argument of a query directive hidden by its enum type is :implicit" do
        b = bases
        level = Class.new(b[:enum]) { graphql_name "Level"; lifecycle removed: VMM_V2; value "LOW" }
        arg_class = b[:argument]
        directive = Class.new(GraphQL::Schema::Directive) do
          graphql_name "tag"
          locations(GraphQL::Schema::Directive::FIELD)
          argument_class(arg_class)
          argument :level, level, required: true
        end
        query = Class.new(b[:object]) { graphql_name "Query"; field :a, String, null: true }
        schema = schema_over(query, vis, dirs: [directive])
        seen = run(schema, "{ a @tag }", VMM_V2, root: obj(a: "ran"))
        report = audit!(schema)
        obs("S03 #{vis} request=#{seen.inspect}", report)
        expect(seen).to eq("data" => { "a" => "ran" })
        expect(failing(report).map(&:first)).to include(:implicit)
        expect(report.ok?).to be(false)
      end

      it "security S04: a required loads: of an interface outside the version is :implicit; an unversioned one is not" do
        b = bases
        node = Module.new { include b[:interface]; graphql_name "Node"; lifecycle removed: VMM_V2; field :id, String, null: true }
        thing = Class.new(b[:object]) { graphql_name "Thing"; lifecycle removed: VMM_V2; implements node; field :name, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :thing, thing, null: true
          field :use, String, null: true do
            argument :node_id, GraphQL::Types::ID, required: true, loads: node
          end
        end
        schema = schema_over(query, vis)
        seen = run(schema, "{ use }", VMM_V2, root: obj(use: "ran", thing: nil))
        report = audit!(schema)
        obs("S04 #{vis} request=#{seen.inspect}", report)
        expect(seen).to eq("data" => { "use" => "ran" })
        expect(failing(report)).to include([:implicit, "Query.use.nodeId"])
      end

      it "preservation S04b: a required loads: of an unversioned interface whose implementers are all outside V is not :implicit" do
        b = bases
        node = Module.new { include b[:interface]; graphql_name "Node"; field :id, String, null: true }
        thing = Class.new(b[:object]) { graphql_name "Thing"; lifecycle removed: VMM_V2; implements node; field :name, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :thing, thing, null: true
          field :use, String, null: true do
            argument :node_id, GraphQL::Types::ID, required: true, loads: node
          end
        end
        schema = schema_over(query, vis)
        seen = run(schema, "{ use }", VMM_V2, root: obj(use: "ran", thing: nil))
        report = audit!(schema)
        obs("S04b #{vis} request=#{seen.inspect}", report)
        expect(failing(report).map(&:first)).not_to include(:implicit)
      end

      it "security S05: a required list loads: hidden by the loaded type is :implicit" do
        b = bases
        thing = Class.new(b[:object]) { graphql_name "Thing"; lifecycle removed: VMM_V2; field :name, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :thing, thing, null: true
          field :use, String, null: true do
            argument :thing_ids, [GraphQL::Types::ID], required: true, loads: thing
          end
        end
        schema = schema_over(query, vis)
        seen = run(schema, "{ use }", VMM_V2, root: obj(use: "ran", thing: nil))
        report = audit!(schema)
        obs("S05 #{vis} request=#{seen.inspect}", report)
        expect(seen).to eq("data" => { "use" => "ran" })
        expect(failing(report)).to include([:implicit, "Query.use.thingIds"])
      end

      it "preservation P06: a required argument with a default, or one hidden by its own lifecycle, is not a problem" do
        b = bases
        old = Class.new(b[:enum]) { graphql_name "OldKind"; lifecycle removed: VMM_V2; value "A" }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :f, String, null: true do
            argument :kind, old, required: true, default_value: "A"
            argument :gone, String, required: true, removed: VMM_V2
          end
        end
        schema = schema_over(query, vis)
        report = audit!(schema)
        obs("P06 #{vis}", report)
        expect(failing(report)).to eq([])
        expect(report.ok?).to be(true)
        expect(info(report)).to include([:implicit, "Query.f.kind"])
        expect(kinds(report)).not_to include([:implicit, "Query.f.gone"])
      end

      it "security S06b: required: :nullable argument hidden by its type: request vs audit" do
        skip "open advisory: required: :nullable lives only in a validator's private state; reported as information"
        b = bases
        old = Class.new(b[:input]) { graphql_name "OldIn"; lifecycle removed: VMM_V2; argument :q, String, required: false }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :f, String, null: true do
            argument :filter, old, required: :nullable
          end
        end
        schema = schema_over(query, vis)
        seen = run(schema, "{ f }", VMM_V2, root: obj(f: "ran"))
        report = audit!(schema)
        obs("S06b #{vis} request=#{seen.inspect}", report)
        # The client of VMM_V2 cannot see `filter`: either the field runs without it, or every call fails.
        if seen == { "data" => { "f" => "ran" } } || seen.key?("errors") || seen.key?("raised")
          expect(report.ok?).to be(false)
        end
      end

      # ------------------------------------------------------------------ :empty
      it "security S07: an object whose fields all come from a parent class, all removed, is :empty; one kept is not" do
        b = bases
        parent = Class.new(b[:object]) { graphql_name "ParentT"; field :a, String, null: true, removed: VMM_V2 }
        child = Class.new(parent) { graphql_name "Child" }
        parent2 = Class.new(b[:object]) { graphql_name "ParentU"; field :a, String, null: true, removed: VMM_V2; field :b, String, null: true }
        child2 = Class.new(parent2) { graphql_name "Child2" }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :child, child, null: true
          field :child2, child2, null: true
        end
        schema = schema_over(query, vis)
        seen = run(schema, '{ __type(name: "Child") { fields { name } } }', VMM_V2)
        report = audit!(schema)
        obs("S07 #{vis} request=#{seen.inspect}", report)
        expect(failing(report)).to include([:empty, "Child"])
        expect(kinds(report)).not_to include([:empty, "Child2"])
      end

      it "security S08: an object whose only fields come from an interface field removed in V is :empty, with the interface" do
        b = bases
        named = Module.new { include b[:interface]; graphql_name "Named"; field :name, String, null: true, removed: VMM_V2 }
        person = Class.new(b[:object]) { graphql_name "Person"; implements named }
        query = Class.new(b[:object]) { graphql_name "Query"; field :person, person, null: true; field :named, named, null: true }
        schema = schema_over(query, vis)
        seen = run(schema, '{ __type(name: "Person") { fields { name } } }', VMM_V2)
        report = audit!(schema)
        obs("S08 #{vis} request=#{seen.inspect}", report)
        expect(failing(report)).to include([:empty, "Person"], [:empty, "Named"])
      end

      it "preservation P09: a connection of a type removed in V (field removed with it) stays ok" do
        b = bases
        item = Class.new(b[:object]) { graphql_name "Item"; lifecycle removed: VMM_V2; field :name, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :items, item.connection_type, null: true, removed: VMM_V2
          field :ping, String, null: true
        end
        report = audit!(schema_over(query, vis))
        obs("P09 #{vis}", report)
        expect(report.ok?).to be(true)
      end

      it "preservation P09b: an unversioned connection whose node type is removed in V: request vs audit" do
        b = bases
        item = Class.new(b[:object]) { graphql_name "Item"; lifecycle removed: VMM_V2; field :name, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :items, item.connection_type, null: true
          field :ping, String, null: true
        end
        schema = schema_over(query, vis)
        seen = run(schema, '{ __type(name: "ItemConnection") { fields { name } } }', VMM_V2)
        report = audit!(schema)
        obs("P09b #{vis} request=#{seen.inspect}", report)
        expect(kinds(report).map(&:first)).not_to include(:unchecked)
      end

      it "preservation P10: a mutation added in VMM_V2, and one whose only argument is added in VMM_V2, stay ok" do
        b = bases
        create = Class.new(b[:mutation]) do
          graphql_name "Create"
          lifecycle added: VMM_V2
          argument :name, String, required: true
          field :ok, String, null: true
        end
        later = Class.new(b[:mutation]) do
          graphql_name "Later"
          argument :name, String, required: false, added: VMM_V2
          field :ok, String, null: true
        end
        mutation_type = Class.new(b[:object]) { graphql_name "Mutation"; field :create, mutation: create; field :later, mutation: later }
        query = Class.new(b[:object]) { graphql_name "Query"; field :ping, String, null: true }
        report = audit!(schema_over(query, vis, mutation_type: mutation_type))
        obs("P10 #{vis}", report)
        expect(report.ok?).to be(true)
      end

      it "security S13: a required argument of an unversioned enum whose values are all added in VMM_V2 is reported" do
        b = bases
        kind = Class.new(b[:enum]) { graphql_name "Kind"; value "A", added: VMM_V2 }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :f, String, null: true do
            argument :kind, kind, required: true
          end
        end
        schema = schema_over(query, vis)
        seen = run(schema, "{ f }", VMM_V1, root: obj(f: "ran"))
        report = audit!(schema)
        obs("S13 #{vis} request=#{seen.inspect}", report)
        expect(report.ok?).to be(false)
      end

      # ------------------------------------------------------------------ :orphan_interface
      it "security S14: an interface implemented only through another interface, implementer removed in V" do
        b = bases
        a = Module.new { include b[:interface]; graphql_name "A"; field :id, String, null: true }
        bb = Module.new { include b[:interface]; graphql_name "B"; implements a; field :id, String, null: true }
        o = Class.new(b[:object]) { graphql_name "O"; lifecycle removed: VMM_V2; implements bb; field :id, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :a, a, null: true
          field :b, bb, null: true
          field :o, o, null: true
        end
        schema = schema_over(query, vis)
        seen = run(schema, '{ __type(name: "A") { possibleTypes { name } } }', VMM_V2)
        report = audit!(schema)
        obs("S14 #{vis} request=#{seen.inspect}", report)
        expect(failing(report)).to include([:orphan_interface, "A"], [:orphan_interface, "B"])
      end

      it "security S14b: an interface whose only object is removed in V, also implemented by an interface with no implementer" do
        b = bases
        a = Module.new { include b[:interface]; graphql_name "A"; field :id, String, null: true }
        bb = Module.new { include b[:interface]; graphql_name "B"; implements a; field :id, String, null: true }
        o = Class.new(b[:object]) { graphql_name "O"; lifecycle removed: VMM_V2; implements a; field :id, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :a, a, null: true
          field :b, bb, null: true
          field :o, o, null: true
          field :ping, String, null: true
        end
        schema = schema_over(query, vis)
        seen = run(schema, '{ __type(name: "A") { possibleTypes { name } } }', VMM_V2)
        data = run(schema, "{ a { id } }", VMM_V2, root: obj(a: Struct.new(:type, :id).new(o, "1")))
        report = audit!(schema)
        obs("S14b #{vis} introspection=#{seen.inspect} data=#{data.inspect}", report)
        expect(failing(report)).to include([:orphan_interface, "A"])
      end

      it "security S15: an interface whose implementer is removed in V, returned by a live field, is :orphan_interface" do
        b = bases
        i = Module.new { include b[:interface]; graphql_name "I"; field :id, String, null: true }
        o = Class.new(b[:object]) { graphql_name "O"; lifecycle removed: VMM_V2; implements i }
        query = Class.new(b[:object]) { graphql_name "Query"; field :i, i, null: true; field :o, o, null: true }
        schema = schema_over(query, vis)
        seen = run(schema, "{ i { id } }", VMM_V2, root: obj(i: nil, o: nil))
        report = audit!(schema)
        obs("S15 #{vis} request=#{seen.inspect}", report)
        expect(failing(report)).to include([:orphan_interface, "I"])
      end

      it "security S16: an implementer reached only by a field removed in V: the audit matches what the request serves" do
        b = bases
        i = Module.new { include b[:interface]; graphql_name "I"; field :id, String, null: true }
        o = Class.new(b[:object]) { graphql_name "O"; implements i }
        query = Class.new(b[:object]) { graphql_name "Query"; field :i, i, null: true; field :o, o, null: true, removed: VMM_V2 }
        schema = schema_over(query, vis)
        seen = run(schema, '{ __type(name: "I") { possibleTypes { name } } }', VMM_V2)
        typed = Struct.new(:type, :id).new(o, "1")
        data = run(schema, "{ i { id ... on O { id } } }", VMM_V2, root: obj(i: typed))
        report = audit!(schema)
        obs("S16 #{vis} introspection=#{seen.inspect} data=#{data.inspect}", report)
        if seen.dig("data", "__type", "possibleTypes") == []
          expect(failing(report)).to include([:orphan_interface, "I"])
        else
          expect(kinds(report)).not_to include([:orphan_interface, "I"])
        end
      end

      it "preservation P17: an interface returned by no field of V, or with no implementer in any version, is not reported" do
        b = bases
        i = Module.new { include b[:interface]; graphql_name "I"; field :id, String, null: true }
        o = Class.new(b[:object]) { graphql_name "O"; lifecycle removed: VMM_V2; implements i }
        lonely = Module.new { include b[:interface]; graphql_name "Lonely"; field :id, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :i, i, null: true, removed: VMM_V2
          field :o, o, null: true
          field :lonely, lonely, null: true
          field :ping, String, null: true
        end
        report = audit!(schema_over(query, vis))
        obs("P17 #{vis}", report)
        expect(kinds(report)).not_to include([:orphan_interface, "I"], [:orphan_interface, "Lonely"])
        expect(report.ok?).to be(true)
      end

      it "preservation P18: a field of an interface the object does not implement yet is not counted as served" do
        b = bases
        j = Module.new { include b[:interface]; graphql_name "J"; field :id, String, null: true }
        obj2 = Class.new(b[:object]) { graphql_name "Obj2"; lifecycle added: VMM_V2; implements j }
        i = Module.new { include b[:interface]; graphql_name "I"; field :j, j, null: true }
        object = Class.new(b[:object]) { graphql_name "Obj"; implements i, added: VMM_V2; field :name, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :obj, object, null: true
          field :obj2, obj2, null: true
        end
        schema = schema_over(query, vis)
        seen = run(schema, '{ j: __type(name: "J") { name } i: __type(name: "I") { name } }', VMM_V1)
        report = audit!(schema)
        obs("P18 #{vis} request=#{seen.inspect}", report)
        # Schema::Visibility serves I with no implementer in VMM_V1, which is what the audit reports; the Warden hides it.
        if seen.dig("data", "i")
          expect(kinds(report)).to include([:orphan_interface, "I"])
        else
          expect(kinds(report)).not_to include([:orphan_interface, "J"])
          expect(report.ok?).to be(true)
        end
      end

      it "preservation P18b: same with a union returned by the not-yet-implemented interface" do
        b = bases
        obj2 = Class.new(b[:object]) { graphql_name "Obj2"; lifecycle added: VMM_V2; field :id, String, null: true }
        u = Class.new(b[:union]) { graphql_name "U"; possible_types obj2 }
        i = Module.new { include b[:interface]; graphql_name "I"; field :u, u, null: true }
        object = Class.new(b[:object]) { graphql_name "Obj"; implements i, added: VMM_V2; field :name, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :obj, object, null: true
          field :obj2, obj2, null: true
        end
        schema = schema_over(query, vis)
        seen = run(schema, '{ u: __type(name: "U") { name } i: __type(name: "I") { name } }', VMM_V1)
        report = audit!(schema)
        obs("P18b #{vis} request=#{seen.inspect}", report)
        # As in P18: only a type a request of VMM_V1 really lists is reported.
        expect(kinds(report)).to include([:orphan_interface, "I"]) if seen.dig("data", "i")
        expect(kinds(report)).to include([:empty, "U"]) if seen.dig("data", "u")
        expect(kinds(report)).not_to include([:empty, "U"]) unless seen.dig("data", "u")
        expect(report.ok?).to be(true) unless seen.dig("data", "i") || seen.dig("data", "u")
      end

      it "preservation P18c: the documented form (interface and its field type new with the membership take a lifecycle) is ok" do
        b = bases
        j = Module.new { include b[:interface]; graphql_name "J"; lifecycle added: VMM_V2; field :id, String, null: true }
        obj2 = Class.new(b[:object]) { graphql_name "Obj2"; lifecycle added: VMM_V2; implements j }
        i = Module.new { include b[:interface]; graphql_name "I"; lifecycle added: VMM_V2; field :j, j, null: true }
        object = Class.new(b[:object]) { graphql_name "Obj"; implements i, added: VMM_V2; field :name, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :obj, object, null: true
          field :obj2, obj2, null: true
        end
        report = audit!(schema_over(query, vis))
        obs("P18c #{vis}", report)
        expect(report.ok?).to be(true)
      end

      it "security S19: a union whose members are all removed in V, returned by a live field, is :empty" do
        b = bases
        a = Class.new(b[:object]) { graphql_name "Ta"; lifecycle removed: VMM_V2; field :id, String, null: true }
        u = Class.new(b[:union]) { graphql_name "U"; possible_types a }
        query = Class.new(b[:object]) { graphql_name "Query"; field :u, u, null: true; field :ping, String, null: true }
        schema = schema_over(query, vis)
        seen = run(schema, "{ u { __typename } }", VMM_V2, root: obj(u: nil, ping: nil))
        report = audit!(schema)
        obs("S19 #{vis} request=#{seen.inspect}", report)
        expect(failing(report)).to include([:empty, "U"])
      end

      it "preservation P20: an interface with has_no_fields(true) is not :empty" do
        b = bases
        marker = Module.new { include b[:interface]; graphql_name "Marker"; has_no_fields(true) }
        o = Class.new(b[:object]) { graphql_name "O"; implements marker; field :id, String, null: true }
        query = Class.new(b[:object]) { graphql_name "Query"; field :marker, marker, null: true; field :o, o, null: true }
        report = audit!(schema_over(query, vis))
        obs("P20 #{vis}", report)
        expect(kinds(report)).not_to include([:empty, "Marker"])
      end

      # ------------------------------------------------------------------ severity
      it "security S21: information in one version never hides a refusal in a later one (argument twins)" do
        b = bases
        later = Class.new(b[:input]) { graphql_name "LaterIn"; lifecycle added: VMM_V2; argument :q, String, required: false }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :f, String, null: true do
            argument :x, later, required: false
            argument :x, String, required: false, added: VMM_V2
          end
        end
        schema = schema_over(query, vis)
        seen = run(schema, "{ f }", VMM_V2, root: obj(f: "ran"))
        report = audit!(schema)
        obs("S21 #{vis} request=#{seen.inspect}", report)
        expect(seen.inspect).to match(/ConfigurationError|defined more than once/)
        expect(report.ok?).to be(false)
        expect(failing(report)).to include([:refused, "Query.f.x"])
      end

      it "security S21b: information in one version never hides a refusal in a later one (field twins)" do
        b = bases
        later = Class.new(b[:object]) { graphql_name "LaterT"; lifecycle added: VMM_V2; field :q, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :f, later, null: true
          field :f, String, null: true, added: VMM_V2
          field :ping, String, null: true
        end
        schema = schema_over(query, vis)
        seen = run(schema, "{ f }", VMM_V2, root: obj(f: "x", ping: "p"))
        report = audit!(schema)
        obs("S21b #{vis} request=#{seen.inspect}", report)
        expect(seen.inspect).to match(/ConfigurationError|defined more than once/)
        expect(report.ok?).to be(false)
        expect(failing(report).map(&:last)).to include("Query.f")
      end

      it "preservation P22: argument twins kept apart by their types' lifecycles, both required, are not :implicit" do
        b = bases
        fa = Class.new(b[:input]) { graphql_name "FA"; lifecycle removed: VMM_V2; argument :q, String, required: false }
        fb = Class.new(b[:input]) { graphql_name "FB"; lifecycle added: VMM_V2; argument :q, String, required: false }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :f, String, null: true do
            argument :x, fa, required: true
            argument :x, fb, required: true
          end
        end
        schema = schema_over(query, vis)
        v1 = run(schema, "{ f }", VMM_V1, root: obj(f: "ran"))
        v2 = run(schema, "{ f }", VMM_V2, root: obj(f: "ran"))
        report = audit!(schema)
        obs("P22 #{vis} v1=#{v1.inspect} v2=#{v2.inspect}", report)
        expect(v1["errors"]).not_to be_nil
        expect(failing(report)).to eq([])
        expect(report.ok?).to be(true)
      end

      it "preservation P23: field twins kept apart by their types' lifecycles stay ok" do
        b = bases
        m1 = Class.new(b[:object]) { graphql_name "Money"; lifecycle removed: VMM_V2; field :cents, Integer, null: true }
        m2 = Class.new(b[:object]) { graphql_name "Money"; lifecycle added: VMM_V2; field :amount, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :total, m1, null: true
          field :total, m2, null: true
        end
        report = audit!(schema_over(query, vis))
        obs("P23 #{vis}", report)
        expect(report.ok?).to be(true)
      end

      it "preservation P24: an information-only schema is ok, prints No problems., the matcher passes and the command answers 0" do
        require "graphql/armory/versioning/rspec"
        b = bases
        contract = Class.new(b[:object]) { graphql_name "Contract"; lifecycle added: VMM_V2; field :party, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :name, String, null: true
          field :contract, contract, null: true
          field :f, String, null: true do
            argument :c, GraphQL::Types::ID, required: false, loads: contract
          end
        end
        schema = schema_over(query, vis)
        report = audit!(schema)
        obs("P24 #{vis}", report)
        expect(report.ok?).to be(true)
        expect(info(report)).not_to be_empty
        text = report.to_s
        expect(text).to start_with("No problems.")
        expect(text).to include("Information:")
        expect(schema).to have_consistent_versions
        name = "Info#{vis.to_s.capitalize}"
        Verify3b1Schemas.send(:remove_const, name) if Verify3b1Schemas.const_defined?(name, false)
        Verify3b1Schemas.const_set(name, schema)
        out = StringIO.new
        status = GraphQL::Armory::Versioning::Audit::Command.new(out: out).("Verify3b1Schemas::#{name}")
        expect(status).to eq(0)
        expect(out.string).to include("Information:")
      end

      it "preservation P24b: a problem and information together: the problem fails ok?, both are printed" do
        b = bases
        filter = Class.new(b[:input]) { graphql_name "Filter"; lifecycle added: VMM_V2; argument :q, String, required: false }
        contract = Class.new(b[:object]) { graphql_name "Contract"; lifecycle added: VMM_V2; field :party, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :contract, contract, null: true
          field :find, String, null: true do
            argument :filter, filter, required: true
          end
        end
        report = audit!(schema_over(query, vis))
        obs("P24b #{vis}", report)
        expect(report.ok?).to be(false)
        expect(report.to_s).to start_with("1 problem:").and include("Information:")
      end

      # ------------------------------------------------------------------ crash paths
      it "preservation P25: an anonymous base interface, a LateBoundType field and argument: ok, no :unchecked" do
        b = bases(anonymous_interface: true)
        thing = Class.new(b[:object]) { graphql_name "Thing"; field :id, String, null: true }
        filter = Class.new(b[:input]) { graphql_name "FilterIn"; argument :q, String, required: false }
        i = Module.new { include b[:interface]; graphql_name "I"; field :id, String, null: true }
        o = Class.new(b[:object]) { graphql_name "O"; implements i }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :thing, thing, null: true
          field :late, GraphQL::Schema::LateBoundType.new("Thing"), null: true
          field :late_i, GraphQL::Schema::LateBoundType.new("I"), null: true
          field :o, o, null: true
          field :f, String, null: true do
            argument :filter, GraphQL::Schema::LateBoundType.new("FilterIn"), required: false
          end
          field :g, String, null: true do
            argument :filter, filter, required: false
          end
        end
        report = audit!(schema_over(query, vis))
        obs("P25 #{vis}", report)
        expect(kinds(report).map(&:first)).not_to include(:unchecked)
        expect(report.ok?).to be(true)
      end

      it "security S25b: a LateBoundType field and argument to types removed in V: no crash, the required one reported" do
        b = bases
        thing = Class.new(b[:object]) { graphql_name "Thing"; lifecycle removed: VMM_V2; field :id, String, null: true }
        filter = Class.new(b[:input]) { graphql_name "FilterIn"; lifecycle removed: VMM_V2; argument :q, String, required: false }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :thing, thing, null: true
          field :late, GraphQL::Schema::LateBoundType.new("Thing"), null: true
          field :g, String, null: true do
            argument :filter, filter, required: false
          end
          field :f, String, null: true do
            argument :filter, GraphQL::Schema::LateBoundType.new("FilterIn"), required: true
          end
        end
        schema = schema_over(query, vis)
        seen = run(schema, "{ f }", VMM_V2, root: obj(f: "ran"))
        report = audit!(schema)
        obs("S25b #{vis} request=#{seen.inspect}", report)
        expect(kinds(report).map(&:first)).not_to include(:unchecked)
        expect(failing(report)).to include([:implicit, "Query.f.filter"]) if seen == { "data" => { "f" => "ran" } }
      end

      it "security S26: an overlapping twin seen while computing the new kinds stays one :refused, no :unchecked" do
        b = bases
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :ping, String, null: true
          field :f, String, null: true do
            argument :x, String, required: false
            argument :x, Integer, required: false, added: VMM_V2
          end
        end
        report = audit!(schema_over(query, vis))
        obs("S26 #{vis}", report)
        expect(failing(report)).to eq([[:refused, "Query.f.x"]])
      end

      it "security S26b: a mutation with a lifecycle returning an orphan interface, and a resolver lifecycle: no crash" do
        b = bases
        i = Module.new { include b[:interface]; graphql_name "I"; field :id, String, null: true }
        o = Class.new(b[:object]) { graphql_name "O"; lifecycle removed: VMM_V2; implements i }
        create = Class.new(b[:mutation]) do
          graphql_name "Create"
          lifecycle removed: VMM_V2
          field :item, i, null: true
        end
        mutation_type = Class.new(b[:object]) { graphql_name "Mutation"; field :create, mutation: create; field :noop, String, null: true }
        query = Class.new(b[:object]) { graphql_name "Query"; field :o, o, null: true; field :ping, String, null: true }
        report = audit!(schema_over(query, vis, mutation_type: mutation_type))
        obs("S26b #{vis}", report)
        expect(kinds(report).map(&:first)).not_to include(:unchecked)
        expect(report.ok?).to be(true)
      end

      # ------------------------------------------------------------------ signal and user
      it "security S27: the audit records no signal on a schema with the new kinds" do
        b = bases
        filter = Class.new(b[:input]) { graphql_name "Filter"; lifecycle added: VMM_V2; argument :q, String, required: false }
        thing = Class.new(b[:object]) { graphql_name "Thing"; field :a, String, null: true, added: VMM_V2 }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :thing, thing, null: true
          field :find, String, null: true do
            argument :filter, filter, required: true
          end
        end
        recorded = []
        report = audit!(schema_over(query, vis, sinks: [->(signal, _data) { recorded << signal }]))
        expect(report.ok?).to be(false)
        expect(recorded).to eq([])
      end

      it "security S28: Authorization visible_when hiding the implementer from no user changes nothing" do
        b = bases(authorization: true)
        adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: false)
        i = Module.new { include b[:interface]; graphql_name "I"; field :id, String, null: true }
        o = Class.new(b[:object]) { graphql_name "O"; authorize :read, model: ::Struct, visible_when: :export; implements i }
        p2 = Class.new(b[:object]) { graphql_name "P"; authorize :read, model: ::Struct, visible_when: :export; implements i, added: VMM_V2; field :name, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          authorize :read, model: ::Struct
          field :i, i, null: true
          field :o, o, null: true
          field :p, p2, null: true
        end
        report = audit!(schema_over(query, vis, adapter: adapter))
        obs("S28 #{vis}", report)
        expect(kinds(report)).not_to include([:orphan_interface, "I"])
        expect(kinds(report).map(&:first)).not_to include(:unchecked)
      end

      it "security S28b: Authorization visible_when on the only implementer does not hide a real orphan" do
        b = bases(authorization: true)
        adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: true)
        i = Module.new { include b[:interface]; graphql_name "I"; field :id, String, null: true }
        o = Class.new(b[:object]) { graphql_name "O"; authorize :read, model: ::Struct, visible_when: :export; implements i, added: VMM_V2 }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          authorize :read, model: ::Struct
          field :i, i, null: true
          field :o, o, null: true
        end
        report = audit!(schema_over(query, vis, adapter: adapter))
        obs("S28b #{vis}", report)
        expect(failing(report)).to include([:orphan_interface, "I"])
      end
    end
  end
end
