# frozen_string_literal: true

require "json"

# Independent verification probes for versioning increment 2b3b (type twins). Each probe is labelled
# "security" or "preservation". Outcomes are also written with `warn` (PROBE ...) for the report.
module TwinProbeNodes
  def self.plain_interface
    @plain_interface ||= Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Node2"
      field :id, String, null: true
    end
  end
end

RSpec.describe "PROBES type twins (2b3b)" do
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:config_error) { GraphQL::Armory::Versioning::ConfigurationError }
  let(:labels) { versioning::Controls::Versions::LABELS }
  let(:retired) { versioning::Controls::Versions::RETIRED }
  TT_OLD = "2024-06-01"
  TT_NEW = "2025-01-01"
  TT_LB = GraphQL::Schema::LateBoundType
  TT_MODES = %i[warden visibility].freeze

  def record(**values) = Struct.new(*values.keys, keyword_init: true).new(**values)

  def run(schema, query_string, version, root: nil, variables: {})
    execute_query(schema, query_string, root_value: root, variables: variables, context: { armory_version: version }).to_h
  end

  # [:raised, class, message] or [:result, hash]
  def outcome(schema, query_string, version, root: nil, variables: {})
    [:result, run(schema, query_string, version, root: root, variables: variables)]
  rescue StandardError => e
    [:raised, e.class, e.message[0, 300]]
  end

  def note(label, value) = warn("PROBE #{label}: #{value.inspect[0, 600]}")

  def errors(result) = Array(result["errors"]).map { |error| error["message"] }

  def brief(o)
    return "#{o[1]}: #{o[2].to_s[0, 140]}" if o[0] == :raised

    o[1]["data"] ? "data=#{o[1]["data"].inspect[0, 160]}" : "errors=#{errors(o[1]).inspect[0, 200]}"
  end

  def schema_over(query_type, visibility, authorization: nil, query_first: true, extra: [], orphans: [], directives: [], mutation: nil)
    plugin = versioning::Controls::Schema::PLUGINS.fetch(visibility)
    labels_ = labels
    retired_ = retired
    Class.new(ArmoryEngine.base_schema) do
      query(query_type) if query_first
      mutation(mutation) if mutation && query_first
      use plugin
      use GraphQL::Armory::Versioning, versions: labels_, retired: retired_, default: :latest
      use GraphQL::Armory::Authorization, adapter: authorization if authorization
      query(query_type) unless query_first
      mutation(mutation) if mutation && !query_first
      extra_types(*extra) unless extra.empty?
      orphan_types(*orphans) unless orphans.empty?
      directives(*directives) unless directives.empty?
      def self.resolve_type(_abstract, object, context)
        object.type.respond_to?(:call) ? object.type.(context[:armory_version]) : object.type
      end
    end
  end

  def bases(authorization: false)
    mods = [GraphQL::Armory::Versioning::Base]
    mods << GraphQL::Armory::Authorization::Base if authorization
    membership = Class.new(GraphQL::Schema::TypeMembership) { include GraphQL::Armory::Versioning::Base }
    argument = Class.new(GraphQL::Schema::Argument) { mods.each { |m| include m } }
    field = Class.new(GraphQL::Schema::Field) { mods.each { |m| include m }; argument_class(argument) }
    object = Class.new(GraphQL::Schema::Object) { mods.each { |m| include m }; field_class(field) }
    input = Class.new(GraphQL::Schema::InputObject) { include GraphQL::Armory::Versioning::Base; argument_class(argument) }
    enum_value = Class.new(GraphQL::Schema::EnumValue) { include GraphQL::Armory::Versioning::Base }
    enum = Class.new(GraphQL::Schema::Enum) { include GraphQL::Armory::Versioning::Base; enum_value_class(enum_value) }
    scalar = Class.new(GraphQL::Schema::Scalar) { include GraphQL::Armory::Versioning::Base }
    union = Class.new(GraphQL::Schema::Union) { include GraphQL::Armory::Versioning::Base; type_membership_class(membership) }
    resolver = Class.new(GraphQL::Schema::Resolver) { include GraphQL::Armory::Versioning::Base; argument_class(argument) }
    interface = Module.new do
      include GraphQL::Schema::Interface
      include GraphQL::Armory::Versioning::Base
      field_class(field)
      type_membership_class(membership)
    end
    { argument: argument, field: field, object: object, input: input, enum: enum, scalar: scalar, union: union,
      resolver: resolver, interface: interface, membership: membership }
  end

  def money_twins(b)
    v1 = Class.new(b[:object]) { graphql_name "Money"; lifecycle removed: "2025-01-01"; field :cents, Integer, null: true }
    v2 = Class.new(b[:object]) { graphql_name "Money"; lifecycle added: "2025-01-01"; field :amount, String, null: true }
    [v1, v2]
  end

  def range_twins(b)
    v1 = Class.new(b[:input]) { graphql_name "Range"; lifecycle removed: "2025-01-01"; argument :from, Integer, required: false }
    v2 = Class.new(b[:input]) do
      graphql_name "Range"
      lifecycle added: "2025-01-01"
      argument :from, String, required: false
      argument :to, String, required: false
    end
    [v1, v2]
  end

  def money = record(cents: 1200, amount: "12.00")

  # A Query with the Money twins (field twins `total`) and Range twins (field twins `search`), plus what the block adds.
  def late_query(b, &block)
    m1, m2 = money_twins(b)
    r1, r2 = range_twins(b)
    Class.new(b[:object]) do
      graphql_name "Query"
      field :total, m1, null: true, removed: "2025-01-01"
      field :total, m2, null: true, added: "2025-01-01"
      field :search, String, null: true, removed: "2025-01-01" do
        argument :range, r1, required: false
      end
      field :search, String, null: true, added: "2025-01-01" do
        argument :range, r2, required: false
      end
      class_eval(&block) if block
    end
  end

  def late_root(price = money) = record(total: money, search: "s", price: price, holder: record(price: price))

  # Expects a ConfigurationError naming the twin in both modes, both versions, both definition orders. On no refusal,
  # writes what each version is served.
  def expect_late_bound_refused(label, name, price: money, probe_new: "{ price { amount } }", probe_old: "{ price { cents } }", directives: [], &block)
    served = []
    TT_MODES.each do |mode|
      [true, false].each do |query_first|
        [TT_OLD, TT_NEW].each do |version|
          b = bases
          query = late_query(b, &block)
          begin
            schema = schema_over(query, mode, query_first: query_first, directives: directives.map { |d| d.(b) })
          rescue GraphQL::Schema::DuplicateNamesError => e
            warn("PROBE #{label}: #{[mode, query_first, version].inspect} refused at definition by graphql-ruby: #{e.class}")
            next
          end
          result = outcome(schema, "{ __typename }", version, root: late_root(price))
          next if result[0] == :raised && result[1] <= config_error && result[2].include?("names #{name} by name")

          other = version == TT_OLD ? probe_new : probe_old
          own = version == TT_OLD ? probe_old : probe_new
          served << [mode, query_first ? :query_first : :use_first, version, result, own: outcome(schema, own, version, root: late_root(price)),
                     other_twin: outcome(schema, other, version, root: late_root(price))]
        end
      end
    end
    served.each { |row| warn("PROBE #{label}: #{row[0..2].inspect} check=#{brief(row[3])} own=#{brief(row[4][:own])} other=#{brief(row[4][:other_twin])}") }
    expect(served).to eq([])
  end

  describe "late-bound references (item 1)" do
    it "security L1: [LateBoundType] list is refused" do
      expect_late_bound_refused("L1", "Money", price: [money]) { field :price, [TT_LB.new("Money")], null: true }
    end

    it "security L2: LateBoundType.to_non_null_type is refused" do
      expect_late_bound_refused("L2", "Money") { field :price, TT_LB.new("Money").to_non_null_type, null: true }
    end

    it "security L3: nested lists [[LateBoundType]] are refused" do
      expect_late_bound_refused("L3", "Money", price: [[money]]) { field :price, [[TT_LB.new("Money")]], null: true }
    end

    it "security L4: [LateBoundType, null: true] (nullable-items list form) is refused" do
      expect_late_bound_refused("L4", "Money", price: [money]) { field :price, [TT_LB.new("Money"), { null: true }], null: true }
    end

    it "security L5: type: keyword with a LateBoundType is refused" do
      expect_late_bound_refused("L5", "Money") { field :price, type: TT_LB.new("Money"), null: true }
    end

    it "security L6: a LateBoundType set with `type` inside the field's block is refused" do
      expect_late_bound_refused("L6", "Money") do
        field :price, null: true do
          type TT_LB.new("Money")
        end
      end
    end

    it "security L7: a Base resolver whose `type` is a LateBoundType is refused" do
      skip "pre-existing: graphql-ruby raises NoMethodError on every use of that field, so nothing is served"
      expect_late_bound_refused("L7", "Money") do
        base_resolver = Class.new(GraphQL::Schema::Resolver) { include GraphQL::Armory::Versioning::Base }
        resolver = Class.new(base_resolver) do
          type TT_LB.new("Money"), null: true
          def resolve = object.price
        end
        field :price, resolver: resolver
      end
    end

    it "security L8: a Base resolver's argument typed LateBoundType is refused" do
      expect_late_bound_refused("L8", "Range", probe_new: '{ price(range: {to: "x"}) }', probe_old: "{ price(range: {from: 1}) }") do
        arg = field_class.argument_class
        resolver = Class.new(GraphQL::Schema::Resolver) do
          include GraphQL::Armory::Versioning::Base
          argument_class arg
          graphql_name "PriceResolver"
          type String, null: true
          argument :range, TT_LB.new("Range"), required: false
          def resolve(range: nil) = range.to_h.to_json
        end
        field :price, resolver: resolver
      end
    end

    it "security L9: an input object's argument typed LateBoundType is refused" do
      expect_late_bound_refused("L9", "Range", probe_new: '{ price(filter: {range: {to: "x"}}) }', probe_old: "{ price(filter: {range: {from: 1}}) }") do
        arg = field_class.argument_class
        filter = Class.new(GraphQL::Schema::InputObject) do
          include GraphQL::Armory::Versioning::Base
          argument_class arg
          graphql_name "Filter"
          argument :range, TT_LB.new("Range"), required: false
        end
        field :price, String, null: true do
          argument :filter, filter, required: false
        end
        define_method(:price) { |filter: nil| filter.to_h.to_json }
      end
    end

    it "security L10: an executable directive's argument typed LateBoundType is refused" do
      directive = lambda do |b|
        arg = b[:argument]
        Class.new(GraphQL::Schema::Directive) do
          graphql_name "tag"
          argument_class arg
          locations GraphQL::Schema::Directive::FIELD
          argument :range, TT_LB.new("Range"), required: false
        end
      end
      expect_late_bound_refused("L10", "Range", directives: [directive], probe_new: '{ search @tag(range: {to: "x"}) }',
                                                probe_old: "{ search @tag(range: {from: 1}) }")
    end

    it "security L11: a late-bound field added after the schema check ran is refused on the next query" do
      TT_MODES.each do |mode|
        b = bases
        query = late_query(b)
        schema = schema_over(query, mode)
        first = outcome(schema, "{ __typename }", TT_NEW)
        query.field :price, TT_LB.new("Money"), null: true
        second = outcome(schema, "{ __typename }", TT_NEW)
        note("L11 #{mode}", [first, second])
        expect(first[0]).to eq(:result)
        expect(second[0..1]).to eq([:raised, config_error])
      end
    end

    it "security L12: a twin added after a late-bound field was already checked does not serve the wrong twin" do
      TT_MODES.each do |mode|
        b = bases
        m1, m2 = money_twins(b)
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :price, TT_LB.new("Money"), null: true
          field :total, m1, null: true, removed: "2025-01-01"
        end
        schema = schema_over(query, mode)
        first = outcome(schema, "{ __typename }", TT_OLD)
        query.field :total, m2, null: true, added: "2025-01-01"
        after = [TT_OLD, TT_NEW].map { |v| [v, outcome(schema, "{ price { cents } }", v, root: late_root), outcome(schema, "{ price { amount } }", v, root: late_root)] }
        note("L12 #{mode}", [first, after])
        leak = after.any? do |v, cents, amount|
          (v == TT_NEW && cents[0] == :result && cents[1].dig("data", "price", "cents")) ||
            (v == TT_OLD && amount[0] == :result && amount[1].dig("data", "price", "amount"))
        end
        expect(leak).to be_falsey
      end
    end

    it "security L13: a Base union whose possible_types names a twin by LateBoundType does not serve the wrong twin" do
      served = []
      TT_MODES.each do |mode|
        b = bases
        m1, m2 = money_twins(b)
        union = Class.new(b[:union]) { graphql_name "Pay"; possible_types TT_LB.new("Money") }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :total, m1, null: true, removed: "2025-01-01"
          field :total, m2, null: true, added: "2025-01-01"
          field :pay, union, null: true
        end
        schema = schema_over(query, mode)
        root = record(total: money, pay: record(cents: 1200, amount: "12.00", type: ->(v) { v == TT_NEW ? m2 : m1 }))
        result = [TT_OLD, TT_NEW].map do |v|
          [v, outcome(schema, '{ pay { __typename ... on Money { cents } } __type(name: "Pay") { possibleTypes { name fields { name } } } }', v, root: root),
           outcome(schema, '{ pay { __typename ... on Money { amount } } }', v, root: root)]
        end
        served << [mode, result]
      end
      note("L13", served)
      wrong = served.any? do |_mode, result|
        result.any? do |v, cents, amount|
          (v == TT_NEW && cents[0] == :result && cents[1].dig("data", "pay", "cents")) ||
            (v == TT_OLD && amount[0] == :result && amount[1].dig("data", "pay", "amount")) ||
            (cents[0] == :result && (cents[1].dig("data", "__type", "possibleTypes") || []).any? { |t| t["fields"].map { |f| f["name"] } != (v == TT_NEW ? ["amount"] : ["cents"]) })
        end
      end
      expect(wrong).to be_falsey
    end

    it "security L14: implements LateBoundType on an interface (interface implementing a twin) is refused" do
      TT_MODES.each do |mode|
        b = bases
        n1 = Module.new { include b[:interface]; graphql_name "Named"; lifecycle removed: "2025-01-01"; field :name, String, null: true }
        n2 = Module.new { include b[:interface]; graphql_name "Named"; lifecycle added: "2025-01-01"; field :name, String, null: false }
        titled = Module.new { include b[:interface]; graphql_name "Titled"; implements TT_LB.new("Named"); field :name, String, null: true }
        person = Class.new(b[:object]) { graphql_name "Person"; implements titled; field :name, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :person, person, null: true
          field :named, n1, null: true, removed: "2025-01-01"
          field :named, n2, null: true, added: "2025-01-01"
        end
        result = outcome(schema_over(query, mode), "{ __typename }", TT_NEW)
        note("L14 #{mode}", result)
        expect(result[0..1]).to eq([:raised, config_error])
      end
    end

    it "security L15: interface orphan_types with a LateBoundType naming a twin does not serve the wrong twin" do
      served = []
      TT_MODES.each do |mode|
        b = bases
        m1, m2 = money_twins(b)
        thing = Module.new { include b[:interface]; graphql_name "Thing"; field :id, String, null: true; orphan_types TT_LB.new("Money") }
        m1.implements(thing)
        m2.implements(thing)
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :total, m1, null: true, removed: "2025-01-01"
          field :total, m2, null: true, added: "2025-01-01"
          field :thing, thing, null: true
        end
        schema = schema_over(query, mode)
        result = [TT_OLD, TT_NEW].map { |v| [v, outcome(schema, '{ __type(name: "Money") { fields { name } } }', v)] }
        served << [mode, result]
      end
      note("L15", served)
      shapes = served.flat_map { |_m, r| r.map { |v, res| [v, res[0] == :result ? res[1].dig("data", "__type", "fields")&.map { |f| f["name"] } : res[1]] } }
      wrong = shapes.any? { |v, names| names.is_a?(Array) && names.sort != (v == TT_NEW ? %w[amount id] : %w[cents id]) }
      expect(wrong).to be_falsey
    end
  end

  describe "twins of every kind (item 2)" do
    it "security K1: interface twins, each version its own fields, introspection, fragments and SDL" do
      TT_MODES.each do |mode|
        b = bases
        p1 = Module.new { include b[:interface]; graphql_name "Priced"; lifecycle removed: "2025-01-01"; field :cents, Integer, null: true }
        p2 = Module.new { include b[:interface]; graphql_name "Priced"; lifecycle added: "2025-01-01"; field :amount, String, null: true }
        item = Class.new(b[:object]) do
          graphql_name "Item"
          implements p1
          implements p2
          field :name, String, null: true
        end
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :priced, p1, null: true, removed: "2025-01-01"
          field :priced, p2, null: true, added: "2025-01-01"
        end
        schema = schema_over(query, mode, orphans: [item])
        root = record(priced: record(name: "n", cents: 5, amount: "0.05", type: item))
        intro = '{ __type(name: "Priced") { fields { name } possibleTypes { name } } item: __type(name: "Item") { fields { name } interfaces { name } } }'
        o_old = outcome(schema, intro, TT_OLD)
        o_new = outcome(schema, intro, TT_NEW)
        note("K1 #{mode} intro", [o_old, o_new])
        expect(o_old[1].dig("data", "__type", "fields").map { |f| f["name"] }).to eq(["cents"])
        expect(o_new[1].dig("data", "__type", "fields").map { |f| f["name"] }).to eq(["amount"])
        expect(o_old[1].dig("data", "item", "fields").map { |f| f["name"] }.sort).to eq(%w[cents name])
        expect(o_new[1].dig("data", "item", "fields").map { |f| f["name"] }.sort).to eq(%w[amount name])
        cross_new = outcome(schema, "{ priced { ... on Priced { cents } ... on Item { cents } } }", TT_NEW, root: root)
        cross_old = outcome(schema, "{ priced { ... on Item { amount } } }", TT_OLD, root: root)
        note("K1 #{mode} cross", [cross_new, cross_old])
        expect(cross_new[1]["data"]).to be_nil
        expect(cross_old[1]["data"]).to be_nil
        expect(run(schema, "{ priced { __typename cents } }", TT_OLD, root: root)).to eq("data" => { "priced" => { "__typename" => "Item", "cents" => 5 } })
        expect(run(schema, "{ priced { __typename amount } }", TT_NEW, root: root)).to eq("data" => { "priced" => { "__typename" => "Item", "amount" => "0.05" } })
        sdl_new = schema.to_definition(context: { armory_version: TT_NEW })
        expect(sdl_new).not_to include("cents")
      end
    end

    it "security K2: union twins list each version's members" do
      TT_MODES.each do |mode|
        b = bases
        card = Class.new(b[:object]) { graphql_name "Card"; field :last4, String, null: true }
        cash = Class.new(b[:object]) { graphql_name "Cash"; lifecycle removed: "2025-01-01"; field :note, String, null: true }
        wire = Class.new(b[:object]) { graphql_name "Wire"; lifecycle added: "2025-01-01"; field :iban, String, null: true }
        u1 = Class.new(b[:union]) { graphql_name "Payment"; lifecycle removed: "2025-01-01"; possible_types card, cash }
        u2 = Class.new(b[:union]) { graphql_name "Payment"; lifecycle added: "2025-01-01"; possible_types card, wire }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :pay, u1, null: true, removed: "2025-01-01"
          field :pay, u2, null: true, added: "2025-01-01"
        end
        schema = schema_over(query, mode)
        intro = '{ __type(name: "Payment") { possibleTypes { name } } }'
        names = [TT_OLD, TT_NEW].map { |v| run(schema, intro, v).dig("data", "__type", "possibleTypes").map { |t| t["name"] }.sort }
        note("K2 #{mode}", names)
        expect(names).to eq([%w[Card Cash], %w[Card Wire]])
        root = record(pay: record(note: "SECRET-CASH", iban: "SECRET-IBAN", last4: "1", type: cash))
        expect(run(schema, "{ pay { ... on Cash { note } } }", TT_NEW, root: root)["data"]).to be_nil
        wroot = record(pay: record(note: "SECRET-CASH", iban: "SECRET-IBAN", last4: "1", type: wire))
        expect(run(schema, "{ pay { ... on Wire { iban } } }", TT_OLD, root: wroot)["data"]).to be_nil
        expect(run(schema, "{ pay { ... on Wire { iban } } }", TT_NEW, root: wroot)).to eq("data" => { "pay" => { "iban" => "SECRET-IBAN" } })
      end
    end

    it "security K3: enum twins in introspection, literals, variables and output" do
      skip "graphql 2.4 with json 3.1 cannot print a literal in its own validation error" unless ArmoryJsonPrinting.prints_strings?
      TT_MODES.each do |mode|
        b = bases
        s1 = Class.new(b[:enum]) { graphql_name "Status"; lifecycle removed: "2025-01-01"; value "OPEN"; value "VOID" }
        s2 = Class.new(b[:enum]) { graphql_name "Status"; lifecycle added: "2025-01-01"; value "OPEN"; value "CANCELLED" }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :pick, String, null: true, removed: "2025-01-01" do
            argument :s, s1, required: true
          end
          field :pick, String, null: true, added: "2025-01-01" do
            argument :s, s2, required: true
          end
          field :status, s1, null: true, removed: "2025-01-01"
          field :status, s2, null: true, added: "2025-01-01"
        end
        schema = schema_over(query, mode)
        intro = '{ __type(name: "Status") { enumValues { name } } }'
        values = [TT_OLD, TT_NEW].map { |v| run(schema, intro, v).dig("data", "__type", "enumValues").map { |e| e["name"] } }
        expect(values).to eq([%w[OPEN VOID], %w[OPEN CANCELLED]])
        root = Struct.new(:status) { define_method(:pick) { |s:| "got #{s}" } }.new("VOID")
        expect(run(schema, "{ pick(s: CANCELLED) }", TT_OLD, root: root)["data"]).to be_nil
        expect(run(schema, "{ pick(s: VOID) }", TT_NEW, root: root)["data"]).to be_nil
        expect(run(schema, "query($s: Status!) { pick(s: $s) }", TT_OLD, root: root, variables: { "s" => "CANCELLED" })["data"]).to be_nil
        expect(run(schema, "query($s: Status!) { pick(s: $s) }", TT_NEW, root: root, variables: { "s" => "VOID" })["data"]).to be_nil
        expect(run(schema, "query($s: Status!) { pick(s: $s) }", TT_NEW, root: root, variables: { "s" => "CANCELLED" })).to eq("data" => { "pick" => "got CANCELLED" })
        out_new = outcome(schema, "{ status }", TT_NEW, root: root)
        note("K3 #{mode} VOID out in TT_NEW", out_new)
        expect(out_new[0] == :result && out_new[1].dig("data", "status") == "VOID").to be(false)
      end
    end

    it "security K4: input object twins through variables and literals" do
      skip "graphql 2.4 with json 3.1 cannot print a literal in its own validation error" unless ArmoryJsonPrinting.prints_strings?
      TT_MODES.each do |mode|
        b = bases
        r1, r2 = range_twins(b)
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :search, String, null: true, removed: "2025-01-01" do
            argument :range, r1, required: true
          end
          field :search, String, null: true, added: "2025-01-01" do
            argument :range, r2, required: true
          end
        end
        schema = schema_over(query, mode)
        root = Struct.new(:x) { define_method(:search) { |range:| range.to_h.to_json } }.new(nil)
        q = "query($r: Range!) { search(range: $r) }"
        expect(run(schema, q, TT_OLD, root: root, variables: { "r" => { "from" => 1 } })).to eq("data" => { "search" => '{"from":1}' })
        expect(run(schema, q, TT_OLD, root: root, variables: { "r" => { "to" => "x" } })["data"]).to be_nil
        expect(run(schema, q, TT_NEW, root: root, variables: { "r" => { "from" => 1 } })["data"]).to be_nil
        expect(run(schema, q, TT_NEW, root: root, variables: { "r" => { "from" => "a", "to" => "b" } })).to eq("data" => { "search" => '{"from":"a","to":"b"}' })
        expect(run(schema, '{ search(range: {to: "x"}) }', TT_OLD, root: root)["data"]).to be_nil
        fields = [TT_OLD, TT_NEW].map { |v| run(schema, '{ __type(name: "Range") { inputFields { name type { name } } } }', v).dig("data", "__type", "inputFields") }
        note("K4 #{mode}", fields)
        expect(fields.map { |f| f.map { |x| [x["name"], x["type"]["name"]] } }).to eq([[%w[from Int]], [%w[from String], %w[to String]]])
      end
    end

    it "security K5: scalar twins coerce with their own version's class" do
      TT_MODES.each do |mode|
        b = bases
        c1 = Class.new(b[:scalar]) do
          graphql_name "Cents"
          lifecycle removed: "2025-01-01"
          def self.coerce_input(value, _ctx) = value.is_a?(Integer) ? "v1:#{value}" : raise(GraphQL::CoercionError, "v1 wants Int")
          def self.coerce_result(value, _ctx) = "v1-out:#{value}"
        end
        c2 = Class.new(b[:scalar]) do
          graphql_name "Cents"
          lifecycle added: "2025-01-01"
          def self.coerce_input(value, _ctx) = value.is_a?(String) ? "v2:#{value}" : raise(GraphQL::CoercionError, "v2 wants String")
          def self.coerce_result(value, _ctx) = "v2-out:#{value}"
        end
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :echo, c1, null: true, removed: "2025-01-01" do
            argument :v, c1, required: true
          end
          field :echo, c2, null: true, added: "2025-01-01" do
            argument :v, c2, required: true
          end
        end
        schema = schema_over(query, mode)
        root = Struct.new(:x) { define_method(:echo) { |v:| v } }.new(nil)
        q = "query($v: Cents!) { echo(v: $v) }"
        res = [[TT_OLD, 5], [TT_OLD, "5"], [TT_NEW, "5"], [TT_NEW, 5]].map { |v, val| [v, val, outcome(schema, q, v, root: root, variables: { "v" => val })] }
        note("K5 #{mode}", res)
        expect(res[0][2][1]).to eq("data" => { "echo" => "v1-out:v1:5" })
        expect(res[1][2][1]["data"]).to be_nil
        expect(res[2][2][1]).to eq("data" => { "echo" => "v2-out:v2:5" })
        expect(res[3][2][1]["data"]).to be_nil
      end
    end

    it "security K6: object twins through named fragments, __typename and variables-free introspection of fields' types" do
      TT_MODES.each do |mode|
        b = bases
        query = late_query(b)
        schema = schema_over(query, mode)
        r_old = outcome(schema, "query { total { ...F } } fragment F on Money { amount }", TT_OLD, root: late_root)
        r_new = outcome(schema, "query { total { ...F __typename } } fragment F on Money { cents }", TT_NEW, root: late_root)
        r_type = outcome(schema, '{ __schema { types { name fields { name } } } }', TT_NEW)
        note("K6 #{mode}", [r_old, r_new])
        expect(r_old[1]["data"]).to be_nil
        expect(r_new[1]["data"]).to be_nil
        money_types = r_type[1].dig("data", "__schema", "types").select { |t| t["name"] == "Money" }
        expect(money_types.map { |t| t["fields"].map { |f| f["name"] } }).to eq([["amount"]])
      end
    end
  end

  describe "reachability (item 3)" do
    it "security R1: twins reached only through one union's possible_types" do
      TT_MODES.each do |mode|
        b = bases
        m1, m2 = money_twins(b)
        result = Class.new(b[:union]) { graphql_name "Result"; possible_types m1, m2 }
        query = Class.new(b[:object]) { graphql_name "Query"; field :result, result, null: true }
        schema = schema_over(query, mode)
        root = record(result: record(cents: 7, amount: "0.07", type: ->(v) { v == TT_NEW ? m2 : m1 }))
        shapes = [TT_OLD, TT_NEW].map { |v| outcome(schema, '{ __type(name: "Money") { fields { name } } r: __type(name: "Result") { possibleTypes { name } } }', v) }
        data = [TT_OLD, TT_NEW].map { |v| outcome(schema, "{ result { ... on Money { __typename } } }", v, root: root) }
        cross = outcome(schema, "{ result { ... on Money { cents } } }", TT_NEW, root: root)
        note("R1 #{mode}", [shapes, data, cross])
        expect(shapes.map { |s| s[0] == :result && s[1].dig("data", "__type", "fields")&.map { |f| f["name"] } }).to eq([["cents"], ["amount"]])
        expect(cross[0] == :result && cross[1].dig("data", "result", "cents")).to be_falsey
      end
    end

    it "security R2: twins reached only through an interface's orphan_types" do
      TT_MODES.each do |mode|
        b = bases
        m1, m2 = money_twins(b)
        thing = Module.new { include b[:interface]; graphql_name "Thing"; field :id, String, null: true }
        m1.implements(thing)
        m2.implements(thing)
        thing.orphan_types(m1, m2)
        query = Class.new(b[:object]) { graphql_name "Query"; field :thing, thing, null: true }
        schema = schema_over(query, mode)
        root = record(thing: record(id: "1", cents: 7, amount: "0.07", type: ->(v) { v == TT_NEW ? m2 : m1 }))
        shapes = [TT_OLD, TT_NEW].map { |v| outcome(schema, '{ __type(name: "Money") { fields { name } } }', v) }
        cross = outcome(schema, "{ thing { ... on Money { cents } } }", TT_NEW, root: root)
        own = outcome(schema, "{ thing { ... on Money { amount } } }", TT_NEW, root: root)
        note("R2 #{mode}", [shapes, cross, own])
        expect(shapes.map { |s| s[0] == :result && s[1].dig("data", "__type", "fields")&.map { |f| f["name"] }&.sort }).to eq([%w[cents id], %w[amount id]])
        expect(cross[0] == :result && cross[1].dig("data", "thing", "cents")).to be_falsey
      end
    end

    it "security R3: a twin in extra_types is refused (fails closed)" do
      TT_MODES.each do |mode|
        b = bases
        m1, = money_twins(b)
        query = late_query(b)
        result = outcome(schema_over(query, mode, extra: [m1]), "{ __typename }", TT_OLD)
        note("R3 #{mode}", result)
        expect(result[0..1]).to eq([:raised, config_error])
      end
    end

    it "security R4: a twin reached only through a field hidden by its own visible? never lends its shape to the other version" do
      TT_MODES.each do |mode|
        b = bases
        m1, m2 = money_twins(b)
        hidden_field = Class.new(b[:field]) { define_method(:visible?) { |_ctx| false } }
        holder = Class.new(b[:object]) do
          graphql_name "Holder"
          field :id, String, null: true
          field_class hidden_field
          field :secret, m1, null: true
        end
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :holder, holder, null: true
          field :total, m2, null: true, added: "2025-01-01"
        end
        schema = schema_over(query, mode)
        shapes = [TT_OLD, TT_NEW].map { |v| outcome(schema, '{ __type(name: "Money") { fields { name } } }', v) }
        note("R4 #{mode}", shapes)
        expect(shapes[1][0] == :result && shapes[1][1].dig("data", "__type", "fields").map { |f| f["name"] }).to eq(["amount"])
        expect(shapes[0][0] == :result && (shapes[0][1].dig("data", "__type", "fields") || []).map { |f| f["name"] }).not_to include("amount")
      end
    end
  end

  describe "abstract-loads walk (item 4)" do
    def archivable_world(b)
      archivable = Module.new { include b[:interface]; graphql_name "Archivable"; field :archived, GraphQL::Types::Boolean, null: true }
      item = Class.new(b[:object]) { graphql_name "Item"; implements archivable, added: "2025-01-01"; field :name, String, null: true }
      [archivable, item]
    end

    it "security A1: an input-object twin unseen by the latest version, with a plain argument loading a versioned-membership interface, is refused (warden)" do
      b = bases
      archivable, item = archivable_world(b)
      plain_arg = Class.new(GraphQL::Schema::Argument)
      in1 = Class.new(GraphQL::Schema::InputObject) do
        extend GraphQL::Armory::Versioning::Integration::Type
        argument_class plain_arg
        graphql_name "Pick"
        lifecycle removed: "2025-01-01"
        argument :item_id, GraphQL::Types::ID, required: true, loads: archivable
      end
      in2 = Class.new(b[:input]) { graphql_name "Pick"; lifecycle added: "2025-01-01"; argument :n, Integer, required: false }
      query = Class.new(b[:object]) do
        graphql_name "Query"
        field :item, item, null: true
        field :pick, String, null: true, removed: "2025-01-01" do
          argument :p, in1, required: true
        end
        field :pick, String, null: true, added: "2025-01-01" do
          argument :p, in2, required: true
        end
      end
      result = outcome(schema_over(query, :warden), "{ __typename }", TT_OLD)
      note("A1", result)
      expect(result[0..1]).to eq([:raised, config_error])
      expect(result[2]).to match(/itemId: it loads Archivable/)
    end

    it "preservation A2: a clean warden schema whose twin name has no twin in the latest version, with a versioned membership, keeps working" do
      b = bases
      _archivable, item = archivable_world(b)
      g1 = Class.new(b[:object]) { graphql_name "Gone"; lifecycle removed: "2024-06-01"; field :id, String, null: true }
      g2 = Class.new(b[:object]) { graphql_name "Gone"; lifecycle added: "2024-06-01", removed: "2025-01-01"; field :id, String, null: true }
      query = Class.new(b[:object]) do
        graphql_name "Query"
        field :item, item, null: true
        field :gone, g1, null: true, removed: "2024-06-01"
        field :gone, g2, null: true, added: "2024-06-01", removed: "2025-01-01"
      end
      schema = schema_over(query, :warden)
      results = [TT_OLD, TT_NEW].map { |v| outcome(schema, "{ item { name } }", v, root: record(item: record(name: "n", archived: false))) }
      note("A2", results)
      expect(results).to all(eq([:result, { "data" => { "item" => { "name" => "n" } } }]))
    end

    it "preservation A3: a clean schema with a versioned membership and an app type marked introspection(true) without `__` keeps working" do
      TT_MODES.each do |mode|
        b = bases
        archivable, item = archivable_world(b)
        meta = Class.new(b[:object]) do
          graphql_name "Meta"
          introspection(true)
          field :info, String, null: true do
            argument :item_id, GraphQL::Types::ID, required: false
          end
        end
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :item, item, null: true
          field :meta, meta, null: true
        end
        result = outcome(schema_over(query, mode), "{ item { name } }", TT_NEW, root: record(item: record(name: "n")))
        note("A3 #{mode}", result)
        expect(result).to eq([:result, { "data" => { "item" => { "name" => "n" } } }])
      end
    end

    it "security A4: an app type marked introspection(true) without `__`, with a plain argument loading a versioned-membership interface, is refused (warden)" do
      b = bases
      archivable, item = archivable_world(b)
      plain = Class.new(GraphQL::Schema::Object) { field_class(Class.new(GraphQL::Schema::Field)) }
      meta = Class.new(plain) do
        graphql_name "Meta"
        introspection(true)
        field :info, String, null: true do
          argument :item_id, GraphQL::Types::ID, required: true, loads: archivable
        end
      end
      query = Class.new(b[:object]) do
        graphql_name "Query"
        field :item, item, null: true
        field :meta, meta, null: true
      end
      result = outcome(schema_over(query, :warden), "{ __typename }", TT_NEW)
      note("A4", result)
      expect(result[0..1]).to eq([:raised, config_error])
    end

    it "preservation A5: implements LateBoundType of an interface without twins keeps working, use before query (lazy Visibility)" do
      TT_MODES.each do |mode|
        [true, false].each do |query_first|
          b = bases
          named = Module.new { include b[:interface]; graphql_name "Named"; field :name, String, null: true }
          person = Class.new(b[:object]) { graphql_name "Person"; implements TT_LB.new("Named"); field :name, String, null: true }
          query = Class.new(b[:object]) do
            graphql_name "Query"
            field :person, person, null: true
            field :named, named, null: true
          end
          result = outcome(schema_over(query, mode, query_first: query_first), "{ person { name } }", TT_NEW, root: record(person: record(name: "n")))
          note("A5 #{mode} query_first=#{query_first}", result)
          expect(result).to eq([:result, { "data" => { "person" => { "name" => "n" } } }])
        end
      end
    end

    it "preservation A6: implements by Ruby constant String keeps working while some late-bound member exists in the process" do
      TwinProbeNodes.const_set(:Iface, TwinProbeNodes.plain_interface) unless TwinProbeNodes.const_defined?(:Iface)
      unless TwinProbeNodes.const_defined?(:Node4)
        TwinProbeNodes.const_set(:Node4, Module.new { include GraphQL::Schema::Interface; graphql_name "Node4"; field :id, String, null: true })
      end
      bad = []
      %w[TwinProbeNodes::Iface TwinProbeNodes::Node4].each do |constant|
        TT_MODES.each do |mode|
          [true, false].each do |query_first|
            b = bases
            Class.new(b[:object]) { graphql_name "Unused"; field :x, TT_LB.new("Unused"), null: true } # bumps the global count
            person = Class.new(b[:object]) { graphql_name "Person"; implements constant; field :id, String, null: true }
            query = Class.new(b[:object]) { graphql_name "Query"; field :person, person, null: true }
            result = outcome(schema_over(query, mode, query_first: query_first), "{ person { id } }", TT_NEW, root: record(person: record(id: "1")))
            note("A6 #{constant} #{mode} query_first=#{query_first}", result)
            bad << [constant, mode, query_first, result] unless result == [:result, { "data" => { "person" => { "id" => "1" } } }]
          end
        end
      end
      expect(bad).to eq([])
    end
  end

  describe "Authorization (item 5)" do
    def auth_world(rule_on:, visible_when: false)
      b = bases(authorization: true)
      none = ->(klass) { klass.authorize :none, reason: "public", covers_fields: true }
      strict = lambda do |klass|
        visible_when ? klass.authorize(:read, model: Object, visible_when: :export) : klass.authorize(:read, model: Object)
      end
      m1 = Class.new(b[:object]) { graphql_name "Money"; lifecycle removed: "2025-01-01"; field :cents, Integer, null: true }
      m2 = Class.new(b[:object]) { graphql_name "Money"; lifecycle added: "2025-01-01"; field :amount, String, null: true }
      (rule_on == :new ? strict : none).(m2)
      (rule_on == :new ? none : strict).(m1)
      query = Class.new(b[:object]) do
        graphql_name "Query"
        authorize :none, reason: "root", covers_fields: true
        field :total, m1, null: true, removed: "2025-01-01"
        field :total, m2, null: true, added: "2025-01-01"
      end
      query
    end

    it "security Z1: the refused user gets no data from the ruled twin in its version, and the audit does not misreport" do
      TT_MODES.each do |mode|
        %i[new old].each do |rule_on|
          adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: false)
          schema = schema_over(auth_world(rule_on: rule_on), mode, authorization: adapter)
          root = record(total: record(cents: 1200, amount: "SECRET"))
          served_new = outcome(schema, "{ total { amount } }", TT_NEW, root: root)
          served_old = outcome(schema, "{ total { cents } }", TT_OLD, root: root)
          report = GraphQL::Armory::Authorization::Audit.(schema)
          note("Z1 #{mode} rule_on=#{rule_on}", [served_new, served_old, report.problems.map { |p| [p.kind, p.path] }])
          ruled = rule_on == :new ? served_new : served_old
          open = rule_on == :new ? served_old : served_new
          expect(ruled.to_s).not_to include("SECRET")
          expect(ruled.to_s).not_to include("1200")
          expect(open.to_s).to include(rule_on == :new ? "1200" : "SECRET")
          expect(report.problems.map(&:kind)).not_to include(:ignored_rule)
        end
      end
    end

    it "security Z2: visible_when on one twin hides it in its version without exposing the other twin" do
      TT_MODES.each do |mode|
        adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: false)
        schema = schema_over(auth_world(rule_on: :new, visible_when: true), mode, authorization: adapter)
        root = record(total: record(cents: 1200, amount: "SECRET"))
        intro = [TT_OLD, TT_NEW].map { |v| outcome(schema, '{ __type(name: "Money") { fields { name } } }', v) }
        data_new = [outcome(schema, "{ total { amount } }", TT_NEW, root: root), outcome(schema, "{ total { cents } }", TT_NEW, root: root)]
        note("Z2 #{mode}", [intro, data_new])
        expect(intro[1][1].dig("data", "__type")).to be_nil
        expect(intro[0][1].dig("data", "__type", "fields").map { |f| f["name"] }).to eq(["cents"])
        expect(data_new.to_s).not_to include("SECRET")
        expect(data_new.to_s).not_to include("1200")
      end
    end
  end

  describe "PayloadReuse (item 6)" do
    def mutation_world
      armory = GraphQL::Armory::Authorization
      field_class = Class.new(GraphQL::Schema::Field) { include armory::Base }
      object = Class.new(GraphQL::Schema::Object) { include armory::Base; field_class(field_class) }
      payload_base = Class.new(object) { authorize :none, reason: "the mutation's rule covers its payload", covers_fields: true }
      move = Class.new(GraphQL::Schema::RelayClassicMutation) do
        include armory::Base
        field_class field_class
        object_class payload_base
        graphql_name "Move"
        authorize :move
        field :done, String, null: true
      end
      [armory, field_class, object, move]
    end

    it "security P1: a late-bound return whose name has a ruled payload twin is reported, whatever order the definitions come in" do
      armory, _f, _o, move = mutation_world
      payload = move.payload_type
      plain = Class.new(GraphQL::Schema::Object) { graphql_name payload.graphql_name; field :done, String, null: true }
      holder = Class.new(GraphQL::Schema::Object) { graphql_name "Holder"; field :last, [TT_LB.new(payload.graphql_name)], null: true }
      results = [[plain, holder, payload], [payload, plain, holder], [holder, payload, plain]].map do |order|
        findings = armory::Audit::Findings.new
        armory::Audit::PayloadReuse.(order, findings)
        findings.report.problems.map { |p| [p.kind, p.path] }
      end
      note("P1", results)
      expect(results).to all(eq([[:payload_outside_mutation, "Holder.last"]]))
    end

    it "preservation P2: a mutation field returning its own payload is not reported (full audit)" do
      armory, _f, object, move = mutation_world
      mutation_root = Class.new(object) { graphql_name "Mutation"; authorize :none, reason: "root", covers_fields: false; field :move, mutation: move }
      query = Class.new(object) { graphql_name "Query"; authorize :none, reason: "root", covers_fields: true; field :ping, String, null: true }
      adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new
      schema = Class.new(ArmoryEngine.base_schema) do
        query(query)
        mutation(mutation_root)
        use armory, adapter: adapter
      end
      problems = armory::Audit.(schema).problems.map { |p| [p.kind, p.path] }
      note("P2", problems)
      expect(problems.map(&:first)).not_to include(:payload_outside_mutation)
    end
  end

  describe "overlapping lifecycles (item 7)" do
    it "security O1: type twins with overlapping lifecycles fail closed in the overlap, never serve one silently" do
      TT_MODES.each do |mode|
        b = bases
        m1 = Class.new(b[:object]) { graphql_name "Money"; lifecycle removed: "2025-01-01"; field :cents, Integer, null: true }
        m2 = Class.new(b[:object]) { graphql_name "Money"; lifecycle added: "2024-06-01"; field :amount, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :total, m1, null: true, removed: "2024-06-01"
          field :total, m2, null: true, added: "2024-06-01"
        end
        schema = schema_over(query, mode)
        root = record(total: record(cents: 1200, amount: "12.00"))
        tries = ['{ __type(name: "Money") { fields { name } } }', "{ total { amount } }", "{ total { cents } }", "{ __typename }"]
        results = tries.map { |q| outcome(schema, q, TT_OLD, root: root) }
        sdl = begin
          schema.to_definition(context: { armory_version: TT_OLD })[/type Money \{[^}]*\}/]
        rescue StandardError => e
          [e.class, e.message[0, 120]]
        end
        note("O1 #{mode}", [results, sdl])
        leaked = results[0..2].select { |r| r[0] == :result && r[1].dig("data", "total", "cents") }
        expect(leaked).to eq([])
      end
    end

    it "security O3: overlapping type twins both reachable in one version (two plain fields) never serve both shapes" do
      skip "pre-existing, documented limit: overlapping type twins fail only where the type is looked up by name"
      TT_MODES.each do |mode|
        b = bases
        m1 = Class.new(b[:object]) { graphql_name "Money"; lifecycle removed: "2025-01-01"; field :cents, Integer, null: true }
        m2 = Class.new(b[:object]) { graphql_name "Money"; lifecycle added: "2024-06-01"; field :amount, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :a, m1, null: true
          field :b, m2, null: true
        end
        schema = schema_over(query, mode)
        root = record(a: record(cents: 1200), b: record(amount: "12.00"))
        both = outcome(schema, "{ a { cents } b { amount } }", TT_OLD, root: root)
        intro = outcome(schema, '{ __type(name: "Money") { fields { name } } }', TT_OLD)
        sdl = begin
          schema.to_definition(context: { armory_version: TT_OLD }).scan(/type Money \{[^}]*\}/)
        rescue StandardError => e
          [e.class, e.message[0, 120]]
        end
        note("O3 #{mode}", [both, intro, sdl])
        (@o3 ||= []) << mode if both[0] == :result && both[1].dig("data", "a", "cents") && both[1].dig("data", "b", "amount")
      end
      expect(@o3 || []).to eq([])
    end

    it "security O2: an unversioned type twin beside a versioned one fails closed" do
      TT_MODES.each do |mode|
        b = bases
        m1 = Class.new(b[:object]) { graphql_name "Money"; field :cents, Integer, null: true }
        m2 = Class.new(b[:object]) { graphql_name "Money"; lifecycle added: "2025-01-01"; field :amount, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :total, m1, null: true, removed: "2025-01-01"
          field :total, m2, null: true, added: "2025-01-01"
        end
        schema = schema_over(query, mode)
        root = record(total: record(cents: 1200, amount: "12.00"))
        results = ['{ __type(name: "Money") { fields { name } } }', "{ total { amount } }", "{ total { cents } }"].map { |q| outcome(schema, q, TT_NEW, root: root) }
        note("O2 #{mode}", results)
        leaked = results.select { |r| r[0] == :result && r[1].dig("data", "total", "cents") }
        expect(leaked).to eq([])
      end
    end
  end

  describe "Definitions refactor (item 8)" do
    it "preservation D1: Authorization audit and Definitions of the integration schema (digest compared across A and B)" do
      schema = IntegrationSchema.build
      problems = GraphQL::Armory::Authorization::Audit.(schema).problems.map { |p| [p.kind.to_s, p.path.to_s, p.message.to_s] }.sort
      names = GraphQL::Armory::Authorization::Definitions.(schema).map(&:graphql_name).sort
      warn "DIGEST D1 problems=#{problems.size} names=#{names.size} #{[problems, names].hash.abs.to_s(36)}"
      warn "DIGEST D1 kinds=#{problems.map(&:first).tally.sort.inspect}"
      problems.each { |row| warn "DIGEST D1 row=#{row.inspect}" }
      warn "DIGEST D1 names=#{names.inspect}"
      expect(problems).not_to be_empty
    end

    it "preservation D2: Authorization audit of a schema with interface, union, connection, directive input, introspection(true) app type and hidden field" do
      armory = GraphQL::Armory::Authorization
      acls = Class.new(GraphQL::Schema::Argument) { include armory::Base }
      fcls = Class.new(GraphQL::Schema::Field) { include armory::Base; argument_class acls }
      object = Class.new(GraphQL::Schema::Object) { include armory::Base; field_class fcls }
      iface = Module.new { include GraphQL::Schema::Interface; graphql_name "Node3"; field_class fcls; field :id, String, null: true }
      a = Class.new(object) { graphql_name "A"; implements iface; field :secret, String, null: true }
      orphan = Class.new(object) { graphql_name "Orphan"; implements iface; field :other, String, null: true }
      iface.orphan_types(orphan)
      c = Class.new(object) { graphql_name "C"; authorize :none, reason: "x", covers_fields: true; field :x, String, null: true }
      u = Class.new(GraphQL::Schema::Union) { graphql_name "U"; possible_types a, c }
      inp = Class.new(GraphQL::Schema::InputObject) { graphql_name "DirIn"; argument :n, Integer, required: false }
      dir = Class.new(GraphQL::Schema::Directive) { graphql_name "dirx"; locations GraphQL::Schema::Directive::FIELD; argument :i, inp, required: false }
      meta = Class.new(object) { graphql_name "Meta"; introspection(true); field :leak, String, null: true }
      hidden_field = Class.new(fcls) { define_method(:visible?) { |_c| false } }
      deep = Class.new(object) { graphql_name "Deep"; field :data, String, null: true }
      query = Class.new(object) do
        graphql_name "Query"
        authorize :none, reason: "root", covers_fields: true
        field :a, a, null: true
        field :u, u, null: true
        field :conn, a.connection_type, null: true
        field :meta, meta, null: true
        field :deep, Class.new(object) { graphql_name "DeepHolder"; field :id, String, null: true; field_class hidden_field; field :inner, deep, null: true }, null: true
        field :node, iface, null: true
      end
      adapter = armory::Adapters::Substitute.new
      schema = Class.new(ArmoryEngine.base_schema) do
        query(query)
        directives(dir)
        use armory, adapter: adapter
      end
      problems = armory::Audit.(schema).problems.map { |p| [p.kind.to_s, p.path.to_s, p.message.to_s] }.sort
      names = armory::Definitions.(schema).map(&:graphql_name).sort
      warn "DIGEST D2 problems=#{problems.size} names=#{names.size} #{[problems, names].hash.abs.to_s(36)}"
      warn "DIGEST D2 list=#{problems.map { |k, p, _| "#{k}@#{p}" }.inspect}"
      warn "DIGEST D2 names=#{names.inspect}"
      expect(problems).not_to be_empty
    end
  end

  describe "method owners (what really runs)" do
    it "preservation M1: owners of the hooked methods with graphql-ruby's install-template order" do
      v = GraphQL::Armory::Versioning
      a = GraphQL::Armory::Authorization
      argument = Class.new(GraphQL::Schema::Argument) { include v::Base; include a::Base }
      field = Class.new(GraphQL::Schema::Field) { argument_class argument; include v::Base; include a::Base }
      object = Class.new(GraphQL::Schema::Object) do
        edge_type_class(GraphQL::Types::Relay::BaseEdge)
        connection_type_class(GraphQL::Types::Relay::BaseConnection)
        field_class field
        include v::Base
        include a::Base
      end
      iface = Module.new do
        include GraphQL::Schema::Interface
        edge_type_class(GraphQL::Types::Relay::BaseEdge)
        connection_type_class(GraphQL::Types::Relay::BaseConnection)
        field_class field
        include v::Base
      end
      child_iface = Module.new { include iface; graphql_name "ChildI" }
      resolver = Class.new(GraphQL::Schema::Resolver) { include v::Base }
      obj = Class.new(object) { graphql_name "O" }
      f = field.new(name: :x, type: String, null: true, owner: obj)
      owners = {
        field_visible: f.method(:visible?).owner, field_init: field.instance_method(:initialize).owner,
        object_implements: obj.method(:implements).owner, iface_implements: child_iface.method(:implements).owner,
        resolver_type: resolver.method(:type).owner, object_visible: obj.method(:visible?).owner
      }
      note("M1", owners.transform_values(&:inspect))
      expect(owners[:object_implements]).to eq(v::Integration::Implements)
      expect(owners[:iface_implements]).to eq(v::Integration::Implements)
    end
  end
end
