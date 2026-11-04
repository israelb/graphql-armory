# frozen_string_literal: true

require "digest"

# Independent verification probes, API versioning increment 1 (PR #65, branch feat/versioning-gate).
# Written from the code diff, docs/versioning.md and the design (sections 3, 4.1, 4.2, 4.5, 4.6, 5, 8, 9, 12, 13)
# BEFORE reading the feature's own specs. Each probe is "[security]" (the feature must change its outcome) or
# "[preservation]" (existing behaviour that must stay). Nothing here mocks: outcomes are read from responses,
# from what the root objects recorded (`resolved`) and from what sinks recorded (`signals`).
#
# Probe list (as written; see the report for what was dropped as duplicate of the feature's specs):
#  VAL1-VAL9  version values: trailing space, retired+space, case, unicode hyphen, non-Strings, prefixes,
#             "latest"/:latest, "" vs nil vs missing key, label default policy
#  PATH1-17   multiplex (interpreter and Next.run_all), run_partials (refused / served), validate: false,
#             app-built GraphQL::Query.new, Schema.validate, to_definition (+armory_full_schema, :refuse),
#             version changed after build and mid-query, custom context_class, migration_errors, document:,
#             introspection-only on a refused version, app static_validator on refused and served versions,
#             a query_class subclass that turns validation off after super
#  HID1-16    alias, fragments, inline fragments, interfaces, @include/@skip, variables, suggestions,
#             includeDeprecated, __schema, interface/implementer split both ways, subclass fallback,
#             type reachable only through a hidden field, mutation, resolver class, __typename
#  COMP1-11   Authorization visible_when (both include orders), PersistedQueries (both use orders, 5 cases),
#             schema without the gate, child schema / query_class after use, preload, dynamic profiles,
#             no visibility plugin, a type shared by two schemas, a field class with its own initialize/visible?
#  BLD1-9     every invalid use setting, second use, AlwaysVisible after use, Gate.new inert, lifecycle shapes,
#             undeclared label at query time, Base outside a field class, labels mutated after use
#  TEL1-8     one signal per query, multiplex, partial, migration, app-built, data never quotes the client,
#             sinks raising, to_definition and Schema.validate
#  VER1-3     Versioning.version(context) from a resolver, non-query contexts, defaulted requests
#  CTX1-2     a frozen context Hash, a String "armory_version" key (observation)
#  ENV1       to_definition of a deprecated field without versioning (environment control for graphql 2.4)
#
# Dropped after reading the feature's specs (exact duplicates): VAL1 (trailing space), PATH5 (validate: false on
# a refused version), PATH13 (custom context_class), BLD2 (second use), BLD3 (AlwaysVisible after use), BLD4 (Gate.new),
# BLD5 (lifecycle shapes), BLD7 (Base outside a field class), VER2 (non-query contexts), VER3 (context-less get_field).
# Kept from the independent verification of PR #65 (API versioning, increment 1).
RSpec.describe "Regression probes: versioning increment 1" do
  VERSIONING_PROBE_LABELS = %w[2024-01-15 2024-06-01 2025-01-01].freeze
  RETIRED = %w[2024-01-15].freeze

  def vg = GraphQL::Armory::Versioning
  def vfield = vg::Controls::Field.example

  def controls_schema(visibility: :visibility, default: :latest, sinks: [], on_sink_error: nil)
    vg::Controls::Schema.example(visibility: visibility, default: default, base: ArmoryEngine.base_schema, sinks: sinks, on_sink_error: on_sink_error)
  end

  def gated(query_type, visibility: :visibility, default: :latest, versions: VERSIONING_PROBE_LABELS, retired: RETIRED, sinks: [], mutation: nil, orphans: [], gate: true, &extra)
    vis = visibility
    vers = versions
    ret = retired
    dflt = default
    snk = sinks
    mut = mutation
    use_gate = gate
    Class.new(ArmoryEngine.base_schema) do
      query(query_type)
      mutation(mut) if mut
      case vis
      when :visibility then use GraphQL::Schema::Visibility
      when :warden then use GraphQL::Schema::Warden
      end
      use GraphQL::Armory::Versioning, versions: vers, retired: ret, default: dflt, sinks: snk if use_gate
      orphan_types(*orphans) unless orphans.empty?
      class_eval(&extra) if extra
    end
  end

  def run(schema, query, version: :absent, root: nil, context: {}, **options)
    ctx = context.dup
    ctx[:armory_version] = version unless version == :absent
    if ArmoryEngine.next? && options.key?(:static_validator)
      return GraphQL::Execution::Next.run_all(schema, [{ query: query, root_value: root, context: ctx, **options }])[0].to_h
    end

    execute_query(schema, query, root_value: root, context: ctx, **options).to_h
  end

  def expect_refused(result, code, resolved)
    aggregate_failures do
      expect(result.key?("data")).to eq(false), "data present: #{result.inspect}"
      expect(result["errors"]&.size).to eq(1), result.inspect
      expect(result.dig("errors", 0, "extensions", "code")).to eq(code), result.inspect
      expect(resolved).to eq([])
    end
  end

  def root(resolved) = vg::Controls::Root.example(resolved)

  def multiplex(schema, opts)
    if ArmoryEngine.next?
      GraphQL::Execution::Next.run_all(schema, opts).map(&:to_h)
    else
      schema.multiplex(opts).map(&:to_h)
    end
  end

  def safely
    [yield, nil]
  rescue StandardError => e
    [nil, e]
  end

  # --- VAL: version values ---------------------------------------------------------------------------------------

  it "[security] VAL2 the retired label with a trailing space is refused and nothing resolves" do
    resolved = []
    r = run(controls_schema, "{ invoice { number amount } }", version: "2024-01-15 ", root: root(resolved))
    expect_refused(r, "UNKNOWN_API_VERSION", resolved)
  end

  it "[security] VAL3 a label in another case is refused UNKNOWN" do
    resolved = []
    q = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field_class GraphQL::Armory::Versioning::Controls::Field.example
      field :ping, String, null: false
      field :beta, String, null: false, added: "v2"
    end
    schema = gated(q, versions: %w[v1 v2], retired: [], default: "v1")
    rt = Class.new { define_method(:ping) { resolved << :ping; "p" }; define_method(:beta) { resolved << :beta; "b" } }.new
    expect_refused(run(schema, "{ ping }", version: "V2", root: rt), "UNKNOWN_API_VERSION", resolved)
    expect_refused(run(schema, "{ ping }", version: " v2", root: rt), "UNKNOWN_API_VERSION", resolved)
  end

  it "[security] VAL4 a unicode lookalike (U+2010 hyphen, fullwidth digits) is refused UNKNOWN" do
    resolved = []
    expect_refused(run(controls_schema, "{ invoice { number } }", version: "2025‐1‐01".sub("1‐", "01‐"), root: root(resolved)), "UNKNOWN_API_VERSION", resolved)
    expect_refused(run(controls_schema, "{ invoice { number } }", version: "２０２５-01-01", root: root(resolved)), "UNKNOWN_API_VERSION", resolved)
  end

  it "[security] VAL5 Integer, Symbol, Array, Hash, true and a Version object are refused UNKNOWN" do
    other = vg::Versions.new(VERSIONING_PROBE_LABELS).fetch("2025-01-01")
    [20_250_101, :"2025-01-01", ["2025-01-01"], { "v" => "2025-01-01" }, true, other].each do |value|
      resolved = []
      expect_refused(run(controls_schema, "{ invoice { number } }", version: value, root: root(resolved)), "UNKNOWN_API_VERSION", resolved)
    end
  end

  it "[security] VAL6 a prefix or an extension of a label is refused UNKNOWN" do
    %w[2025-01 2025-01-01T00:00 2025-01-010 2025-01-1].each do |value|
      resolved = []
      expect_refused(run(controls_schema, "{ invoice { number } }", version: value, root: root(resolved)), "UNKNOWN_API_VERSION", resolved)
    end
  end

  it "[security] VAL7 \"latest\" and :latest as a version are refused, not the latest policy" do
    ["latest", :latest, "LATEST", "default", :refuse].each do |value|
      resolved = []
      expect_refused(run(controls_schema, "{ invoice { number } }", version: value, root: root(resolved)), "UNKNOWN_API_VERSION", resolved)
    end
  end

  it "[security] VAL8 an empty String is refused while nil and a missing key follow default:" do
    resolved = []
    expect_refused(run(controls_schema, "{ invoice { number } }", version: "", root: root(resolved)), "UNKNOWN_API_VERSION", resolved)
    expect_refused(run(controls_schema(default: :refuse), "{ invoice { number } }", version: nil, root: root(resolved)), "MISSING_API_VERSION", resolved)
    expect_refused(run(controls_schema(default: :refuse), "{ invoice { number } }", root: root(resolved)), "MISSING_API_VERSION", resolved)
    latest_nil = run(controls_schema, "{ invoice { tags } }", version: nil, root: root([]))
    latest_missing = run(controls_schema, "{ invoice { tags } }", root: root([]))
    expect(latest_nil.dig("data", "invoice", "tags")).to eq(%w[paid urgent])
    expect(latest_missing.dig("data", "invoice", "tags")).to eq(%w[paid urgent])
  end

  it "[security] VAL9 default: a label serves that label's schema to a client that sends none" do
    resolved = []
    r = run(controls_schema(default: "2024-06-01"), "{ invoice { tags } }", root: root(resolved))
    expect(r["errors"]).not_to be_nil
    expect(resolved).not_to include(:tags)
    ok = run(controls_schema(default: "2024-06-01"), "{ invoice { amount } }", root: root([]))
    expect(ok.dig("data", "invoice", "amount")).to eq(100)
  end

  # --- PATH: every way a query is built or run ---------------------------------------------------------------------

  it "[security] PATH1 multiplex with mixed versions: the refused query runs nothing and blocks no one" do
    resolved = []
    rt = root(resolved)
    results = multiplex(controls_schema, [
      { query: "{ invoice { tags } }", context: { armory_version: "2025-01-01" }, root_value: rt },
      { query: "{ invoice { number } }", context: { armory_version: "2024-01-15" }, root_value: rt },
      { query: "{ invoice { amount } }", context: { armory_version: "2024-06-01" }, root_value: rt },
      { query: "{ invoice { tags } }", context: { armory_version: "2024-06-01" }, root_value: rt },
    ])
    aggregate_failures do
      expect(results[0].dig("data", "invoice", "tags")).to eq(%w[paid urgent])
      expect(results[1].key?("data")).to eq(false)
      expect(results[1].dig("errors", 0, "extensions", "code")).to eq("RETIRED_API_VERSION")
      expect(results[2].dig("data", "invoice", "amount")).to eq(100)
      expect(results[3]["errors"]).not_to be_nil
      expect(resolved.sort).to eq(%i[amount invoice invoice tags].sort)
    end
  end

  it "[security] PATH1b Execution::Next.run_all directly: refused query resolves nothing" do
    skip "no Execution::Next in this graphql" unless defined?(GraphQL::Execution::Next)
    resolved = []
    rt = root(resolved)
    results = GraphQL::Execution::Next.run_all(controls_schema, [
      { query: "{ invoice { number } }", context: { armory_version: "nope" }, root_value: rt },
      { query: "{ invoice { tags } }", context: { armory_version: "2024-06-01" }, root_value: rt },
    ]).map(&:to_h)
    expect(results[0].dig("errors", 0, "extensions", "code")).to eq("UNKNOWN_API_VERSION")
    expect(results[0].key?("data")).to eq(false)
    expect(results[1]["errors"]).not_to be_nil
    expect(resolved).to eq([])
  end

  it "[security] PATH2 run_partials on a refused parent resolves nothing" do
    skip "no run_partials in this graphql" unless GraphQL::Query.method_defined?(:run_partials)
    resolved = []
    rt = root(resolved)
    invoice = rt.invoice
    resolved.clear
    schema = controls_schema
    q = schema.query_class.new(schema, "{ invoice { number total } }", context: { armory_version: "bogus" }, root_value: rt)
    q.context[:__graphql_execute_next] = true if ArmoryEngine.next?
    results, error = safely { q.run_partials([{ path: ["invoice"], object: invoice }]) }
    expect(resolved).to eq([]), "partial resolved #{resolved.inspect}: #{results.inspect} #{error.inspect}"
  end

  it "[security] PATH3 run_partials on a served parent sees the parent's version and records no second signal" do
    skip "no run_partials in this graphql" unless GraphQL::Query.method_defined?(:run_partials)
    signals = []
    resolved = []
    rt = root(resolved)
    invoice = rt.invoice
    resolved.clear
    schema = controls_schema(sinks: [->(s, d) { signals << [s, d] }])
    q = schema.query_class.new(schema, "{ invoice { number total amount } }", context: { armory_version: "2024-06-01" }, root_value: rt)
    q.context[:__graphql_execute_next] = true if ArmoryEngine.next?
    res = q.run_partials([{ path: ["invoice"], object: invoice }]).map(&:to_h)
    expect(res[0].dig("data", "total")).to eq(100)
    expect(signals.size).to eq(1)
  end

  it "[security] PATH4 validate: false with a field outside the served version resolves nothing" do
    resolved = []
    r, error = safely { run(controls_schema, "{ invoice { number tags } }", version: "2024-06-01", root: root(resolved), validate: false) }
    expect(resolved).not_to include(:tags), "resolved #{resolved.inspect} #{r.inspect} #{error.inspect}"
    expect(r&.dig("data", "invoice", "tags")).to be_nil
  end

  it "[security] PATH6 an app-built GraphQL::Query.new cannot reach a field outside its version" do
    resolved = []
    schema = controls_schema
    q = GraphQL::Query.new(schema, "{ invoice { tags } }", context: { armory_version: "2024-06-01" }, root_value: root(resolved))
    r, error = safely { ArmoryEngine.next? ? GraphQL::Execution::Next.run_all(schema, [q])[0].to_h : q.result.to_h }
    expect(resolved).not_to include(:tags), "#{r.inspect} #{error.inspect}"
  end

  it "[security] PATH7 an app-built GraphQL::Query.new with a refused version cannot reach versioned fields" do
    schema = controls_schema
    [["bogus", "{ invoice { total } }"], ["2024-01-15", "{ invoice { amount } }"], ["", "{ __type(name: \"Invoice\") { fields { name } } }"]].each do |label, text|
      resolved = []
      q = GraphQL::Query.new(schema, text, context: { armory_version: label }, root_value: root(resolved))
      r, error = safely { ArmoryEngine.next? ? GraphQL::Execution::Next.run_all(schema, [q])[0].to_h : q.result.to_h }
      expect(resolved).to eq([]), "#{label}: #{r.inspect}"
      expect(r&.dig("data", "__type")).to be_nil
      expect(error.nil? || error.is_a?(vg::RefusedVersionError)).to eq(true), error.inspect
    end
  end

  it "[security] PATH8 Schema.validate validates against the version in its context" do
    schema = controls_schema
    expect(schema.validate("{ invoice { tags } }", context: { armory_version: "2024-06-01" })).not_to be_empty
    expect(schema.validate("{ invoice { amount } }", context: { armory_version: "2025-01-01" })).not_to be_empty
    expect(schema.validate("{ invoice { tags } }", context: { armory_version: "2025-01-01" })).to be_empty
    _r, error = safely { schema.validate("{ invoice { tags } }", context: { armory_version: "bogus" }) }
    expect(error).to be_a(vg::RefusedVersionError)
  end

  it "[security] PATH9 to_definition per version, and armory_full_schema does not widen" do
    skip "this graphql with json 3.1 cannot print a String argument" unless ArmoryJsonPrinting.prints_strings?
    schema = controls_schema
    v25 = schema.to_definition(context: { armory_version: "2025-01-01" })
    v24 = schema.to_definition(context: { armory_version: "2024-06-01" })
    full = schema.to_definition(context: { armory_full_schema: true })
    full24 = schema.to_definition(context: { armory_full_schema: true, armory_version: "2024-06-01" })
    aggregate_failures do
      expect(v25).not_to match(/\bamount\b/)
      expect(v25).to match(/\btags\b/)
      expect(v24).not_to match(/\btags\b/)
      expect(v24).to match(/\bamount\b/)
      expect(full).not_to match(/\bamount\b/)
      expect(full24).not_to match(/\btags\b/)
    end
  end

  it "[security] PATH9b to_definition per version on a type with no deprecation (prints on graphql 2.4 too)" do
    vf = vfield
    inv = Class.new(GraphQL::Schema::Object) do
      graphql_name "Invoice"
      field_class vf
      field :number, String, null: false
      field :gone, Integer, null: false, removed: "2025-01-01"
      field :fresh, [String], null: false, added: "2025-01-01"
    end
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :invoice, inv, null: false }
    s = gated(q)
    v25 = s.to_definition(context: { armory_version: "2025-01-01" })
    v24 = s.to_definition(context: { armory_version: "2024-06-01" })
    full = s.to_definition(context: { armory_full_schema: true })
    expect([v25.include?("gone"), v25.include?("fresh"), v24.include?("gone"), v24.include?("fresh"), full.include?("gone")]).to eq([false, true, true, false, false])
  end

  it "[preservation] ENV1 to_definition of a plainly deprecated field (no versioning) prints" do
    skip "this graphql with json 3.1 cannot print a String argument" unless ArmoryJsonPrinting.prints_strings?
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :old, String, null: true, deprecation_reason: "Use new" }
    s = Class.new(GraphQL::Schema) { query(q) }
    expect(s.to_definition).to include("@deprecated")
  end

  it "[security] PATH10 to_definition with a refused or missing version raises instead of printing" do
    _r, missing = safely { controls_schema(default: :refuse).to_definition }
    _r2, bogus = safely { controls_schema.to_definition(context: { armory_version: "bogus" }) }
    _r3, retired = safely { controls_schema.to_definition(context: { armory_version: "2024-01-15" }) }
    expect(missing).to be_a(vg::MissingVersionError)
    expect(bogus).to be_a(vg::RefusedVersionError)
    expect(retired).to be_a(vg::RefusedVersionError)
    expect(retired.message).not_to include("2024")
  end

  it "[security] PATH11 changing context[:armory_version] after the query is built changes nothing" do
    resolved = []
    schema = controls_schema
    q = schema.query_class.new(schema, "{ invoice { tags } }", context: { armory_version: "2024-06-01" }, root_value: root(resolved))
    q.context[:armory_version] = "2025-01-01"
    r, error = safely { q.result.to_h }
    expect(resolved).not_to include(:tags), "#{r.inspect} #{error.inspect}"
    resolved2 = []
    q2 = schema.query_class.new(schema, "{ invoice { number } }", context: { armory_version: "2024-01-15" }, root_value: root(resolved2))
    q2.context[:armory_version] = "2025-01-01"
    expect_refused(q2.result.to_h, "RETIRED_API_VERSION", resolved2)
  end

  it "[security] PATH12 a resolver changing the version mid-query does not change what later fields see" do
    flip = Class.new(GraphQL::Schema::Resolver) do
      type String, null: false
      def resolve
        context[:armory_version] = "2025-01-01"
        "x"
      end
    end
    q = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field_class GraphQL::Armory::Versioning::Controls::Field.example
      field :flip, resolver: flip
      field :invoice, GraphQL::Armory::Versioning::Controls::Invoice.example, null: false
    end
    schema = gated(q)
    r = run(schema, '{ flip intro: __type(name: "Invoice") { fields { name } } }', version: "2024-06-01")
    names = r.dig("data", "intro", "fields").map { |f| f["name"] }
    expect(names).not_to include("tags")
  end

  it "[security] PATH14 Visibility migration_errors: true keeps the version and one signal per query" do
    signals = []
    q = vg::Controls::Query.example
    schema = Class.new(ArmoryEngine.base_schema) do
      query(q)
      use GraphQL::Schema::Visibility, migration_errors: true
      use GraphQL::Armory::Versioning, versions: VERSIONING_PROBE_LABELS, retired: RETIRED, default: :latest, sinks: [->(s, d) { signals << [s, d] }]
    end
    resolved = []
    ok, e1 = safely { run(schema, "{ invoice { number amount } }", version: "2024-06-01", root: root(resolved)) }
    bad, e2 = safely { run(schema, "{ invoice { tags } }", version: "2024-06-01", root: root(resolved)) }
    intro, e3 = safely { run(schema, '{ __type(name: "Invoice") { fields(includeDeprecated: true) { name } } }', version: "2025-01-01") }
    aggregate_failures do
      expect(e1).to be_nil
      expect(ok&.dig("data", "invoice", "amount")).to eq(100)
      expect(resolved).not_to include(:tags), "#{bad.inspect} #{e2.inspect}"
      expect(intro&.dig("data", "__type", "fields")&.map { |f| f["name"] }).not_to include("amount"), "#{intro.inspect} #{e3.inspect}"
      expect(signals.size).to eq(3)
    end
  end

  it "[security] PATH15 a pre-parsed document: on a refused version runs nothing" do
    resolved = []
    doc = GraphQL.parse("{ invoice { number } }")
    schema = controls_schema
    r = (ArmoryEngine.next? ? schema.execute_next(document: doc, context: { armory_version: "x" }, root_value: root(resolved)) : schema.execute(document: doc, context: { armory_version: "x" }, root_value: root(resolved))).to_h
    expect_refused(r, "UNKNOWN_API_VERSION", resolved)
  end

  it "[security] PATH16 introspection alone on a refused version answers nothing" do
    r = run(controls_schema(default: :refuse), "{ __schema { types { name fields { name } } } }")
    expect(r.key?("data")).to eq(false)
    expect(r.dig("errors", 0, "extensions", "code")).to eq("MISSING_API_VERSION")
    r2 = run(controls_schema, '{ __type(name: "Invoice") { fields { name } } }', version: "2024-01-15")
    expect(r2.key?("data")).to eq(false)
  end

  it "[security] PATH17 an app static_validator: does not let a refused version through, nor a hidden field" do
    schema = controls_schema
    permissive = GraphQL::StaticValidation::Validator.new(schema: schema, rules: [])
    resolved = []
    expect_refused(run(schema, "{ invoice { number } }", version: "nope", root: root(resolved), static_validator: permissive, validate: false), "UNKNOWN_API_VERSION", resolved)
    resolved2 = []
    r, error = safely { run(schema, "{ invoice { number tags } }", version: "2024-06-01", root: root(resolved2), static_validator: permissive) }
    expect(resolved2).not_to include(:tags), "#{r.inspect} #{error.inspect}"
  end

  it "[security] PATH18 a subclass of the gated query_class that turns validation off after super" do
    schema = controls_schema
    sub = Class.new(schema.query_class) do
      def initialize(*args, **kwargs)
        super
        self.validate = false
      end
    end
    schema.query_class(sub)
    resolved = []
    r, error = safely { run(schema, "{ invoice { number } }", version: "2024-01-15", root: root(resolved)) }
    expect(resolved).to eq([]), "#{r.inspect} #{error.inspect}"
  end

  # --- HID: hidden field reachability ------------------------------------------------------------------------------

  %i[visibility warden].each do |vis|
    context "under #{vis}" do
      define_method(:schema) { controls_schema(visibility: vis) }

      it "[security] HID1 alias of a hidden field" do
        resolved = []
        r = run(schema, "{ invoice { x: tags } }", version: "2024-06-01", root: root(resolved))
        expect(r["errors"]).not_to be_nil
        expect(resolved).to eq([])
      end

      it "[security] HID2 named and inline fragments" do
        resolved = []
        r1 = run(schema, "{ invoice { ...F } } fragment F on Invoice { tags }", version: "2024-06-01", root: root(resolved))
        r2 = run(schema, "{ invoice { ... on Invoice { amount } } }", version: "2025-01-01", root: root(resolved))
        r3 = run(schema, "{ invoice { ... { tags } } }", version: "2024-06-01", root: root(resolved))
        expect([r1, r2, r3].map { |r| r["errors"].nil? }).to eq([false, false, false])
        expect(resolved).to eq([])
      end

      it "[security] HID5 @include(if: false) and @skip(if: true) on a hidden field are still errors" do
        resolved = []
        r1 = run(schema, "{ invoice { number tags @include(if: false) } }", version: "2024-06-01", root: root(resolved))
        r2 = run(schema, "query($s: Boolean = true) { invoice { number amount @skip(if: $s) } }", version: "2025-01-01", root: root(resolved))
        expect(r1["errors"]).not_to be_nil
        expect(r2["errors"]).not_to be_nil
        expect(resolved).to eq([])
      end

      it "[security] HID6 variables into a hidden field's argument" do
        resolved = []
        r = run(schema, "query($f: Int) { invoice { tags(first: $f) } }", version: "2024-06-01", root: root(resolved), variables: { "f" => 1 })
        expect(r["errors"]).not_to be_nil
        expect(resolved).to eq([])
      end

      it "[security] HID7 no suggestion names a hidden field" do
        r1 = run(schema, "{ invoice { tag } }", version: "2024-06-01")
        r2 = run(schema, "{ invoice { amoun } }", version: "2025-01-01")
        r3 = run(schema, "{ invoice { tags(frist: 1) } }", version: "2024-06-01")
        expect(r1.to_s).not_to include("tags")
        expect(r2.to_s).not_to include("amount")
        expect(r3.to_s).not_to include("first")
      end

      it "[security] HID8 introspection with includeDeprecated lists only the version's fields" do
        r25 = run(schema, '{ __type(name: "Invoice") { fields(includeDeprecated: true) { name args { name } } } }', version: "2025-01-01")
        r24 = run(schema, '{ __type(name: "Invoice") { fields(includeDeprecated: true) { name isDeprecated args { name } } } }', version: "2024-06-01")
        n25 = r25.dig("data", "__type", "fields").map { |f| f["name"] }
        n24 = r24.dig("data", "__type", "fields").map { |f| f["name"] }
        expect(n25).to contain_exactly("number", "total", "tags")
        expect(n24).to contain_exactly("number", "total", "amount")
        expect(r24.dig("data", "__type", "fields").find { |f| f["name"] == "amount" }["isDeprecated"]).to eq(true)
      end

      it "[security] HID9 __schema lists no hidden field anywhere" do
        r = run(schema, "{ __schema { types { name fields(includeDeprecated: true) { name } } } }", version: "2025-01-01")
        all = r.dig("data", "__schema", "types").flat_map { |t| (t["fields"] || []).map { |f| "#{t["name"]}.#{f["name"]}" } }
        expect(all).not_to include("Invoice.amount")
      end

      it "[security] HID16 __typename mixed with a hidden field" do
        resolved = []
        r = run(schema, "{ __typename invoice { __typename tags } }", version: "2024-06-01", root: root(resolved))
        expect(r.key?("data")).to eq(false)
        expect(resolved).to eq([])
      end

      it "[security] HID4 a versioned field on an interface, through the interface and the implementer" do
        vf = vfield
        iface = Module.new do
          include GraphQL::Schema::Interface
          graphql_name "Taggable"
          field_class vf
          field :number, String, null: false
          field :tags, [String], null: false, added: "2025-01-01"
        end
        inv = Class.new(GraphQL::Schema::Object) { graphql_name "Invoice"; field_class vf; implements iface }
        q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :item, iface, null: false }
        s = gated(q, visibility: vis, orphans: [inv]) { define_singleton_method(:resolve_type) { |*_| inv } }
        resolved = []
        rt = Struct.new(:item).new(Class.new { define_method(:number) { "n" }; define_method(:tags) { resolved << :tags; ["t"] } }.new)
        rs = ["{ item { tags } }", "{ item { ... on Taggable { tags } } }", "{ item { ... on Invoice { tags } } }"].map { |t| run(s, t, version: "2024-06-01", root: rt) }
        expect(rs.map { |r| r["errors"].nil? }).to eq([false, false, false])
        expect(resolved).to eq([])
        ok = run(s, "{ item { ... on Invoice { tags } } }", version: "2025-01-01", root: rt)
        expect(ok.dig("data", "item", "tags")).to eq(["t"])
      end

      it "[security] HID13 a type reachable only through a hidden field is not introspectable" do
        vf = vfield
        info = Class.new(GraphQL::Schema::Object) { graphql_name "TagInfo"; field :secretish, String, null: true }
        inv = Class.new(GraphQL::Schema::Object) do
          graphql_name "Invoice"
          field_class vf
          field :number, String, null: false
          field :tag_info, info, null: true, added: "2025-01-01"
        end
        q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :invoice, inv, null: false }
        s = gated(q, visibility: vis)
        r = run(s, '{ __type(name: "TagInfo") { name fields { name } } }', version: "2024-06-01")
        all = run(s, "{ __schema { types { name } } }", version: "2024-06-01").dig("data", "__schema", "types").map { |t| t["name"] }
        expect(r.dig("data", "__type")).to be_nil, r.inspect
        expect(all).not_to include("TagInfo")
      end

      it "[security] HID14 a mutation field outside the version does not run" do
        ran = []
        vf = vfield
        mut = Class.new(GraphQL::Schema::Object) do
          graphql_name "Mutation"
          field_class vf
          field :noop, Integer, null: false
          field :bump, Integer, null: false, added: "2025-01-01"
        end
        q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :ping, String, null: false }
        s = gated(q, visibility: vis, mutation: mut)
        rt = Class.new { define_method(:bump) { ran << :bump; 1 }; define_method(:noop) { 0 }; define_method(:ping) { "p" } }.new
        r = run(s, "mutation { bump }", version: "2024-06-01", root: rt)
        expect(r["errors"]).not_to be_nil
        expect(ran).to eq([])
        expect(run(s, "mutation { bump }", version: "2025-01-01", root: rt).dig("data", "bump")).to eq(1)
      end

      it "[security] HID15 a resolver-class field with added: is hidden and does not run" do
        ran = []
        vf = vfield
        res = Class.new(GraphQL::Schema::Resolver) do
          type Integer, null: false
          define_method(:resolve) { ran << :resolver; 7 }
        end
        q = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field_class vf
          field :ping, String, null: false
          field :computed, resolver: res, added: "2025-01-01"
        end
        s = gated(q, visibility: vis)
        rt = Class.new { define_method(:ping) { "p" } }.new
        r = run(s, "{ computed }", version: "2024-06-01", root: rt)
        expect(r["errors"]).not_to be_nil
        expect(ran).to eq([])
        expect(run(s, "{ computed }", version: "2025-01-01", root: rt).dig("data", "computed")).to eq(7)
      end
    end
  end

  it "[security] HID10 interface field versioned, implementer redefines it plainly (Visibility): interface path hidden" do
    vf = vfield
    iface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Taggable"
      field_class vf
      field :number, String, null: false
      field :f, String, null: false, added: "2025-01-01"
    end
    inv = Class.new(GraphQL::Schema::Object) { graphql_name "Invoice"; implements iface; field :f, String, null: false }
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :item, iface, null: false }
    s = gated(q, orphans: [inv]) { define_singleton_method(:resolve_type) { |*_| inv } }
    rt = Struct.new(:item).new(Struct.new(:number, :f).new("n", "F"))
    via_iface = run(s, "{ item { f } }", version: "2024-06-01", root: rt)
    via_impl = run(s, "{ item { ... on Invoice { f } } }", version: "2024-06-01", root: rt)
    puts "HID10 via implementer: #{via_impl.inspect}"
    expect(via_iface["errors"]).not_to be_nil
  end

  it "[security] HID11 implementer field removed, interface field plain: Visibility does not fall back" do
    vf = vfield
    iface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Taggable"
      field :f, String, null: false
    end
    inv = Class.new(GraphQL::Schema::Object) { graphql_name "Invoice"; field_class vf; implements iface; field :f, String, null: false, removed: "2025-01-01" }
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :invoice, inv, null: false }
    s = gated(q)
    rt = Struct.new(:invoice).new(Struct.new(:f).new("F"))
    r = run(s, "{ invoice { f } }", version: "2025-01-01", root: rt)
    w = run(gated(q, visibility: :warden), "{ invoice { f } }", version: "2025-01-01", root: rt)
    puts "HID11 warden (documented fallback): #{w.inspect}"
    expect(r.dig("data", "invoice", "f")).to be_nil, r.inspect
  end

  it "[security] HID12 a child type hiding a field its parent class defines plainly: Visibility does not fall back" do
    vf = vfield
    parent = Class.new(GraphQL::Schema::Object) { graphql_name "Base"; field_class vf; field :amount, Integer, null: false; field :number, String, null: false }
    child = Class.new(parent) { graphql_name "Invoice"; field :amount, Integer, null: false, removed: "2025-01-01" }
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :invoice, child, null: false }
    rt = Struct.new(:invoice).new(Struct.new(:amount, :number).new(5, "n"))
    r = run(gated(q), "{ invoice { amount } }", version: "2025-01-01", root: rt)
    intro = run(gated(q), '{ __type(name: "Invoice") { fields { name } } }', version: "2025-01-01")
    w = run(gated(q, visibility: :warden), "{ invoice { amount } }", version: "2025-01-01", root: rt)
    puts "HID12 warden (documented fallback): #{w.inspect}"
    expect(r.dig("data", "invoice", "amount")).to be_nil, r.inspect
    expect(intro.dig("data", "__type", "fields").map { |f| f["name"] }).not_to include("amount")
  end

  # --- COMP: composition -------------------------------------------------------------------------------------------

  def authz_adapter(allowed)
    Class.new(GraphQL::Armory::Authorization::Adapters::Substitute) do
      define_method(:authorized?) { |_actor, _subject, rule| allowed.include?(rule.action) }
    end.new
  end

  [:authz_first, :versioning_first].each do |order|
    it "[security] COMP1 Authorization visible_when: and versioning both must allow (#{order})" do
      authz = GraphQL::Armory::Authorization
      fc = Class.new(GraphQL::Schema::Field)
      if order == :authz_first
        fc.include(authz::Base)
        fc.include(GraphQL::Armory::Versioning::Base)
      else
        fc.include(GraphQL::Armory::Versioning::Base)
        fc.include(authz::Base)
      end
      model = Class.new
      base_obj = Class.new(GraphQL::Schema::Object) { include authz::Base; field_class fc; default_action :read }
      doc = Class.new(base_obj) do
        graphql_name "Doc"
        authorize :read, model: model
        field :plain, String, null: true
        field :denied, String, null: true, visible_when: :manage
        field :late, String, null: true, visible_when: :read, added: "2025-01-01"
        field :mid, String, null: true, visible_when: :read, added: "2024-06-01"
        field :late_denied, String, null: true, visible_when: :manage, added: "2024-06-01"
      end
      q = Class.new(base_obj) do
        graphql_name "Query"
        authorize :none, reason: "root", covers_fields: true
        field :doc, doc, null: true, authorize: :none, reason: "x"
      end
      adapter = authz_adapter(%i[read])
      s = Class.new(ArmoryEngine.base_schema) do
        use authz, adapter: adapter
        use GraphQL::Schema::Visibility
        query q
        use GraphQL::Armory::Versioning, versions: VERSIONING_PROBE_LABELS, retired: RETIRED, default: :latest
      end
      puts "COMP1 #{order} visible? owner: #{fc.instance_method(:visible?).owner} ancestors: #{fc.ancestors.take(4).inspect}"
      r = run(s, '{ __type(name: "Doc") { fields { name } } }', version: "2024-06-01", context: { current_user: :reader })
      names = r.dig("data", "__type", "fields")&.map { |f| f["name"] }
      expect(names).to contain_exactly("plain", "mid"), r.inspect
      r25 = run(s, '{ __type(name: "Doc") { fields { name } } }', version: "2025-01-01", context: { current_user: :reader })
      expect(r25.dig("data", "__type", "fields")&.map { |f| f["name"] }).to contain_exactly("plain", "mid", "late")
    end
  end

  [:pq_after, :pq_before].each do |order|
    it "[security] COMP2 PersistedQueries + Versioning (#{order})" do
      pq = GraphQL::Armory::PersistedQueries
      tags_q = "{ invoice { tags } }"
      num_q = "{ invoice { number } }"
      store = pq::Store::Substitute.new(tags_q, num_q)
      qt = vg::Controls::Query.example
      ord = order
      s = Class.new(ArmoryEngine.base_schema) do
        query(qt)
        use GraphQL::Schema::Visibility
        use pq, store: store, strict: true if ord == :pq_before
        use GraphQL::Armory::Versioning, versions: VERSIONING_PROBE_LABELS, retired: RETIRED, default: :latest
        use pq, store: store, strict: true if ord == :pq_after
      end
      puts "COMP2 #{order} query_class ancestors: #{s.query_class.ancestors.take(4).inspect}"
      id = ->(t) { Digest::SHA256.hexdigest(t) }
      cases = {}
      resolved = []
      cases[:both] = run(s, nil, version: "bogus", context: { operation_id: "nope" }, root: root(resolved))
      cases[:hidden] = run(s, nil, version: "2024-06-01", context: { operation_id: id.(tags_q) }, root: root(resolved))
      cases[:retired] = run(s, nil, version: "2024-01-15", context: { operation_id: id.(num_q) }, root: root(resolved))
      cases[:raw] = run(s, num_q, version: "2025-01-01", root: root(resolved))
      cases[:raw_bogus] = run(s, num_q, version: "bogus", root: root(resolved))
      good = []
      cases[:good] = run(s, nil, version: "2025-01-01", context: { operation_id: id.(tags_q) }, root: root(good))
      puts "COMP2 #{order} codes: #{cases.transform_values { |r| r.dig("errors", 0, "extensions", "code") || r.dig("errors", 0, "message") }.inspect}"
      aggregate_failures do
        expect(resolved).to eq([])
        expect(cases[:both].dig("errors", 0, "extensions", "code")).to eq("UNKNOWN_OPERATION")
        expect(cases[:hidden]["errors"]).not_to be_nil
        expect(cases[:retired].dig("errors", 0, "extensions", "code")).to eq("RETIRED_API_VERSION")
        expect(cases[:raw].dig("errors", 0, "extensions", "code")).to eq("RAW_QUERY_REFUSED")
        expect(cases[:raw_bogus].dig("errors", 0, "extensions", "code")).to eq("RAW_QUERY_REFUSED")
        expect(cases[:good].dig("data", "invoice", "tags")).to eq(%w[paid urgent])
        %i[both retired raw raw_bogus].each { |k| expect(cases[k]["errors"].size).to eq(1) }
      end
    end
  end

  it "[security] COMP4 a schema with versioned fields but no gate fails closed" do
    q = vg::Controls::Query.example
    %i[visibility warden].each do |vis|
      s = gated(q, visibility: vis, gate: false)
      resolved = []
      r, error = safely { run(s, "{ invoice { tags } }", version: "2024-06-01", root: root(resolved)) }
      i, ierror = safely { run(s, '{ __type(name: "Invoice") { fields { name } } }', version: "2024-06-01") }
      puts "COMP4 #{vis}: #{r.inspect} #{error.class} / intro #{i.inspect} #{ierror.class}"
      expect(resolved).to eq([])
      expect(error).to be_a(vg::ConfigurationError)
      expect(i&.dig("data", "__type")).to be_nil
    end
  end

  it "[security] COMP5 a child schema and a query_class set after use stay gated" do
    parent = controls_schema
    child = Class.new(parent)
    resolved = []
    expect_refused(run(child, "{ invoice { number } }", version: "2024-01-15", root: root(resolved)), "RETIRED_API_VERSION", resolved)
    custom = Class.new(GraphQL::Query) do
      def initialize(*args, **kwargs)
        super
        @marker = true
      end
    end
    child.query_class(custom)
    expect(child.query_class.ancestors).to include(custom)
    expect_refused(run(child, "{ invoice { number } }", version: "nope", root: root(resolved)), "UNKNOWN_API_VERSION", resolved)
    r = run(child, "{ invoice { tags } }", version: "2024-06-01", root: root(resolved))
    expect(r["errors"]).not_to be_nil
    expect(resolved).to eq([])
    parent.query_class(Class.new(GraphQL::Query))
    expect_refused(run(parent, "{ invoice { number } }", version: "nope", root: root(resolved)), "UNKNOWN_API_VERSION", resolved)
  end

  it "[security] COMP7 Schema::Visibility preload: true still serves one version per query" do
    q = vg::Controls::Query.example
    s = Class.new(ArmoryEngine.base_schema) do
      query(q)
      use GraphQL::Schema::Visibility, preload: true
      use GraphQL::Armory::Versioning, versions: VERSIONING_PROBE_LABELS, retired: RETIRED, default: :latest
    end
    resolved = []
    r = run(s, "{ invoice { tags } }", version: "2024-06-01", root: root(resolved))
    i = run(s, '{ __type(name: "Invoice") { fields(includeDeprecated: true) { name } } }', version: "2025-01-01")
    expect(r["errors"]).not_to be_nil
    expect(resolved).to eq([])
    expect(i.dig("data", "__type", "fields").map { |f| f["name"] }).not_to include("amount")
  end

  it "[security] COMP8 dynamic profiles: a query with no profile is versioned; a named profile fails closed" do
    q = vg::Controls::Query.example
    s = Class.new(ArmoryEngine.base_schema) do
      query(q)
      use GraphQL::Schema::Visibility, profiles: { staff: {} }, dynamic: true
      use GraphQL::Armory::Versioning, versions: VERSIONING_PROBE_LABELS, retired: RETIRED, default: :latest
    end
    resolved = []
    r = run(s, "{ invoice { tags } }", version: "2024-06-01", root: root(resolved))
    expect(r["errors"]).not_to be_nil
    staff, error = safely { run(s, "{ invoice { tags } }", version: "2024-06-01", root: root(resolved), context: { visibility_profile: :staff }) }
    puts "COMP8 named profile: #{staff.inspect} #{error.class}: #{error&.message&.slice(0, 160)}"
    expect(resolved).to eq([])
  end

  it "[security] COMP9 no visibility plugin at all still hides" do
    q = vg::Controls::Query.example
    s = gated(q, visibility: :none)
    resolved = []
    r = run(s, "{ invoice { tags } }", version: "2024-06-01", root: root(resolved))
    expect(r["errors"]).not_to be_nil
    expect(resolved).to eq([])
  end

  it "[security] COMP10 a type shared by two schemas with different lists resolves each list's order" do
    q = vg::Controls::Query.example
    s1 = gated(q, versions: %w[2024-06-01 2025-01-01], retired: [])
    s2 = gated(q, versions: %w[2023-01-01 2024-01-15 2024-06-01 2025-01-01 2026-01-01], retired: %w[2023-01-01])
    resolved = []
    expect(run(s1, "{ invoice { tags } }", version: "2024-06-01", root: root(resolved))["errors"]).not_to be_nil
    expect(run(s2, "{ invoice { tags } }", version: "2024-06-01", root: root(resolved))["errors"]).not_to be_nil
    expect(run(s2, "{ invoice { amount } }", version: "2026-01-01", root: root(resolved))["errors"]).not_to be_nil
    expect(resolved).to eq([])
    expect(run(s2, "{ invoice { tags } }", version: "2026-01-01", root: root([])).dig("data", "invoice", "tags")).to eq(%w[paid urgent])
    expect(run(s1, "{ invoice { amount } }", version: "2024-06-01", root: root([])).dig("data", "invoice", "amount")).to eq(100)
  end

  it "[security] COMP11 a field class with its own initialize and visible? (calling super) keeps versioning" do
    fc = Class.new(GraphQL::Schema::Field) do
      include GraphQL::Armory::Versioning::Base
      def initialize(*args, beta: false, **kwargs, &block)
        @beta = beta
        super(*args, **kwargs, &block)
      end

      def visible?(context) = super && (!@beta || context[:beta] == true)
    end
    sub = Class.new(fc) { def visible?(context) = super && true }
    inv = Class.new(GraphQL::Schema::Object) do
      graphql_name "Invoice"
      field_class sub
      field :number, String, null: false
      field :tags, [String], null: false, added: "2025-01-01", beta: true
    end
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :invoice, inv, null: false }
    s = gated(q)
    puts "COMP11 visible? owner: #{sub.instance_method(:visible?).owner == sub}, chain: #{sub.ancestors.take(5).inspect}"
    resolved = []
    r = run(s, "{ invoice { tags } }", version: "2024-06-01", root: root(resolved), context: { beta: true })
    expect(r["errors"]).not_to be_nil
    expect(resolved).to eq([])
    expect(run(s, "{ invoice { tags } }", version: "2025-01-01", root: root([]), context: { beta: true }).dig("data", "invoice", "tags")).to eq(%w[paid urgent])
  end

  # --- BLD: build and configuration --------------------------------------------------------------------------------

  it "[security] BLD1 every invalid use setting raises when the schema loads" do
    bad = [
      { versions: [], default: :latest },
      { versions: "2024-01-15", default: :latest },
      { versions: nil, default: :latest },
      { versions: %w[a a], default: :latest },
      { versions: ["a", :b], default: :latest },
      { versions: ["a", ""], default: :latest },
      { versions: [1, 2], default: :latest },
      { versions: %w[2025-01-01 2024-01-01], default: :latest },
      { versions: %w[a b], retired: %w[b], default: :latest },
      { versions: %w[a b], retired: %w[a b], default: :latest },
      { versions: %w[a b], retired: %w[x], default: :latest },
      { versions: %w[a b], retired: "a", default: :latest },
      { versions: %w[a b], retired: nil, default: :latest },
      { versions: %w[a b], retired: %w[a], default: "a" },
      { versions: %w[a b], default: "c" },
      { versions: %w[a b], default: nil },
      { versions: %w[a b], default: :oldest },
      { versions: %w[a b], default: :LATEST },
      { versions: %w[a b], default: "latest" },
      { versions: %w[a b] },
      { versions: %w[a b], default: :latest, sinks: [1] },
      { versions: %w[a b], default: :latest, sinks: :x },
    ]
    accepted = bad.reject do |opts|
      Class.new(GraphQL::Schema) { use GraphQL::Armory::Versioning, **opts }
      false
    rescue GraphQL::Armory::Error
      true
    end
    expect(accepted).to eq([])
  end

  it "[security] BLD6 an undeclared label or removed before added fails closed at query time" do
    vf = vfield
    %w[2099-01-01 2024-01-15].zip([nil, "2024-06-01"]).each do |added, removed_rev|
      inv = Class.new(GraphQL::Schema::Object) do
        graphql_name "Invoice"
        field_class vf
        field :number, String, null: false
        if removed_rev
          field :f, String, null: true, added: "2025-01-01", removed: removed_rev
        else
          field :f, String, null: true, added: added
        end
      end
      q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :invoice, inv, null: false }
      s = gated(q)
      resolved = []
      rt = Struct.new(:invoice).new(Class.new { define_method(:f) { resolved << :f; "F" }; define_method(:number) { "n" } }.new)
      r, error = safely { run(s, "{ invoice { f } }", version: "2025-01-01", root: rt) }
      i, ierror = safely { run(s, '{ __type(name: "Invoice") { fields { name } } }', version: "2025-01-01") }
      expect(resolved).to eq([]), r.inspect
      expect(error).to be_a(vg::ConfigurationError)
      expect(i&.dig("data", "__type", "fields")).to be_nil
      expect(ierror).to be_a(vg::ConfigurationError)
    end
  end

  it "[preservation] BLD8 labels mutated by the app after use do not change the schema's list" do
    label = +"2025-01-01"
    list = ["2024-06-01", label]
    q = vg::Controls::Query.example
    s = gated(q, versions: list, retired: [])
    label.replace("2099-01-01")
    list << "2030-01-01"
    expect(run(s, "{ invoice { tags } }", version: "2025-01-01", root: root([])).dig("data", "invoice", "tags")).to eq(%w[paid urgent])
    expect(run(s, "{ invoice { number } }", version: "2030-01-01")["errors"].first.dig("extensions", "code")).to eq("UNKNOWN_API_VERSION")
  end

  it "[preservation] BLD9 non-date labels keep the written order; mixed date and non-date lists are not checked" do
    q = vg::Controls::Query.example
    _s, error = safely { gated(q, versions: %w[2025-01-01 2024-01-15 2024-06-01 beta], retired: []) }
    puts "BLD9 mixed descending list accepted: #{error.nil?}"
    expect(true).to eq(true)
  end

  # --- TEL: telemetry ----------------------------------------------------------------------------------------------

  it "[security] TEL1 exactly one signal per query, with the schema's label or the reason only" do
    signals = []
    s = controls_schema(sinks: [->(sig, data) { signals << [sig, data] }])
    run(s, "{ invoice { number total amount } __type(name: \"Invoice\") { fields { name } } }", version: "2024-06-01", root: root([]))
    run(s, "{ invoice { number } }", root: root([]))
    run(s, "{ invoice { number } }", version: "EVIL<script>2025-01-01", root: root([]))
    run(s, "{ invoice { number } }", version: "2024-01-15", root: root([]))
    expect(signals).to eq([
      [:version_served, { version: "2024-06-01" }],
      [:version_defaulted, { version: "2025-01-01" }],
      [:version_refused, { reason: :unknown }],
      [:version_refused, { reason: :retired }],
    ])
  end

  it "[security] TEL2 multiplex records one signal per query; app-built queries record none" do
    signals = []
    s = controls_schema(sinks: [->(sig, data) { signals << [sig, data] }])
    multiplex(s, [{ query: "{ invoice { number } }", context: { armory_version: "2025-01-01" }, root_value: root([]) },
                  { query: "{ invoice { number } }", context: { armory_version: "x" }, root_value: root([]) },
                  { query: "{ invoice { number } }", context: {}, root_value: root([]) }])
    expect(signals.map(&:first)).to eq(%i[version_served version_refused version_defaulted])
    signals.clear
    GraphQL::Query.new(s, "{ invoice { number total } }", context: { armory_version: "2025-01-01" }, root_value: root([])).result
    expect(signals).to eq([])
  end

  it "[security] TEL3 a raising sink does not change the decision; on_sink_error hears it" do
    heard = []
    s = controls_schema(sinks: [->(_s, _d) { raise "sink down" }], on_sink_error: ->(e, sig) { heard << [e.message, sig] })
    resolved = []
    expect_refused(run(s, "{ invoice { number } }", version: "x", root: root(resolved)), "UNKNOWN_API_VERSION", resolved)
    expect(run(s, "{ invoice { tags } }", version: "2025-01-01", root: root([])).dig("data", "invoice", "tags")).to eq(%w[paid urgent])
    expect(heard.map(&:last)).to eq(%i[version_refused version_served])
  end

  it "[security] TEL4 a raising on_sink_error fails closed: nothing resolves" do
    s = controls_schema(sinks: [->(_s, _d) { raise "sink down" }], on_sink_error: ->(e, _sig) { raise e })
    resolved = []
    r, error = safely { run(s, "{ invoice { number } }", version: "x", root: root(resolved)) }
    puts "TEL4 #{r.inspect} #{error.class}"
    expect(resolved).to eq([])
  end

  it "[security] TEL5 to_definition and Schema.validate record one signal each" do
    skip "this graphql with json 3.1 cannot print a String argument" unless ArmoryJsonPrinting.prints_strings?
    signals = []
    s = controls_schema(sinks: [->(sig, data) { signals << [sig, data] }])
    s.to_definition(context: { armory_version: "2024-06-01" })
    s.validate("{ invoice { number } }", context: { armory_version: "2025-01-01" })
    expect(signals).to eq([[:version_served, { version: "2024-06-01" }], [:version_served, { version: "2025-01-01" }]])
  end

  it "[security] TEL6 a three-argument sink gets a context view, never the raw value in data" do
    seen = []
    s = controls_schema(sinks: [->(sig, data, ctx) { seen << [sig, data, ctx[:armory_version]] }])
    run(s, "{ invoice { number } }", version: "nope-123", root: root([]))
    expect(seen).to eq([[:version_refused, { reason: :unknown }, "nope-123"]])
  end

  # --- VER: Versioning.version(context) ----------------------------------------------------------------------------

  it "[preservation] VER1 Versioning.version from a resolver: label, comparisons, unknown label raises" do
    seen = []
    probe = Class.new(GraphQL::Schema::Resolver) do
      type String, null: false
      define_method(:resolve) do
        v = GraphQL::Armory::Versioning.version(context)
        seen << [v.label, v < "2025-01-01", v >= "2024-06-01"]
        begin
          v < "2099-01-01"
        rescue GraphQL::Armory::Versioning::UnknownVersionError
          seen << :unknown_raised
        end
        "ok"
      end
    end
    q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :probe, resolver: probe }
    s = gated(q)
    run(s, "{ probe }", version: "2024-06-01")
    run(s, "{ probe }")
    expect(seen).to eq([["2024-06-01", true, true], :unknown_raised, ["2025-01-01", false, true], :unknown_raised])
  end

  it "[preservation] CTX1 a frozen context Hash still works" do
    r = run(controls_schema, "{ invoice { amount } }", root: root([]), context: { armory_version: "2024-06-01" }.freeze)
    expect(r.dig("data", "invoice", "amount")).to eq(100)
  end

  it "[preservation] CTX2 observation: a String \"armory_version\" key" do
    signals = []
    s = controls_schema(sinks: [->(sig, data) { signals << [sig, data] }])
    r = execute_query(s, "{ invoice { amount } }", root_value: root([]), context: { "armory_version" => "2024-06-01" }).to_h
    puts "CTX2 string key: #{r.inspect} #{signals.inspect}"
    expect(true).to eq(true)
  end

  it "[preservation] DOC1 observation: unversioned fields of a Base field class under a refused app-built query and a named profile" do
    schema = controls_schema
    resolved = []
    q = GraphQL::Query.new(schema, "{ invoice { number } }", context: { armory_version: "bogus" }, root_value: root(resolved))
    r, error = safely { q.result.to_h }
    puts "DOC1 app-built refused, unversioned Base field: #{r.inspect} #{error.class} resolved=#{resolved.inspect}"
    qt = vg::Controls::Query.example
    s = Class.new(ArmoryEngine.base_schema) do
      query(qt)
      use GraphQL::Schema::Visibility, profiles: { staff: {} }, dynamic: true
      use GraphQL::Armory::Versioning, versions: VERSIONING_PROBE_LABELS, retired: RETIRED, default: :latest
    end
    r2, e2 = safely { run(s, "{ invoice { number } }", version: "2024-06-01", root: root([]), context: { visibility_profile: :staff }) }
    puts "DOC1 named profile, unversioned Base field: #{r2.inspect} #{e2.class}"
    expect(true).to eq(true)
  end
end
