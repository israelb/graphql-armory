# frozen_string_literal: true

# Probes from the independent verification of increment 2b1 (type lifecycles, Versioning.types), kept as regressions.
# VERSIONING_2B1_V = 2024-06-01 (served, older), VERSIONING_2B1_L = 2025-01-01 (latest).
RSpec.describe "Versioning 2b1 probes: type lifecycles" do
  VERSIONING_2B1_REC = Class.new(Hash) do
    def method_missing(name, *args) = key?(name) ? self[name] : super
    def respond_to_missing?(name, priv = false) = key?(name) || super
  end
  VERSIONING_2B1_V = "2024-06-01"
  VERSIONING_2B1_L = "2025-01-01"
  VERSIONING_2B1_VER = GraphQL::Armory::Versioning

  def log = (@log ||= [])

  def bases
    mod = VERSIONING_2B1_VER::Base
    argument = Class.new(GraphQL::Schema::Argument) { include mod }
    field = Class.new(GraphQL::Schema::Field) { include mod; argument_class(argument) }
    object = Class.new(GraphQL::Schema::Object) { include mod; field_class(field) }
    interface = Module.new do
      include GraphQL::Schema::Interface
      include mod
      field_class(field)
    end
    input = Class.new(GraphQL::Schema::InputObject) { include mod; argument_class(argument) }
    {
      argument: argument, field: field, object: object, interface: interface, input: input,
      enum: Class.new(GraphQL::Schema::Enum) { include mod },
      union: Class.new(GraphQL::Schema::Union) { include mod },
      scalar: Class.new(GraphQL::Schema::Scalar) { include mod },
      relay: Class.new(GraphQL::Schema::RelayClassicMutation) { include mod; argument_class(argument); field_class(field); object_class(object); input_object_class(input) },
      mutation: Class.new(GraphQL::Schema::Mutation) { include mod; argument_class(argument); field_class(field); object_class(object) },
      resolver: Class.new(GraphQL::Schema::Resolver) { include mod; argument_class(argument) }
    }
  end

  def world(b = bases)
    lg = log
    node = Module.new { include b[:interface]; graphql_name "Node"; field :id, GraphQL::Types::ID, null: false }
    archivable = Module.new { include b[:interface]; graphql_name "Archivable"; lifecycle added: VERSIONING_2B1_L; field :archived_at, String, null: true }
    titled = Module.new { include b[:interface]; graphql_name "Titled"; implements archivable; field :title, String, null: true }
    lonely = Module.new { include b[:interface]; graphql_name "Lonely"; field :solo, String, null: true }
    deep = Class.new(b[:object]) { graphql_name "Deep"; field :depth, Integer, null: true }
    contract = Class.new(b[:object]) do
      graphql_name "Contract"
      lifecycle added: VERSIONING_2B1_L
      implements node, lonely
      field :party, String, null: true
      field :deep, deep, null: true
      field :note, String, null: true do
        argument :lang, String, required: false
      end
    end
    orphan = Class.new(b[:object]) { graphql_name "Orphan"; lifecycle added: VERSIONING_2B1_L; implements node; field :o, String, null: true }
    orphan2 = Class.new(b[:object]) { graphql_name "OrphanTwo"; lifecycle added: VERSIONING_2B1_L; implements node; field :o2, String, null: true }
    node.orphan_types(orphan2)
    invoice = Class.new(b[:object]) { graphql_name "Invoice"; implements node, archivable; field :number, String, null: true }
    memo = Class.new(b[:object]) { graphql_name "Memo"; implements titled; field :body, String, null: true }
    thing = Class.new(b[:object]) do
      graphql_name "Thing"
      implements archivable
      field :archived_at, String, null: true, added: VERSIONING_2B1_L
      field :name, String, null: true
    end
    doc = Class.new(b[:union]) { graphql_name "Doc"; possible_types invoice, contract }
    ldoc = Class.new(b[:union]) { graphql_name "LoadDoc"; possible_types invoice, contract }
    new_input = Class.new(b[:input]) { graphql_name "NewInput"; lifecycle added: VERSIONING_2B1_L; argument :a, Integer, required: false }
    filter = Class.new(b[:input]) { graphql_name "Filter"; argument :since, Integer, required: false; argument :extra, new_input, required: false }
    new_enum = Class.new(b[:enum]) { graphql_name "NewEnum"; lifecycle added: VERSIONING_2B1_L; value "ONE" }
    new_scalar = Class.new(b[:scalar]) { graphql_name "NewScalar"; lifecycle added: VERSIONING_2B1_L }
    via = Class.new(GraphQL::Schema::Resolver) { type contract, null: true; define_method(:resolve) { lg << :via; VERSIONING_2B1_REC[type: contract, party: "P"] } }
    vres = Class.new(b[:resolver]) { graphql_name "VRes"; lifecycle added: VERSIONING_2B1_L; type String, null: true; define_method(:resolve) { lg << :vres; "r" } }
    flag = Class.new(GraphQL::Schema::Directive) do
      graphql_name "flag"
      locations GraphQL::Schema::Directive::FIELD
      argument_class(b[:argument])
      argument :kind, new_enum, required: false
      argument :plain, String, required: false
    end

    root_methods = Module.new do
      define_method(:invoice) { lg << :invoice; VERSIONING_2B1_REC[type: invoice, id: "i1", number: "N", archived_at: "yesterday"] }
      define_method(:memo) { lg << :memo; VERSIONING_2B1_REC[type: memo, title: "T", body: "B", archived_at: "yesterday"] }
      define_method(:thing) { lg << :thing; VERSIONING_2B1_REC[type: thing, name: "n", archived_at: "yesterday"] }
      define_method(:docs) { lg << :docs; [VERSIONING_2B1_REC[type: invoice, id: "i1", number: "N"]] }
      define_method(:node) { lg << :node; VERSIONING_2B1_REC[type: invoice, id: "i1", number: "N"] }
      define_method(:lonely) { lg << :lonely; nil }
      define_method(:contracts) { lg << :contracts; [VERSIONING_2B1_REC[type: contract, id: "c1", party: "SECRET"], VERSIONING_2B1_REC[type: contract, id: "c2", party: "S2"]] }
      define_method(:contract_list) { lg << :contract_list; [] }
      define_method(:contract) { lg << :contract; VERSIONING_2B1_REC[type: contract, id: "c1", party: "SECRET"] }
      define_method(:count) { |filter: nil| lg << [:count, filter&.to_h]; 1 }
      define_method(:pick) { |kind: nil| lg << [:pick, kind]; "p" }
      define_method(:priced) { |p: nil| lg << [:priced, p]; "x" }
      define_method(:sign) { |doc:| lg << [:sign, doc]; doc[:party] || doc[:number] }
      define_method(:archive) { |item:| lg << [:archive, item]; "a" }
    end
    @root = Object.new.extend(root_methods)
    query = Class.new(b[:object]) do
      graphql_name "Query"
      field :invoice, invoice, null: true
      field :memo, memo, null: true
      field :thing, thing, null: true
      field :docs, [doc], null: false
      field :node, node, null: true
      field :lonely, lonely, null: true
      field :contracts, contract.connection_type, null: false
      field :contract_list, [contract], null: false
      field :contract, contract, null: true
      field :via_resolver, resolver: via
      field :versioned_resolver, resolver: vres
      field :count, Integer, null: true do
        argument :filter, filter, required: false
      end
      field :pick, String, null: true do
        argument :kind, new_enum, required: false
      end
      field :priced, String, null: true do
        argument :p, new_scalar, required: false
      end
      field :sign, String, null: true do
        argument :doc_id, GraphQL::Types::ID, required: true, loads: ldoc, as: :doc
      end
      field :archive, String, null: true do
        argument :item_id, GraphQL::Types::ID, required: true, loads: archivable, as: :item
      end

      include root_methods
    end

    create = Class.new(b[:relay]) do
      graphql_name "CreateContract"
      lifecycle added: VERSIONING_2B1_L
      argument :party, String, required: true
      field :party, String, null: true
      define_method(:resolve) { |party:| lg << [:create, party]; VERSIONING_2B1_REC[party: party] }
    end
    plain = Class.new(b[:mutation]) do
      graphql_name "PlainCreate"
      lifecycle added: VERSIONING_2B1_L
      argument :party, String, required: true
      field :party, String, null: true
      define_method(:resolve) { |party:| lg << [:plain, party]; VERSIONING_2B1_REC[party: party] }
    end
    legacy = Class.new(b[:mutation]) do
      graphql_name "LegacyCreate"
      argument :party, String, required: true
      field :party, String, null: true
      define_method(:resolve) { |party:| lg << [:legacy, party]; VERSIONING_2B1_REC[party: party] }
    end
    nobase = Class.new(b[:mutation]) do
      graphql_name "NobaseCreate"
      object_class GraphQL::Schema::Object
      lifecycle added: VERSIONING_2B1_L
      argument :party, String, required: true
      field :party, String, null: true
      define_method(:resolve) { |party:| lg << [:nobase, party]; VERSIONING_2B1_REC[party: party] }
    end
    mutation = Class.new(b[:object]) do
      graphql_name "Mutation"
      field :create_contract, mutation: create
      field :plain_create, mutation: plain
      field :legacy_create, mutation: legacy, added: VERSIONING_2B1_L
      field :nobase_create, mutation: nobase
    end

    {
      b: b, node: node, archivable: archivable, titled: titled, lonely: lonely, deep: deep, contract: contract, orphan: orphan,
      orphan2: orphan2, invoice: invoice, memo: memo, thing: thing, doc: doc, ldoc: ldoc, new_input: new_input, filter: filter,
      new_enum: new_enum, new_scalar: new_scalar, via: via, vres: vres, flag: flag, query: query, mutation: mutation, create: create
    }
  end

  def schema_for(w, visibility, extra: [], &blk)
    plugin = VERSIONING_2B1_VER::Controls::Schema::PLUGINS.fetch(visibility)
    contract = w[:contract]
    Class.new(ArmoryEngine.base_schema) do
      query(w[:query])
      mutation(w[:mutation]) if w[:mutation]
      orphan_types(w[:orphan]) if w[:orphan]
      directives(w[:flag]) if w[:flag]
      extra_types(*extra) unless extra.empty?
      use plugin
      use GraphQL::Armory::Versioning, versions: VERSIONING_2B1_VER::Controls::Versions::LABELS, retired: VERSIONING_2B1_VER::Controls::Versions::RETIRED, default: :latest
      define_singleton_method(:resolve_type) { |_abstract, object, _ctx| object.fetch(:type) }
      define_singleton_method(:object_from_id) { |id, _ctx| VERSIONING_2B1_REC[type: contract, id: id, party: "LOADED-CONTRACT"] }
      define_singleton_method(:id_from_object) { |object, _type, _ctx| object[:id] }
      class_eval(&blk) if blk
    end
  end

  def run(schema, q, version, variables: {})
    execute_query(schema, q, variables: variables, root_value: @root, context: { armory_version: version }).to_h
  end

  def msgs(result) = Array(result["errors"]).map { |e| e["message"] }

  def names(schema, version)
    run(schema, "{ __schema { types { name } } }", version).dig("data", "__schema", "types").map { |t| t["name"] }
  end

  %i[visibility warden].each do |vis|
    context "with #{vis}" do
      let(:w) { world }
      let(:schema) { schema_for(w, vis) }

      # ---------- reachability ----------
      it "security S3/S4: __schema.types in V lists no versioned type (orphan types included)" do
        expect(names(schema, VERSIONING_2B1_V) & %w[Contract Orphan OrphanTwo Archivable NewInput NewEnum NewScalar CreateContractInput CreateContractPayload PlainCreatePayload NobaseCreatePayload]).to eq([])
        expect(names(schema, VERSIONING_2B1_L)).to include("Contract", "Orphan", "OrphanTwo", "Archivable", "NewInput", "NewEnum", "NewScalar")
      end

      it "security S4/S5: __type on a schema orphan type and an interface orphan type is null in V" do
        r = run(schema, '{ a: __type(name: "Orphan") { name } b: __type(name: "OrphanTwo") { name } }', VERSIONING_2B1_V)
        expect(r).to eq("data" => { "a" => nil, "b" => nil })
      end

      it "security S5/S7: a visible interface's possibleTypes exclude versioned implementers in V" do
        pt = run(schema, '{ __type(name: "Node") { possibleTypes { name } } }', VERSIONING_2B1_V).dig("data", "__type", "possibleTypes").map { |t| t["name"] }
        expect(pt).to eq(["Invoice"])
        ptl = run(schema, '{ __type(name: "Node") { possibleTypes { name } } }', VERSIONING_2B1_L).dig("data", "__type", "possibleTypes").map { |t| t["name"] }
        expect(ptl).to include("Contract", "Orphan", "OrphanTwo")
      end

      it "security S6: a visible union's possibleTypes exclude its versioned member, and a spread on it inside the union is refused in V" do
        pt = run(schema, '{ __type(name: "Doc") { possibleTypes { name } } }', VERSIONING_2B1_V).dig("data", "__type", "possibleTypes").map { |t| t["name"] }
        expect(pt).to eq(["Invoice"])
        r = run(schema, "{ docs { ... on Contract { party } } }", VERSIONING_2B1_V)
        expect(r.key?("data")).to be(false)
        expect(log).not_to include(:docs)
      end

      it "security S7/S8: inline and named fragments on a versioned type through a visible interface are refused in V, with no suggestion naming it" do
        r1 = run(schema, "{ node { ... on Contract { party } } }", VERSIONING_2B1_V)
        r2 = run(schema, "{ node { ...F } } fragment F on Contract { party }", VERSIONING_2B1_V)
        r3 = run(schema, "{ node { ... on Contrac { id } } }", VERSIONING_2B1_V)
        expect([r1.key?("data"), r2.key?("data"), r3.key?("data")]).to eq([false, false, false])
        expect((msgs(r1) + msgs(r2) + msgs(r3)).join(" ")).not_to match(/Did you mean/)
        expect(msgs(r3).join(" ")).not_to include("Contract")
        expect(log).to eq([])
      end

      it "security S9: variables typed with versioned input, list-wrapped input, scalar and enum are refused in V" do
        qs = {
          "NewInput" => "query($i: NewInput) { count(filter: { extra: $i }) }",
          "[NewInput!]" => "query($i: [NewInput!]) { count }",
          "NewScalar" => "query($i: NewScalar) { priced(p: $i) }",
          "NewEnum" => "query($i: NewEnum) { pick(kind: $i) }"
        }
        out = qs.transform_values { |q| msgs(run(schema, q, VERSIONING_2B1_V)).join(" | ") }
        expect(out.values).to all(match(/isn't a defined input type/))
        expect(log).to eq([])
      end

      it "security S10: an input field whose type is versioned is hidden in V (inputFields and literal)" do
        f = run(schema, '{ __type(name: "Filter") { inputFields { name } } }', VERSIONING_2B1_V).dig("data", "__type", "inputFields").map { |x| x["name"] }
        expect(f).to eq(["since"])
        r = run(schema, "{ count(filter: { extra: { a: 1 } }) }", VERSIONING_2B1_V)
        expect(r.key?("data")).to be(false)
        expect(log).to eq([])
      end

      it "security S11: an argument of a versioned enum type and scalar type is hidden in V" do
        args = run(schema, '{ __type(name: "Query") { fields { name args { name } } } }', VERSIONING_2B1_V).dig("data", "__type", "fields")
          .to_h { |f| [f["name"], f["args"].map { |a| a["name"] }] }
        expect([args["pick"], args["priced"]]).to eq([[], []])
        expect(msgs(run(schema, "{ pick(kind: ONE) }", VERSIONING_2B1_V))).to eq(["Field 'pick' doesn't accept argument 'kind'"])
      end

      it "security S13: an argument that loads a versioned interface is hidden in V" do
        expect(msgs(run(schema, '{ archive(itemId: "x") }', VERSIONING_2B1_V))).to eq(["Field 'archive' doesn't accept argument 'itemId'"])
        expect(log).to eq([])
      end

      it "security S14: an argument that loads a visible union, not referenced elsewhere, refuses a member outside V" do
        r = run(schema, '{ sign(docId: "c9") }', VERSIONING_2B1_V)
        expect(log.select { |e| e.is_a?(Array) && e.first == :sign }).to eq([])
        expect(r.dig("data", "sign")).to be_nil
      end

      it "security S15: a field whose resolver class returns a versioned type is hidden in V" do
        expect(msgs(run(schema, "{ viaResolver { party } }", VERSIONING_2B1_V))).to eq(["Field 'viaResolver' doesn't exist on type 'Query'"])
        expect(log).to eq([])
      end

      it "security S16: a field returning the versioned type's connection is not served in V" do
        r = run(schema, "{ contracts { edges { cursor } pageInfo { hasNextPage } } }", VERSIONING_2B1_V)
        intro = run(schema, '{ c: __type(name: "ContractConnection") { name } e: __type(name: "ContractEdge") { name fields { name } } }', VERSIONING_2B1_V)
        sdl = schema.to_definition(context: { armory_version: VERSIONING_2B1_V })
        aggregate_failures do
          expect(r.key?("data")).to be(false), "served in VERSIONING_2B1_V: #{r.inspect}"
          expect(log).not_to include(:contracts)
          expect(intro["data"]).to eq("c" => nil, "e" => nil)
          expect(sdl.scan(/\w*Contract\w*/).uniq).to eq([])
        end
      end

      it "security S17: V's SDL names no versioned type, payload or input" do
        sdl = schema.to_definition(context: { armory_version: VERSIONING_2B1_V })
        hidden = %w[Contract Orphan OrphanTwo Archivable NewInput NewEnum NewScalar CreateContractInput CreateContractPayload PlainCreatePayload NobaseCreatePayload VRes]
        expect(hidden.select { |n| sdl.match?(/^(?:type|enum|union|interface|input|scalar) #{n}\b/) }).to eq([])
      end

      it "security S51: a field returning [Contract]! (wrappers) is hidden from selection and introspection in V" do
        fields = run(schema, '{ __type(name: "Query") { fields { name } } }', VERSIONING_2B1_V).dig("data", "__type", "fields").map { |f| f["name"] }
        expect(fields & %w[contractList contract viaResolver versionedResolver]).to eq([])
        expect(msgs(run(schema, "{ contractList { party } }", VERSIONING_2B1_V))).to eq(["Field 'contractList' doesn't exist on type 'Query'"])
      end

      it "security S18: no suggestion in V names a field returning a versioned type" do
        r = run(schema, "{ contrac { party } contractLis { party } }", VERSIONING_2B1_V)
        expect(msgs(r).join(" ")).not_to match(/contract\b|contractList/)
      end

      # ---------- interfaces ----------
      it "security S19/S21: a field inherited from a versioned interface is hidden on its implementer in V" do
        f = run(schema, '{ __type(name: "Invoice") { fields { name } } }', VERSIONING_2B1_V).dig("data", "__type", "fields").map { |x| x["name"] }
        expect(f).not_to include("archivedAt")
        expect(msgs(run(schema, "{ invoice { archivedAt } }", VERSIONING_2B1_V))).to eq(["Field 'archivedAt' doesn't exist on type 'Invoice'"])
        expect(log).to eq([])
      end

      it "security S20: an unversioned interface implementing a versioned one does not serve the versioned interface's fields in V " do
        t = run(schema, '{ t: __type(name: "Titled") { fields { name } interfaces { name } } m: __type(name: "Memo") { fields { name } interfaces { name } } }', VERSIONING_2B1_V)["data"]
        r = run(schema, "{ memo { archivedAt } }", VERSIONING_2B1_V)
        aggregate_failures do
          expect(t["t"]["interfaces"]).to eq([])
          expect(t["m"]["interfaces"].map { |x| x["name"] }).to eq(["Titled"])
          expect(t["t"]["fields"].map { |x| x["name"] }).not_to include("archivedAt")
          expect(t["m"]["fields"].map { |x| x["name"] }).not_to include("archivedAt")
          expect(r.key?("data")).to be(false), "served: #{r.inspect}"
        end
      end

      it "preservation P22: an interface whose only implementer is versioned (Warden hides it, Visibility keeps it: documented)" do
        r = run(schema, '{ __type(name: "Lonely") { name possibleTypes { name } } }', VERSIONING_2B1_V)
        expected = vis == :warden ? nil : { "name" => "Lonely", "possibleTypes" => [] }
        expect(r.dig("data", "__type")).to eq(expected)
      end

      it "security S23: an object's own field hidden in V never falls back to a versioned interface's definition" do
        r = run(schema, "{ thing { archivedAt } }", VERSIONING_2B1_V)
        expect(msgs(r)).to eq(["Field 'archivedAt' doesn't exist on type 'Thing'"])
        expect(run(schema, "{ thing { archivedAt } }", VERSIONING_2B1_L)).to eq("data" => { "thing" => { "archivedAt" => "yesterday" } })
      end

      # ---------- mutations / resolvers ----------
      it "security S24: a versioned RelayClassicMutation: field, input by variable and fragment on payload are refused in V" do
        r1 = run(schema, 'mutation { createContract(input: { party: "x" }) { party } }', VERSIONING_2B1_V)
        r2 = run(schema, "mutation($i: CreateContractInput!) { createContract(input: $i) { party } }", VERSIONING_2B1_V, variables: { "i" => { "party" => "x" } })
        r3 = run(schema, "{ invoice { ... on CreateContractPayload { party } } }", VERSIONING_2B1_V)
        r4 = run(schema, '{ __type(name: "CreateContractInput") { name } }', VERSIONING_2B1_V)
        aggregate_failures do
          expect([r1, r2, r3].map { |r| r.key?("data") }).to eq([false, false, false])
          expect(msgs(r2).join).to match(/CreateContractInput isn't a defined input type/)
          expect(msgs(r3).join).to match(/No such type CreateContractPayload/)
          expect(r4).to eq("data" => { "__type" => nil })
          expect(log).to eq([])
          expect(run(schema, 'mutation { createContract(input: { party: "x" }) { party } }', VERSIONING_2B1_L)).to eq("data" => { "createContract" => { "party" => "x" } })
        end
      end

      it "security S25: a versioned plain Mutation: field and payload by name refused in V" do
        r1 = run(schema, 'mutation { plainCreate(party: "x") { party } }', VERSIONING_2B1_V)
        r2 = run(schema, "{ invoice { ... on PlainCreatePayload { party } } }", VERSIONING_2B1_V)
        expect([r1.key?("data"), msgs(r2).join]).to match([false, /No such type PlainCreatePayload/])
        expect(log).to eq([])
      end

      it "security S26: a mutation field versioned only by its own added: (payload unversioned) is refused in V; payload by name (documented limit)" do
        r1 = run(schema, 'mutation { legacyCreate(party: "x") { party } }', VERSIONING_2B1_V)
        r2 = run(schema, '{ __type(name: "LegacyCreatePayload") { name } }', VERSIONING_2B1_V)
        expect([r1.key?("data"), r2]).to eq([false, { "data" => { "__type" => nil } }])
        expect(log).to eq([])
      end

      it "security S27: a versioned mutation whose object_class lacks Base: payload by name refused in V" do
        r1 = run(schema, 'mutation { nobaseCreate(party: "x") { party } }', VERSIONING_2B1_V)
        r2 = run(schema, '{ __type(name: "NobaseCreatePayload") { name } }', VERSIONING_2B1_V)
        r3 = run(schema, "{ invoice { ... on NobaseCreatePayload { party } } }", VERSIONING_2B1_V)
        expect([r1.key?("data"), r2, r3.key?("data")]).to eq([false, { "data" => { "__type" => nil } }, false])
        expect(log).to eq([])
      end

      it "security S28: a GraphQL::Schema::Resolver with a lifecycle hides its field (resolver:) in V, serves it in L" do
        expect(msgs(run(schema, "{ versionedResolver }", VERSIONING_2B1_V))).to eq(["Field 'versionedResolver' doesn't exist on type 'Query'"])
        expect(log).to eq([])
        expect(run(schema, "{ versionedResolver }", VERSIONING_2B1_L)).to eq("data" => { "versionedResolver" => "r" })
      end

      # ---------- inheritance ----------
      it "preservation P29: a subclass narrower than its versioned parent is served in its versions" do
        b = w[:b]
        parent = Class.new(b[:object]) { graphql_name "Parent"; lifecycle added: VERSIONING_2B1_V; field :x, Integer, null: true }
        child = Class.new(parent) { graphql_name "Child"; lifecycle added: VERSIONING_2B1_L }
        q = Class.new(b[:object]) { graphql_name "Query"; field :parent, parent, null: true; field :child, child, null: true }
        s = schema_for({ query: q }, vis)
        expect([names(s, VERSIONING_2B1_V).include?("Parent"), names(s, VERSIONING_2B1_V).include?("Child"), names(s, VERSIONING_2B1_L).include?("Child")]).to eq([true, false, true])
      end

      it "security S30: a wider subclass is refused on every ask, every query, and in to_definition (no memo poisoning)" do
        b = w[:b]
        parent = Class.new(b[:object]) { graphql_name "Parent"; lifecycle added: VERSIONING_2B1_L; field :x, Integer, null: true }
        child = Class.new(parent) { graphql_name "Child"; lifecycle added: VERSIONING_2B1_V }
        q = Class.new(b[:object]) { graphql_name "Query"; field :child, child, null: true; field :y, Integer, null: true }
        s = schema_for({ query: q }, vis)
        err = VERSIONING_2B1_VER::ConfigurationError
        expect { names(s, VERSIONING_2B1_V) }.to raise_error(err, /Child/)
        expect { run(s, "{ child { x } }", VERSIONING_2B1_V) }.to raise_error(err, /Child/)
        expect(names(s, VERSIONING_2B1_L)).to include("Child")
        expect { names(s, VERSIONING_2B1_V) }.to raise_error(err, /Child/)
        expect { s.to_definition(context: { armory_version: VERSIONING_2B1_V }) }.to raise_error(err, /Child/)
        expect { VERSIONING_2B1_VER.types(s, VERSIONING_2B1_V).type("Child") }.to raise_error(err, /Child/)
      end

      it "security S31: `lifecycle` with no keywords is refused, so a subclass cannot widen its versioned parent with it" do
        parent = Class.new(w[:b][:object]) { graphql_name "Parent"; lifecycle added: VERSIONING_2B1_L; field :x, Integer, null: true }
        expect { Class.new(parent) { graphql_name "Child"; lifecycle } }.to raise_error(VERSIONING_2B1_VER::ConfigurationError, /Child: lifecycle needs added:/)
      end

      it "security S34: a grandchild under a wider intermediate parent (never asked) is not served where the grandparent is not" do
        b = w[:b]
        gp = Class.new(b[:object]) { graphql_name "GrandParent"; lifecycle added: VERSIONING_2B1_L; field :x, Integer, null: true }
        p = Class.new(gp) { graphql_name "ParentX"; lifecycle added: VERSIONING_2B1_V }
        c = Class.new(p) { graphql_name "GrandChild" }
        q = Class.new(b[:object]) { graphql_name "Query"; field :c, c, null: true; field :y, Integer, null: true }
        s = schema_for({ query: q }, vis)
        outcome = begin
          names(s, VERSIONING_2B1_V).include?("GrandChild") ? :served : :hidden
        rescue VERSIONING_2B1_VER::ConfigurationError
          :refused
        end
        expect(outcome).not_to eq(:served)
      end

      it "preservation P32: a class including Base whose superclass does not is versioned" do
        mod = VERSIONING_2B1_VER::Base
        fld = w[:b][:field]
        lone = Class.new(GraphQL::Schema::Object) { include mod; field_class(fld); graphql_name "Lone"; lifecycle added: VERSIONING_2B1_L; field :x, Integer, null: true }
        q = Class.new(w[:b][:object]) { graphql_name "Query"; field :lone, lone, null: true; field :y, Integer, null: true }
        s = schema_for({ query: q }, vis)
        expect([names(s, VERSIONING_2B1_V).include?("Lone"), names(s, VERSIONING_2B1_L).include?("Lone")]).to eq([false, true])
      end

      it "security S33: Authorization's Base and Versioning's Base in both orders: the type is hidden in V, both visible? in the chain" do
        vmod = VERSIONING_2B1_VER::Base
        amod = GraphQL::Armory::Authorization::Base
        fld = w[:b][:field]
        av = Class.new(GraphQL::Schema::Object) { include amod; include vmod; field_class(fld); graphql_name "AuthFirst"; lifecycle added: VERSIONING_2B1_L; field :x, Integer, null: true }
        va = Class.new(GraphQL::Schema::Object) { include vmod; include amod; field_class(fld); graphql_name "VerFirst"; lifecycle added: VERSIONING_2B1_L; field :x, Integer, null: true }
        q = Class.new(w[:b][:object]) { graphql_name "Query"; field :av, av, null: true; field :va, va, null: true; field :y, Integer, null: true }
        s = schema_for({ query: q }, vis)
        chain = ->(k) { k.singleton_class.ancestors.select { |m| m.instance_methods(false).include?(:visible?) }.map(&:to_s) }
        aggregate_failures do
          expect(names(s, VERSIONING_2B1_V) & %w[AuthFirst VerFirst]).to eq([])
          expect(names(s, VERSIONING_2B1_L) & %w[AuthFirst VerFirst]).to match_array(%w[AuthFirst VerFirst])
          expect(chain.(av).grep(/Versioning::Integration::Type/).size).to eq(1)
          expect(chain.(va).grep(/Versioning::Integration::Type/).size).to eq(1)
          expect(chain.(av).grep(/Authorization::Integration::Object/).size).to eq(1)
          expect(chain.(va).grep(/Authorization::Integration::Object/).size).to eq(1)
        end
      end

      # ---------- roots / extra_types ----------
      it "security S35: a versioned mutation root and a root inheriting a lifecycle from its base are refused" do
        b = w[:b]
        vbase = Class.new(b[:object]) { lifecycle added: VERSIONING_2B1_V }
        qroot = Class.new(vbase) { graphql_name "Query"; field :y, Integer, null: true }
        s1 = schema_for({ query: qroot }, vis)
        mroot = Class.new(b[:object]) { graphql_name "Mutation"; lifecycle added: VERSIONING_2B1_L; field :z, Integer, null: true }
        q = Class.new(b[:object]) { graphql_name "Query"; field :y, Integer, null: true }
        s2 = schema_for({ query: q, mutation: mroot }, vis)
        expect { run(s1, "{ y }", VERSIONING_2B1_L) }.to raise_error(VERSIONING_2B1_VER::ConfigurationError, /root/)
        expect { run(s2, "{ y }", VERSIONING_2B1_L) }.to raise_error(VERSIONING_2B1_VER::ConfigurationError, /Mutation: .*root/)
      end

      it "security S36: a child schema adding a versioned extra type is refused even after its parent passed" do
        run(schema, "{ __typename }", VERSIONING_2B1_L)
        contract = w[:contract]
        child = Class.new(schema) { extra_types(contract) }
        expect { run(child, '{ __type(name: "Contract") { name } }', VERSIONING_2B1_V) }.to raise_error(VERSIONING_2B1_VER::ConfigurationError, /extra_types/)
      end

      it "security S36b: a versioned extra type added after the first query is still refused" do
        run(schema, "{ __typename }", VERSIONING_2B1_L)
        schema.extra_types(w[:contract])
        outcome = begin
          run(schema, '{ __type(name: "Contract") { name } }', VERSIONING_2B1_V)
        rescue VERSIONING_2B1_VER::ConfigurationError => e
          e
        end
        expect(outcome).to be_a(VERSIONING_2B1_VER::ConfigurationError)
      end

      it "security S37: a plain GraphQL::Query (no query_class) on a schema with a versioned extra type does not serve it in V" do
        s = schema_for(w, vis, extra: [w[:contract]])
        outcome = begin
          GraphQL::Query.new(s, '{ __type(name: "Contract") { name fields { name } } }', context: { armory_version: VERSIONING_2B1_V }).result.to_h
        rescue VERSIONING_2B1_VER::ConfigurationError => e
          e
        end
        expect(outcome).not_to eq("data" => { "__type" => { "name" => "Contract", "fields" => [{ "name" => "deep" }, { "name" => "id" }, { "name" => "note" }, { "name" => "party" }] } })
        expect(outcome.is_a?(Hash) ? outcome.dig("data", "__type") : nil).to be_nil
      end

      it "security S38: to_definition and Schema.validate run the root and extra_types check" do
        s = schema_for(w, vis, extra: [w[:contract]])
        expect { s.to_definition(context: { armory_version: VERSIONING_2B1_V }) }.to raise_error(VERSIONING_2B1_VER::ConfigurationError, /extra_types/)
        s2 = schema_for(w, vis, extra: [w[:contract]])
        expect { s2.validate("{ invoice { number } }", context: { armory_version: VERSIONING_2B1_V }) }.to raise_error(VERSIONING_2B1_VER::ConfigurationError, /extra_types/)
      end

      # ---------- Versioning.types / View ----------
      it "security S39: View.type answers nil for a versioned type and for a type reachable only through it" do
        v = VERSIONING_2B1_VER.types(schema, VERSIONING_2B1_V)
        expect([v.type("Contract"), v.type("Deep"), v.type("Orphan"), v.type("ContractConnection")&.graphql_name]).to eq([nil, nil, nil, nil])
        expect(VERSIONING_2B1_VER.types(schema, VERSIONING_2B1_L).type("Deep")&.graphql_name).to eq("Deep")
        expect(v.all_types.map(&:graphql_name) & %w[Contract Deep Orphan]).to eq([])
      end

      it "security S40: View answers nothing for members of hidden owners, and hides the directive argument typed with a versioned enum" do
        v = VERSIONING_2B1_VER.types(schema, VERSIONING_2B1_V)
        note = w[:contract].get_field("note")
        list = w[:query].get_field("contract_list")
        aggregate_failures do
          expect(v.fields(w[:contract])).to eq([])
          expect(v.field(w[:contract], "party")).to be_nil
          expect(v.arguments(note)).to eq([])
          expect(v.arguments(list)).to eq([])
          expect(v.arguments(w[:new_input])).to eq([])
          expect(v.possible_types(w[:doc]).map(&:graphql_name)).to eq(["Invoice"])
          expect(v.possible_types(w[:contract])).to eq([])
          expect(v.enum_values(w[:new_enum])).to eq([])
          expect(v.interfaces(w[:contract])).to eq([])
          expect(v.interfaces(w[:invoice]).map(&:graphql_name)).to eq(["Node"])
          expect(v.arguments(w[:flag]).map(&:graphql_name)).to eq(["plain"])
          expect(v.visible?(w[:contract])).to be(false)
          expect(v.visible?(w[:invoice])).to be(true)
          expect(v.field(w[:invoice], "archivedAt")).to be_nil
        end
      end

      it "security S41: Versioning.types raises for an unknown label and an empty String, and follows default: for nil" do
        expect { VERSIONING_2B1_VER.types(schema, "2030-01-01") }.to raise_error(VERSIONING_2B1_VER::Error)
        expect { VERSIONING_2B1_VER.types(schema, "") }.to raise_error(VERSIONING_2B1_VER::Error)
        expect(VERSIONING_2B1_VER.types(schema, nil).type("Contract")&.graphql_name).to eq("Contract")
      end

      it "security S43: Versioning.types refuses a schema that uses Schema::AlwaysVisible" do
        s = schema_for(w, vis)
        s.use(GraphQL::Schema::AlwaysVisible)
        outcome = begin
          VERSIONING_2B1_VER.types(s, VERSIONING_2B1_V).type("Contract")&.graphql_name
        rescue VERSIONING_2B1_VER::ConfigurationError => e
          e
        end
        expect(outcome).to be_a(VERSIONING_2B1_VER::ConfigurationError)
      end

      # ---------- defaults / directives ----------
      it "security S50: a directive used in the SDL whose argument type is a versioned enum type is refused" do
        b = w[:b]
        tier = Class.new(b[:enum]) { graphql_name "Tier"; lifecycle added: VERSIONING_2B1_L; value "GOLD" }
        dir = Class.new(GraphQL::Schema::Directive) do
          graphql_name "tagged"
          locations GraphQL::Schema::Directive::OBJECT
          argument_class(b[:argument])
          argument :tier, tier, required: false
        end
        q = Class.new(b[:object]) { graphql_name "Query"; field :y, Integer, null: true; field :t, tier, null: true }
        s = schema_for({ query: q, flag: dir }, vis)
        expect { run(s, "{ __schema { directives { name args { name } } } }", VERSIONING_2B1_L) }.to raise_error(VERSIONING_2B1_VER::ConfigurationError, /tagged.*SDL/)
      end

      # ---------- caching ----------
      it "security S47: sequential queries of different versions on one schema each see their own version" do
        seq = [VERSIONING_2B1_L, VERSIONING_2B1_V, VERSIONING_2B1_L, VERSIONING_2B1_V].map { |ver| names(schema, ver).include?("Contract") }
        expect(seq).to eq([true, false, true, false])
      end

      it "security S48: a multiplex with two versions serves each its own schema" do
        q = '{ __type(name: "Contract") { name } }'
        opts = [{ query: q, context: { armory_version: VERSIONING_2B1_V } }, { query: q, context: { armory_version: VERSIONING_2B1_L } }, { query: q, context: { armory_version: VERSIONING_2B1_V } }]
        results = ArmoryEngine.next? ? schema.multiplex_next(opts) : schema.multiplex(opts)
        expect(results.map { |r| r.to_h.dig("data", "__type") }).to eq([nil, { "name" => "Contract" }, nil])
      end
    end
  end

  # ---------- membership refusals (no schema needed) ----------
  describe "membership keywords" do
    it "security S45a: implements with added: inside an interface is refused" do
      bb = bases
      other = Module.new { include bb[:interface]; graphql_name "Other" }
      expect { Module.new { include bb[:interface]; graphql_name "I2"; implements other, added: VERSIONING_2B1_L } }.to raise_error(VERSIONING_2B1_VER::ConfigurationError, /implements/)
    end

    it "security S45b: implements with a late-bound String and removed: on an object is refused" do
      bb = bases
      expect { Class.new(bb[:object]) { graphql_name "X"; implements "Other", removed: VERSIONING_2B1_L } }.to raise_error(VERSIONING_2B1_VER::ConfigurationError, /implements/)
    end

    it "security S45c: keywords through a **Hash splat are refused, on objects and unions" do
      bb = bases
      other = Module.new { include bb[:interface]; graphql_name "Other" }
      obj = Class.new(bb[:object]) { graphql_name "Obj" }
      opts = { added: VERSIONING_2B1_L }
      expect { Class.new(bb[:object]) { graphql_name "X"; implements other, **opts } }.to raise_error(VERSIONING_2B1_VER::ConfigurationError)
      expect { Class.new(bb[:union]) { graphql_name "U"; possible_types obj, **opts } }.to raise_error(VERSIONING_2B1_VER::ConfigurationError)
    end

    it "preservation P46: implements and possible_types without keywords, and possible_types(context:), still work" do
      bb = bases
      other = Module.new { include bb[:interface]; graphql_name "Other" }
      obj = Class.new(bb[:object]) { graphql_name "Obj"; implements other }
      u = Class.new(bb[:union]) { graphql_name "U"; possible_types obj }
      expect([obj.interfaces, u.possible_types, u.possible_types(context: GraphQL::Query::NullContext.instance)]).to eq([[other], [obj], [obj]])
    end

    it "preservation P44: View.new answers nothing" do
      v = VERSIONING_2B1_VER::View.new
      expect([v.type("Query"), v.all_types, v.fields(Object), v.field(Object, "x"), v.arguments(Object), v.possible_types(Object), v.interfaces(Object), v.enum_values(Object), v.visible?(Object)])
        .to eq([nil, [], [], nil, [], [], [], [], false])
    end
  end
end
