# frozen_string_literal: true
require "spec_helper"
require "digest"

PQR = GraphQL::Armory::PersistedQueries unless defined?(PQR)

RSpec.describe "PR32 recheck" do
  let(:resolved) { [] }
  let(:root) { PQR::Controls::Root.example(resolved) }
  let(:ops) { PQR::Controls::Operations }
  let(:signals) { [] }
  let(:sink) { ->(signal, data) { signals << [signal, data[:reason]] } }

  def st = PQR::Store::Substitute.new(ops.invoices, ops.greeting)
  def id_of(t) = Digest::SHA256.hexdigest(t)
  def schema(strict: true, sinks: [sink], on_sink_error: nil, qt: PQR::Controls::Query.example, &after)
    store = st
    s = Class.new(ArmoryEngine.base_schema) do
      query qt
      use PQR, store: store, strict: strict, sinks: sinks, on_sink_error: on_sink_error
    end
    after&.call(s)
    s
  end
  def engine = ArmoryEngine.next? ? GraphQL::Execution::Next : GraphQL::Execution::Interpreter
  def run_all(s, *qs, **o) = engine.run_all(s, qs, **o)
  def built(s, text = "{ secret }", **o) = GraphQL::Query.new(s, text, root_value: root, **o)
  def stored(s) = s.query_class.new(s, nil, root_value: root, context: { operation_id: id_of(ops.invoices) })
  def try_it
    yield
  rescue StandardError => e
    "RAISED #{e.class}: #{e.message[0, 90]}"
  end
  def hsh(r) = r.is_a?(String) ? r : (r.is_a?(Array) ? r.map { hsh(_1) } : r.to_h)
  def report(id, r)
    puts "@@ #{id}: result=#{hsh(r).inspect} resolved=#{resolved} signals=#{signals}"
  end
  def partials? = GraphQL::Query.method_defined?(:run_partials)
  def analyzer(err, on: :visit)
    Class.new(GraphQL::Analysis::Analyzer) do
      if on == :visit
        define_method(:on_enter_field) { |*_| raise err, "busy" }
        define_method(:result) { nil }
      else
        define_method(:result) { raise err, "busy" }
      end
    end
  end
  def refused_only!(r)
    expect(resolved).to eq([])
    expect(signals).to eq([[:operation_refused, :raw_query]])
    expect(hsh(r)["data"]).to be_nil
    expect(hsh(r)["errors"].first["extensions"]["code"]).to eq("RAW_QUERY_REFUSED")
  end

  describe "B1 run_partials" do
    before { skip "no run_partials on #{GraphQL::VERSION}" unless partials? }
    it("R01 security root partial") { s = schema; r = try_it { built(s).run_partials([{ path: [], object: root }]) }; report("R01", r); expect(resolved).to eq([]); expect(hsh(r).first["errors"].first["extensions"]["code"]).to eq("RAW_QUERY_REFUSED") }
    it("R02 security two partials") { s = schema; r = try_it { built(s).run_partials([{ path: [], object: root }, { path: [], object: root }]) }; report("R02", r); expect(resolved).to eq([]) }
    it("R03 security leaf partial by path") { s = schema; r = try_it { built(s).run_partials([{ path: ["secret"], object: root }]) }; report("R03", r); expect(hsh(r).first["data"].to_s).not_to include("s3cr3t") }
    it("R04 security partial with its own allowing context") { s = schema; r = try_it { built(s).run_partials([{ path: [], object: root, context: { armory_allow_raw_query: true } }]) }; report("R04", r); expect(resolved).to eq([]) }
    it("R05 security partial on the Next route") { s = schema; r = try_it { built(s, context: { __graphql_execute_next: ArmoryEngine.next? }).run_partials([{ path: [], object: root }]) }; report("R05", r); expect(resolved).to eq([]) }
    it("R06 security partial after a full refused run") { s = schema; q = built(s); run_all(s, q); r = try_it { q.run_partials([{ path: [], object: root }]) }; report("R06", r); expect(resolved).to eq([]) }
    it("R07 partial of a built query with the flag") { s = schema; r = try_it { built(s, context: { armory_allow_raw_query: true }).run_partials([{ path: [], object: root }, { path: [], object: root }]) }; report("R07", r) }
    it("R08 whole run then partial, with the flag") { s = schema; q = built(s, context: { armory_allow_raw_query: true }); run_all(s, q); r = try_it { q.run_partials([{ path: [], object: root }]) }; report("R08", r) }
  end

  describe "B2 analysis cannot undo the refusal" do
    def check(id, r) = (report(id, r); refused_only!(r))
    it("R10 security analyzer ExecutionError visit") { s = schema { _1.query_analyzer(analyzer(GraphQL::ExecutionError)) }; check("R10", run_all(s, built(s)).first) }
    it("R11 security analyzer ExecutionError result") { s = schema { _1.query_analyzer(analyzer(GraphQL::ExecutionError, on: :result)) }; check("R11", run_all(s, built(s)).first) }
    it("R12 security analyzer UnauthorizedError") { s = schema { _1.query_analyzer(analyzer(GraphQL::UnauthorizedError)) }; check("R12", run_all(s, built(s)).first) }
    it("R13 security multiplex analyzer ExecutionError") { s = schema { _1.multiplex_analyzer(analyzer(GraphQL::ExecutionError)) }; check("R13", run_all(s, built(s)).first) }
    it("R14 security trace analyze_query ExecutionError") do
      t = Module.new { def analyze_query(query:) = raise(GraphQL::ExecutionError, "busy") }
      s = schema { _1.trace_with(t) }
      r = try_it { run_all(s, built(s)).first }
      report("R14", r)
      expect(resolved).to eq([])
      expect(signals).to eq([[:operation_refused, :raw_query]]) unless r.is_a?(String)
    end
    it("R15 security raising complexity proc") do
      qt = Class.new(GraphQL::Schema::Object) do
        graphql_name "Query"
        field :secret, String, null: false
        field :items, String, null: false do
          argument :n, GraphQL::Types::Int
          complexity(->(_c, a, _ch) { raise GraphQL::ExecutionError, "too large" if a[:n] > 10; a[:n] })
        end
      end
      r0 = resolved
      v = Class.new { define_method(:secret) { r0 << :secret; "s" }; define_method(:items) { |n:| r0 << :items; "i" } }.new
      s = schema(qt: qt) { _1.max_complexity(100) }
      r = try_it { run_all(s, GraphQL::Query.new(s, "{ secret items(n: 50) }", root_value: v)).first }
      report("R15", r)
      expect(resolved).to eq([])
      expect(signals).to eq([]) if r.is_a?(String)
    end
    it("R16 security on_sink_error re-raising an ExecutionError, strict") do
      s = schema(sinks: [->(_a, _b) { raise GraphQL::ExecutionError, "boom" }], on_sink_error: ->(e, _s) { raise e })
      r = run_all(s, built(s)).first
      report("R16", r)
      expect(resolved).to eq([])
      expect(hsh(r)["data"]).to be_nil
    end
    it("R17 security on_sink_error re-raising, allowed query") do
      s = schema(sinks: [->(_a, _b) { raise GraphQL::ExecutionError, "boom" }], on_sink_error: ->(e, _s) { raise e })
      r = try_it { run_all(s, built(s, context: { armory_allow_raw_query: true })).first }
      report("R17", r)
    end
    it("R18 preservation analyzer ExecutionError on an allowed query: one signal") do
      s = schema { _1.query_analyzer(analyzer(GraphQL::ExecutionError)) }
      r = run_all(s, built(s, context: { armory_allow_raw_query: true })).first
      report("R18", r)
      expect(signals).to eq([[:raw_query_allowed, nil]])
    end
  end

  describe "B3 validate: false and friends" do
    def slow = Class.new(GraphQL::Analysis::Analyzer) { define_method(:on_enter_field) { |*_| sleep 0.05 }; define_method(:result) { nil } }
    v = "query($x: String!) { secret greeting(name: $x) }"
    it("R20 security validate: nil") { s = schema; r = try_it { run_all(s, built(s, validate: nil)).first }; report("R20", r); refused_only!(r) }
    it("R21 security validate: false") { s = schema; r = try_it { run_all(s, built(s, validate: false)).first }; report("R21", r); refused_only!(r) }
    it("R22 security validate = false after build") { s = schema; q = built(s); q.validate = false; r = try_it { run_all(s, q).first }; report("R22", r); refused_only!(r) }
    it("R23 security validate = nil after build") { s = schema; q = built(s); q.validate = nil; r = try_it { run_all(s, q).first }; report("R23", r); refused_only!(r) }
    it("R24 security validate: false, variable does not coerce") { s = schema; r = try_it { run_all(s, built(s, v, validate: false, variables: { "x" => 5 })).first }; report("R24", r); expect(resolved).to eq([]) }
    it("R25 security validate: false, variable missing") { s = schema; r = try_it { run_all(s, built(s, v, validate: false)).first }; report("R25", r); expect(resolved).to eq([]) }
    it("R26 security validate: false, validate_timeout hit") do
      sl = slow
      s = schema { _1.validate_timeout(0.02); _1.query_analyzer(sl) }
      r = try_it { run_all(s, built(s, "{ secret a: secret b: secret c: secret }", validate: false)).first }
      report("R26", r)
      expect(resolved).to eq([])
    end
    it("R27 security validate: true, validate_timeout hit") do
      sl = slow
      s = schema { _1.validate_timeout(0.02); _1.query_analyzer(sl) }
      r = try_it { run_all(s, built(s, "{ secret a: secret b: secret c: secret }")).first }
      report("R27", r)
      expect(resolved).to eq([])
    end
    it("R28 security validate: false, invalid text") { s = schema; r = try_it { run_all(s, built(s, "{ secre }", validate: false)).first }; report("R28", r); expect(resolved).to eq([]) }
    it("R29 security validate: false beside a stored query, both orders") do
      s = schema
      a = try_it { run_all(s, built(s, validate: false), stored(s)) }
      report("R29a", a)
      expect(resolved).to eq([:invoices])
      expect(hsh(a).last["data"]).to eq("invoices" => ["A-1"])
      resolved.clear; signals.clear
      b = try_it { run_all(s, stored(s), built(s, validate: false)) }
      report("R29b", b)
      expect(resolved).to eq([:invoices])
      expect(hsh(b).first["data"]).to eq("invoices" => ["A-1"])
    end
    it("R30 security validate: false, bad variable, beside a stored query") do
      s = schema
      a = try_it { run_all(s, stored(s), built(s, v, validate: false, variables: { "x" => 5 })) }
      report("R30", a)
      expect(resolved).to eq([:invoices]) unless a.is_a?(String)
    end
    it("R31 validate: false, no operation selected") { s = schema; r = try_it { run_all(s, built(s, "query A { secret }", validate: false, operation_name: "B")).first }; report("R31", r); expect(resolved).to eq([]) }
    it("R32 validate: false, parse error") { s = schema; r = try_it { run_all(s, built(s, "{ secret", validate: false)).first }; report("R32", r); expect(resolved).to eq([]) }
    it("R33 validate: false, fragment only") { s = schema; r = try_it { run_all(s, built(s, "fragment F on Query { secret }", validate: false)).first }; report("R33", r); expect(resolved).to eq([]) }
    it("R34 validate: false, flag: runs") { s = schema; r = run_all(s, built(s, validate: false, context: { armory_allow_raw_query: true })).first; report("R34", r); expect(hsh(r)["data"]).to eq("secret" => "s3cr3t") }
  end

  describe "regressions" do
    it("R40 stored runs alone") { s = schema; r = run_all(s, stored(s)).first; report("R40", r); expect(hsh(r)).to eq("data" => { "invoices" => ["A-1"] }); expect(signals).to eq([[:operation_persisted, nil]]) }
    it("R41 stored beside refused, both orders") do
      s = schema
      a = run_all(s, built(s), stored(s))
      b = run_all(s, stored(s), built(s))
      report("R41", [*a, *b])
      expect(resolved).to eq(%i[invoices invoices])
      expect(hsh(a[1])["data"]).to eq("invoices" => ["A-1"])
      expect(hsh(b[0])["data"]).to eq("invoices" => ["A-1"])
      expect(signals.tally).to eq({ [:operation_persisted, nil] => 2, [:operation_refused, :raw_query] => 2 })
    end
    it("R42 stored through execute / execute_next") { s = schema; r = execute_query(s, nil, root_value: root, context: { operation_id: id_of(ops.invoices) }); report("R42", r); expect(hsh(r)["data"]).to eq("invoices" => ["A-1"]) }
    it("R43 allowed: one signal, built and plugin") do
      s = schema
      run_all(s, built(s, context: { armory_allow_raw_query: true }))
      expect(signals).to eq([[:raw_query_allowed, nil]])
      signals.clear
      execute_query(s, "{ secret }", root_value: root, context: { armory_allow_raw_query: true })
      expect(signals).to eq([[:raw_query_allowed, nil]])
    end
    it("R44 non-strict: one signal, built and plugin") do
      s = schema(strict: false)
      run_all(s, built(s))
      expect(signals).to eq([[:raw_query_run, nil]])
      signals.clear
      execute_query(s, "{ secret }", root_value: root)
      expect(signals).to eq([[:raw_query_run, nil]])
    end
    it("R45 stored through Query#result") { s = schema; q = stored(s); r = q.result; report("R45", r); expect(hsh(r)["data"]).to eq("invoices" => ["A-1"]) }
    it("R46 security Query#result on built") { s = schema; r = built(s).result; report("R46", r); refused_only!(r) }
    it("R47 security child made before use, with its own trace") do
      t = Module.new { def execute_query(query:) = super }
      parent = Class.new(ArmoryEngine.base_schema) { query PQR::Controls::Query.example }
      child = Class.new(parent) { trace_with t }
      child.new_trace
      store = st; si = sink
      parent.use(PQR, store: store, strict: true, sinks: [si])
      r = run_all(child, built(child)).first
      report("R47", r)
      refused_only!(r)
    end
    it("R48 security trace_class set after use") do
      s = schema
      s.trace_class(Class.new(GraphQL::Tracing::Trace))
      r = run_all(s, built(s)).first
      report("R48", r)
      refused_only!(r)
    end
    it("R49 security context backtrace: true") { s = schema; r = try_it { run_all(s, built(s, context: { backtrace: true })).first }; report("R49", r); expect(resolved).to eq([]) }
    it("R50 security trace_with mode inherits the check") do
      m = Module.new
      s = schema { _1.trace_with(m, mode: :x) }
      r = run_all(s, built(s), context: { trace_mode: :x }).first
      report("R50", r)
      refused_only!(r)
    end
    it("R51 security app trace wrapping execute_query with super") do
      t = Module.new { def execute_query(query:, &b) = super }
      s = schema { _1.trace_with(t) }
      r = run_all(s, built(s)).first
      report("R51", r)
      refused_only!(r)
    end
    it("R52 preservation plugin refusal unchanged") do
      s = schema
      r = execute_query(s, "{ secret }", root_value: root)
      report("R52", r)
      expect(hsh(r)["errors"].first["extensions"]["code"]).to eq("RAW_QUERY_REFUSED")
      expect(signals).to eq([[:operation_refused, :raw_query]])
    end
  end

  describe "documented limits" do
    it("L01 invalid built text: ordinary errors, no signal, nothing resolves") { s = schema; r = run_all(s, built(s, "{ secre }")).first; report("L01", r); expect(resolved).to eq([]); expect(signals).to eq([]); expect(hsh(r)["errors"].first["extensions"]&.fetch("code", nil)).not_to eq("RAW_QUERY_REFUSED") }
    it("L02 invalid: missing variable") { s = schema; r = run_all(s, built(s, "query($x: String!) { secret greeting(name: $x) }")).first; report("L02", r); expect(resolved).to eq([]); expect(signals).to eq([]) }
    it("L03 invalid: parse error") { s = schema; r = run_all(s, built(s, "{ secret")).first; report("L03", r); expect(resolved).to eq([]); expect(signals).to eq([]) }
    it("L10 does trace_type exist") { puts "@@ L10: respond_to trace_type=#{GraphQL::Schema.respond_to?(:trace_type)} private=#{GraphQL::Schema.respond_to?(:trace_type, true)}" }
    bare = -> { Class.new(GraphQL::Tracing::Trace) }
    it("L11 query context[:trace]") { s = schema; r = try_it { run_all(s, built(s, context: { trace: bare.call.new })).first }; report("L11", r) }
    it("L12 query context[:trace_mode], bare mode") { b = bare.call; s = schema { _1.trace_mode(:bare, b) }; r = try_it { run_all(s, built(s, context: { trace_mode: :bare })).first }; report("L12", r) }
    it("L13 multiplex context[:trace]") { s = schema; r = try_it { run_all(s, built(s), context: { trace: bare.call.new }).first }; report("L13", r) }
    it("L14 multiplex context[:trace_mode], bare mode") { b = bare.call; s = schema { _1.trace_mode(:bare, b) }; r = try_it { run_all(s, built(s), context: { trace_mode: :bare }).first }; report("L14", r) }
    it("L15 query context[:trace_mode] after the query was parsed") { b = bare.call; s = schema { _1.trace_mode(:bare, b) }; q = built(s, context: { trace_mode: :bare }); q.valid?; r = try_it { run_all(s, q).first }; report("L15", r) }
    it("L16 query.result with context[:trace]") { s = schema; r = try_it { built(s, context: { trace: bare.call.new }).result }; report("L16", r) }
    it("L17 first query with own trace, second plain, in a multiplex") { s = schema; r = try_it { run_all(s, built(s, context: { trace: bare.call.new }), built(s, "{ invoices }")) }; report("L17", r) }
    it("L18 Schema.multiplex context[:trace]") { s = schema; r = try_it { s.multiplex([built(s)], context: { trace: bare.call.new }).first }; report("L18", r) }
    it("L19 default_trace_mode set to a bare mode") { b = bare.call; s = schema { _1.trace_mode(:bare, b); _1.default_trace_mode(:bare) }; r = try_it { run_all(s, built(s)).first }; report("L19", r) }
    it("L20 stored query with own trace still runs its stored document") { s = schema; q = s.query_class.new(s, nil, root_value: root, context: { operation_id: id_of(ops.invoices), trace: bare.call.new }); r = run_all(s, q).first; report("L20", r); expect(hsh(r)["data"]).to eq("invoices" => ["A-1"]) }
  end
end
