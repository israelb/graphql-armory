# frozen_string_literal: true

# Kept from the independent verification of PR #49. Pending probes are limits named in docs/rate-limiting.md.

# Verifier probes for PR #49. Each `it` is labelled security (the branch must change its outcome) or preservation.
# LOG lines report measured values.
RSpec.describe "PR49 probes" do
  RL = GraphQL::Armory::RateLimits unless defined?(RL)
  def resolved = (@resolved ||= [])
  def store = (@store ||= RL::Store::Substitute.new)
  def log(tag, value) = STDOUT.puts("LOG|#{ENV['GRAPHQL_ARMORY_ENGINE']}|#{GraphQL::VERSION}|#{tag}|#{value.inspect}")

  def root
    seen = resolved
    Class.new do
      %i[cheap report leaf boom boom_arg other prep].each do |f|
        define_method(f) { |**| seen << f; "ok" }
      end
      define_method(:node) { seen << :node; self }
      define_method(:child) { seen << :child; self }
      define_method(:act) { seen << :act; "done" }
    end.new
  end

  def build_schema(limiters: [[:points, { soft: true }]], max_depth: nil, max_complexity: nil, analyzers: [], hook: ->(_c, _a) {}, timeout: :default, parent: nil, traces: [])
    hook_c = ->(ctx, args, child) { hook.call(ctx, args); 1 + child }
    node = Class.new(GraphQL::Schema::Object) do
      graphql_name "Node"
      field :leaf, String, null: false
      field :child, self, null: false
      field :boom, String, null: false, complexity: hook_c
    end
    query = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :cheap, String, null: false
      field :report, String, null: false, complexity: 40
      field :other, String, null: false, complexity: 40
      field :node, node, null: false
      field :boom, String, null: false, complexity: hook_c
      field :boom_arg, String, null: false, complexity: hook_c do
        argument :x, GraphQL::Types::Boolean, required: false
      end
      field :prep, String, null: false do
        argument :v, String, required: false, prepare: ->(v, _ctx) { raise GraphQL::ExecutionError, "bad" if v == "bad"; v }
      end
    end
    mutation = Class.new(GraphQL::Schema::Object) do
      graphql_name "Mutation"
      field :act, String, null: false, complexity: 40
      field :boom, String, null: false, complexity: hook_c
    end
    store = self.store
    Class.new(parent || ArmoryEngine.base_schema) do
      query query
      mutation mutation
      complexity_cost_calculation_mode(:future) if respond_to?(:complexity_cost_calculation_mode)
      validate_timeout(timeout) unless timeout == :default
      max_depth(max_depth) if max_depth
      max_complexity(max_complexity) if max_complexity
      traces.first(1).each { |t| trace_with(t) }
      limiters.each do |kind, options|
        klass = { points: RL::Points, time: RL::Time, concurrency: RL::Concurrency }.fetch(kind)
        defaults = kind == :concurrency ? { limit: 5 } : { limit: 1000, window: 60 }
        use klass, store: store, **defaults.merge(options)
      end
      traces.drop(1).each { |t| trace_with(t) }
      analyzers.each { |a| query_analyzer(a) }
    end
  end

  def run(schema, q, key: "user:1", context: {}, **options)
    full = { rate_limit_key: key }.merge(context)
    # execute_next takes no max_depth:/max_complexity:; a per-query value on Next goes through multiplex_next.
    if ArmoryEngine.next? && (options.key?(:max_depth) || options.key?(:max_complexity))
      return schema.multiplex_next([{ query: q, context: full, root_value: root, **options }], max_complexity: nil).first
    end

    execute_query(schema, q, context: full, root_value: root, **options)
  end

  def mx(schema, queries, **options)
    if ArmoryEngine.next?
      schema.multiplex_next(queries, **options)
    else
      schema.multiplex(queries, **options)
    end
  end

  def errs(res) = Array(res.to_h["errors"])
  def msgs(res) = errs(res).map { |e| e["message"] }
  def codes(res) = errs(res).map { |e| e.dig("extensions", "code") }

  def expect_refused(res, pattern = nil)
    log("refused?", msgs(res)) unless res.to_h["data"].nil?
    expect(res.to_h["data"]).to be_nil
    expect(errs(res)).not_to be_empty
    expect(resolved).to be_empty
    expect(msgs(res).join("|")).to match(pattern) if pattern
  end

  def expect_ran(res)
    log("ran?", res.to_h) unless res.to_h["data"]
    expect(errs(res)).to be_empty
    expect(res.to_h["data"]).not_to be_nil
  end

  # An analyzer that raises from `hook`. `only` picks which calls raise (1-based over the whole run).
  def raiser(hook, error: GraphQL::ExecutionError.new("raised"), only: ->(_n) { true }, base: GraphQL::Analysis::Analyzer, counter: [0])
    fire = lambda do
      counter[0] += 1
      raise error if only.call(counter[0])
    end
    Class.new(base) do
      case hook
      when :initialize then define_method(:initialize) { |q| fire.call; super(q) }
      when :analyze? then define_method(:analyze?) { fire.call; true }
      when :result
        define_method(:result) { fire.call; nil }
      else
        define_method(hook) { |*a| fire.call; super(*a) }
        define_method(:result) { nil } if base == GraphQL::Analysis::Analyzer
      end
      define_method(:result) { nil } if base == GraphQL::Analysis::Analyzer && hook != :result
    end
  end

  DEEP = "query Q { node { child { child { child { leaf } } } } ...F ... on Query { cheap } boomArg(x: false) @include(if: true) } fragment F on Query { cheap }"
  COSTLY = "{ report other }"
  HOOKS = %i[on_enter_field on_leave_field on_enter_operation_definition on_leave_operation_definition on_enter_fragment_spread on_enter_inline_fragment on_enter_argument on_enter_directive result analyze? initialize].freeze

  # ---- G0 environment
  it "preservation G0 who answers analyze_query" do
    schema = build_schema
    q = GraphQL::Query.new(schema, "{ cheap }", context: { rate_limit_key: "u" })
    owner = q.current_trace.method(:analyze_query).owner
    log("owner", [owner, schema.trace_class.ancestors.first(6)])
    expect(owner).to eq(RL::AnalysisGuard)
  end

  # ---- G1 every hook x every maximum
  HOOKS.each do |hook|
    it "security G1 max_depth survives a raise in #{hook}" do
      schema = build_schema(max_depth: 3, analyzers: [raiser(hook)])
      expect_refused(run(schema, DEEP), /depth/)
    end

    it "security G1 max_complexity survives a raise in #{hook}" do
      schema = build_schema(max_complexity: 3, analyzers: [raiser(hook)])
      expect_refused(run(schema, DEEP), /complexity/)
    end

    it "security G1 raise only on first call in #{hook}, both maximums" do
      schema = build_schema(max_depth: 3, max_complexity: 3, analyzers: [raiser(hook, only: ->(n) { n == 1 })])
      res = run(schema, DEEP)
      expect_refused(res, /depth.*complexity/)
    end
  end

  it "security G1 UnauthorizedError from an analyzer keeps max_depth" do
    schema = build_schema(max_depth: 3, analyzers: [raiser(:on_enter_field, error: GraphQL::UnauthorizedError.new("no"))])
    expect_refused(run(schema, DEEP), /depth/)
  end

  it "security G1 analyzer raising only for a client-chosen alias keeps max_depth, either order" do
    pick = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:on_enter_field) { |node, _p, _v| raise GraphQL::ExecutionError, "x" if node.alias == "trigger" }
      define_method(:result) { nil }
    end
    schema = build_schema(max_depth: 3, analyzers: [pick])
    expect_refused(run(schema, "{ trigger: cheap node { child { child { child { leaf } } } } }"), /depth/)
    expect_refused(run(schema, "{ node { child { child { child { leaf } } } } trigger: cheap }"), /depth/)
  end

  # ---- G1b lambdas
  {
    "always" => ->(_n, _a) { true },
    "first call only" => ->(n, _a) { n == 1 },
    "second call only" => ->(n, _a) { n == 2 },
    "from the second call on" => ->(n, _a) { n >= 2 },
    "odd calls" => ->(n, _a) { n.odd? },
    "even calls" => ->(n, _a) { n.even? },
    "third call only" => ->(n, _a) { n == 3 },
  }.each do |name, cond|
    it "security G1b lambda raising #{name}, over max_complexity, soft limiter" do
      n = 0
      hook = ->(_c, a) { n += 1; raise GraphQL::ExecutionError, "x" if cond.call(n, a) }
      schema = build_schema(max_complexity: 10, hook: hook)
      res = run(schema, "{ report boom }")
      log("lambda #{name}", [n, msgs(res)])
      expect_refused(res)
    end

    it "security G1b lambda raising #{name}, over max_complexity, hard limiter and exempt client" do
      n = 0
      hook = ->(_c, a) { n += 1; raise GraphQL::ExecutionError, "x" if cond.call(n, a) }
      schema = build_schema(limiters: [[:points, { soft: false, limit: ->(_k, _q) { nil } }]], max_complexity: 10, hook: hook)
      expect_refused(run(schema, "{ report boom }"))
    end
  end

  it "security G1b lambda raising Unauthorized over max_complexity" do
    schema = build_schema(max_complexity: 10, hook: ->(_c, _a) { raise GraphQL::UnauthorizedError, "no" })
    res = run(schema, "{ report boom }")
    expect_refused(res)
    expect(codes(res)).to eq(["QUERY_LIMIT_UNKNOWN"])
  end

  it "security G1b lambda raising under the maximum refuses with QUERY_LIMIT_UNKNOWN as documented (soft)" do
    schema = build_schema(max_complexity: 100, hook: ->(_c, _a) { raise GraphQL::ExecutionError, "no" })
    res = run(schema, "{ cheap boom }")
    expect_refused(res)
    expect(codes(res)).to eq(["QUERY_LIMIT_UNKNOWN"])
  end

  it "security G1b lambda raising for an exempt client refuses with QUERY_LIMIT_UNKNOWN" do
    schema = build_schema(limiters: [[:points, { soft: false, limit: ->(_k, _q) { nil } }]], max_complexity: 100, hook: ->(_c, _a) { raise GraphQL::ExecutionError, "no" })
    res = run(schema, "{ cheap boom }")
    expect_refused(res)
    expect(codes(res)).to eq(["QUERY_LIMIT_UNKNOWN"])
  end

  it "security G1b lambda raising by argument, in a fragment, aliased, over max_complexity" do
    hook = ->(_c, a) { raise GraphQL::ExecutionError, "x" if a[:x] }
    schema = build_schema(max_complexity: 10, hook: hook)
    ["{ report a: boomArg(x: true) }", "{ a: boomArg(x: true) report }", "{ report ...F } fragment F on Query { b: boomArg(x: true) }", "{ report ... on Query { boomArg(x: true) } }"].each do |q|
      expect_refused(run(schema, q))
    end
  end

  it "security G1b lambda raising via variable" do
    hook = ->(_c, a) { raise GraphQL::ExecutionError, "x" if a[:x] }
    schema = build_schema(max_complexity: 10, hook: hook)
    expect_refused(run(schema, "query Q($v: Boolean) { report boomArg(x: $v) }", variables: { "v" => true }))
  end

  it "security G1b deep query with raising lambda under Node keeps max_depth" do
    schema = build_schema(max_depth: 2, hook: ->(_c, _a) { raise GraphQL::ExecutionError, "x" })
    res = run(schema, "{ node { child { child { boom } } } }")
    expect_refused(res, /depth/)
    log("depth+lambda", msgs(res))
  end

  it "preservation G1b raising field under @skip: lambda not visited, the maximum answers" do
    n = 0
    schema = build_schema(max_complexity: 10, hook: ->(_c, _a) { n += 1; raise GraphQL::ExecutionError, "x" })
    res = run(schema, "{ report boom @skip(if: true) }")
    expect_refused(res, /complexity/)
    expect(n).to eq(0)
  end

  it "security G1b raising field under @include via variable, over the maximum" do
    schema = build_schema(max_complexity: 10, hook: ->(_c, _a) { raise GraphQL::ExecutionError, "x" })
    expect_refused(run(schema, "query Q($v: Boolean!) { report boom @include(if: $v) }", variables: { "v" => true }))
  end

  # ---- G1c per-query values
  it "security G1c per-query max_depth low and 0 stand over a raise" do
    schema = build_schema(analyzers: [raiser(:on_enter_field)])
    expect_refused(run(schema, "{ node { leaf } }", max_depth: 1), /depth/)
    expect_refused(run(schema, "{ cheap }", max_depth: 0), /depth/)
  end

  it "security G1c per-query max_complexity low and 0 stand over a raise" do
    schema = build_schema(analyzers: [raiser(:on_enter_field)])
    expect_refused(run(schema, "{ report }", max_complexity: 1), /complexity/)
    expect_refused(run(schema, "{ cheap }", max_complexity: 0), /complexity/)
  end

  it "preservation G1c per-query max_depth nil and max_complexity nil lift the schema's, also on the raise path" do
    schema = build_schema(max_depth: 1, max_complexity: 1, hook: ->(_c, _a) { raise GraphQL::ExecutionError, "x" })
    expect_ran(run(schema, "{ node { leaf } boom }", max_depth: nil, max_complexity: nil))
  end

  it "security G1c child schema adding maximums after the parent's use" do
    parent = build_schema(analyzers: [raiser(:on_enter_field)])
    child = Class.new(parent) { max_depth 2 }
    expect_refused(run(child, "{ node { child { child { leaf } } } }"), /depth/)
  end

  it "security G1c mutation over max_complexity with a raising lambda resolves nothing" do
    schema = build_schema(max_complexity: 10, hook: ->(_c, _a) { raise GraphQL::ExecutionError, "x" })
    expect_refused(run(schema, "mutation { act boom }"))
  end

  it "security G1c several operations and operation_name" do
    schema = build_schema(max_depth: 2, analyzers: [raiser(:on_enter_field)])
    doc = "query A { cheap } query B { node { child { child { leaf } } } }"
    expect_refused(run(schema, doc, operation_name: "B"), /depth/)
  end

  it "preservation G1c unselected raising operation does not refuse a selected cheap one" do
    schema = build_schema(max_complexity: 100, hook: ->(_c, _a) { raise GraphQL::ExecutionError, "x" })
    expect_ran(run(schema, "query A { cheap } query B { boom }", operation_name: "A"))
  end

  it "security G1c key: lambda raising keeps a maximum (soft)" do
    schema = build_schema(limiters: [[:points, { soft: true, key: ->(_q) { raise GraphQL::ExecutionError, "x" } }]], max_depth: 2)
    expect_refused(run(schema, "{ node { child { child { leaf } } } }"), /depth/)
  end

  it "security G1c limit: lambda raising keeps a maximum (soft)" do
    schema = build_schema(limiters: [[:points, { soft: true, limit: ->(_k, _q) { raise GraphQL::ExecutionError, "x" } }]], max_depth: 2)
    expect_refused(run(schema, "{ node { child { child { leaf } } } }"), /depth/)
  end

  it "security G1c on_store_error raising in soft keeps a maximum" do
    store.fail_with(IOError.new("down"))
    schema = build_schema(limiters: [[:points, { soft: true, on_store_error: ->(_e, _q) { raise GraphQL::ExecutionError, "x" } }]], max_depth: 2)
    expect_refused(run(schema, "{ node { child { child { leaf } } } }"), /depth/)
  end

  it "security G1c argument prepare raising, chosen by the client, over max_depth" do
    schema = build_schema(max_depth: 2)
    res = run(schema, "{ prep(v: \"bad\") node { child { child { leaf } } } }")
    log("prepare", msgs(res))
    expect_refused(res, /depth/)
  end

  it "security G1c validate: false on the interpreter keeps the maximum" do
    skip "documented limit on Next" if ArmoryEngine.next?
    schema = build_schema(max_depth: 2, analyzers: [raiser(:on_enter_field)])
    expect_refused(run(schema, "{ node { child { child { leaf } } } }", validate: false), /depth/)
  end

  [:concurrency, :time].each do |kind|
    it "security G1c #{kind} alone protects maximums" do
      schema = build_schema(limiters: [[kind, { soft: true }]], max_depth: 2, analyzers: [raiser(:on_enter_field)])
      expect_refused(run(schema, "{ node { child { child { leaf } } } }"), /depth/)
    end

    it "security G1c #{kind} alone: lambda raising refuses" do
      schema = build_schema(limiters: [[kind, { soft: true }]], max_complexity: 10, hook: ->(_c, _a) { raise GraphQL::ExecutionError, "x" })
      res = run(schema, "{ report boom }")
      expect_refused(res)
      expect(codes(res)).to eq(["QUERY_LIMIT_UNKNOWN"])
    end
  end

  it "security G1d max subclass that raises only on the re-ask refuses" do
    sub = Class.new(GraphQL::Analysis::MaxQueryDepth) do
      define_method(:result) { raise GraphQL::ExecutionError, "x" }
    end
    schema = build_schema(analyzers: [raiser(:on_enter_field), sub])
    res = run(schema, "{ cheap }")
    expect_refused(res)
    expect(codes(res)).to eq(["QUERY_LIMIT_UNKNOWN"])
  end

  # ---- G2 the cannot-answer test
  it "preservation G2 analyze? false subclass does not refuse" do
    sub = Class.new(GraphQL::Analysis::MaxQueryDepth) { define_method(:analyze?) { false } }
    schema = build_schema(analyzers: [raiser(:on_enter_field), sub])
    expect_ran(run(schema, "{ cheap }"))
  end

  it "preservation G2 subclass whose result is a String or [] does not refuse" do
    [("nope"), []].each do |value|
      sub = Class.new(GraphQL::Analysis::MaxQueryDepth) { define_method(:result) { value } }
      schema = build_schema(analyzers: [raiser(:on_enter_field), sub])
      expect_ran(run(schema, "{ cheap }"))
    end
  end

  it "security G2 subclass returning a nested [error] refuses" do
    sub = Class.new(GraphQL::Analysis::MaxQueryDepth) { define_method(:result) { [[GraphQL::AnalysisError.new("nested")]] } }
    schema = build_schema(analyzers: [raiser(:on_enter_field), sub])
    expect_refused(run(schema, "{ cheap }"), /nested/)
  end

  it "preservation G2 app results that are not arrays survive flatten" do
    [{ a: 1 }, 5, nil, :sym, Struct.new(:x).new(1), BasicObject.new].each do |value|
      app = Class.new(GraphQL::Analysis::Analyzer) { define_method(:result) { value } }
      schema = build_schema(analyzers: [raiser(:on_enter_field), app])
      expect_ran(run(schema, "{ cheap }"))
    end
  end

  %i[on_enter_field result analyze? initialize].each do |hook|
    [GraphQL::Analysis::MaxQueryDepth, GraphQL::Analysis::MaxQueryComplexity].each do |base|
      it "security G2 raising #{base.name.split('::').last} subclass in #{hook} refuses with QUERY_LIMIT_UNKNOWN" do
        sub = raiser(hook, base: base)
        schema = build_schema(analyzers: [sub], max_complexity: nil)
        res = run(schema, "{ cheap }", max_complexity: 1000)
        expect_refused(res)
        expect(codes(res)).to include("QUERY_LIMIT_UNKNOWN")
      end
    end
  end

  it "preservation G2 analyze? raising once then false: nothing to answer, query runs" do
    n = 0
    sub = Class.new(GraphQL::Analysis::MaxQueryDepth) do
      define_method(:analyze?) { n += 1; raise GraphQL::ExecutionError, "x" if n == 1; false }
    end
    schema = build_schema(analyzers: [sub])
    expect_ran(run(schema, "{ cheap }"))
  end

  xit "security G2 QueryComplexity-based app maximum (not a subclass) with a raising lambda must not be passable" do
    app_max = Class.new(GraphQL::Analysis::QueryComplexity) do
      define_method(:result) do
        cost = super()
        GraphQL::AnalysisError.new("app max: #{cost}") if cost > 10
      end
    end
    schema = build_schema(analyzers: [app_max], hook: ->(_c, _a) { raise GraphQL::ExecutionError, "x" })
    expect_refused(run(schema, "{ report }"), /app max/) # the control: without the raising field it refuses
    @resolved = []
    res = run(schema, "{ report boom }")
    log("app QueryComplexity max + raising lambda", res.to_h)
    expect_refused(res)
  end

  it "security G2 QueryDepth-based app maximum (not a subclass) stands when another analyzer raises" do
    app_max = Class.new(GraphQL::Analysis::QueryDepth) do
      define_method(:result) { GraphQL::AnalysisError.new("app depth #{super()}") if super() > 2 }
    end
    schema = build_schema(analyzers: [raiser(:on_enter_field), app_max])
    expect_refused(run(schema, "{ node { child { child { leaf } } } }"), /app depth/)
  end

  it "security G2 QueryComplexity-based app maximum stands when another analyzer raises (no raising lambda)" do
    app_max = Class.new(GraphQL::Analysis::QueryComplexity) do
      define_method(:result) { GraphQL::AnalysisError.new("app cost") if super() > 10 }
    end
    schema = build_schema(analyzers: [raiser(:on_enter_field), app_max])
    expect_refused(run(schema, COSTLY), /app cost/)
  end

  it "preservation G2 analyzer given as a non-Class factory that raises must not turn into a crash" do
    inner = raiser(:on_enter_field)
    factory = Object.new
    factory.define_singleton_method(:new) { |q| inner.new(q) }
    schema = build_schema(analyzers: [factory])
    expect_ran(run(schema, "{ cheap }"))
  end

  # ---- G3 effects of asking again
  it "preservation G3 side effects repeat as documented (count)" do
    runs = 0
    app = Class.new(GraphQL::Analysis::Analyzer) { define_method(:result) { runs += 1; nil } }
    schema = build_schema(analyzers: [app, raiser(:result)])
    expect_ran(run(schema, "{ cheap }"))
    log("app analyzer result runs", runs)
    expect(runs).to eq(2)
  end

  it "preservation G3 app-written limiter is charged twice (documented; measure)" do
    bucket = 100
    app = Class.new(GraphQL::Analysis::QueryComplexity) do
      define_method(:result) { bucket -= super(); nil }
    end
    schema = build_schema(analyzers: [app, raiser(:result)])
    expect_ran(run(schema, "{ report }"))
    log("app limiter bucket after a 40-point query", bucket)
    expect(bucket).to eq(20)
  end

  it "preservation G3 nested analysis in an analyzer passes through and does not recurse or charge" do
    nested = Class.new(GraphQL::Analysis::QueryDepth)
    seen = []
    app = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:result) { seen << GraphQL::Analysis.analyze_query(query, [nested]); nil }
    end
    schema = build_schema(analyzers: [raiser(:on_enter_field), app])
    expect_ran(run(schema, "{ node { leaf } }"))
    log("nested", seen)
    expect(seen).to eq([[2]])
    expect(store.calls.count { |c| c[0] == :take }).to eq(1)
  end

  it "preservation G3 a nested analysis that raises inside a re-ask does not stop the guard" do
    nested = raiser(:on_enter_field)
    app = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:result) { GraphQL::Analysis.analyze_query(query, [nested]); nil }
    end
    schema = build_schema(analyzers: [app], max_depth: 1)
    expect_refused(run(schema, "{ node { leaf } }"), /depth/)
  end

  it "security G3 a non-ExecutionError on the re-ask raises to the app, no data, slot released" do
    n = 0
    app = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:result) { n += 1; raise ArgumentError, "again" if n >= 1; nil }
    end
    schema = build_schema(limiters: [[:concurrency, { soft: false, limit: 1 }]], analyzers: [raiser(:on_enter_field), app])
    expect { run(schema, "{ cheap }") }.to raise_error(ArgumentError)
    expect(resolved).to be_empty
    expect(store.held("user:1")).to eq(0)
  end

  it "preservation G3 an ExecutionError returned (not raised) is not a refusal" do
    app = Class.new(GraphQL::Analysis::Analyzer) { define_method(:result) { GraphQL::ExecutionError.new("returned") } }
    schema = build_schema(analyzers: [raiser(:on_enter_field), app])
    expect_ran(run(schema, "{ cheap }"))
  end

  it "security G3 order and duplicates with a limiter's kept refusal and a maximum" do
    store.take("user:1", cost: 1000, limit: 1000, window: 60, force: true)
    store.calls.clear
    limiter_first = [[:points, { soft: false, limit: 1000 }]]
    schema = build_schema(limiters: limiter_first, max_depth: 2, analyzers: [raiser(:result)])
    res = run(schema, "{ node { child { child { leaf } } } }")
    log("order", [codes(res), msgs(res)])
    expect_refused(res)
    expect(codes(res).first).to eq("RATE_LIMITED")
    expect(msgs(res).uniq.size).to eq(msgs(res).size)
    expect(msgs(res).last).to match(/depth/)
    expect(store.calls.count { |c| c[0] == :take }).to eq(1)
  end

  it "security G3 an AnalysisError raised by one analyzer stands when another raises ExecutionError" do
    a = raiser(:on_enter_field, error: GraphQL::AnalysisError.new("refused by raise"))
    b = raiser(:on_leave_operation_definition)
    schema = build_schema(analyzers: [a, b])
    expect_refused(run(schema, "{ cheap }"), /refused by raise/)
  end

  xit "security G3 one analyzer raising AnalysisError then ExecutionError in the same visit" do
    app = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:on_enter_field) { |node, _p, _v| raise GraphQL::AnalysisError, "refused by raise" if node.name == "cheap"; raise GraphQL::ExecutionError, "x" if node.name == "report" }
      define_method(:result) { nil }
    end
    schema = build_schema(analyzers: [app])
    res = run(schema, "{ cheap report }")
    log("same analyzer AnalysisError then ExecutionError", res.to_h)
    expect_refused(res, /refused by raise/)
  end

  xit "security G3 an app refusal memoized in the context (returned once) stands" do
    app = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:result) do
        next if query.context[:checked]
        query.context[:checked] = true
        GraphQL::AnalysisError.new("once")
      end
    end
    schema = build_schema(analyzers: [app, raiser(:result)])
    res = run(schema, "{ cheap }")
    log("memoized app refusal", res.to_h)
    expect_refused(res, /once/)
  end

  xit "security G3 an app analyzer that returned a refusal and raises only on the re-ask" do
    n = 0
    app = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:result) do
        n += 1
        raise GraphQL::ExecutionError, "x" if n == 2
        GraphQL::AnalysisError.new("first answer")
      end
    end
    schema = build_schema(analyzers: [app, raiser(:result)])
    res = run(schema, "{ cheap }")
    log("refusal then raise on re-ask", res.to_h)
    expect_refused(res, /first answer/)
  end

  xit "security G3 an app analyzer that raises in its own visit and would refuse" do
    app = Class.new(GraphQL::Analysis::QueryDepth) do
      define_method(:on_enter_field) { |node, p, v| raise GraphQL::ExecutionError, "x" if node.name == "cheap"; super(node, p, v) }
      define_method(:result) { GraphQL::AnalysisError.new("too deep") if super() > 2 }
    end
    schema = build_schema(analyzers: [app])
    res = run(schema, "{ cheap node { child { child { leaf } } } }")
    log("app analyzer raising itself", res.to_h)
    expect_refused(res)
  end

  it "preservation G3 frozen empty array: soft, no maximum, raising lambda runs" do
    schema = build_schema(hook: ->(_c, _a) { raise GraphQL::ExecutionError, "x" })
    res = run(schema, "{ boom }")
    expect_ran(res)
    expect(res.context[:rate_limit_points]).to include(charged: false, limited: false, soft: true)
  end

  # ---- G4 timeouts
  def slow(counter, seconds)
    Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:on_enter_field) { |*| counter[0] += 1; sleep(seconds) }
      define_method(:result) { nil }
    end
  end

  def timed
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    r = yield
    [r, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t]
  end

  def timeout_msg?(res) = msgs(res).any? { |m| m =~ /Timeout/ }

  it "security G4 timeout from the visit, soft limiter and maximum: refused, others not re-asked" do
    c = [0]; other = [0]
    witness = Class.new(GraphQL::Analysis::Analyzer) { define_method(:result) { other[0] += 1; nil } }
    schema = build_schema(max_depth: 50, analyzers: [slow(c, 0.06), witness], timeout: 0.05)
    res, took = timed { run(schema, "{ cheap report other }") }
    log("timeout soft", [msgs(res), c[0], other[0], took.round(3)])
    expect_refused(res, /Timeout/)
    expect(other[0]).to eq(0)
  end

  it "security G4 timeout from the visit, hard limiter" do
    c = [0]
    schema = build_schema(limiters: [[:points, { soft: false }]], analyzers: [slow(c, 0.06)], timeout: 0.05)
    res = run(schema, "{ cheap report other }")
    log("timeout hard", [msgs(res), codes(res), c[0], store.calls.size])
    expect_refused(res, /Timeout/)
  end

  it "security G4 timeout for an exempt client" do
    c = [0]
    schema = build_schema(limiters: [[:points, { soft: false, limit: ->(_k, _q) { nil } }]], analyzers: [slow(c, 0.06)], timeout: 0.05)
    res = run(schema, "{ cheap report other }")
    expect_refused(res, /Timeout/)
  end

  it "security G4 a TimeoutError raised from a lambda refuses (soft, hard) and asks no non-limiter again" do
    [{ soft: true }, { soft: false }].each do |opts|
      @resolved = []
      other = [0]
      witness = Class.new(GraphQL::Analysis::Analyzer) { define_method(:result) { other[0] += 1; nil } }
      n = 0
      hook = ->(_c, _a) { n += 1; raise GraphQL::Analysis::TimeoutError }
      schema = build_schema(limiters: [[:points, opts]], analyzers: [witness], hook: hook)
      res = run(schema, "{ boom }")
      log("timeout lambda #{opts}", [msgs(res), n, other[0]])
      expect_refused(res, /Timeout/)
    end
  end

  it "security G4 the limiter is the only thing visited again after a timeout (doc: 'nothing is analyzed again')" do
    c = [0]
    visits = [0]
    schema = build_schema(limiters: [[:points, { soft: true }]], max_depth: 50, analyzers: [slow(c, 0.06)], timeout: 0.05)
    res, took = timed { run(schema, "{ cheap report other }") }
    log("after timeout", [c[0], took.round(3), store.calls.size, visits[0]])
    expect_refused(res, /Timeout/)
    expect(c[0]).to eq(1)
  end

  it "security G4 several limiters after a timeout: count analysis of each" do
    calls = [0]
    hook = ->(_c, _a) { calls[0] += 1 }
    c = [0]
    schema = build_schema(limiters: [[:points, { soft: true, key: ->(_q) { "a" } }], [:points, { soft: true, key: ->(_q) { "b" } }], [:points, { soft: true, key: ->(_q) { "c" } }]], analyzers: [slow(c, 0.0)], hook: hook, timeout: 0.05)
    # The slow witness below makes only the first pass slow.
    n = 0
    only_first = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:on_enter_field) { |*| n += 1; sleep(0.06) if n == 1 }
      define_method(:result) { nil }
    end
    schema.query_analyzer(only_first)
    res = run(schema, "{ cheap boom other }")
    log("3 limiters after a visit timeout: lambda calls, charges", [msgs(res), calls[0], store.calls.size])
    expect_refused(res, /Timeout/)
  end

  it "security G4 a timeout only on the re-ask refuses" do
    n = 0
    app = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:on_enter_field) { |*| n += 1; sleep(0.06) if n >= 2 }
      define_method(:result) { nil }
    end
    schema = build_schema(analyzers: [app, raiser(:on_enter_operation_definition, only: ->(k) { k == 1 })], timeout: 0.05)
    res = run(schema, "{ cheap report other }")
    log("timeout on re-ask", [msgs(res), codes(res)])
    expect_refused(res, /Timeout/)
  end

  it "security G4 N analyzers each timing out on the re-ask do not multiply analysis time" do
    counters = Array.new(4) { [0] }
    slows = counters.map { |c| slow(c, 0.06) }
    raising_first = raiser(:on_enter_operation_definition, only: ->(k) { k == 1 })
    schema = build_schema(analyzers: [raising_first, *slows], timeout: 0.05)
    res, took = timed { run(schema, "{ cheap report other }") }
    log("re-ask timeouts", [msgs(res), counters.flatten, took.round(3)])
    expect_refused(res, /Timeout/)
    expect(counters.flatten.count { |x| x > 0 }).to eq(1)
    expect(msgs(res).size).to eq(1)
  end

  it "preservation G4 time of the same schema with no raise: baseline for the multiplication" do
    counters = Array.new(4) { [0] }
    slows = counters.map { |c| slow(c, 0.06) }
    schema = build_schema(analyzers: slows, timeout: 0.05)
    res, took = timed { run(schema, "{ cheap report other }") }
    log("baseline no raise", [msgs(res), counters.flatten, took.round(3)])
    expect_refused(res, /Timeout/)
  end

  # ---- G5 regressions
  it "preservation G5 exempt client, raising lambda, no maximum runs" do
    schema = build_schema(limiters: [[:points, { soft: false, limit: ->(_k, _q) { nil } }]], hook: ->(_c, _a) { raise GraphQL::ExecutionError, "x" })
    expect_ran(run(schema, "{ boom }"))
  end

  it "preservation G5 hard limiter, raising lambda, maximum: exactly one error" do
    schema = build_schema(limiters: [[:points, { soft: false }]], max_complexity: 100, max_depth: 10, hook: ->(_c, _a) { raise GraphQL::ExecutionError, "x" })
    res = run(schema, "{ boom }")
    expect(codes(res)).to eq(["RATE_LIMIT_NOT_CHARGED"])
  end

  it "preservation G5 hard limiter refusing with a maximum refusing without a raise: graphql's own two errors" do
    schema = build_schema(limiters: [[:points, { soft: false, limit: 5 }]], max_complexity: 10)
    res = run(schema, "{ report other }")
    log("no raise two errors", msgs(res))
    expect(errs(res).size).to eq(2)
  end

  it "preservation G5 under maximums, another analyzer raises: runs and is charged once" do
    schema = build_schema(limiters: [[:points, { soft: false, limit: 100 }]], max_depth: 10, max_complexity: 100, analyzers: [raiser(:on_enter_field)])
    res = run(schema, "{ report }")
    expect_ran(res)
    expect(store.calls.count { |c| c[0] == :take }).to eq(1)
    expect(res.context[:rate_limit_points]).to include(cost: 40, remaining: 60)
  end

  it "preservation G5 no raise at all: guard does not touch the answer (depth only)" do
    schema = build_schema(max_depth: 2)
    expect_refused(run(schema, "{ node { child { leaf } } }"), /depth/)
  end

  it "security G5 multiplex: only the raising query is on the raise path, others untouched, each charged once" do
    n = 0
    pick = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:on_enter_field) { |node, _p, _v| n += 1; raise GraphQL::ExecutionError, "x" if node.alias == "trigger" }
      define_method(:result) { nil }
    end
    schema = build_schema(limiters: [[:points, { soft: false, limit: 1000 }]], max_depth: 3, analyzers: [pick])
    queries = [
      { query: "{ cheap }", context: { rate_limit_key: "a" }, root_value: root },
      { query: "{ trigger: cheap node { child { child { child { leaf } } } } }", context: { rate_limit_key: "b" }, root_value: root },
      { query: "{ report }", context: { rate_limit_key: "c" }, root_value: root },
      { query: "{ trigger: cheap report }", context: { rate_limit_key: "d" }, root_value: root },
    ]
    results = mx(schema, queries, max_complexity: nil)
    expect(results[0].to_h).to eq("data" => { "cheap" => "ok" })
    expect(msgs(results[1]).join).to match(/depth/)
    expect(results[1].to_h["data"]).to be_nil
    expect(results[2].to_h).to eq("data" => { "report" => "ok" })
    expect(results[3].to_h["data"]).to eq("trigger" => "ok", "report" => "ok")
    expect(store.calls.select { |c| c[0] == :take }.map { |c| c[1] }.sort).to eq(%w[a b c d])
  end

  it "security G5 multiplex sharing a context hash" do
    pick = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:on_enter_field) { |node, _p, _v| raise GraphQL::ExecutionError, "x" if node.alias == "trigger" }
      define_method(:result) { nil }
    end
    schema = build_schema(max_depth: 2, analyzers: [pick])
    ctx = { rate_limit_key: "a" }
    results = mx(schema, [{ query: "{ trigger: cheap node { child { child { leaf } } } }", context: ctx, root_value: root }, { query: "{ trigger: cheap }", context: ctx, root_value: root }, { query: "{ node { child { child { leaf } } } }", context: ctx, root_value: root }], max_complexity: nil)
    expect(results[0].to_h["data"]).to be_nil
    expect(results[1].to_h["data"]).to eq("trigger" => "ok")
    expect(results[2].to_h["data"]).to be_nil
  end

  xit "security G5 multiplex default: schema max_complexity at multiplex level counts the sum; a raise undercounts" do
    pick = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:on_enter_field) { |node, _p, _v| raise GraphQL::ExecutionError, "x" if node.alias == "trigger" }
      define_method(:result) { nil }
    end
    schema = build_schema(max_complexity: 50, analyzers: [pick])
    q = ->(s) { { query: s, context: { rate_limit_key: "a" }, root_value: root } }
    control = mx(schema, [q.("{ report }"), q.("{ other }")])
    log("multiplex default control", control.map(&:to_h))
    @resolved = []
    results = mx(schema, [q.("{ trigger: cheap report }"), q.("{ other }")])
    log("multiplex default raise", results.map(&:to_h))
    expect(results.map { |r| r.to_h["data"] }).to eq([nil, nil])
  end

  it "preservation G5 analysis the app runs itself passes through and charges nothing" do
    schema = build_schema(max_depth: 1, analyzers: [raiser(:on_enter_field)])
    q = GraphQL::Query.new(schema, "{ node { leaf } }", context: { rate_limit_key: "u" })
    out = GraphQL::Analysis.analyze_query(q, q.analyzers)
    expect(out).to eq([])
    expect(store.calls).to be_empty
  end

  it "preservation G5 invalid query charged once by the trace, no guard" do
    schema = build_schema(max_depth: 1, analyzers: [raiser(:on_enter_field)])
    res = run(schema, "{ nope }")
    expect(res.to_h["data"]).to be_nil
    expect(store.calls.size).to eq(1)
  end

  [:before, :after].each do |where|
    it "security G5 an app trace with analyze_query #{where} `use` does not undo the guard" do
      seen = []
      trace = Module.new do
        define_method(:analyze_query) { |query:, &b| seen << :traced; super(query: query, &b) }
      end
      schema = build_schema(traces: where == :before ? [trace] : [nil, trace].compact.then { |t| [Module.new, *t] }, max_depth: 2, analyzers: [raiser(:on_enter_field)])
      expect_refused(run(schema, "{ node { child { child { leaf } } } }"), /depth/)
      expect(seen).not_to be_empty
    end
  end

  it "preservation G5 schema with no limiter keeps graphql's behaviour (documented limit)" do
    schema = build_schema(limiters: [], max_depth: 2, analyzers: [raiser(:on_enter_field)])
    expect_ran(run(schema, "{ node { child { child { leaf } } } }"))
  end

  it "preservation G5 two limiters, raising lambda, soft: each records charged false once; maximum refuses" do
    schema = build_schema(limiters: [[:points, { soft: true }], [:time, { soft: true }]], max_complexity: 100, hook: ->(_c, _a) { raise GraphQL::ExecutionError, "x" })
    res = run(schema, "{ boom }")
    expect(codes(res)).to eq(["QUERY_LIMIT_UNKNOWN"])
    log("two limiters", [res.context[:rate_limit_points], res.context[:rate_limit_time]])
  end

  # ---- G6 charge and slots
  { "depth" => [{ max_depth: 1 }, "{ node { leaf } boom }"], "unknown" => [{ max_complexity: 100 }, "{ boom }"] }.each do |why, (max, q)|
    [true, false].each do |soft|
      it "preservation G6 Concurrency soft=#{soft} slot released when refused by #{why}" do
        hook = ->(_c, _a) { raise GraphQL::ExecutionError, "x" }
        schema = build_schema(limiters: [[:concurrency, { soft: soft, limit: 1 }]], hook: hook, **max)
        res = run(schema, q)
        expect_refused(res)
        expect(store.held("user:1")).to eq(0)
        log("slots #{why} #{soft}", store.calls.map(&:first))
        expect(store.calls.count { |c| c[0] == :acquire }).to eq(1)
        expect(store.calls.count { |c| c[0] == :release }).to eq(1)
      end
    end
  end

  it "preservation G6 Concurrency several keys, refused by depth: all slots back" do
    schema = build_schema(limiters: [[:concurrency, { soft: false, limit: 1, key: ->(_q) { %w[a b] } }]], max_depth: 1, analyzers: [raiser(:on_enter_field)])
    expect_refused(run(schema, "{ node { leaf } }"), /depth/)
    expect([store.held("a"), store.held("b")]).to eq([0, 0])
  end

  it "preservation G6 Time refused by unknown: debt settled once, record says so" do
    clock = RL::Clock::Substitute.new
    hook = ->(_c, _a) { clock.advance(0.5); raise GraphQL::ExecutionError, "x" }
    schema = build_schema(limiters: [[:time, { soft: false, limit: 10_000, clock: clock }]], max_complexity: 100, hook: hook)
    res = run(schema, "{ boom }")
    expect_refused(res)
    takes = store.calls.select { |c| c[0] == :take }
    log("time refused unknown", [takes.map { |c| c[2].slice(:cost, :force) }, res.context[:rate_limit_time]])
    expect(takes.size).to eq(2)
    expect(takes.last[2][:cost]).to be > 0
    expect(res.context.namespace(:graphql_armory)[:time_charges].to_h).to be_empty
  end

  it "preservation G6 exhausted Time, raising analyzer, maximum: refused and no debt" do
    clock = RL::Clock::Substitute.new
    store.take(RL::Time.bucket_key("user:1"), cost: 10_000, limit: 10_000, window: 60, force: true)
    store.calls.clear
    schema = build_schema(limiters: [[:time, { soft: false, limit: 10_000, clock: clock }]], max_depth: 1, analyzers: [raiser(:result)])
    res = run(schema, "{ node { leaf } }")
    log("time exhausted", [codes(res), msgs(res), store.calls.map { |c| c[2].slice(:cost) }])
    expect_refused(res)
    expect(codes(res).first).to eq("RATE_LIMITED")
    expect(store.calls.size).to eq(1)
  end

  it "preservation G6 Points refused by depth after a raise: charged once as the docs say" do
    schema = build_schema(limiters: [[:points, { soft: false, limit: 100 }]], max_depth: 1, analyzers: [raiser(:on_enter_field)])
    res = run(schema, "{ node { leaf } }")
    expect_refused(res, /depth/)
    takes = store.calls.select { |c| c[0] == :take }
    expect(takes.size).to eq(1)
    expect(res.context[:rate_limit_points]).to include(cost: 2, remaining: 98, limited: false)
  end

  it "preservation G6 Points soft refused by unknown: not charged, record says charged false" do
    schema = build_schema(limiters: [[:points, { soft: true, limit: 100 }]], max_complexity: 100, hook: ->(_c, _a) { raise GraphQL::ExecutionError, "x" })
    res = run(schema, "{ boom }")
    expect_refused(res)
    expect(store.calls).to be_empty
    expect(res.context[:rate_limit_points]).to include(charged: false, limited: false)
    log("record says", res.context[:rate_limit_points])
  end

  it "preservation G6 re-ask does not run the limiter twice when its answer was kept (lambda raising only after the limiter)" do
    n = 0
    hook = ->(_c, _a) { n += 1; raise GraphQL::ExecutionError, "x" if n == 2 }
    schema = build_schema(limiters: [[:points, { soft: false, limit: 100 }]], max_complexity: 100, hook: hook)
    res = run(schema, "{ boom }")
    log("limiter then Max raises once", [n, msgs(res), store.calls.size])
    expect_ran(res)
    expect(store.calls.count { |c| c[0] == :take }).to eq(1)
  end

  # ---- second batch
  it "security G4b slow per-field app analyzers: a client-chosen raise must not multiply a timeout (measure)" do
    trigger = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:on_enter_field) { |node, _p, _v| raise GraphQL::ExecutionError, "x" if node.alias == "trigger" }
      define_method(:result) { nil }
    end
    slows = Array.new(4) { slow([0], 0.02) }
    fields = (1..40).map { |i| "a#{i}: cheap" }.join(" ")
    schema = build_schema(analyzers: [trigger, *slows], timeout: 0.1)
    base, t_base = timed { run(schema, "{ #{fields} }") }
    @resolved = []
    hit, t_hit = timed { run(schema, "{ trigger: cheap #{fields} }") }
    log("timing slow analyzers", { base: [msgs(base), t_base.round(3)], raising: [msgs(hit), t_hit.round(3), hit.to_h.key?("data")] })
    expect_refused(hit, /Timeout/)
    expect(msgs(hit).size).to eq(1)
    expect(t_hit).to be < t_base * 1.5
  end

  it "security G5b guard present on a named default trace mode" do
    mode_mod = Module.new
    schema = build_schema(max_depth: 2, analyzers: [raiser(:on_enter_field)])
    schema.trace_with(mode_mod, mode: :custom)
    schema.default_trace_mode(:custom)
    q = GraphQL::Query.new(schema, "{ cheap }", context: { rate_limit_key: "u" })
    log("custom mode owner", q.current_trace.method(:analyze_query).owner)
    expect_refused(run(schema, "{ node { child { child { leaf } } } }"), /depth/)
  end

  it "preservation G4b real analyzers only: timing of a raise on a big document (log only)" do
    trigger = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:on_enter_field) { |node, _p, _v| raise GraphQL::ExecutionError, "x" if node.alias == "trigger" }
      define_method(:result) { nil }
    end
    app_depth = Class.new(GraphQL::Analysis::QueryDepth) { define_method(:result) { nil } }
    fields = (1..6000).map { |i| "a#{i}: cheap" }.join(" ")
    plain = "{ #{fields} }"
    raising = "{ trigger: cheap #{fields} }"
    probe = build_schema(max_depth: 50, max_complexity: 100_000_000, analyzers: [trigger, app_depth])
    q = GraphQL::Query.new(probe, plain, context: { rate_limit_key: "c" })
    _, t_val = timed { q.static_errors }
    _, t_one = timed { GraphQL::Analysis.analyze_query(q, [GraphQL::Analysis::MaxQueryDepth]) }
    timeout = t_val * 1.5 + t_one * 0.5
    schema = build_schema(max_depth: 50, max_complexity: 100_000_000, analyzers: [trigger, app_depth], timeout: timeout)
    base, t_base = timed { run(schema, plain) }
    @resolved = []
    hit, t_hit = timed { run(schema, raising) }
    log("timing", { t_val: t_val.round(3), t_one: t_one.round(3), timeout: timeout.round(3), base: [msgs(base), t_base.round(3)], raising: [msgs(hit), t_hit.round(3), hit.to_h.key?("data")] })
  end

  it "security G5b a multiplex analyzer raising in its visit keeps max_depth" do
    mpx = raiser(:on_enter_field)
    schema = build_schema(max_depth: 2)
    schema.multiplex_analyzer(mpx)
    res = run(schema, "{ node { child { child { leaf } } } }")
    expect_refused(res, /depth/)
  end

  it "security G5b exempt client, raising analyzer, over max_depth" do
    schema = build_schema(limiters: [[:points, { soft: false, limit: ->(_k, _q) { nil } }]], max_depth: 2, analyzers: [raiser(:on_enter_field)])
    expect_refused(run(schema, "{ node { child { child { leaf } } } }"), /depth/)
  end

  it "preservation G5b hard limiter not charged plus a depth refusal: both errors, log the order" do
    schema = build_schema(limiters: [[:points, { soft: false }]], max_depth: 2, hook: ->(_c, _a) { raise GraphQL::ExecutionError, "x" })
    res = run(schema, "{ node { child { child { boom } } } }")
    log("not charged + depth", [codes(res), msgs(res)])
    expect_refused(res)
  end

  it "preservation G4b soft limiter, no maximum: a timeout only on the re-ask (log what happens)" do
    n = 0
    trigger = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:on_enter_operation_definition) { |*| n += 1; raise GraphQL::ExecutionError, "x" if n == 1 }
      define_method(:on_enter_field) { |*| sleep(0.06) }
      define_method(:result) { nil }
    end
    schema = build_schema(analyzers: [trigger], timeout: 0.05)
    res = run(schema, "{ cheap report other }")
    log("timeout on re-ask, only non-limiter slow", [msgs(res), res.to_h.key?("data")])
    expect(res.to_h["data"]).to be_nil
  end

  it "preservation G5b unsized connection with a maximum: what the client gets with and without a raise (log)" do
    node = Class.new(GraphQL::Schema::Object) { graphql_name "Item"; field :leaf, String, null: false }
    query = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :cheap, String, null: false
      field :conn, node.connection_type, null: false
    end
    trigger = Class.new(GraphQL::Analysis::Analyzer) do
      define_method(:on_enter_field) { |n, _p, _v| raise GraphQL::ExecutionError, "x" if n.alias == "trigger" }
      define_method(:result) { nil }
    end
    store = self.store
    schema = Class.new(ArmoryEngine.base_schema) do
      query query
      complexity_cost_calculation_mode(:future) if respond_to?(:complexity_cost_calculation_mode)
      max_complexity 100
      use RL::Points, store: store, limit: 1000, soft: true
      query_analyzer trigger
    end
    r = ->(q) { begin; res = run(schema, q); [codes(res), msgs(res)]; rescue StandardError => e; [e.class, e.message[0, 60]]; end }
    log("unsized connection", { no_raise: r.call("{ conn { nodes { leaf } } }"), raise: r.call("{ trigger: cheap conn { nodes { leaf } } }") })
  end
end
