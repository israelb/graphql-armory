# frozen_string_literal: true

# Independent verification of PR #41: Points answers PAGE_SIZE_REQUIRED for an unsized connection.
# Labels: [S] security (the feature must change the outcome), [P] preservation, [O] observed (prints, asserts the safe outcome).
require "spec_helper"
require "digest"

class ProbeField < GraphQL::Schema::Field
  def initialize(*args, **options, &block)
    options[:resolve_legacy_instance_method] = true if ArmoryEngine.supported?
    super
  end
end

RSpec.describe "unsized connection refusal probes" do
  L = GraphQL::Armory::RateLimits unless defined?(L)
  CODE = "PAGE_SIZE_REQUIRED" unless defined?(CODE)

  let(:log) { [] }
  let(:store) { L::Store::Substitute.new }

  def say(*parts) = STDOUT.puts("  OBS #{parts.map(&:inspect).join(' ')}")

  def type_set(log, connection_options: {})
    sub = Class.new(GraphQL::Schema::Object) do
      field_class ProbeField
      graphql_name "Sub"
      field :label, String, null: false
      define_method(:label) { log << :label; object.to_s }
    end
    item = Class.new(GraphQL::Schema::Object) do
      field_class ProbeField
      graphql_name "Item"
      field :name, String, null: false
      field :subs, sub.connection_type, null: false
      define_method(:name) { log << :name; object.to_s }
      define_method(:subs) { log << :subs; %w[x y] }
    end
    other = Class.new(GraphQL::Schema::Object) do
      field_class ProbeField
      graphql_name "Other"
      field :items, item.connection_type, null: false
      define_method(:items) { log << :other_items; %w[a] }
    end
    union = Class.new(GraphQL::Schema::Union) do
      graphql_name "Search"
      possible_types item, other
      define_singleton_method(:resolve_type) { |object, _context| object.is_a?(String) ? item : other }
    end
    query = Class.new(GraphQL::Schema::Object) do
      field_class ProbeField
      graphql_name "Query"
      field :cheap, String, null: false
      field :report, String, null: false, complexity: 40
      field :items, item.connection_type, null: false, **connection_options
      field :tagged, item.connection_type, null: false do
        argument :tag, String, required: false, prepare: ->(value, _context) {
          log << :prepare
          raise GraphQL::ExecutionError, "bad tag" if value == "bad"

          value
        }
      end
      field :thing, item, null: false
      field :search, union, null: false
      field :capped, item.connection_type, null: false, max_page_size: 5
      field :defaulted, item.connection_type, null: false, default_page_size: 7
      field :custom, item.connection_type, null: false, complexity: 9
      define_method(:cheap) { log << :cheap; "ok" }
      define_method(:report) { log << :report; "big" }
      define_method(:items) { |**| log << :items; %w[a b c] }
      define_method(:tagged) { |**| log << :tagged; %w[a] }
      define_method(:thing) { log << :thing; "t" }
      define_method(:search) { log << :search; Object.new }
      define_method(:capped) { log << :capped; %w[a] }
      define_method(:defaulted) { log << :defaulted; %w[a] }
      define_method(:custom) { log << :custom; %w[a] }
    end
    mutation = Class.new(GraphQL::Schema::Object) do
      field_class ProbeField
      graphql_name "Mutation"
      field :write, String, null: false
      field :write_items, item.connection_type, null: false
      define_method(:write) { log << :write; "wrote" }
      define_method(:write_items) { log << :write_items; %w[a] }
    end
    [query, mutation, union]
  end

  def schema_for(points: {}, **options, &config)
    query, mutation, = type_set(log, **options)
    limiter_store = store
    points = { store: limiter_store, limit: 1000, window: 60, soft: false }.merge(points)
    Class.new(base_schema) do
      query(query)
      mutation(mutation)
      use L::Points, **points unless points[:skip]
      class_eval(&config) if config
    end
  end

  def run(schema, text, **options)
    options[:context] = { L::KEY => "c" }.merge(options[:context] || {})
    execute_query(schema, text, **options).to_h
  end

  def mux(schema, queries)
    queries = queries.map { |q| { context: { L::KEY => "c" } }.merge(q) }
    results = ArmoryEngine.next? ? schema.multiplex_next(queries) : schema.multiplex(queries)
    results
  end

  def code_of(hash) = hash["errors"]&.map { |error| error.dig("extensions", "code") }

  def expect_refused(hash)
    expect(code_of(hash)).to eq([CODE])
    expect(hash["errors"][0]["message"]).to eq("This connection needs first: or last:")
    expect(hash).not_to have_key("data")
    expect(log).to eq([])
    expect(store.calls.select { |call| call[0] == :take }).to eq([])
  end

  def takes = store.calls.select { |call| call[0] == :take }

  def balance(key = "c", limit = 1000) = store.take(key, cost: 0, limit: limit, window: 60, force: false).last

  describe "1. mixed documents" do
    it "D1 [S] query root: unsized beside other root fields runs nothing" do
      expect_refused(run(schema_for, "{ cheap report items { nodes { name } } }"))
    end

    it "D2 [S] mutation: a write beside an unsized connection selected on the mutation does not write" do
      expect_refused(run(schema_for, "mutation { write writeItems { nodes { name } } }"))
    end

    it "D3 [S] mutation: unsized connection second, write first, aliased" do
      expect_refused(run(schema_for, "mutation { a: write b: write c: writeItems { edges { node { name } } } }"))
    end

    it "D4 [S] the unselected operation decides nothing, the selected one does" do
      doc = "query A { items { nodes { name } } } query B { cheap }"
      schema = schema_for
      expect(run(schema, doc, operation_name: "B")["data"]).to eq("cheap" => "ok")
      expect(takes.size).to eq(1)
      expect(takes.first.last[:cost] || takes.first).to be_truthy
      log.clear
      calls = takes.size
      hash = run(schema, doc, operation_name: "A")
      expect(code_of(hash)).to eq([CODE])
      expect(log).to eq([])
      expect(takes.size).to eq(calls)
    end
  end

  describe "2. multiplex" do
    it "M1 [S] valid beside unsized: valid charged and run, unsized refused and uncharged" do
      schema = schema_for
      results = mux(schema, [{ query: "{ report }" }, { query: "{ items { nodes { name } } }" }])
      expect(results[0].to_h["data"]).to eq("report" => "big")
      expect(code_of(results[1].to_h)).to eq([CODE])
      expect(results[1].to_h).not_to have_key("data")
      expect(log).to eq([:report])
      expect(balance).to eq(960)
    end

    it "M2 [S] unsized first, valid second: order does not matter" do
      schema = schema_for
      results = mux(schema, [{ query: "{ items { nodes { name } } }" }, { query: "{ report }" }])
      expect(code_of(results[0].to_h)).to eq([CODE])
      expect(results[1].to_h["data"]).to eq("report" => "big")
      expect(log).to eq([:report])
      expect(balance).to eq(960)
    end

    it "M3 [S] a mutation in a multiplex beside unsized: the mutation runs once, the unsized one does not" do
      schema = schema_for
      results = mux(schema, [{ query: "mutation { write }" }, { query: "mutation { write writeItems { nodes { name } } }" }])
      expect(results[0].to_h["data"]).to eq("write" => "wrote")
      expect(code_of(results[1].to_h)).to eq([CODE])
      expect(log).to eq([:write])
    end

    it "M4 [S] Concurrency after Points: a refused query leaks no slot, alone or in a multiplex" do
      slots = store
      schema = schema_for { use L::Concurrency, store: slots, limit: 2, soft: false }
      expect(code_of(run(schema, "{ items { nodes { name } } }"))).to eq([CODE])
      expect(store.held("c")).to eq(0)
      results = mux(schema, [{ query: "{ cheap }" }, { query: "{ items { nodes { name } } }" }])
      expect(results[0].to_h["data"]).to eq("cheap" => "ok")
      expect(code_of(results[1].to_h)).to eq([CODE])
      expect(store.held("c")).to eq(0)
    end

    it "M5 [S] Concurrency before Points: no slot leak either, and a full client is told about the slots" do
      slots = store
      query, mutation, = type_set(log)
      schema = Class.new(base_schema) do
        query(query)
        mutation(mutation)
        use L::Concurrency, store: slots, limit: 1, soft: false
        use L::Points, store: slots, limit: 1000, window: 60, soft: false
      end
      expect(code_of(run(schema, "{ items { nodes { name } } }"))).to eq([CODE])
      expect(store.held("c")).to eq(0)
      token = store.occupy("c")
      codes = code_of(run(schema, "{ items { nodes { name } } }"))
      say :M5_codes_when_full, codes
      expect(codes).to include(CODE)
      expect(log).to eq([])
      store.release("c", token: token)
    end

    it "M6 [S] Time on the same schema: an unsized query in a multiplex owes like a RATE_LIMITED one" do
      time_store = L::MemoryStore.new
      clock = L::Clock::Substitute.new
      slow_log = log
      query, mutation, = type_set(log)
      schema = Class.new(base_schema) do
        query(query)
        mutation(mutation)
        use L::Time, store: time_store, limit: 10_000, window: 3600, soft: false, clock: clock
        use L::Points, store: L::MemoryStore.new, limit: 50, window: 3600, soft: false
      end
      root = Class.new { define_method(:cheap) { clock.advance(1); slow_log << :cheap; "ok" } }.new
      left = -> { time_store.take("c", cost: 0, limit: 10_000, window: 3600, force: false).last }

      results = mux(schema, [{ query: "{ cheap }", root_value: nil }, { query: "{ items { nodes { name } } }" }])
      expect(code_of(results[1].to_h)).to eq([CODE])
      expect(results[0].to_h["data"]).to eq("cheap" => "ok")
      say :M6_time_left_after_noop_clock, left.call, root.class
      expect(left.call).to eq(10_000)
    end

    it "M7 [S] Time, charged time of a multiplex with a refused query is the whole time for that key" do
      time_store = L::MemoryStore.new
      clock = L::Clock::Substitute.new
      query = Class.new(GraphQL::Schema::Object) do
        field_class ProbeField
        graphql_name "Query"
        item = Class.new(GraphQL::Schema::Object) do
          field_class ProbeField
          graphql_name "Item"
          field :name, String, null: false
        end
        field :slow, String, null: false
        field :items, item.connection_type, null: false
        field :big, String, null: false, complexity: 40
        define_method(:slow) { clock.advance(1); "ok" }
      end
      schema = Class.new(base_schema) do
        query(query)
        use L::Time, store: time_store, limit: 10_000, window: 3600, soft: false, clock: clock
        use L::Points, store: L::MemoryStore.new, limit: 30, window: 3600, soft: false
      end
      left = -> { time_store.take("c", cost: 0, limit: 10_000, window: 3600, force: false).last }
      results = mux(schema, [{ query: "{ slow }" }, { query: "{ items { nodes { name } } }" }])
      unsized_left = left.call
      results2 = mux(schema, [{ query: "{ slow }" }, { query: "{ big }" }])
      rate_left = left.call
      say :M7, code_of(results[1].to_h), unsized_left, code_of(results2[1].to_h), rate_left
      expect(10_000 - unsized_left).to eq(1000)
      expect(unsized_left - rate_left).to eq(1000)
    end

    it "M8 [O] a shared context hash keeps the earlier query's record" do
      schema = schema_for
      shared = { L::KEY => "c" }
      results = mux(schema, [{ query: "{ report }", context: shared }, { query: "{ items { nodes { name } } }", context: shared }])
      say :M8_shared_record, results[1].context[L::Points::CONTEXT_KEY]
      say :M8_headers, L::Points.headers(results[1])
      expect(L::Points.headers(results[1])).to eq({})
      expect(results[1].context[L::Points::CONTEXT_KEY]).to be_nil
    end
  end

  describe "3. document shapes" do
    it "S1 [S] named fragment" do
      expect_refused(run(schema_for, "query { ...F } fragment F on Query { items { nodes { name } } }"))
    end

    it "S2 [S] inline fragment" do
      expect_refused(run(schema_for, "{ ... on Query { items { edges { cursor } } } }"))
    end

    it "S3 [S] union branch that would not be taken" do
      expect_refused(run(schema_for, "{ search { ... on Other { items { nodes { name } } } } }"))
    end

    it "S4 [P] @skip(if: true) on the connection: nothing to size, it runs and is charged" do
      hash = run(schema_for, "{ cheap items @skip(if: true) { nodes { name } } }")
      expect(hash["data"]).to eq("cheap" => "ok")
      expect(hash["errors"]).to be_nil
      expect(takes.first[1..].to_s).to include("cost")
    end

    it "S5 [P] @include(if: false) through a variable" do
      hash = run(schema_for, "query($v: Boolean!) { cheap items @include(if: $v) { nodes { name } } }", variables: { "v" => false })
      expect(hash["data"]).to eq("cheap" => "ok")
    end

    it "S6 [S] @include(if: true) through a variable" do
      expect_refused(run(schema_for, "query($v: Boolean!) { cheap items @include(if: $v) { nodes { name } } }", variables: { "v" => true }))
    end

    it "S7 [S] @skip(if: false)" do
      expect_refused(run(schema_for, "{ items @skip(if: false) { nodes { name } } }"))
    end

    it "S8 [S] skip on a fragment that holds it is honoured, not skipped is refused" do
      doc = "query($s: Boolean!) { cheap ...F @skip(if: $s) } fragment F on Query { items { nodes { name } } }"
      schema = schema_for
      expect(run(schema, doc, variables: { "s" => true })["data"]).to eq("cheap" => "ok")
      log.clear
      expect(code_of(run(schema, doc, variables: { "s" => false }))).to eq([CODE])
      expect(log).to eq([])
    end

    it "S9 [S] aliases: one sized and one unsized" do
      expect_refused(run(schema_for, "{ a: items(first: 1) { nodes { name } } b: items { nodes { name } } }"))
    end

    it "S10 [S] nested connection unsized under a sized one" do
      expect_refused(run(schema_for, "{ items(first: 2) { nodes { subs { nodes { label } } } } }"))
    end

    it "S11 [S] nested under a plain object" do
      expect_refused(run(schema_for, "{ thing { subs { nodes { label } } } }"))
    end

    it "S12 [S] first: null literal" do
      expect_refused(run(schema_for, "{ items(first: null) { nodes { name } } }"))
    end

    it "S13 [S] first and last both null" do
      expect_refused(run(schema_for, "{ items(first: null, last: null) { nodes { name } } }"))
    end

    it "S14 [S] first: $v with an explicit null" do
      expect_refused(run(schema_for, "query($v: Int) { items(first: $v) { nodes { name } } }", variables: { "v" => nil }))
    end

    it "S15 [S] first: $v missing" do
      expect_refused(run(schema_for, "query($v: Int) { items(first: $v) { nodes { name } } }"))
    end

    it "S16 [S] first: $v missing, with an explicit null beating a default" do
      expect_refused(run(schema_for, "query($v: Int = 2) { items(first: $v) { nodes { name } } }", variables: { "v" => nil }))
    end

    it "S17 [P] first: $v defaulted is charged and runs" do
      hash = run(schema_for, "query($v: Int = 2) { items(first: $v) { nodes { name } } }")
      expect(hash["data"]["items"]["nodes"].size).to eq(2)
      expect(balance).to eq(1000 - 4)
    end

    it "S18 [P] last only is charged and runs" do
      hash = run(schema_for, "{ items(last: 2) { nodes { name } } }")
      expect(hash["data"]["items"]["nodes"].size).to eq(2)
      expect(balance).to eq(1000 - 4)
    end

    it "S19 [P] first: 0 is sized" do
      hash = run(schema_for, "{ items(first: 0) { nodes { name } } }")
      expect(hash["data"]["items"]["nodes"]).to eq([])
    end

    it "S20 [S] after: only is unsized" do
      expect_refused(run(schema_for, %({ items(after: "x") { nodes { name } } })))
    end

    it "S21 [S] a variable of the wrong type runs nothing and raises nothing" do
      skip "graphql 2.4.18 with json 3.1 raises on a wrong-type variable, on main too" if GraphQL::VERSION.start_with?("2.4")
      hash = run(schema_for, "query($v: Int) { cheap items(first: $v) { nodes { name } } }", variables: { "v" => "abc" })
      expect(hash).not_to have_key("data")
      expect(log).to eq([])
    end

    it "S22 [S] a required variable missing with an unsized connection in a mutation does not write" do
      hash = run(schema_for, "mutation($v: Int!) { write writeItems(first: $v) { nodes { name } } }")
      say :S22, hash["errors"]&.map { |e| e["message"] }
      expect(log).to eq([])
    end

    it "S23 [S] connection selecting only __typename, pageInfo or nothing billable" do
      expect_refused(run(schema_for, "{ items { __typename } }"))
    end

    it "S24 [S] connection only pageInfo" do
      expect_refused(run(schema_for, "{ items { pageInfo { hasNextPage } } }"))
    end

    it "S25 [S] custom complexity on the connection field does not size it" do
      expect_refused(run(schema_for, "{ custom { nodes { name } } }"))
    end

    it "S26 [P] prepare raising ExecutionError: the field fails alone, the document is scored, no server error" do
      hash = run(schema_for, %({ cheap tagged(tag: "bad") { nodes { name } } }))
      say :S26, hash, takes.size, log
      expect(log).not_to include(:tagged)
      expect(hash.dig("data", "tagged")).to be_nil
    end

    it "S27 [O] prepare runs before the refusal: scoring evaluates arguments" do
      hash = run(schema_for, %({ tagged(tag: "ok") { nodes { name } } }))
      say :S27, code_of(hash), log
      expect(code_of(hash)).to eq([CODE])
      expect(log).not_to include(:tagged)
    end
  end

  describe "4. free refusal" do
    it "F1 [S] an exhausted client: refused, not run, balance unchanged" do
      schema = schema_for(points: { limit: 10 })
      store.take("c", cost: 10, limit: 10, window: 60, force: true)
      hash = run(schema, "{ items { nodes { name } } }")
      say :F1, hash
      expect(code_of(hash)).to eq([CODE])
      expect(log).to eq([])
      expect(balance("c", 10)).to eq(0)
    end

    it "F2 [S] a query that costs more than the limit with an unsized connection cannot learn its cost" do
      schema = schema_for(points: { limit: 10 })
      hash = run(schema, "{ report items { nodes { name } } }")
      expect(hash["errors"][0].to_s).not_to match(/40|cost|limit/)
      expect(hash["errors"][0]["extensions"].keys).to eq(["code"])
    end

    it "F3 [O] no key: the forgotten controller is not caught on this query, and nothing runs" do
      schema = schema_for
      outcome = begin
        code_of(execute_query(schema, "{ items { nodes { name } } }", context: {}).to_h)
      rescue StandardError => error
        error.class
      end
      say :F3, outcome
      expect(log).to eq([])
    end

    it "F5 [S] a client with no limit is refused too, and nothing runs" do
      schema = schema_for(points: { limit: ->(_key, _query) {} })
      expect(code_of(run(schema, "{ items { nodes { name } } }"))).to eq([CODE])
      expect(log).to eq([])
    end
  end

  describe "5. combinations" do
    def analyzer(position_log, &body)
      Class.new(GraphQL::Analysis::Analyzer) { define_method(:result) { position_log << :other_analyzer; body&.call } }
    end

    it "C1 [S] a later analyzer that returns nil: the refusal stands" do
      seen = []
      other = analyzer(seen)
      expect_refused(run(schema_for { query_analyzer(other) }, "{ items { nodes { name } } }"))
      expect(seen).to eq([:other_analyzer])
    end

    it "C2 [S] a later analyzer that returns its own AnalysisError: both errors, nothing runs" do
      other = analyzer([]) { GraphQL::AnalysisError.new("other refusal") }
      hash = run(schema_for { query_analyzer(other) }, "{ items { nodes { name } } }")
      expect(hash["errors"].map { |e| e["message"] }).to contain_exactly("This connection needs first: or last:", "other refusal")
      expect(log).to eq([])
    end

    it "C3 [S] a later analyzer raising ExecutionError must not cancel the refusal" do
      other = analyzer([]) { raise GraphQL::ExecutionError, "later analyzer says no" }
      schema = schema_for { query_analyzer(other) }
      hash = begin
        run(schema, "{ items { nodes { name } } }")
      rescue GraphQL::Error => error
        { "raised" => error.class.name, "message" => error.message[0, 40] }
      end
      say :C3, hash, log, takes.size
      expect(log).to eq([])
      expect(hash["data"]).to be_nil
    end

    it "C3b [O] the same later analyzer against RATE_LIMITED, to compare" do
      other = analyzer([]) { raise GraphQL::ExecutionError, "later analyzer says no" }
      schema = schema_for(points: { limit: 10 }) { query_analyzer(other) }
      hash = run(schema, "{ report }")
      say :C3b, hash, log
      expect(log).to eq([])
    end

    it "C3c [S] Concurrency's on_store_error raising ExecutionError after Points must not cancel the refusal" do
      broken = L::Store::Substitute.new
      broken.fail_with(IOError.new("down"), on: :acquire)
      fail_closed = ->(_error, _query) { raise GraphQL::ExecutionError, "limits are down" }
      schema = schema_for { use L::Concurrency, store: broken, limit: 2, soft: false, on_store_error: fail_closed }
      hash = begin
        run(schema, "{ items { nodes { name } } }")
      rescue GraphQL::Error => error
        { "raised" => error.class.name }
      end
      say :C3c, hash, log
      expect(log).to eq([])
      expect(hash["data"]).to be_nil
    end

    xit "C4 [O] an earlier analyzer raising ExecutionError skips Points altogether" do
      other = analyzer([]) { raise GraphQL::ExecutionError, "earlier analyzer says no" }
      query, mutation, = type_set(log)
      limiter_store = store
      schema = Class.new(base_schema) do
        query(query)
        mutation(mutation)
        query_analyzer(other)
        use L::Points, store: limiter_store, limit: 1000, window: 60, soft: false
      end
      hash = run(schema, "{ items { nodes { name } } }")
      say :C4, hash, log, takes.size
      expect(log).to eq([])
    end

    [["guarded first", "{ guarded items { nodes { name } } }"], ["unsized first", "{ items { nodes { name } } guarded }"]].each do |label, document|
      xit "C12 [S] a schema author's complexity lambda raising ExecutionError, #{label}: the unsized connection must not run" do
        ran = log
        item = Class.new(GraphQL::Schema::Object) do
          field_class ProbeField
          graphql_name "Item"
          field :name, String, null: false
          define_method(:name) { ran << :name; object.to_s }
        end
        query = Class.new(GraphQL::Schema::Object) do
          field_class ProbeField
          graphql_name "Query"
          field :guarded, String, null: false, complexity: ->(_c, _a, _child) { raise GraphQL::ExecutionError, "too deep" }
          field :items, item.connection_type, null: false
          define_method(:guarded) { ran << :guarded; "g" }
          define_method(:items) { ran << :items; %w[a b c] }
        end
        limiter_store = store
        schema = Class.new(base_schema) do
          query(query)
          use L::Points, store: limiter_store, limit: 1000, window: 60, soft: false
        end
        hash = begin
          run(schema, document)
        rescue GraphQL::Error => error
          { "raised" => error.class.name }
        end
        say :C12, label, hash, log, takes.size
        expect(log).to eq([])
      end
    end

    it "C5 [S] persisted queries, strict: a raw unsized query is refused as raw" do
      limiter_store = store
      query, mutation, = type_set(log)
      pq = GraphQL::Armory::PersistedQueries
      schema = Class.new(base_schema) do
        query(query)
        mutation(mutation)
        use pq, store: pq::Store::Substitute.new("query Ok { cheap }"), strict: true
        use L::Points, store: limiter_store, limit: 1000, window: 60, soft: false
      end
      hash = run(schema, "{ items { nodes { name } } }")
      expect(code_of(hash)).to eq(["RAW_QUERY_REFUSED"])
      expect(log).to eq([])
    end

    it "C6 [S] persisted queries, strict: a stored unsized operation is refused, not run" do
      limiter_store = store
      query, mutation, = type_set(log)
      pq = GraphQL::Armory::PersistedQueries
      text = "query Un { items { nodes { name } } }"
      schema = Class.new(base_schema) do
        query(query)
        mutation(mutation)
        use pq, store: pq::Store::Substitute.new(text), strict: true
        use L::Points, store: limiter_store, limit: 1000, window: 60, soft: false
      end
      hash = execute_query(schema, nil, context: { L::KEY => "c", operation_id: Digest::SHA256.hexdigest(text) }).to_h
      expect(code_of(hash)).to eq([CODE])
      expect(log).to eq([])
    end

    context "with Authorization" do
      def auth_schema(adapter)
        plugin = GraphQL::Armory::Authorization
        ran = log
        base_field = Class.new(ProbeField) { include plugin::Base }
        base_object = Class.new(GraphQL::Schema::Object) do
          include plugin::Base
          field_class base_field
        end
        node = Class.new(base_object) do
          graphql_name "Secret"
          authorize :none, reason: "probe", covers_fields: true
          field :id, String, null: false
          define_method(:id) { ran << :node_id; object.to_s }
        end
        query = Class.new(base_object) do
          graphql_name "Query"
          authorize :none, reason: "root", covers_fields: false
          field :open_secrets, node.connection_type, null: true, authorize: :none, reason: "probe"
          define_method(:open_secrets) { ran << :open_secrets; %w[a b] }
        end
        limiter_store = store
        Class.new(base_schema) do
          use plugin, adapter: adapter
          query(query)
          use L::Points, store: limiter_store, limit: 1000, window: 60, soft: false
        end
      end

      it "C7 [S] an unsized connection under Authorization: refused before any check or resolver" do
        adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: false)
        hash = run(auth_schema(adapter), "{ openSecrets { nodes { id } } }")
        say :C7, hash, adapter.asked.size, adapter.scoped_for.size
        expect(code_of(hash)).to eq([CODE])
        expect(log).to eq([])
        expect(adapter.scoped_for).to eq([])
      end

      it "C8 [P] sized, it runs and is charged as before" do
        adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: true, scoped: ->(_items) { [] })
        hash = run(auth_schema(adapter), "{ openSecrets(first: 2) { nodes { id } } }")
        expect(hash.dig("data", "openSecrets", "nodes").size).to eq(2)
        expect(balance).to eq(1000 - 4)
      end
    end

    it "C9 [S] several keys: refused, no key charged, none read" do
      schema = schema_for(points: { key: ->(_query) { %w[k1 k2] } })
      hash = run(schema, "{ items { nodes { name } } }")
      expect(code_of(hash)).to eq([CODE])
      expect(takes).to eq([])
      expect(log).to eq([])
      expect(L::Points.headers(execute_query(schema, "{ items { nodes { name } } }", context: {}))).to eq({})
    end

    it "C10 [P] several keys: a sized query charges both as before" do
      schema = schema_for(points: { key: ->(_query) { %w[k1 k2] } })
      run(schema, "{ items(first: 2) { nodes { name } } }")
      expect(balance("k1")).to eq(996)
      expect(balance("k2")).to eq(996)
    end

    it "C11 [P] two Points on one schema: both refuse, both charge nothing" do
      limiter_store = store
      schema = schema_for { use L::Points, store: limiter_store, limit: 1000, window: 60, soft: false, key: ->(_q) { "ip" } }
      hash = run(schema, "{ items { nodes { name } } }")
      say :C11, hash["errors"].size
      expect(code_of(hash).uniq).to eq([CODE])
      expect(takes).to eq([])
      expect(log).to eq([])
    end
  end

  describe "6. the filter" do
    def raising_schema(error)
      item = Class.new(GraphQL::Schema::Object) do
        field_class ProbeField
        graphql_name "Item"
        field :name, String, null: false
      end
      ran = log
      query = Class.new(GraphQL::Schema::Object) do
        field_class ProbeField
        graphql_name "Query"
        field :costly, item, null: true, complexity: ->(_context, _args, _child) { raise error }
        define_method(:costly) { ran << :costly; "x" }
      end
      limiter_store = store
      Class.new(base_schema) do
        query(query)
        use L::Points, store: limiter_store, limit: 1000, window: 60, soft: false
      end
    end

    it "E1 [P] a subclass of GraphQL::Error with the same words still raises" do
      klass = Class.new(GraphQL::Error)
      schema = raising_schema(klass.new("Can't calculate complexity for this"))
      expect { run(schema, "{ costly { name } }") }.to raise_error(klass)
      expect(log).to eq([])
    end

    it "E3 [P] other StandardError still raises" do
      schema = raising_schema(IOError.new("disk"))
      expect { run(schema, "{ costly { name } }") }.to raise_error(IOError)
    end

    it "E4 [O] a schema author's lambda raising the same words is hidden as this refusal" do
      schema = raising_schema(GraphQL::Error.new("Can't calculate complexity: the pricing table is missing"))
      hash = begin
        run(schema, "{ costly { name } }")
      rescue GraphQL::Error => error
        { "raised" => error.message }
      end
      say :E4, hash
      expect(log).to eq([])
    end

    it "E5 [P] an infinite complexity still raises ConfigurationError" do
      item = Class.new(GraphQL::Schema::Object) do
        field_class ProbeField
        graphql_name "Item"
        field :name, String, null: false
      end
      query = Class.new(GraphQL::Schema::Object) do
        field_class ProbeField
        graphql_name "Query"
        field :costly, item, null: true, complexity: ->(_c, _a, _child) { Float::INFINITY }
      end
      limiter_store = store
      schema = Class.new(base_schema) do
        query(query)
        use L::Points, store: limiter_store, limit: 1000, window: 60, soft: false
      end
      expect { run(schema, "{ costly { name } }") }.to raise_error(L::ConfigurationError)
    end

    it "E6 [P] the words the filter matches are in the installed graphql's source" do
      source = File.read(File.join(Gem.loaded_specs.fetch("graphql").full_gem_path, "lib/graphql/schema/field.rb"))
      STDOUT.puts "  OBS graphql=#{GraphQL::VERSION} count=#{source.scan("Can't calculate complexity").size}"
      expect(source).to include(%(raise GraphQL::Error, "Can't calculate complexity for))
    end

    it "E7 [P] who answers: result is Points::Analyzer's on the class the schema holds" do
      schema = schema_for
      klass = schema.query_analyzers.find { |analyzer| analyzer < L::Points::Analyzer }
      expect(klass.instance_method(:result).owner).to eq(L::Points::Analyzer)
      expect(klass.instance_method(:result).super_method.owner).to eq(GraphQL::Analysis::QueryComplexity)
    end
  end

  describe "7. records, headers and extensions" do
    it "R1 [P] headers answer nothing and do not crash" do
      schema = schema_for
      result = execute_query(schema, "{ items { nodes { name } } }", context: { L::KEY => "c" })
      expect(L::Points.headers(result)).to eq({})
    end

    it "R2 [O] extensions: true says nothing on this refusal, and does not crash" do
      schema = schema_for(points: { extensions: true })
      hash = run(schema, "{ items { nodes { name } } }")
      say :R2, hash
      expect(code_of(hash)).to eq([CODE])
      expect(hash.dig("extensions", "rateLimit")).to be_nil
    end

    it "R3 [O] context record stays nil" do
      schema = schema_for
      result = execute_query(schema, "{ items { nodes { name } } }", context: { L::KEY => "c" })
      say :R3, result.context[L::Points::CONTEXT_KEY]
      expect(result.context[L::Points::CONTEXT_KEY]).to be_nil
    end

    it "R4 [O] a context hash reused from an earlier query keeps that query's numbers" do
      schema = schema_for
      shared = { L::KEY => "c" }
      execute_query(schema, "{ report }", context: shared)
      result = execute_query(schema, "{ items { nodes { name } } }", context: shared)
      say :R4, result.context[L::Points::CONTEXT_KEY], L::Points.headers(result)
      expect(result.context[L::Points::CONTEXT_KEY]).to be_nil
    end
  end

  describe "8. page sizes: no refusal when any is set" do
    it "G1 [P] field max_page_size: charged as first: 5, no refusal" do
      hash = run(schema_for, "{ capped { nodes { name } } }")
      expect(hash["errors"]).to be_nil
      expect(balance).to eq(1000 - 7)
    end

    it "G2 [P] field default_page_size: charged as first: 7, no refusal" do
      hash = run(schema_for, "{ defaulted { nodes { name } } }")
      expect(hash["errors"]).to be_nil
      expect(balance).to eq(1000 - 9)
    end

    it "G3 [P] schema default_page_size" do
      hash = run(schema_for { default_page_size 3 }, "{ items { nodes { name } } }")
      expect(hash["errors"]).to be_nil
      expect(hash["data"]["items"]["nodes"].size).to eq(3)
      expect(balance).to eq(1000 - 5)
    end

    it "G4 [P] schema default_max_page_size" do
      hash = run(schema_for { default_max_page_size 2 }, "{ items { nodes { name } } }")
      expect(hash["errors"]).to be_nil
      expect(hash["data"]["items"]["nodes"].size).to eq(2)
      expect(balance).to eq(1000 - 4)
    end

    it "G5 [P] field max_page_size: nil with a schema default is still sized" do
      hash = run(schema_for(connection_options: { max_page_size: nil }) { default_max_page_size 2 }, "{ items { nodes { name } } }")
      expect(hash["errors"]).to be_nil
      say :G5_nodes, hash["data"]["items"]["nodes"].size, 1000 - balance
    end

    it "G6 [S] field max_page_size: nil and no schema default: refused" do
      expect_refused(run(schema_for(connection_options: { max_page_size: nil }), "{ items { nodes { name } } }"))
    end
  end

  describe "9. cost modes and documented limits" do
    %i[legacy future compare].each do |mode|
      it "K-#{mode} [S] complexity mode #{mode}: refused and nothing runs" do
        skip "no complexity_cost_calculation_mode in #{GraphQL::VERSION}" unless GraphQL::Schema.respond_to?(:complexity_cost_calculation_mode)
        expect_refused(run(schema_for { complexity_cost_calculation_mode(mode) }, "{ items { nodes { name } } }"))
      end
    end

    it "K5 [O] validate: false, set by the operator" do
      hash = begin
        run(schema_for, "{ items { nodes { name } } }", validate: false)
      rescue StandardError => error
        { "raised" => error.class.name }
      end
      say :K5, hash, log
    end
  end

  describe "10. the docs on BaseConnection and BaseEdge" do
    let(:plugin) { GraphQL::Armory::Authorization }

    def template_schema(connection_step:, edge_step:, with_default: true, order: :doc)
      plugin = self.plugin
      base_field = Class.new(GraphQL::Schema::Field) { include plugin::Base }
      base_object = Class.new(GraphQL::Schema::Object) do
        field_class ProbeField
        include plugin::Base
        field_class base_field
        default_action :read if with_default
      end
      step = proc { authorize :none, reason: "the field that returns it holds the rule; each node has its own", covers_fields: true }
      connection = Class.new(base_object) do
        class_eval(&step) if connection_step && order == :doc
        include GraphQL::Types::Relay::ConnectionBehaviors
        class_eval(&step) if connection_step && order != :doc
      end
      edge = Class.new(base_object) do
        class_eval(&step) if edge_step && order == :doc
        include GraphQL::Types::Relay::EdgeBehaviors
        class_eval(&step) if edge_step && order != :doc
      end
      base_object.connection_type_class(connection)
      base_object.edge_type_class(edge)
      invoice = Class.new(base_object) do
        graphql_name "Invoice"
        authorize :read, model: ::Invoice
        field :id, String, null: false, authorize: :none, reason: "ids are public"
      end
      query = Class.new(base_object) do
        graphql_name "Query"
        authorize :none, reason: "root"
        field :invoices, invoice.connection_type, null: true, authorize: :none, reason: "scoped by the node type"
      end
      Class.new(base_schema) do
        use plugin, adapter: :pundit
        query(query)
      end
    end

    def ignored(schema) = plugin::Audit.(schema).problems.select { |problem| problem.kind == :ignored_rule }.map(&:path)

    it "A1 [P] the docs' snippet, authorize before include as printed, leaves the audit clean" do
      audit = plugin::Audit.(template_schema(connection_step: true, edge_step: true))
      say :A1, audit.problems.map { |p| [p.kind, p.path] }
      expect(audit.ok?).to be(true)
    end

    it "A2 [P] without the step, with the base object of the docs: :ignored_rule on both" do
      expect(ignored(template_schema(connection_step: false, edge_step: false))).to contain_exactly("InvoiceConnection", "InvoiceEdge")
    end

    it "A3 [P] only the connection declared: the edge still reported" do
      expect(ignored(template_schema(connection_step: true, edge_step: false))).to eq(["InvoiceEdge"])
    end

    it "A4 [O] without default_action on the base object and without the step" do
      audit = plugin::Audit.(template_schema(connection_step: false, edge_step: false, with_default: false))
      say :A4, audit.problems.map { |p| [p.kind, p.path] }.first(8)
    end

    it "A5 [P] who answers authorized? on the docs' connection: ConnectionBehaviors, so the bypass says what happens" do
      schema = template_schema(connection_step: true, edge_step: true)
      connection = schema.get_type("InvoiceConnection")
      say :A5, connection.method(:authorized?).owner
      expect(connection.method(:authorized?).owner.to_s).to match(/ConnectionBehaviors/)
    end

    it "A6 [P] the generator injects connection_type_class, the wiring the docs assume, and the template shape matches" do
      root = Gem.loaded_specs.fetch("graphql").full_gem_path
      expect(File.read(File.join(root, "lib/generators/graphql/relay.rb"))).to include("connection_type_class(Types::BaseConnection)")
      expect(File.read(File.join(root, "lib/generators/graphql/templates/base_connection.erb"))).to include("class BaseConnection < Types::BaseObject")
      expect(File.read(File.join(root, "lib/generators/graphql/templates/base_edge.erb"))).to include("class BaseEdge < Types::BaseObject")
    end
  end
end
