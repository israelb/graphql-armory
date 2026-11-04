# frozen_string_literal: true

# Probes from the independent verification of PR #70 (versioning increment 2b3a: twins), kept as regressions.
# Each `it` is labelled "security" (exactly the right twin, or no data a rule refuses) or "preservation".
# TW_V1 = 2024-06-01, TW_V2 = 2025-01-01 (latest); 2024-01-15 retired.
RSpec.describe "Regression probes: versioning twins (2b3a)" do
  TW_V1 = "2024-06-01"
  TW_V2 = "2025-01-01"
  TW_LABELS = %w[2024-01-15 2024-06-01 2025-01-01].freeze
  TW_RETIRED = %w[2024-01-15].freeze

  let(:calls) { [] }
  let(:cfg) { GraphQL::Armory::Versioning::ConfigurationError }
  let(:az) { GraphQL::Armory::Authorization }

  def record(**values) = Struct.new(*values.keys, keyword_init: true).new(**values)

  def adapter(allowed)
    Class.new(GraphQL::Armory::Authorization::Adapters::Substitute) do
      define_method(:authorized?) { |_actor, _subject, rule| allowed.include?(rule.action) }
    end.new
  end

  def bases(order: :versioning_first)
    mods = [GraphQL::Armory::Versioning::Base, GraphQL::Armory::Authorization::Base]
    mods = mods.reverse if order == :authz_first
    argument = Class.new(GraphQL::Schema::Argument) { mods.each { |mod| include mod } }
    field = Class.new(GraphQL::Schema::Field) { mods.each { |mod| include mod }; argument_class(argument) }
    object = Class.new(GraphQL::Schema::Object) { mods.each { |mod| include mod }; field_class(field) }
    interface = Module.new do
      include GraphQL::Schema::Interface
      include GraphQL::Armory::Versioning::Base
      field_class(field)
    end
    input = Class.new(GraphQL::Schema::InputObject) { mods.each { |mod| include mod }; argument_class(argument) }
    value = Class.new(GraphQL::Schema::EnumValue) { include GraphQL::Armory::Versioning::Base }
    enum = Class.new(GraphQL::Schema::Enum) { include GraphQL::Armory::Versioning::Base; enum_value_class(value) }
    resolver = Class.new(GraphQL::Schema::Resolver) { mods.each { |mod| include mod }; argument_class(argument) }
    payload = Class.new(object) { authorize :none, reason: "payload", covers_fields: true }
    mutation = Class.new(GraphQL::Schema::Mutation) { mods.each { |mod| include mod }; argument_class(argument); field_class(field); object_class(payload) }
    { argument: argument, field: field, object: object, interface: interface, input: input, enum: enum, resolver: resolver, mutation: mutation }
  end

  def schema_over(query_type, visibility, allowed: %i[read], subscription: nil, mutation: nil, authz: true)
    plugin = { visibility: GraphQL::Schema::Visibility, warden: GraphQL::Schema::Warden }.fetch(visibility)
    adp = adapter(allowed)
    Class.new(ArmoryEngine.base_schema) do
      query(query_type)
      mutation(mutation) if mutation
      subscription(subscription) if subscription
      use plugin
      use GraphQL::Armory::Versioning, versions: TW_LABELS, retired: TW_RETIRED, default: :latest
      use GraphQL::Armory::Authorization, adapter: adp if authz
    end
  end

  def run(schema, text, version, root: nil, variables: {})
    execute_query(schema, text, root_value: root, variables: variables, context: { armory_version: version }).to_h
  end

  def attempt
    [:ok, yield]
  rescue StandardError => e
    [e.class.name.split("::").last, e.message[0, 160]]
  end

  def messages(result) = Array(result["errors"]).map { |e| e["message"] }

  # A root whose methods record what they receive.
  def recorder(**answers)
    log = calls
    Class.new do
      answers.each do |name, answer|
        define_method(name) do |**kw|
          log << [name, kw.transform_values { |v| v.respond_to?(:to_h) && !v.is_a?(Hash) && !v.is_a?(Array) && !v.nil? && !v.is_a?(Symbol) ? v.to_h : v }]
          answer.respond_to?(:call) ? answer.(**kw) : answer
        end
      end
    end.new
  end

  def query_root(b, &block)
    Class.new(b[:object]) do
      graphql_name "Query"
      authorize :none, reason: "probe", covers_fields: true
      class_exec(&block)
    end
  end

  %i[visibility warden].each do |visibility|
    context "with #{visibility}" do
      let(:vis) { visibility }

      # ------------------------------------------------------------------ paths: variables, inputs, enums
      it "security T1: argument twins through variables: each version coerces with its own twin, the other's shape is refused" do
        b = bases
        q = query_root(b) do
          field :echo, String, null: true do
            argument :first, Integer, required: false, removed: TW_V2
            argument :first, String, required: false, added: TW_V2
          end
        end
        s = schema_over(q, vis)
        r = recorder(echo: ->(first: nil) { first.class.name })
        a = run(s, "query($f: Int) { echo(first: $f) }", TW_V1, root: r, variables: { "f" => 3 })
        c = run(s, "query($f: String) { echo(first: $f) }", TW_V2, root: r, variables: { "f" => "3" })
        bad1 = run(s, "query($f: String) { echo(first: $f) }", TW_V1, root: r, variables: { "f" => "3" })
        bad2 = run(s, "query($f: Int) { echo(first: $f) }", TW_V2, root: r, variables: { "f" => 3 })
        expect([a["data"], c["data"]]).to eq([{ "echo" => "Integer" }, { "echo" => "String" }])
        expect([bad1.key?("errors"), bad2.key?("errors")]).to eq([true, true])
        expect(calls.map(&:last)).to eq([{ first: 3 }, { first: "3" }])
      end

      it "security T2: input-object field twins, literal and variable, per version" do
        b = bases
        filter = Class.new(b[:input]) do
          graphql_name "Filter"
          argument :since, Integer, required: false, removed: TW_V2
          argument :since, String, required: false, added: TW_V2
        end
        q = query_root(b) do
          field :search, String, null: true do
            argument :filter, filter, required: true
          end
        end
        s = schema_over(q, vis)
        r = recorder(search: ->(filter:) { filter[:since].class.name })
        out = [
          run(s, "{ search(filter: { since: 1 }) }", TW_V1, root: r),
          run(s, '{ search(filter: { since: "1" }) }', TW_V2, root: r),
          run(s, "query($f: Filter!) { search(filter: $f) }", TW_V1, root: r, variables: { "f" => { "since" => 1 } }),
          run(s, "query($f: Filter!) { search(filter: $f) }", TW_V2, root: r, variables: { "f" => { "since" => "1" } })
        ]
        bad = [
          attempt { run(s, '{ search(filter: { since: "1" }) }', TW_V1, root: r) },
          attempt { run(s, "{ search(filter: { since: 1 }) }", TW_V2, root: r) },
          attempt { run(s, "query($f: Filter!) { search(filter: $f) }", TW_V1, root: r, variables: { "f" => { "since" => "1" } }) },
          attempt { run(s, "query($f: Filter!) { search(filter: $f) }", TW_V2, root: r, variables: { "f" => { "since" => 1 } }) }
        ]
        warn "T2 #{vis} bad: #{bad.map { |st, x| st == :ok ? x.keys : [st, x[0, 40]] }.inspect}"
        expect(out.map { |o| o.dig("data", "search") }).to eq(%w[Integer String Integer String])
        # graphql 2.4 with json 3.1 raises ArgumentError (quirks_mode) printing a String literal in its own error: refused anyway.
        expect(bad.map { |st, x| st == :ok ? x.key?("errors") : (st == "ArgumentError" && x.include?("quirks")) }).to eq([true, true, true, true])
        expect(calls.size).to eq(4)
      end

      it "security T3: enum twins with different Ruby values: input (literal, variable) and results per version" do
        b = bases
        kind = Class.new(b[:enum]) do
          graphql_name "Kind"
          value "VOID", value: :old, removed: TW_V2
          value "VOID", value: :new, value_method: false, added: TW_V2
        end
        q = query_root(b) do
          field :echo, String, null: true do
            argument :k, kind, required: true
          end
          field :kind, kind, null: true
        end
        s = schema_over(q, vis)
        r = recorder(echo: ->(k:) { k.inspect })
        lit = [TW_V1, TW_V2].map { |v| run(s, "{ echo(k: VOID) }", v, root: r).dig("data", "echo") }
        var = [TW_V1, TW_V2].map { |v| run(s, "query($k: Kind!) { echo(k: $k) }", v, root: r, variables: { "k" => "VOID" }).dig("data", "echo") }
        expect([lit, var]).to eq([[":old", ":new"], [":old", ":new"]])
        res = [[TW_V1, :old], [TW_V2, :new]].map { |v, val| run(s, "{ kind }", v, root: record(kind: val)) }
        expect(res.map { |x| x.dig("data", "kind") }).to eq(%w[VOID VOID])
        cross = [[TW_V1, :new], [TW_V2, :old]].map { |v, val| attempt { run(s, "{ kind }", v, root: record(kind: val)) } }
        warn "T3 #{vis} cross-version enum results: #{cross.inspect}"
        expect(cross.map { |st, x| st == :ok && x.dig("data", "kind") == "VOID" }).to eq([false, false])
      end

      it "security T4: resolver-class and mutation argument twins, per version" do
        b = bases
        res = Class.new(b[:resolver]) do
          graphql_name "EchoResolver"
          authorize :none, reason: "probe"
          type String, null: true
          argument :first, Integer, required: false, removed: TW_V2
          argument :first, String, required: false, added: TW_V2
          def resolve(first: nil) = first.class.name
        end
        mut = Class.new(b[:mutation]) do
          graphql_name "Bump"
          authorize :none, reason: "probe"
          argument :by, Integer, required: true, removed: TW_V2
          argument :by, String, required: true, added: TW_V2
          field :seen, String, null: true
          def resolve(by:) = Struct.new(:seen).new(by.class.name)
        end
        q = query_root(b) { field :echo, resolver: res, authorize: :none, reason: "probe" }
        m = Class.new(b[:object]) { graphql_name "Mutation"; authorize :none, reason: "probe", covers_fields: true; field :bump, mutation: mut, authorize: :none, reason: "probe" }
        s = schema_over(q, vis, mutation: m)
        out = [run(s, "{ echo(first: 1) }", TW_V1), run(s, '{ echo(first: "1") }', TW_V2),
               run(s, "mutation { bump(by: 1) { seen } }", TW_V1), run(s, 'mutation { bump(by: "1") { seen } }', TW_V2)]
        warn "T4 #{vis}: #{out.inspect}"
        # The payload's fields answer null under this harness's rules with or without twins (see T6's control): only
        # which argument twin was accepted is asserted for the mutation.
        expect(out.map { |o| o["data"]&.values&.first }).to eq(["Integer", "String", { "seen" => nil }, { "seen" => nil }])
        expect(out.map { |o| o.key?("errors") }).to eq([false, false, false, false])
        bad = [attempt { run(s, '{ echo(first: "1") }', TW_V1) }, attempt { run(s, "{ echo(first: 1) }", TW_V2) },
               attempt { run(s, 'mutation { bump(by: "1") { seen } }', TW_V1) }, attempt { run(s, "mutation { bump(by: 1) { seen } }", TW_V2) }]
        # graphql 2.4 with json 3.1 raises ArgumentError (quirks_mode) printing a String literal in its own error: refused anyway.
        expect(bad.map { |st, x| st == :ok ? x.key?("errors") : (st == "ArgumentError" && x.include?("quirks")) }).to eq([true, true, true, true])
      end

      it "security T5: interface field twins inherited by an implementer, through the object, a fragment and introspection" do
        b = bases
        priced = Module.new do
          include b[:interface]
          graphql_name "Priced"
          field :price, Integer, null: true, method: :cents, removed: TW_V2
          field :price, String, null: true, method: :text, added: TW_V2
        end
        item = Class.new(b[:object]) { graphql_name "Item"; authorize :none, reason: "probe", covers_fields: true; implements priced }
        q = query_root(b) { field :item, item, null: true; field :priced, priced, null: true }
        s = schema_over(q, vis)
        s.define_singleton_method(:resolve_type) { |_t, _o, _c| item }
        root = record(item: record(cents: 100, text: "1.00"), priced: record(cents: 100, text: "1.00"))
        txt = '{ item { price } priced { price ... on Item { price } } __type(name: "Item") { fields { name type { name } } } }'
        out = [TW_V1, TW_V2].map { |v| run(s, txt, v, root: root) }
        shape = out.map { |o| [o.dig("data", "item", "price"), o.dig("data", "priced", "price"), o.dig("data", "__type", "fields").map { |f| f["type"]["name"] }] }
        expect(shape).to eq([[100, 100, ["Int"]], ["1.00", "1.00", ["String"]]])
      end

      it "security T6: mutation field twins with different mutation classes and payloads" do
        b = bases
        m1 = Class.new(b[:mutation]) { graphql_name "CreateV1"; authorize :none, reason: "probe"; field :id, Integer, null: true; def resolve = Struct.new(:id).new(1) }
        m2 = Class.new(b[:mutation]) { graphql_name "CreateV2"; authorize :none, reason: "probe"; field :uuid, String, null: true; def resolve = Struct.new(:uuid).new("u") }
        m = Class.new(b[:object]) do
          graphql_name "Mutation"
          authorize :none, reason: "probe", covers_fields: true
          field :create, mutation: m1, authorize: :none, reason: "probe", removed: TW_V2
          field :create, mutation: m2, authorize: :none, reason: "probe", added: TW_V2
          field :ctrl, mutation: Class.new(m1) { graphql_name "Ctrl" }, authorize: :none, reason: "probe"
        end
        q = query_root(b) { field :x, String, null: true }
        s = schema_over(q, vis, mutation: m)
        out = [run(s, "mutation { create { id } }", TW_V1), run(s, "mutation { create { uuid } }", TW_V2),
               run(s, "mutation { create { uuid } }", TW_V1), run(s, "mutation { create { id } }", TW_V2)]
        warn "T6 #{vis}: #{out.inspect} control(no twins)=#{run(s, "mutation { ctrl { id } }", TW_V1).inspect}"
        # Payload fields answer null under this harness with or without twins (control): the payload TYPE per version is asserted.
        expect(out[0..1].map { |o| o["data"] }).to eq([{ "create" => { "id" => nil } }, { "create" => { "uuid" => nil } }])
        expect(messages(out[2]).first).to include("CreateV1Payload")
        expect(messages(out[3]).first).to include("CreateV2Payload")
        expect(out[2..3].map { |o| o.key?("errors") }).to eq([true, true])
      end

      # ------------------------------------------------------------------ Authorization on twins
      %i[versioning_first authz_first].each do |order|
        it "security T7 (#{order}): visible_when: on the V twin refuses; the other twin is never served in V" do
          b = bases(order: order)
          doc = Class.new(b[:object]) do
            graphql_name "Doc"
            authorize :read, model: Object
            field :secret, Integer, null: true, method: :cents, visible_when: :manage, removed: TW_V2
            field :secret, String, null: true, method: :text, visible_when: :read, added: TW_V2
          end
          q = query_root(b) { field :doc, doc, null: true, authorize: :none, reason: "probe" }
          s = schema_over(q, vis, allowed: %i[read])
          root = record(doc: record(cents: 100, text: "LEAK"))
          v1 = run(s, "{ doc { secret } }", TW_V1, root: root)
          v1i = run(s, '{ __type(name: "Doc") { fields { name } } }', TW_V1)
          v2 = run(s, "{ doc { secret } }", TW_V2, root: root)
          warn "T7 #{vis} #{order} owner=#{b[:field].instance_method(:visible?).owner} v1=#{v1.inspect}"
          expect(v1.to_s).not_to include("LEAK")
          expect(v1.dig("data", "doc", "secret")).to be_nil
          expect(v1i.dig("data", "__type", "fields").map { |f| f["name"] }).not_to include("secret")
          expect(v2.dig("data", "doc", "secret")).to eq("LEAK")
        end

        it "security T8 (#{order}): authorize: on the V twin refuses at runtime; the other twin's method never runs in V" do
          b = bases(order: order)
          log = calls
          doc = Class.new(b[:object]) do
            graphql_name "Doc"
            authorize :read, model: Object
            field :secret, Integer, null: true, authorize: :manage, removed: TW_V2
            field :secret, String, null: true, authorize: :read, added: TW_V2
          end
          q = query_root(b) { field :doc, doc, null: true, authorize: :none, reason: "probe" }
          s = schema_over(q, vis, allowed: %i[read])
          src = Class.new { define_method(:secret) { log << :secret; 100 } }.new
          root = record(doc: src)
          v1 = run(s, "{ doc { secret } }", TW_V1, root: root)
          warn "T8 #{vis} #{order} v1=#{v1.inspect} calls=#{calls.inspect}"
          expect(v1.dig("data", "doc", "secret")).to be_nil
          expect(calls).to eq([])
          v2 = run(s, "{ doc { secret } }", TW_V2, root: root)
          expect(v2.dig("data", "doc", "secret")).to eq("100")
        end

        it "security T9 (#{order}): visible_when: on an argument twin: a refused user cannot pass it in V" do
          b = bases(order: order)
          doc = Class.new(b[:object]) do
            graphql_name "Doc"
            authorize :read, model: Object
            field :find, String, null: true, authorize: :read do
              argument :key, Integer, required: false, visible_when: :manage, removed: TW_V2
              argument :key, String, required: false, added: TW_V2
            end
            define_method(:find) { |key: nil| "got #{key.inspect}" }
          end
          q = query_root(b) { field :doc, doc, null: true, authorize: :none, reason: "probe" }
          s = schema_over(q, vis, allowed: %i[read])
          root = record(doc: record(x: 1))
          out = [run(s, "{ doc { find(key: 1) } }", TW_V1, root: root), run(s, '{ doc { find(key: "1") } }', TW_V1, root: root)]
          warn "T9 #{vis} #{order}: #{out.inspect}"
          expect(out.map { |o| o.dig("data", "doc", "find").to_s }).not_to include(a_string_including("got 1"), a_string_including('got "1"'))
        end
      end

      it "security T10: parent definition + child twins: Warden falls back for a refused user (pre-existing), and the audit reports the twins" do
        b = bases
        parent = Class.new(b[:object]) do
          graphql_name "DocParent"
          authorize :read, model: Object
          field :secret, String, null: true, method: :plain
        end
        doc = Class.new(parent) do
          graphql_name "Doc"
          authorize :read, model: Object
          field :secret, String, null: true, method: :hidden, visible_when: :manage, removed: TW_V2
          field :secret, String, null: true, method: :hidden, visible_when: :manage, added: TW_V2
        end
        q = query_root(b) { field :doc, doc, null: true, authorize: :none, reason: "probe" }
        s = schema_over(q, vis, allowed: %i[read])
        root = record(doc: record(plain: "PARENT", hidden: "CHILD"))
        v1 = run(s, "{ doc { secret } }", TW_V1, root: root)
        warn "T10 #{vis} refused user V1: #{v1.inspect}"
        report = GraphQL::Armory::Authorization::Audit.(s)
        ignored = report.problems.select { |p| p.kind == :ignored_rule }.map(&:path).uniq
        warn "T10 #{vis} ignored_rule: #{ignored.inspect}"
        expect(v1.to_s).not_to include("CHILD")
        expect(ignored).to include("Doc.secret") if vis == :warden
      end

      # ------------------------------------------------------------------ audit
      it "security T11: audit: three definitions where two overlap, resolver argument twins over a parent's, input twins over a parent's, twins on a parent level" do
        b = bases
        three = Class.new(b[:object]) do
          graphql_name "Three"
          authorize :read, model: Object
          field :total, Integer, null: true, removed: TW_V2
          field :total, String, null: true, added: TW_V2
          field :total, Float, null: true, added: TW_V2
        end
        pres = Class.new(b[:resolver]) do
          graphql_name "PRes"
          type String, null: true
          argument :first, Integer, required: false
          def resolve(**) = "x"
        end
        cres = Class.new(pres) do
          graphql_name "CRes"
          argument :first, Integer, required: false, removed: TW_V2
          argument :first, String, required: false, added: TW_V2
        end
        pin = Class.new(b[:input]) { graphql_name "PIn"; argument :since, Integer, required: false }
        cin = Class.new(pin) do
          graphql_name "CIn"
          argument :since, Integer, required: false, removed: TW_V2
          argument :since, String, required: false, added: TW_V2
        end
        tparent = Class.new(b[:object]) do
          graphql_name "TParent"
          authorize :read, model: Object
          field :total, Integer, null: true, removed: TW_V2
          field :total, String, null: true, added: TW_V2
        end
        tchild = Class.new(tparent) { graphql_name "TChild"; authorize :read, model: Object; field :total, String, null: true, authorize: :manage }
        q = query_root(b) do
          field :three, three, null: true, authorize: :none, reason: "p"
          field :tchild, tchild, null: true, authorize: :none, reason: "p"
        end
        s = schema_over(q, vis)
        audit = attempt { GraphQL::Armory::Authorization::Audit.(s).problems.select { |p| p.kind == :ignored_rule }.map(&:path).uniq.sort }
        warn "T11 #{vis} ignored_rule: #{audit.inspect}"
        # Either reported, or the overlapping definitions refuse the audit itself (fail closed).
        expect(audit.first == :ok ? audit.last : %w[Three.total TChild.total]).to include("Three.total", "TChild.total")
        expect(audit.first).to eq(:ok).or eq("ConfigurationError")
        q2 = query_root(b) do
          field :cres, resolver: cres, authorize: :none, reason: "p"
          field :cin, String, null: true do
            argument :i, cin, required: false
          end
        end
        s2 = schema_over(q2, vis)
        audit2 = attempt { GraphQL::Armory::Authorization::Audit.(s2).problems.select { |p| p.kind == :ignored_rule }.map(&:path).uniq.sort }
        runs = [attempt { run(s2, "{ cres }", TW_V1) }, attempt { run(s2, "{ cin(i: { since: 1 }) }", TW_V1, root: record(cin: "x")) }]
        warn "T11b #{vis} resolver/input twins over a parent's: audit=#{audit2.inspect} runs=#{runs.inspect}"
        # Either the audit names them, or versioning refuses them before any query runs.
        expect(audit2.first == :ok ? (audit2.last.grep(/first/).any? && audit2.last.grep(/since/).any?) : true).to eq(true)
        expect(runs.map(&:first)).to eq(%w[ConfigurationError ConfigurationError])
      end

      it "preservation T12: audit: twins with override_reason: and nothing falling back are named; a lone twin pair reports nothing" do
        b = bases
        doc = Class.new(b[:object]) do
          graphql_name "Doc"
          authorize :read, model: Object
          field :total, Integer, null: true, removed: TW_V2, override_reason: "probe"
          field :total, String, null: true, added: TW_V2
        end
        q = query_root(b) { field :doc, doc, null: true, authorize: :none, reason: "p" }
        report = GraphQL::Armory::Authorization::Audit.(schema_over(q, vis))
        found = report.problems.select { |p| p.kind == :ignored_rule }.map { |p| [p.path, p.message[0, 50]] }
        warn "T12 #{vis}: #{found.inspect}"
        expect(found.map(&:first)).to eq(["Doc.total"])
        expect(found.first.last).to include("nothing falls back")
      end

      it "security T13: audit judges each twin: a twin without a rule on a bypassed type is reported, and denied at runtime" do
        b = bases
        doc = Class.new(b[:object]) do
          graphql_name "Doc"
          authorize :none, reason: "public type"
          field :total, Integer, null: true, authorize: :read, removed: TW_V2
          field :total, String, null: true, added: TW_V2
        end
        q = query_root(b) { field :doc, doc, null: true, authorize: :none, reason: "p" }
        s = schema_over(q, vis)
        report = GraphQL::Armory::Authorization::Audit.(s)
        kinds = report.problems.map { |p| [p.kind, p.path] }
        warn "T13 #{vis}: #{kinds.inspect}"
        expect(kinds).to include([:field_without_rule, "Doc.total"])
        v2 = run(s, "{ doc { total } }", TW_V2, root: record(doc: record(total: "OPEN")))
        warn "T13 #{vis} runtime v2: #{v2.inspect}"
        expect(v2.dig("data", "doc", "total")).to be_nil
      end

      it "preservation T14: Authorization without Versioning still reports two definitions on one level (disjoint? is false)" do
        fc = Class.new(GraphQL::Schema::Field) { include GraphQL::Armory::Authorization::Base }
        obj = Class.new(GraphQL::Schema::Object) { include GraphQL::Armory::Authorization::Base; field_class(fc) }
        doc = Class.new(obj) do
          graphql_name "Doc"
          authorize :read, model: Object
          field :total, Integer, null: true
          field :total, String, null: true, authorize: :manage
        end
        q = Class.new(obj) { graphql_name "Query"; authorize :none, reason: "p", covers_fields: true; field :doc, doc, null: true, authorize: :none, reason: "p" }
        adp = adapter(%i[read])
        plugin = { visibility: GraphQL::Schema::Visibility, warden: GraphQL::Schema::Warden }.fetch(vis)
        s = Class.new(ArmoryEngine.base_schema) { query(q); use plugin; use GraphQL::Armory::Authorization, adapter: adp }
        report = GraphQL::Armory::Authorization::Audit.(s)
        expect(report.problems.select { |p| p.kind == :ignored_rule }.map(&:path).uniq).to eq(["Doc.total"])
        expect(GraphQL::Armory::Versioning.disjoint?(s, doc.own_fields["total"])).to eq(false)
      end

      # ------------------------------------------------------------------ overlap detection gaps
      it "security T15: argument twins, one unversioned: refused in the overlapping version" do
        b = bases
        q = query_root(b) do
          field :echo, String, null: true do
            argument :first, Integer, required: false
            argument :first, String, required: false, added: TW_V2
          end
        end
        s = schema_over(q, vis)
        r = recorder(echo: "x")
        out = [attempt { run(s, "{ echo(first: 1) }", TW_V1, root: r) }, attempt { run(s, "{ echo(first: 1) }", TW_V2, root: r) }]
        warn "T15 #{vis}: #{out.inspect}"
        expect(out[1].first).to eq("ConfigurationError").or eq("DuplicateNamesError")
        expect(out[0]).to eq([:ok, { "data" => { "echo" => "x" } }])
      end

      it "security T16: a twin without Base beside one with Base: never both served" do
        b = bases
        q = query_root(b) do
          add_field(GraphQL::Schema::Field.new(name: :total, type: Integer, null: true, owner: self))
          field :total, String, null: true, added: TW_V2
        end
        s = schema_over(q, vis)
        root = record(total: 5)
        out = [attempt { run(s, "{ total }", TW_V1, root: root) }, attempt { run(s, "{ total }", TW_V2, root: root) }]
        warn "T16 #{vis}: #{out.inspect}"
        expect(out[0]).to eq([:ok, { "data" => { "total" => 5 } }])
        expect(out[1].first).to eq("ConfigurationError").or eq("DuplicateNamesError")
      end

      it "security T17: a twin added to the owner after the first query (memoized twins) is still refused when it overlaps" do
        b = bases
        q = query_root(b) { field :total, Integer, null: true, removed: TW_V2 }
        s = schema_over(q, vis)
        root = record(total: 5)
        first = run(s, "{ total }", TW_V1, root: root)
        q.field :total, String, null: true, added: TW_V1
        later = [attempt { run(s, "{ total }", TW_V1, root: root) }, attempt { run(s, "{ total }", TW_V2, root: root) }]
        warn "T17 #{vis}: first=#{first.inspect} later=#{later.inspect}"
        expect(later[0].first).to eq("ConfigurationError").or eq("DuplicateNamesError")
        expect(later[1]).to eq([:ok, { "data" => { "total" => "5" } }])
      end

      it "security T18: argument twins disjoint only through their types' lifecycles: never both served, never the wrong one" do
        b = bases
        old_in = Class.new(b[:input]) { graphql_name "OldIn"; lifecycle removed: TW_V2; argument :a, Integer, required: false }
        new_in = Class.new(b[:input]) { graphql_name "NewIn"; lifecycle added: TW_V2; argument :b, Integer, required: false }
        q = query_root(b) do
          field :echo, String, null: true do
            argument :f, old_in, required: false
            argument :f, new_in, required: false
          end
        end
        s = schema_over(q, vis)
        r = recorder(echo: ->(f: nil) { f.to_h.inspect })
        out = [attempt { run(s, "{ echo(f: { a: 1 }) }", TW_V1, root: r) }, attempt { run(s, "{ echo(f: { b: 1 }) }", TW_V2, root: r) },
               attempt { run(s, "{ echo(f: { b: 1 }) }", TW_V1, root: r) }]
        warn "T18 #{vis} (type-disjoint twins): #{out.inspect}"
        echoes = out.map { |st, x| st == :ok ? x.dig("data", "echo") : st }
        expect([echoes[0], echoes[1]]).to match([a_string_including(":a"), a_string_including(":b")])
        expect(echoes[2]).to be_nil.or(be_a(String).and(satisfy { |e| !e.include?(":b") }))
      end

      it "preservation T19 (advisory probe): overlap refusal does not depend on the user (Authorization first in the chain)" do
        b = bases(order: :authz_first)
        doc = Class.new(b[:object]) do
          graphql_name "Doc"
          authorize :read, model: Object
          field :secret, Integer, null: true, visible_when: :manage
          field :secret, String, null: true, visible_when: :manage, added: TW_V2
        end
        q = query_root(b) { field :doc, doc, null: true, authorize: :none, reason: "probe" }
        root = record(doc: record(secret: 1))
        refused = attempt { run(schema_over(q, vis, allowed: %i[read]), "{ doc { __typename } }", TW_V2, root: root) }
        allowed = attempt { run(schema_over(q, vis, allowed: %i[read manage]), "{ doc { __typename } }", TW_V2, root: root) }
        refused_sel = attempt { run(schema_over(q, vis, allowed: %i[read]), "{ doc { secret } }", TW_V2, root: root) }
        allowed_sel = attempt { run(schema_over(q, vis, allowed: %i[read manage]), "{ doc { secret } }", TW_V2, root: root) }
        warn "T19 #{vis} refused=#{refused.inspect} allowed=#{allowed.inspect} refused_sel=#{refused_sel.inspect} allowed_sel=#{allowed_sel.first}"
        expect(refused_sel.first).to eq(allowed_sel.first)
      end

      # ------------------------------------------------------------------ subscriptions
      it "security T20: subscription argument twins are refused: direct, list of recursive input, and a Subscription class" do
        b = bases
        deep = Class.new(b[:input]) { graphql_name "Deep" }
        deep.argument :next, [deep], required: false
        deep.argument :at, Integer, required: false, removed: TW_V2
        deep.argument :at, String, required: false, added: TW_V2
        outer = Class.new(b[:input]) { graphql_name "Outer"; argument :deep, [deep], required: false }
        subcls = Class.new(GraphQL::Schema::Subscription) do
          graphql_name "OnEvt"
          include GraphQL::Armory::Authorization::Base
          argument_class(b[:argument])
          field_class(b[:field])
          type String, null: true
          argument :n, Integer, required: false, removed: TW_V2
          argument :n, String, required: false, added: TW_V2
        end
        q = query_root(b) { field :x, String, null: true }
        mk = lambda do |&blk|
          Class.new(b[:object]) { graphql_name "Subscription"; authorize :none, reason: "p", covers_fields: true; class_exec(&blk) }
        end
        direct = mk.call do
          field :evt, String, null: true do
            argument :n, Integer, required: false, removed: TW_V2
            argument :n, String, required: false, added: TW_V2
          end
        end
        nested = mk.call { field :evt, String, null: true do argument :o, outer, required: false end }
        klass = mk.call { field :evt, subscription: subcls, authorize: :none, reason: "p" }
        out = { direct: direct, nested: nested, klass: klass }.transform_values do |sub|
          attempt { run(schema_over(q, vis, subscription: sub), "{ __typename }", TW_V2) }
        end
        warn "T20 #{vis}: #{out.inspect}"
        expect(out.values.map(&:first)).to eq(%w[ConfigurationError ConfigurationError ConfigurationError])
      end

      it "security T21: enum twins in a subscription argument are refused (field twins on the subscription root are not)" do
        b = bases
        kind = Class.new(b[:enum]) do
          graphql_name "Kind"
          value "VOID", value: :old, removed: TW_V2
          value "VOID", value: :new, value_method: false, added: TW_V2
        end
        lazy_in = Class.new(b[:input]) { graphql_name "LazyIn"; argument :a, Integer, required: false }
        q = query_root(b) { field :x, String, null: true }
        sub = Class.new(b[:object]) do
          graphql_name "Subscription"
          authorize :none, reason: "p", covers_fields: true
          field :evt, String, null: true do
            argument :k, kind, required: false
          end
          field :tick, Integer, null: true, removed: TW_V2
          field :tick, String, null: true, added: TW_V2
          field :lazy, String, null: true do
            argument :i, lazy_in, required: false
          end
        end
        s = schema_over(q, vis, subscription: sub)
        first = attempt { run(s, "{ __typename }", TW_V2) }
        lazy_in.argument :a, String, required: false, added: TW_V2
        lazy_in.own_arguments["a"].first.instance_variable_set(:@armory_lifecycle, GraphQL::Armory::Versioning::Lifecycle.build(removed: TW_V2)) rescue nil
        later = attempt { run(s, "{ __typename }", TW_V2) }
        coerce = attempt { kind.coerce_isolated_input("VOID") }
        warn "T21 #{vis}: first=#{first.inspect} later(added input twin)=#{later.inspect} context-free VOID=#{coerce.inspect}"
        expect(first.first).to eq("ConfigurationError")
      end

      # ------------------------------------------------------------------ default values
      it "security T22: default values naming an enum twin or an input-field twin" do
        b = bases
        kind = Class.new(b[:enum]) do
          graphql_name "Kind"
          value "VOID", value: :old, removed: TW_V2
          value "VOID", value: :new, value_method: false, added: TW_V2
        end
        filter = Class.new(b[:input]) do
          graphql_name "Filter"
          argument :since, Integer, required: false, removed: TW_V2
          argument :since, String, required: false, added: TW_V2
        end
        q1 = query_root(b) do
          field :echo, String, null: true do
            argument :k, kind, required: false, default_value: :old
          end
        end
        q2 = query_root(b) do
          field :search, String, null: true do
            argument :f, filter, required: false, default_value: { since: 1 }
          end
        end
        r = recorder(echo: ->(k: nil) { k.inspect }, search: ->(f: nil) { f.to_h.inspect })
        out = {
          enum_v1: attempt { run(schema_over(q1, vis), "{ echo }", TW_V1, root: r) },
          enum_v2: attempt { run(schema_over(q1, vis), "{ echo }", TW_V2, root: r) },
          enum_sdl_v1: attempt { schema_over(q1, vis).to_definition(context: { armory_version: TW_V1 })[/k: Kind[^)]*/] },
          input_v1: attempt { run(schema_over(q2, vis), "{ search }", TW_V1, root: r) },
          input_v2: attempt { run(schema_over(q2, vis), "{ search }", TW_V2, root: r) }
        }
        warn "T22 #{vis}: #{out.inspect}"
        # In V2 the default names :old, a twin outside V2: never run with :old.
        expect(out[:enum_v2].to_s).not_to include("\"echo\"=>\":old\"")
        expect(out[:input_v2].to_s).not_to include("data")
      end

      it "preservation T22b: a default naming an enum twin pair that shares its Ruby value runs in both versions" do
        b = bases
        kind = Class.new(b[:enum]) do
          graphql_name "Kind"
          value "VOID", "old", value: :void, removed: TW_V2
          value "VOID", "new", value: :void, value_method: false, added: TW_V2
        end
        q = query_root(b) do
          field :echo, String, null: true do
            argument :k, kind, required: false, default_value: :void
          end
        end
        s = schema_over(q, vis)
        r = recorder(echo: ->(k: nil) { k.inspect })
        out = [TW_V1, TW_V2].map { |v| attempt { run(s, "{ echo }", v, root: r) } }
        warn "T22b #{vis}: #{out.inspect}"
        expect(out).to eq([[:ok, { "data" => { "echo" => ":void" } }]] * 2)
      end

      # ------------------------------------------------------------------ interface + memberships
      it "security T23: interface twins + versioned membership + a parent class that declares the name: refused" do
        b = bases
        membership = Class.new(GraphQL::Schema::TypeMembership) { include GraphQL::Armory::Versioning::Base }
        priced = Module.new do
          include b[:interface]
          graphql_name "Priced"
          type_membership_class(membership)
          field :price, Integer, null: true, removed: TW_V2
          field :price, String, null: true, added: TW_V2
        end
        parent = Class.new(b[:object]) { graphql_name "ItemBase"; authorize :none, reason: "p", covers_fields: true; field :price, Float, null: true }
        item = Class.new(parent) { graphql_name "Item"; authorize :none, reason: "p", covers_fields: true; implements priced, added: TW_V2 }
        q = query_root(b) { field :item, item, null: true }
        out = [TW_V1, TW_V2].map { |v| attempt { run(schema_over(q, vis), "{ item { price } }", v, root: record(item: record(price: 1.5))) } }
        warn "T23 #{vis}: #{out.inspect}"
        expect(out.map(&:first)).to eq(%w[ConfigurationError ConfigurationError])
      end

      it "preservation T24: interface twins + versioned membership + another interface including it: no false refusal of shared twins" do
        b = bases
        membership = Class.new(GraphQL::Schema::TypeMembership) { include GraphQL::Armory::Versioning::Base }
        priced = Module.new do
          include b[:interface]
          graphql_name "Priced"
          type_membership_class(membership)
          field :price, Integer, null: true, removed: TW_V2
          field :price, String, null: true, added: TW_V2
        end
        other = Module.new { include b[:interface]; graphql_name "Other"; type_membership_class(membership); field :price, Integer, null: true, removed: TW_V2; field :price, String, null: true, added: TW_V2 }
        item = Class.new(b[:object]) { graphql_name "Item"; authorize :none, reason: "p", covers_fields: true; implements other; implements priced, added: TW_V2 }
        q = query_root(b) { field :item, item, null: true }
        out = attempt { run(schema_over(q, vis), "{ item { price } }", TW_V2, root: record(item: record(price: "1"))) }
        warn "T24 #{vis} (two interfaces each with their own twins): #{out.inspect}"
        expect(out.first).to eq("ConfigurationError")
      end

      # ------------------------------------------------------------------ tooling
      it "security T25: Versioning.types sees one twin per version for fields, arguments and enum values" do
        b = bases
        kind = Class.new(b[:enum]) { graphql_name "Kind"; value "VOID", "old", removed: TW_V2; value "VOID", "new", value_method: false, added: TW_V2 }
        q = query_root(b) do
          field :total, Integer, null: true, removed: TW_V2
          field :total, String, null: true, added: TW_V2
          field :echo, kind, null: true do
            argument :first, Integer, required: false, removed: TW_V2
            argument :first, String, required: false, added: TW_V2
          end
        end
        s = schema_over(q, vis)
        shapes = [TW_V1, TW_V2].map do |v|
          view = GraphQL::Armory::Versioning.types(s, v)
          fields = view.fields(q)
          echo = fields.find { |f| f.graphql_name == "echo" }
          [fields.select { |f| f.graphql_name == "total" }.map { |f| f.type.to_type_signature },
           view.arguments(echo).map { |a| a.type.to_type_signature }, view.enum_values(kind).map(&:description)]
        end
        expect(shapes).to eq([[["Int"], ["Int"], ["old"]], [["String"], ["String"], ["new"]]])
      end

      it "preservation T26: field twins on graphql #{GraphQL::VERSION}: served (>= 2.4.9) or refused with ConfigurationError" do
        b = bases
        q = query_root(b) do
          field :total, Integer, null: true, removed: TW_V2
          field :total, String, null: true, added: TW_V2
        end
        s = schema_over(q, vis)
        out = [TW_V1, TW_V2].map { |v| attempt { run(s, "{ total }", v, root: record(total: 7)) } }
        warn "T26 #{vis} graphql #{GraphQL::VERSION}: #{out.inspect}"
        expected = Gem::Version.new(GraphQL::VERSION) >= Gem::Version.new("2.4.9") ? [[:ok, { "data" => { "total" => 7 } }], [:ok, { "data" => { "total" => "7" } }]] : nil
        expect(out).to eq(expected) if expected
      end

      it "security T27: child versioned twins shadowing a parent's unversioned field (not same owner), in a version where neither twin lives" do
        b = bases
        parent = Class.new(b[:object]) { graphql_name "P"; authorize :none, reason: "p", covers_fields: true; field :total, Integer, null: true, method: :parent_total }
        child = Class.new(parent) do
          graphql_name "C"
          authorize :none, reason: "p", covers_fields: true
          field :total, String, null: true, method: :child_total, added: TW_V2
          field :total, Float, null: true, method: :child_float, removed: TW_V1
        end
        q = query_root(b) { field :c, child, null: true }
        out = [TW_V1, TW_V2].map { |v| attempt { run(schema_over(q, vis), "{ c { total } }", v, root: record(c: record(parent_total: 1, child_total: "c", child_float: 1.0))) } }
        warn "T27 #{vis} (parent fallback, pre-existing class): #{out.inspect}"
        expect(out[1]).to eq([:ok, { "data" => { "c" => { "total" => "c" } } }])
      end
    end
  end
end
