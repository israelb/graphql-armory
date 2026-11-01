# frozen_string_literal: true

require "spec_helper"
require "digest"
require "json"

PQ = GraphQL::Armory::PersistedQueries unless defined?(PQ)

RSpec.describe "PR32 probes: hand-built queries in strict mode" do
  let(:resolved) { [] }
  let(:root) { PQ::Controls::Root.example(resolved) }
  let(:ops) { PQ::Controls::Operations }
  let(:signals) { [] }
  let(:sink) { ->(signal, data) { signals << [signal, data[:reason]] } }

  def store = PQ::Store::Substitute.new(ops.invoices, ops.greeting)
  def id_of(text) = Digest::SHA256.hexdigest(text)

  def armored(strict: true, sinks: [sink], on_sink_error: nil, query_type: PQ::Controls::Query.example, before: nil, after: nil)
    schema = ArmoryEngine.base_schema
    schema.query(query_type)
    before&.call(schema)
    schema.use(PQ, store: store, strict: strict, sinks: sinks, on_sink_error: on_sink_error)
    after&.call(schema)
    schema
  end

  def engine = ArmoryEngine.next? ? GraphQL::Execution::Next : GraphQL::Execution::Interpreter
  def run_all(schema, *queries, **opts) = engine.run_all(schema, queries, **opts)
  def built(schema, text = nil, **opts) = GraphQL::Query.new(schema, text, root_value: root, **opts)
  def code(result) = result.to_h["errors"]&.first&.dig("extensions", "code")
  def show(r) = r.respond_to?(:to_h) ? r.to_h : r.inspect

  def attempt
    yield
  rescue StandardError => e
    e
  end

  def expect_refused(result)
    expect(resolved).to eq([])
    expect(result.to_h["data"]).to be_nil
    expect(code(result)).to eq("RAW_QUERY_REFUSED")
  end

  def analyzer_raising(error, on: :visit, field: nil)
    Class.new(GraphQL::Analysis::Analyzer) do
      if on == :visit
        define_method(:on_enter_field) { |node, _parent, _visitor| raise error, "busy" if field.nil? || node.name == field }
        define_method(:result) { nil }
      else
        define_method(:result) { raise error, "busy" }
      end
    end
  end

  describe "build shapes" do
    it("S02 security: document:") { s = armored; expect_refused(run_all(s, built(s, document: GraphQL.parse("{ secret }"))).first) }
    it("S03 security: query: keyword") { s = armored; expect_refused(run_all(s, built(s, query: "{ secret }")).first) }
    it("S04 security: a subclass of GraphQL::Query") do
      s = armored
      q = Class.new(GraphQL::Query).new(s, "{ secret }", root_value: root)
      expect_refused(run_all(s, q).first)
    end
    it("S05 security: original custom class (unwrapped) after use") do
      custom = Class.new(GraphQL::Query)
      s = armored
      s.query_class(custom)
      expect_refused(run_all(s, custom.new(s, "{ secret }", root_value: root)).first)
    end
    it("S06 security: child schema") do
      child = Class.new(armored)
      expect_refused(run_all(child, built(child, "{ secret }")).first)
    end
    it("S07 security: child defined before the parent's use") do
      parent = ArmoryEngine.base_schema
      parent.query(PQ::Controls::Query.example)
      child = Class.new(parent)
      parent.use(PQ, store: store, strict: true)
      expect_refused(run_all(child, built(child, "{ secret }")).first)
    end
    it("S08 security: Query#result directly") { s = armored; expect_refused(built(s, "{ secret }").result) }
    it("S10 security: run_partials on a built query resolves nothing") do
      s = armored
      q = built(s, "{ secret }")
      skip "no partials" unless q.respond_to?(:run_partials)
      results = attempt { q.run_partials([{ path: [], object: root }]) }
      expect(resolved).to eq([]), "resolved #{resolved} result=#{results.is_a?(Array) ? results.map(&:to_h) : results.inspect}; signals=#{signals}"
    end
    it("S10b preservation: run_partials on a plugin-refused query") do
      s = armored
      q = s.query_class.new(s, "{ secret }", root_value: root)
      skip "no partials" unless q.respond_to?(:run_partials)
      attempt { q.run_partials([{ path: [], object: root }]) }
      expect(resolved).to eq([])
    end
    it("S10c security: run_partials after the whole query was refused") do
      s = armored
      q = built(s, "{ secret }")
      skip "no partials" unless q.respond_to?(:run_partials)
      run_all(s, q)
      attempt { q.run_partials([{ path: [], object: root }]) }
      expect(resolved).to eq([])
    end
    it("S11 security: child whose query class was set before the parent's use (hash path, no Lookup)") do
      parent = ArmoryEngine.base_schema
      parent.query(PQ::Controls::Query.example)
      child = Class.new(parent)
      child.query_class(Class.new(GraphQL::Query))
      parent.use(PQ, store: store, strict: true)
      expect_refused(execute_query(child, "{ secret }", root_value: root))
    end
    it("S12 security: as_default Next schema, Schema.multiplex with an object") do
      skip "no Next" unless ArmoryEngine.supported?
      s = Class.new(GraphQL::Schema) { use GraphQL::Execution::Next, as_default: true }
      s.query(PQ::Controls::Query.example)
      s.use(PQ, store: store, strict: true)
      expect_refused(s.multiplex([built(s, "{ secret }")]).first)
    end
    it("S13 security: execute(query: a Query object) resolves nothing") do
      s = armored
      attempt { execute_query(s, nil, query: built(s, "{ secret }"), root_value: root) }
      expect(resolved).to eq([])
    end
  end

  describe "analyzers skipped or swallowed" do
    it("S20 security: app analyzer raising ExecutionError during the visit, added before use") do
      s = armored(before: ->(x) { x.query_analyzer(analyzer_raising(GraphQL::ExecutionError, field: "greeting")) })
      r = attempt { run_all(s, built(s, '{ secret greeting(name: "x") }')).first }
      expect(resolved).to eq([]), "resolved #{resolved}; result=#{show(r)}; signals=#{signals}"
    end
    it("S21 security: same, added after use") do
      s = armored(after: ->(x) { x.query_analyzer(analyzer_raising(GraphQL::ExecutionError, field: "greeting")) })
      r = attempt { run_all(s, built(s, '{ secret greeting(name: "x") }')).first }
      expect(resolved).to eq([]), "resolved #{resolved}; result=#{show(r)}; signals=#{signals}"
    end
    it("S22 security: app analyzer raising ExecutionError from result, after BuiltQueries") do
      s = armored(after: ->(x) { x.query_analyzer(analyzer_raising(GraphQL::ExecutionError, on: :result)) })
      r = attempt { run_all(s, built(s, "{ secret }")).first }
      expect(resolved).to eq([]), "resolved #{resolved}; result=#{show(r)}; signals=#{signals}"
    end
    it("S23 security: analyzer raising UnauthorizedError during the visit") do
      s = armored(after: ->(x) { x.query_analyzer(analyzer_raising(GraphQL::UnauthorizedError, field: "secret")) })
      r = attempt { run_all(s, built(s, "{ secret }")).first }
      expect(resolved).to eq([]), "resolved #{resolved}; result=#{show(r)}; signals=#{signals}"
    end

    def complexity_setup
      type = Class.new(GraphQL::Schema::Object) do
        graphql_name "Query"
        field :secret, String, null: false
        field :items, String, null: false do
          argument :n, GraphQL::Types::Int
          complexity(->(_ctx, args, child) { raise GraphQL::ExecutionError, "n too large" if args[:n] > 10; args[:n] + child })
        end
        field :prep, String, null: false do
          argument :s, String, prepare: ->(_v, _ctx) { raise GraphQL::ExecutionError, "bad s" }
        end
      end
      r = resolved
      value = Class.new do
        define_method(:secret) { r << :secret; "s3cr3t" }
        define_method(:items) { |n:| r << :items; n.to_s }
        define_method(:prep) { |s:| r << :prep; s }
      end.new
      s = armored(query_type: type, after: lambda { |x|
        x.max_complexity(100)
        x.complexity_cost_calculation_mode(:future) if x.respond_to?(:complexity_cost_calculation_mode)
      })
      [s, value]
    end

    it("S24 security: field complexity proc raising ExecutionError on a client's argument (max_complexity)") do
      s, value = complexity_setup
      q = GraphQL::Query.new(s, "{ secret items(n: 50) }", root_value: value)
      r = attempt { run_all(s, q).first }
      expect(resolved).to eq([]), "resolved #{resolved}; result=#{show(r)}; signals=#{signals}"
    end
    it("S24b security: same, multiplex without its own max_complexity") do
      s, value = complexity_setup
      q = GraphQL::Query.new(s, "{ secret items(n: 50) }", root_value: value)
      r = attempt { run_all(s, q, max_complexity: nil).first }
      expect(resolved).to eq([]), "resolved #{resolved}; result=#{show(r)}; signals=#{signals}"
    end
    it("S25 security: argument prepare raising ExecutionError (max_complexity)") do
      s, value = complexity_setup
      q = GraphQL::Query.new(s, '{ secret prep(s: "x") }', root_value: value)
      r = attempt { run_all(s, q).first }
      expect(resolved).to eq([]), "resolved #{resolved}; result=#{show(r)}; signals=#{signals}"
    end
    it("S27 security: analyzer's result raising a StandardError: nothing runs") do
      s = armored(after: ->(x) { x.query_analyzer(analyzer_raising(RuntimeError, on: :result)) })
      attempt { run_all(s, built(s, "{ secret }")) }
      expect(resolved).to eq([])
    end

    def slow_analyzer
      Class.new(GraphQL::Analysis::Analyzer) do
        define_method(:on_enter_field) { |_n, _p, _v| sleep 0.05 }
        define_method(:result) { nil }
      end
    end

    it("S28 security: validate_timeout hit during the visit") do
      s = armored(after: ->(x) { x.validate_timeout(0.02); x.query_analyzer(slow_analyzer) })
      r = run_all(s, built(s, "{ secret a: secret b: secret c: secret }")).first
      expect(resolved).to eq([]), "resolved #{resolved}; result=#{r.to_h}"
    end
    it("S29 security: validate_timeout hit in the visit with validate: false") do
      s = armored(after: ->(x) { x.validate_timeout(0.02); x.query_analyzer(slow_analyzer) })
      r = attempt { run_all(s, built(s, "{ secret a: secret b: secret c: secret }", validate: false)).first }
      expect(resolved).to eq([]), "resolved #{resolved.size}; result=#{show(r)}; signals=#{signals}"
    end

    { "S31 parse error" => ["{ secret", {}],
      "S32 unknown operation name" => ["query A { secret }", { operation_name: "B" }],
      "S33 several operations, no name" => ["query A { secret } query B { secret }", {}],
      "S30 fragment only" => ["fragment F on Query { secret }", {}],
      "S34f missing variable" => ["query($x: String!) { secret greeting(name: $x) }", {}] }.each do |name, (text, opts)|
      it("#{name} security: validate: true runs nothing") do
        s = armored
        attempt { run_all(s, built(s, text, **opts)) }
        expect(resolved).to eq([])
      end
    end

    [[:false, false], [:nil, nil]].each do |label, value|
      { "S34a missing variable" => ["query($x: String!) { secret greeting(name: $x) }", {}],
        "S34b wrong variable type" => ["query($x: String!) { secret greeting(name: $x) }", { variables: { "x" => 5 } }],
        "S34c unknown operation name" => ["query A { secret }", { operation_name: "B" }],
        "S34d several operations, no name" => ["query A { secret } query B { secret }", {}],
        "S34e fragment only" => ["fragment F on Query { secret }", {}] }.each do |name, (text, opts)|
        it("#{name} security: validate: #{label} runs nothing") do
          s = armored
          r = attempt { run_all(s, built(s, text, validate: value, **opts)).first }
          expect(resolved).to eq([]), "resolved #{resolved}; result=#{show(r)}; signals=#{signals}"
        end
      end
    end

    it("S35 security: subclass replaces query_analyzers (schema author)") do
      s = armored
      def s.query_analyzers = []
      r = run_all(s, built(s, "{ secret }")).first
      expect(resolved).to eq([]), "resolved #{resolved}; #{r.to_h}"
    end
    it("S35b security: analysis_engine replaced (schema author)") do
      s = armored
      engine_stub = Module.new { def self.analyze_multiplex(_m, _a) = [] }
      s.define_singleton_method(:analysis_engine) { engine_stub }
      r = run_all(s, built(s, "{ secret }")).first
      expect(resolved).to eq([]), "resolved #{resolved}; #{r.to_h}"
    end
    it("S37 security: a trace's analyze_query raising ExecutionError") do
      trace = Module.new { def analyze_query(query:) = raise(GraphQL::ExecutionError, "busy") }
      s = armored(after: ->(x) { x.trace_with(trace) })
      r = attempt { run_all(s, built(s, "{ secret }")).first }
      expect(resolved).to eq([]), "resolved #{resolved}; #{show(r)}; #{signals}"
    end
    it("S38 security: a multiplex analyzer raising ExecutionError in the visit") do
      s = armored(after: ->(x) { x.multiplex_analyzer(analyzer_raising(GraphQL::ExecutionError, field: "secret")) })
      r = attempt { run_all(s, built(s, "{ secret }")).first }
      expect(resolved).to eq([]), "resolved #{resolved}; #{show(r)}; #{signals}"
    end
  end

  describe "validate: false and friends" do
    it("S42 security: validate: nil is refused") do
      s = armored
      r = attempt { run_all(s, built(s, "{ secret }", validate: nil)).first }
      expect(resolved).to eq([]), "resolved #{resolved}; #{show(r)}; #{signals}"
    end
    it("S42b security: validate: nil assigned after the build") do
      s = armored
      q = built(s, "{ secret }")
      q.validate = nil
      r = attempt { run_all(s, q).first }
      expect(resolved).to eq([]), "resolved #{resolved}; #{show(r)}; #{signals}"
    end
    it("S44 security: validate: false records one refusal") do
      s = armored
      attempt { run_all(s, built(s, "{ secret }", validate: false)) }
      expect(signals).to eq([[:operation_refused, :raw_query]])
    end
    it("S46 preservation: plugin-built raw with validate: nil is refused") do
      s = armored
      expect_refused(run_all(s, s.query_class.new(s, "{ secret }", root_value: root, validate: nil)).first)
    end
    it("S47 preservation: plugin mismatch with validate: false is refused") do
      s = armored
      r = run_all(s, s.query_class.new(s, "{ secret }", root_value: root, validate: false, context: { operation_id: id_of(ops.invoices) })).first
      expect(resolved).to eq([])
      expect(code(r)).to eq("OPERATION_MISMATCH")
    end
    it("S48 preservation: plugin-built with the flag and validate: false runs") do
      s = armored
      r = run_all(s, s.query_class.new(s, "{ secret }", root_value: root, validate: false, context: { armory_allow_raw_query: true })).first
      expect(r.to_h["data"]).to eq("secret" => "s3cr3t")
    end
    it("S49 security: built with the flag records one :raw_query_allowed") do
      s = armored
      run_all(s, built(s, "{ secret }", context: { armory_allow_raw_query: true }))
      expect(signals).to eq([[:raw_query_allowed, nil]])
    end
  end

  describe "flag values" do
    { "S50 string true" => "true", "S51 one" => 1, "S52 symbol" => :true, "S52b object" => Object.new }.each do |name, value|
      it("#{name} security: refused") do
        s = armored
        expect_refused(run_all(s, built(s, "{ secret }", context: { armory_allow_raw_query: value })).first)
      end
    end
    it("S53 security: string key refused") do
      s = armored
      expect_refused(run_all(s, built(s, "{ secret }", context: { "armory_allow_raw_query" => true })).first)
    end
    it("S53b security: multiplex-level context does not allow") do
      s = armored
      expect_refused(run_all(s, built(s, "{ secret }"), context: { armory_allow_raw_query: true }).first)
    end
    it("S55 security: a Query::Context passed as context, no flag") do
      s = armored
      other = GraphQL::Query.new(s, "{ __typename }", context: { current_user: :u }).context
      expect_refused(run_all(s, built(s, "{ secret }", context: other)).first)
    end
    it("S57 security: an id with its stored text, built by hand, is still refused (documented)") do
      s = armored
      expect_refused(run_all(s, built(s, ops.invoices, context: { operation_id: id_of(ops.invoices) })).first)
    end
  end

  describe "signals" do
    it("S60b preservation: non-strict plugin raw records one") do
      s = armored(strict: false)
      execute_query(s, "{ secret }", root_value: root)
      expect(signals).to eq([[:raw_query_run, nil]])
    end
    it("S62 security: one refusal per query in a multiplex") do
      s = armored
      run_all(s, built(s, "{ secret }"), built(s, "{ secret }"), built(s, "{ invoices }"))
      expect(signals).to eq([[:operation_refused, :raw_query]] * 3)
      expect(resolved).to eq([])
    end
    it("S63 security: allowed and refused counted per query") do
      s = armored
      results = run_all(s, built(s, "{ secret }", context: { armory_allow_raw_query: true }), built(s, "{ invoices }"))
      expect(signals).to eq([[:raw_query_allowed, nil], [:operation_refused, :raw_query]])
      expect(resolved).to eq([:secret])
      expect(code(results[1])).to eq("RAW_QUERY_REFUSED")
    end
    it("S64 security: a raising sink does not change the refusal") do
      errors = []
      s = armored(sinks: [->(_s, _d) { raise "boom" }], on_sink_error: ->(e, sig) { errors << [e.class, sig] })
      expect_refused(run_all(s, built(s, "{ secret }")).first)
      expect(errors).to eq([[RuntimeError, :operation_refused]])
    end
    it("S64b security: a sink raising ExecutionError") do
      s = armored(sinks: [->(_s, _d) { raise GraphQL::ExecutionError, "boom" }], on_sink_error: ->(_e, _s) {})
      expect_refused(run_all(s, built(s, "{ secret }")).first)
    end
    it("S65 security: on_sink_error re-raising an ExecutionError fails closed") do
      s = armored(sinks: [->(_s, _d) { raise GraphQL::ExecutionError, "boom" }], on_sink_error: ->(e, _s) { raise e })
      r = attempt { run_all(s, built(s, "{ secret }")).first }
      expect(resolved).to eq([]), "resolved #{resolved}; #{show(r)}"
    end
    it("S65b security: on_sink_error raising RuntimeError fails closed") do
      s = armored(sinks: [->(_s, _d) { raise "boom" }], on_sink_error: ->(e, _s) { raise e })
      expect { run_all(s, built(s, "{ secret }")) }.to raise_error(RuntimeError)
      expect(resolved).to eq([])
    end
    it("S66 security: a 3-argument sink reads the built query's context through the view") do
      seen = []
      three = ->(signal, _data, view) { seen << [signal, view[:client_key], view.fetch(:client_key), view.key?(:client_key), view.dig(:client_key)] }
      errors = []
      s = armored(sinks: [three], on_sink_error: ->(e, _s) { errors << e })
      run_all(s, built(s, "{ secret }", context: { client_key: "k" }))
      expect(errors).to eq([])
      expect(seen).to eq([[:operation_refused, "k", "k", true, "k"]])
    end
    it("S69 security: built introspection is refused") do
      s = armored
      expect_refused(run_all(s, built(s, "{ __schema { types { name } } }")).first)
    end
  end

  describe "gate" do
    it("S70 security: Gate.new refuses a built query") do
      expect(PQ::Gate.new.built_query({})).to eq(PQ::RAW_QUERY_REFUSED)
    end
    it("S70b security: Gate.new refuses with a non-true flag") do
      expect(PQ::Gate.new.built_query({ armory_allow_raw_query: "true" })).to eq(PQ::RAW_QUERY_REFUSED)
    end
    it("S71 security: Gate.build non-strict answers nil") do
      expect(PQ::Gate.build(store: store, strict: false).built_query({})).to be_nil
    end
    it("S72 preservation: a second use raises; a child's use raises") do
      s = armored
      expect { s.use(PQ, store: store) }.to raise_error(PQ::ConfigurationError)
      expect { Class.new(s).use(PQ, store: store) }.to raise_error(PQ::ConfigurationError)
    end
  end

  describe "preservation" do
    it("P80 plain requests") do
      s = armored
      inv = id_of(ops.invoices)
      expect(execute_query(s, nil, root_value: root, context: { operation_id: inv }).to_h).to eq("data" => { "invoices" => ["A-1"] })
      expect(execute_query(s, ops.invoices, root_value: root, context: { operation_id: inv }).to_h).to eq("data" => { "invoices" => ["A-1"] })
      greet = execute_query(s, nil, root_value: root, variables: { "name" => "Ann" }, operation_name: "Greeting", context: { operation_id: id_of(ops.greeting) }).to_h
      expect(greet).to eq("data" => { "greeting" => "Hello Ann" })
      expect(code(execute_query(s, "{ secret }", root_value: root, context: { operation_id: inv }))).to eq("OPERATION_MISMATCH")
      expect(code(execute_query(s, nil, root_value: root, context: { operation_id: "nope" }))).to eq("UNKNOWN_OPERATION")
      expect(code(execute_query(s, "{ secret }", root_value: root))).to eq("RAW_QUERY_REFUSED")
      expect(resolved).to eq(%i[invoices invoices greeting])
    end
    it("P80b non-strict raw") do
      s = armored(strict: false)
      expect(execute_query(s, "{ secret }", root_value: root).to_h).to eq("data" => { "secret" => "s3cr3t" })
    end
    def subscription_setup
      deliveries = []
      memory = {}
      subs_class = Class.new(GraphQL::Subscriptions) do
        define_method(:write_subscription) do |query, events|
          id = "sub-#{memory.size}"
          query.context[:subscription_id] = id
          memory[id] = { events: events, query_string: query.query_string, operation_name: query.selected_operation_name, variables: query.provided_variables, context: { operation_id: query.context[:operation_id], armory_allow_raw_query: query.context[:armory_allow_raw_query] } }
        end
        define_method(:execute_all) do |event, object|
          memory.each { |id, entry| execute(id, event, object) if entry[:events].any? { |e| e.topic == event.topic } }
        end
        define_method(:read_subscription) { |id| memory[id] }
        define_method(:deliver) { |id, result| deliveries << [id, result.to_h] }
        define_method(:delete_subscription) { |id| memory.delete(id) }
      end
      sub_type = Class.new(GraphQL::Schema::Object) do
        graphql_name "Subscription"
        field :tick, String, null: true
        define_method(:tick) { object.is_a?(String) ? object : nil }
      end
      text = "subscription Tick { tick }"
      s = ArmoryEngine.base_schema
      s.query(PQ::Controls::Query.example)
      s.subscription(sub_type)
      s.use(subs_class)
      st = PQ::Store::Substitute.new(text, ops.invoices)
      s.use(PQ, store: st, strict: true, sinks: [sink])
      [s, text, memory, deliveries]
    end

    it("P83 a stored subscription re-runs through the plugin") do
      s, text, memory, deliveries = subscription_setup
      r = s.execute(nil, context: { operation_id: id_of(text) })
      expect(r.to_h["errors"]).to be_nil
      expect(memory.size).to eq(1)
      s.subscriptions.trigger(:tick, {}, "t1")
      expect(deliveries.map { |_, h| h }).to eq([{ "data" => { "tick" => "t1" } }])
    end
    it("P83b security: a built subscription is refused and registers nothing") do
      s, text, memory, = subscription_setup
      r = run_all(s, GraphQL::Query.new(s, text)).first
      expect(code(r)).to eq("RAW_QUERY_REFUSED")
      expect(memory).to be_empty
    end
    it("P85 owners") do
      s = armored
      expect(s.method(:query_class).owner).to eq(PQ::Guard)
      expect(s.query_class.instance_method(:initialize).owner).to eq(PQ::Lookup)
      expect(s.method(:execute).owner).not_to eq(PQ::Guard)
    end
    it("P86 install-template shaped schema") do
      s = Class.new(GraphQL::Schema) do
        use GraphQL::Execution::Next if ArmoryEngine.available?
        use GraphQL::Dataloader
        max_query_string_tokens(5000) if respond_to?(:max_query_string_tokens)
        validate_max_errors(100)
        default_max_page_size 50
      end
      s.query(PQ::Controls::Query.example)
      s.use(PQ, store: store, strict: true)
      expect(execute_query(s, nil, root_value: root, context: { operation_id: id_of(ops.invoices) }).to_h).to eq("data" => { "invoices" => ["A-1"] })
      expect(code(execute_query(s, "{ secret }", root_value: root))).to eq("RAW_QUERY_REFUSED")
      expect(resolved).to eq([:invoices])
    end
    it("P86b security: install-template shaped schema refuses a built query") do
      s = Class.new(GraphQL::Schema) do
        use GraphQL::Execution::Next if ArmoryEngine.available?
        use GraphQL::Dataloader
        validate_max_errors(100)
      end
      s.query(PQ::Controls::Query.example)
      s.use(PQ, store: store, strict: true)
      expect_refused(run_all(s, built(s, "{ secret }")).first)
    end
    it("P87 custom query_class before and after use") do
      custom = Class.new(GraphQL::Query)
      s = armored(before: ->(x) { x.query_class(custom) })
      s2 = armored(after: ->(x) { x.query_class(custom) })
      [s, s2].each do |schema|
        expect(execute_query(schema, nil, root_value: root, context: { operation_id: id_of(ops.invoices) }).to_h).to eq("data" => { "invoices" => ["A-1"] })
        expect(code(execute_query(schema, "{ secret }", root_value: root))).to eq("RAW_QUERY_REFUSED")
      end
    end
    it("P88 hash multiplex keeps its plugin behaviour") do
      s = armored
      results = run_all(s, { query: "{ secret }", root_value: root }, { query: nil, root_value: root, context: { operation_id: id_of(ops.invoices) } })
      expect(code(results[0])).to eq("RAW_QUERY_REFUSED")
      expect(results[1].to_h["data"]).to eq("invoices" => ["A-1"])
      expect(signals).to eq([[:operation_refused, :raw_query], [:operation_persisted, nil]])
    end
  end
end
