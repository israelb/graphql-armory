# frozen_string_literal: true

require "digest"
require "stringio"
require "delegate"

# Kept from the independent verification of the sink changes. Each `it` is labelled [S] security or [P] preservation; [D] only dumps what happens.
RSpec.describe "Telemetry sinks: verifier probes" do
  armory = GraphQL::Armory
  has_hook = armory::Telemetry.instance_method(:initialize).parameters.any? { |_, name| name == :on_sink_error }
  has_ctx = armory::Telemetry.instance_method(:record).parameters.any? { |_, name| name == :context }
  denied_q = "{ myInvoice { number internalNotes } }"
  qtext = "query Invoices { invoices }"

  let(:armory) { GraphQL::Armory }
  let(:w) { Dummy::World.build }
  let(:encoder) { armory::IDs::Controls::Encoder.example }
  let(:pq_id) { Digest::SHA256.hexdigest(qtext) }

  define_method(:qtext) { qtext }
  define_method(:has_hook) { has_hook }
  define_method(:has_ctx) { has_ctx }

  def obs(label, value)
    nil
  end

  def quiet
    original = $stderr
    $stderr = StringIO.new
    value = yield
    [value, $stderr.string]
  ensure
    $stderr = original
  end

  def attempt
    yield
  rescue Exception => e # rubocop:disable Lint/RescueException
    [:raised, e.class.name, e.message.to_s[0, 80]]
  end

  # --- authorization ---
  def auth_schema(mode: :null, **opts)
    schema = IntegrationSchema.build(on_unauthorized: mode, plugin: false)
    schema.use(armory::Authorization, adapter: :pundit, on_unauthorized: mode, **opts)
    schema
  end

  def run_q(schema, query, user:, **root)
    execute_query(schema, query, context: { current_user: user }, root_value: IntegrationSchema::Root.new(**root)).to_h
  end

  def raises_on(*signals, error: -> { RuntimeError.new("boom s3cr3t") })
    ->(signal, _data) { raise error.call if signals.empty? || signals.include?(signal) }
  end

  %i[null error].each do |mode|
    it "D1 [S] sink raising on :denied answers as no sink, mode #{mode}" do
      baseline = run_q(auth_schema(mode: mode), denied_q, user: w.alice, my_invoice: w.b1)
      got, = quiet { attempt { run_q(auth_schema(mode: mode, sinks: [raises_on(:denied)]), denied_q, user: w.alice, my_invoice: w.b1) } }
      obs("D1 #{mode}", got)
      expect(got).to eq(baseline)
      expect(got.to_s).not_to include("B-1")
    end
  end

  it "D1 [S] sink raising on :denied in mode :raise still raises NotAuthorizedError" do
    got, = quiet { attempt { run_q(auth_schema(mode: :raise, sinks: [raises_on(:denied)]), denied_q, user: w.alice, my_invoice: w.b1) } }
    obs("D1 raise", got)
    expect(got[1]).to end_with("NotAuthorizedError")
  end

  it "D1b [S] field-level denied with raising sink: internal notes stay hidden" do
    got, = quiet { attempt { run_q(auth_schema(sinks: [raises_on(:denied)]), denied_q, user: w.alice, my_invoice: w.a1) } }
    obs("D1b", got)
    expect(got.to_s).not_to include("secret A-1")
    expect(got.to_s).to include("A-1")
  end

  it "D3 [S] memo: sink failing, same denied object twice: stays denied, decided once" do
    seen = []
    sink = lambda do |signal, _data|
      seen << signal
      raise "boom"
    end
    q = "{ a: myInvoice { number } b: myInvoice { number } }"
    got, = quiet { attempt { run_q(auth_schema(sinks: [sink]), q, user: w.alice, my_invoice: w.b1) } }
    obs("D3 denied", [got, seen.tally])
    expect(got).to eq("data" => { "a" => nil, "b" => nil })
    expect(seen.count(:denied)).to eq(1)
  end

  it "D2 [S] allowed + failing sink: data served, once memoized" do
    seen = []
    sink = lambda do |signal, _data|
      seen << signal
      raise "boom"
    end
    q = "{ a: myInvoice { number } b: myInvoice { number } }"
    got, = quiet { attempt { run_q(auth_schema(sinks: [sink]), q, user: w.alice, my_invoice: w.a1) } }
    obs("D2", [got, seen.tally])
    expect(got.dig("data", "a", "number")).to eq("A-1")
  end

  %i[null error raise].each do |mode|
    it "D4 [S] on_sink_error raising on :denied: closed, mode #{mode}" do
      s = auth_schema(mode: mode, sinks: [raises_on(:denied)], on_sink_error: ->(_e, _s) { raise IOError, "audit down" })
      got = attempt { run_q(s, denied_q, user: w.alice, my_invoice: w.b1) }
      obs("D4 #{mode}", got)
      expect(got.to_s).not_to include("B-1")
      expect(got[1]).to eq("IOError")
    end
  end

  it "D5 [S] on_sink_error raising on :allowed: no data" do
    s = auth_schema(sinks: [raises_on(:allowed)], on_sink_error: ->(_e, _s) { raise IOError, "audit down" })
    got = attempt { run_q(s, "{ myInvoice { number } }", user: w.alice, my_invoice: w.a1) }
    obs("D5", got)
    expect(got[1]).to eq("IOError")
  end

  it "D6 [S] on_sink_error raising on :scoped: no list" do
    s = auth_schema(sinks: [raises_on(:scoped)], on_sink_error: ->(_e, _s) { raise IOError, "audit down" })
    got = attempt { run_q(s, "{ invoices { number } }", user: w.alice, invoices: Invoice.all) }
    obs("D6", got)
    expect(got[1]).to eq("IOError")
  end

  it "D7 [S] on_sink_error raising on :bypassed: no data" do
    s = auth_schema(sinks: [raises_on(:bypassed)], on_sink_error: ->(_e, _s) { raise IOError, "audit down" })
    got = attempt { run_q(s, "{ ping }", user: w.alice) }
    obs("D7", got)
    expect(got[0]).to eq(:raised)
  end

  it "D7b [D] the class of the error when the root type's bypass fails closed, and when the field's does" do
    s = auth_schema(sinks: [raises_on(:bypassed)], on_sink_error: ->(_e, _s) { raise IOError, "audit down" })
    q = GraphQL::Query.new(s, "{ ping }", context: { current_user: w.alice })
    obs("D7b owner", s.query.method(:authorized_new).owner)
    obs("D7b root", attempt { s.query.authorized_new(IntegrationSchema::Root.new, q.context) })
    expect(true).to eq(true)
  end

  it "D8d [S] fail closed on :scoped vs a rescue_from answering true: no list" do
    s = auth_schema(sinks: [raises_on(:scoped)], on_sink_error: ->(_e, _s) { raise IOError, "audit down" })
    s.rescue_from(StandardError) { |_err, *| true }
    got = attempt { run_q(s, "{ invoices { number } }", user: w.alice, invoices: Invoice.all) }
    obs("D8d", got)
    expect(got.to_s).not_to include("B-1")
    expect(got.to_s).not_to include("A-1")
  end

  it "D8e [S] fail closed on find_by and loads vs a rescue_from answering true" do
    s = auth_schema(sinks: [raises_on(:scoped)], on_sink_error: ->(_e, _s) { raise IOError, "audit down" })
    s.rescue_from(StandardError) { |_err, *| true }
    a = attempt { execute_query(s, "query($id: ID!) { invoice(id: $id) { number } }", variables: { "id" => w.b1.id.to_s }, context: { current_user: w.alice }, root_value: IntegrationSchema::Root.new).to_h }
    b = attempt { execute_query(s, "query($id: ID!) { invoiceViaRef(invoiceId: $id) { number } }", variables: { "id" => w.b1.id.to_s }, context: { current_user: w.alice }, root_value: IntegrationSchema::Root.new).to_h }
    obs("D8e", [a, b])
    expect(a.to_s).not_to include("B-1")
    expect(b.to_s).not_to include("B-1")
  end

  it "D8f [S] the default handler with a raising sink and that rescue_from: the denial stands" do
    s = auth_schema(sinks: [raises_on(:denied)])
    s.rescue_from(StandardError) { |_err, *| true }
    got, = quiet { attempt { run_q(s, "{ myInvoice { number } }", user: w.alice, my_invoice: w.b1) } }
    obs("D8f", got)
    expect(got.to_s).not_to include("B-1")
  end

  it "D8g [S] a rescue_from that logs with Logger#error (answers true), the realistic shape" do
    require "logger"
    logger = Logger.new(StringIO.new)
    s = auth_schema(**closing(:denied) { IOError.new("audit down") })
    s.rescue_from(StandardError) { |err, *| logger.error(err.class.name) }
    got = attempt { run_q(s, "{ myInvoice { number internalNotes } }", user: w.alice, my_invoice: w.b1) }
    obs("D8g", got)
    expect(got.to_s).not_to include("B-1")
  end

  it "D8h [S] the same through a list: every denied row of a raw list" do
    s = auth_schema(**closing(:denied) { IOError.new("audit down") })
    s.rescue_from(StandardError) { |_err, *| true }
    got = attempt { run_q(s, "{ myAccount { allInvoices { number } } }", user: w.alice, my_account: w.account_a) }
    obs("D8h", got)
    expect(true).to eq(true)
  end

  # Works on both copies: on A the hook raises; on B the sink itself raises (B's documented fail closed).
  def closing(signal, &make_error)
    if has_hook
      { sinks: [raises_on(signal)], on_sink_error: ->(_e, _s) { raise make_error.call } }
    else
      { sinks: [raises_on(signal, error: make_error)] }
    end
  end

  [["true", true], ["a String (a logger's answer)", "logged"]].each do |label, answer|
    it "D8 [S] fail closed vs a rescue_from answering #{label}, object denied: refused user must not get the object" do
      s = auth_schema(**closing(:denied) { IOError.new("audit down") })
      s.rescue_from(StandardError) { |_err, *| answer }
      got = attempt { run_q(s, "{ myInvoice { number } }", user: w.alice, my_invoice: w.b1) }
      obs("D8 #{label}", got)
      expect(got.to_s).not_to include("B-1")
    end
  end

  it "D8 [D] rescue_from answering nil: closed" do
    s = auth_schema(**closing(:denied) { IOError.new("audit down") })
    s.rescue_from(StandardError) { |_err, *| nil }
    got = attempt { run_q(s, "{ myInvoice { number } }", user: w.alice, my_invoice: w.b1) }
    obs("D8 nil", got)
    expect(got.to_s).not_to include("B-1")
  end

  it "D8c [D] control: a raising policy with the same rescue_from (no sinks at all)" do
    policy = Class.new do
      def initialize(*) = nil
      def read? = raise(IOError, "policy down")
    end
    original = InvoicePolicy.instance_method(:read?)
    InvoicePolicy.send(:define_method, :read?) { raise IOError, "policy down" }
    begin
      s = auth_schema
      s.rescue_from(StandardError) { |_err, *| true }
      got = attempt { run_q(s, "{ myInvoice { number } }", user: w.alice, my_invoice: w.b1) }
      obs("D8c", [got, policy.name])
    ensure
      InvoicePolicy.send(:define_method, :read?, original)
    end
    expect(true).to eq(true)
  end

  it "D9 [S] on_sink_error raising UnauthorizedError on :allowed: no object" do
    s = auth_schema(sinks: [raises_on(:allowed)], on_sink_error: ->(_e, _s) { raise GraphQL::UnauthorizedError.new("x") })
    got = attempt { run_q(s, "{ myInvoice { number } }", user: w.alice, my_invoice: w.a1) }
    obs("D9 unauthorized", got)
    expect(got.to_s).not_to include("A-1")
  end

  it "D9 [S] on_sink_error raising ExecutionError on :denied: no object" do
    s = auth_schema(sinks: [raises_on(:denied)], on_sink_error: ->(_e, _s) { raise GraphQL::ExecutionError, "audit" })
    got = attempt { run_q(s, "{ myInvoice { number } }", user: w.alice, my_invoice: w.b1) }
    obs("D9 exec", got)
    expect(got.to_s).not_to include("B-1")
  end

  it "D9b [S] on_sink_error raising ExecutionError on :allowed: no object" do
    s = auth_schema(sinks: [raises_on(:allowed)], on_sink_error: ->(_e, _s) { raise GraphQL::ExecutionError, "audit" })
    got = attempt { run_q(s, "{ myInvoice { number } }", user: w.alice, my_invoice: w.a1) }
    obs("D9b", got)
    expect(got.to_s).not_to include("A-1")
  end

  [GraphQL::ExecutionError, GraphQL::UnauthorizedError].each do |klass|
    it "D10 [S] sink raising #{klass} on :denied: same as no sink" do
      baseline = run_q(auth_schema, denied_q, user: w.alice, my_invoice: w.b1)
      got, = quiet { attempt { run_q(auth_schema(sinks: [raises_on(:denied, error: -> { klass.new("x") })]), denied_q, user: w.alice, my_invoice: w.b1) } }
      obs("D10 #{klass}", got)
      expect(got).to eq(baseline)
    end
  end

  it "D10b [D] sink raising ExecutionError on :allowed" do
    got, = quiet { attempt { run_q(auth_schema(sinks: [raises_on(:allowed, error: -> { GraphQL::ExecutionError.new("no") })]), "{ myInvoice { number } }", user: w.alice, my_invoice: w.a1) } }
    obs("D10b", got)
    expect(true).to eq(true)
  end

  [NotImplementedError, Exception, SystemStackError].each do |klass|
    it "D11 [S] sink raising #{klass} (not StandardError) on :denied: no data, propagates" do
      s = auth_schema(sinks: [raises_on(:denied, error: -> { klass.new("x") })])
      got, err = quiet { attempt { run_q(s, "{ myInvoice { number } }", user: w.alice, my_invoice: w.b1) } }
      obs("D11 #{klass}", [got, err])
      expect(got.to_s).not_to include("B-1")
      # graphql-ruby turns SystemStackError into its "too large" error, so that one answers, without data.
      expect(got.to_s).to include("too large").or(satisfy { got[0] == :raised })
    end
  end

  it "D12 [S] sink raising on :scoped: list stays scoped and answers" do
    got, = quiet { attempt { run_q(auth_schema(sinks: [raises_on(:scoped)]), "{ invoices { number } }", user: w.alice, invoices: Invoice.all) } }
    obs("D12", got)
    expect(got.dig("data", "invoices").map { |i| i["number"] }.sort).to eq(%w[A-1 A-2])
  end

  it "D12b [S] connection: raising sink keeps total and page scoped" do
    got, = quiet { attempt { run_q(auth_schema(sinks: [raises_on]), "{ invoicesConnection { totalCount nodes { number } } }", user: w.alice, invoices_connection: Invoice.all) } }
    obs("D12b", got)
    expect(got.to_s).not_to include("B-1")
    expect(got.dig("data", "invoicesConnection", "totalCount")).to eq(2)
  end

  it "D12c [S] find_by and loads with raising sink: foreign id looks missing" do
    s = auth_schema(sinks: [raises_on])
    a, = quiet { attempt { execute_query(s, "query($id: ID!) { invoice(id: $id) { number } }", variables: { "id" => w.b1.id.to_s }, context: { current_user: w.alice }, root_value: IntegrationSchema::Root.new).to_h } }
    b, = quiet { attempt { execute_query(s, "query($id: ID!) { invoiceViaRef(invoiceId: $id) { number } }", variables: { "id" => w.b1.id.to_s }, context: { current_user: w.alice }, root_value: IntegrationSchema::Root.new).to_h } }
    obs("D12c", [a, b])
    expect(a.to_s).not_to include("B-1")
    expect(b.to_s).not_to include("B-1")
    expect(a).to eq("data" => { "invoice" => nil })
  end

  it "D13 [P] bypass with raising sink returns the data" do
    got, = quiet { attempt { run_q(auth_schema(sinks: [raises_on]), "{ ping }", user: w.alice) } }
    obs("D13", got)
    expect(got).to eq("data" => { "ping" => "pong" })
  end

  # --- IDs ---
  def ids_schema(found: { "1" => armory::IDs::Controls::Record.example(id: 1) }, **opts)
    invoice = Class.new(GraphQL::Schema::Object) do
      graphql_name "Invoice"
      implements GraphQL::Types::Relay::Node
      field :number, String, null: false, **(ArmoryEngine.supported? ? { resolve_legacy_instance_method: true } : {})
      def number = "SECRET-1"
    end
    payload = Class.new(GraphQL::Schema::Object) { graphql_name "Payload"; field :ok, GraphQL::Types::Boolean, null: false }
    query = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :ok, GraphQL::Types::Boolean, null: false
      field :node, GraphQL::Types::Relay::Node, null: true, **(ArmoryEngine.supported? ? { resolve_legacy_instance_method: true } : {}) do
        argument :id, GraphQL::Types::ID
      end
      def node(id:) = context.schema.object_from_id(id, context)
    end
    plugin = armory::IDs
    enc = encoder
    Class.new(ArmoryEngine.base_schema) do
      query query
      orphan_types invoice, payload
      define_singleton_method(:resolve_type) { |_t, _o, _c| invoice }
      use plugin, encoder: enc, find: ->(_type, key, _context) { found[key] }, **opts
    end
  end

  def ctx_of(schema) = GraphQL::Query.new(schema, "{ ok }").context

  { "valid" => ->(e) { e.encode("Invoice/1") }, "malformed" => ->(e) { e.encode("Invoice") }, "unknown" => ->(e) { e.encode("Ghost/1") },
    "payload" => ->(e) { e.encode("Payload/1") }, "missing" => ->(e) { e.encode("Invoice/9") }, "forged" => ->(e) { e.encode("Invoice/1").reverse } }.each do |name, make|
    it "D14 [S] IDs raising sink, #{name}: answer as no sink" do
      plain = ids_schema
      failing = ids_schema(sinks: [raises_on])
      id = make.(encoder)
      base = attempt { plain.object_from_id(id, ctx_of(plain))&.id }
      got, err = quiet { attempt { failing.object_from_id(id, ctx_of(failing))&.id } }
      obs("D14 #{name}", [base, got, err])
      expect(got).to eq(base)
    end
  end

  it "D15 [P] sink raising InvalidError on :id_resolved: object still served, one signal" do
    seen = []
    sink = lambda do |signal, _d|
      seen << signal
      raise armory::Encoder::InvalidError
    end
    s = ids_schema(sinks: [sink])
    got, = quiet { attempt { s.object_from_id(encoder.encode("Invoice/1"), ctx_of(s))&.id } }
    obs("D15", [got, seen])
    expect(got).to eq(1)
    expect(seen).to eq([:id_resolved])
  end

  it "D16 [S] on_sink_error raising InvalidError on :id_resolved only: no object" do
    seen = []
    sink = lambda do |signal, _d|
      seen << signal
      raise "boom" if signal == :id_resolved
    end
    s = ids_schema(sinks: [sink], on_sink_error: ->(_e, _s) { raise armory::Encoder::InvalidError })
    got = attempt { s.object_from_id(encoder.encode("Invoice/1"), ctx_of(s)) }
    obs("D16", [got, seen])
    expect(got).to be_nil.or(satisfy { |v| v.is_a?(Array) && v[0] == :raised })
  end

  it "D17 [S] on_sink_error raising InvalidError on :id_refused: no recursion, no data" do
    seen = []
    sink = lambda do |signal, data|
      seen << [signal, data[:reason]]
      raise "boom"
    end
    s = ids_schema(sinks: [sink], on_sink_error: ->(_e, _s) { raise armory::Encoder::InvalidError })
    got = attempt { s.object_from_id(encoder.encode("Invoice/9"), ctx_of(s)) }
    obs("D17", [got, seen])
    expect(seen.size).to be <= 2
    expect(got.to_s).not_to include("SECRET")
    expect(got[1]).to eq("GraphQL::Armory::Encoder::InvalidError")
  end

  [GraphQL::Armory::Encoder::InvalidError, IOError].each do |klass|
    it "D17b [S] through a real query: on_sink_error raising #{klass} on :id_resolved gives no data" do
      s = ids_schema(sinks: [raises_on(:id_resolved)], on_sink_error: ->(_e, _s) { raise klass, "x" })
      got = attempt { execute_query(s, "query($id: ID!) { node(id: $id) { ... on Invoice { number } } }", variables: { "id" => encoder.encode("Invoice/1") }).to_h }
      obs("D17b #{klass}", got)
      expect(got.to_s).not_to include("SECRET-1")
    end
  end

  it "D18 [S] on_sink_error raising ArgumentError through a loads: lookup: no data (request fail?)" do
    enc = encoder
    s = IntegrationSchema.build(plugin: false)
    s.use(armory::Authorization, adapter: :pundit)
    hook = ->(_e, _sig) { raise ArgumentError, "audit down" }
    lookup_sinks = [raises_on(:id_resolved)]
    record = w.a1
    s.define_singleton_method(:object_from_id) do |id, context|
      GraphQL::Armory::IDs::Lookup.build(encoder: enc, find: ->(_t, _k, _c) { record }, sinks: lookup_sinks, on_sink_error: hook).object_for(id, context)
    end
    id = enc.encode("Invoice/#{w.a1.id}")
    got = attempt { execute_query(s, "query($id: ID!) { invoiceViaRef(invoiceId: $id) { number } }", variables: { "id" => id }, context: { current_user: w.alice }, root_value: IntegrationSchema::Root.new).to_h }
    obs("D18", got)
    expect(got.to_s).not_to include("A-1")
  end

  it "D19 [S] on_sink_error raising IOError: object_from_id raises" do
    s = ids_schema(sinks: [raises_on], on_sink_error: ->(_e, _s) { raise IOError, "x" })
    got = attempt { s.object_from_id(encoder.encode("Invoice/1"), ctx_of(s)) }
    obs("D19", got)
    expect(got[1]).to eq("IOError")
  end

  # --- persisted queries ---
  def pq_schema(strict: true, **opts)
    plugin = armory::PersistedQueries
    q = plugin::Controls::Query.example
    store = plugin::Store::Substitute.new(qtext)
    Class.new(ArmoryEngine.base_schema) do
      query q
      use plugin, store: store, strict: strict, **opts
    end
  end

  def pq_run(schema, text, root_log, **ctx)
    execute_query(schema, text, root_value: armory::PersistedQueries::Controls::Root.example(root_log), context: ctx).to_h
  end

  it "D20 [S] raising sink at raw refused: never runs" do
    log = []
    got, = quiet { attempt { pq_run(pq_schema(sinks: [raises_on]), "{ secret }", log) } }
    obs("D20 raw", [got, log])
    expect(log).to eq([])
    expect(got["data"]).to be_nil
    expect(got["errors"].size).to eq(1)
  end

  it "D20 [S] raising sink at unknown: never runs" do
    log = []
    got, = quiet { attempt { pq_run(pq_schema(sinks: [raises_on]), "{ secret }", log, operation_id: "deadbeef") } }
    obs("D20 unk", [got, log])
    expect(log).to eq([])
    expect(got["errors"].size).to eq(1)
  end

  it "D20 [S] raising sink at mismatch: never runs" do
    log = []
    got, = quiet { attempt { pq_run(pq_schema(sinks: [raises_on]), "{ secret }", log, operation_id: pq_id) } }
    obs("D20 mis", [got, log])
    expect(log).to eq([])
    expect(got["errors"].size).to eq(1)
  end

  { raw: {}, unknown: { operation_id: "nope" }, mismatch: { operation_id: :id }, ok: { operation_id: :id, text: nil } }.each do |name, base_ctx|
    it "D21 [S] on_sink_error raising in gate #{name}: raises, nothing runs" do
      log = []
      ctx = base_ctx.dup
      ctx[:operation_id] = pq_id if ctx[:operation_id] == :id
      text = ctx.key?(:text) ? ctx.delete(:text) : "{ secret }"
      s = pq_schema(sinks: [raises_on], on_sink_error: ->(_e, _s) { raise IOError, "x" })
      got = attempt { pq_run(s, text, log, **ctx) }
      obs("D21 #{name}", [got, log])
      expect(log).to eq([])
      expect(got[1]).to eq("IOError")
    end
  end

  it "D22 [P] raising sink at persisted: operation runs" do
    log = []
    got, = quiet { attempt { pq_run(pq_schema(sinks: [raises_on]), nil, log, operation_id: pq_id) } }
    obs("D22", [got, log])
    expect(log).to eq([:invoices])
  end

  # --- sink shapes ---
  def shape_table
    three = Class.new { attr_accessor :got; def call(a, b, c) = @got = [a, b, c] }.new
    two = Class.new { attr_accessor :got; def call(a, b) = @got = [a, b] }.new
    rest = Class.new { attr_accessor :got; def call(*a) = @got = a }.new
    opt = Class.new { attr_accessor :got; def call(a, b, c = :none) = @got = [a, b, c] }.new
    mm = Class.new do
      attr_accessor :got
      def method_missing(name, *args) = name == :call ? (@got = args) : super
      def respond_to_missing?(name, priv = false) = name == :call || super
    end.new
    mod = Module.new { def self.call(a, b, c) = (@got = [a, b, c]); def self.got = @got }
    mod2 = Module.new { def self.call(a, b) = (@got = [a, b]); def self.got = @got }
    param = Class.new { attr_accessor :got; def parameters = [[:req], [:req], [:req]]; def call(a, b) = @got = [a, b] }.new
    h = {}
    holder = Class.new do
      attr_accessor :got
      def rest(*a) = @got = a
      def m3(a, b, c) = @got = [a, b, c]
      def m2(a, b) = @got = [a, b]
    end
    m3 = holder.new
    m2 = holder.new
    mr = holder.new
    rest2 = Class.new { attr_accessor :got; def call(*a) = @got = a }.new
    deleg = SimpleDelegator.new(rest2)

    { "lam 3req" => [->(a, b, c) { h[:l3] = [a, b, c] }, -> { h[:l3] }],
      "lam c=nil" => [->(a, b, c = :none) { h[:lo] = [a, b, c] }, -> { h[:lo] }],
      "lam *args" => [->(*a) { h[:lr] = a }, -> { h[:lr] }],
      "lam a,b,*c" => [->(a, b, *c) { h[:lbr] = [a, b, c] }, -> { h[:lbr] }],
      "lam a,b,c,*d" => [->(a, b, c, *d) { h[:lcr] = [a, b, c, d] }, -> { h[:lcr] }],
      "lam 4req" => [->(a, b, c, d) { h[:l4] = [a, b, c, d] }, -> { h[:l4] }],
      "lam 1req" => [->(a) { h[:l1] = [a] }, -> { h[:l1] }],
      "lam a,b,k:1" => [->(a, b, k: 1) { h[:lk] = [a, b, k] }, -> { h[:lk] }],
      "lam a,b,k:" => [->(a, b, k:) { h[:lkr] = [a, b, k] }, -> { h[:lkr] }],
      "lam a,b,c,k:1" => [->(a, b, c, k: 1) { h[:l3k] = [a, b, c, k] }, -> { h[:l3k] }],
      "lam a,*b,c" => [->(a, *b, c) { h[:lm] = [a, b, c] }, -> { h[:lm] }],
      "proc a" => [proc { |a| h[:p1] = [a] }, -> { h[:p1] }],
      "proc a,b" => [proc { |a, b| h[:p2] = [a, b] }, -> { h[:p2] }],
      "proc a,b,c" => [proc { |a, b, c| h[:p3] = [a, b, c] }, -> { h[:p3] }],
      "proc a,b,c=1" => [proc { |a, b, c = :none| h[:po] = [a, b, c] }, -> { h[:po] }],
      "proc *a" => [proc { |*a| h[:pr] = a }, -> { h[:pr] }],
      "proc a,b,*c" => [proc { |a, b, *c| h[:pbr] = [a, b, c] }, -> { h[:pbr] }],
      "proc a,b,c,*d" => [proc { |a, b, c, *d| h[:pcr] = [a, b, c, d] }, -> { h[:pcr] }],
      "proc a,b,k:1" => [proc { |a, b, k: 1| h[:pk] = [a, b, k] }, -> { h[:pk] }],
      "proc _1,_2,_3" => [proc { h[:pn] = [_1, _2, _3] }, -> { h[:pn] }],
      "proc no args" => [proc { h[:p0] = true }, -> { h[:p0] }],
      "sym to_proc" => [:then.to_proc, -> { :no_view }],
      "curried lam3" => [->(a, b, c) { h[:cu] = [a, b, c] }.curry, -> { h[:cu] }],
      "Method 3req" => [m3.method(:m3), -> { m3.got }],
      "Method 2req" => [m2.method(:m2), -> { m2.got }],
      "Method rest" => [mr.method(:rest), -> { mr.got }],
      "Method stdout.puts" => [StringIO.new.method(:puts), -> { :no_view }],
      "obj 3req" => [three, -> { three.got }],
      "obj 2req" => [two, -> { two.got }],
      "obj rest" => [rest, -> { rest.got }],
      "obj c=nil" => [opt, -> { opt.got }],
      "method_missing+respond_to_missing" => [mm, -> { mm.got }],
      "Module 3" => [mod, -> { mod.got }],
      "Module 2" => [mod2, -> { mod2.got }],
      "obj with parameters method" => [param, -> { param.got }],
      "SimpleDelegator(rest)" => [deleg, -> { rest2.got }] }
  end

  it "D23 [S] shape table: who gets the context; only what requires a third slot does" do
    context = { token: "TOKEN" }
    leaks = []
    shape_table.each do |label, (sink, read)|
      result, err = quiet do
        attempt do
          t = armory::Telemetry.build(sinks: [sink])
          has_ctx ? t.record(:sig, context: context, a: 1) : t.record(:sig, a: 1)
          read.call
        end
      end
      got_it = result.to_s.include?("TOKEN")
      leaks << label if got_it
      "OBS D23 #{label}: ctx=#{got_it} warn=#{!err.empty?} got=#{result.inspect[0, 70]}"
    end
    obs("D23 got context", leaks)
    allowed = ["lam 3req", "lam a,b,c,*d", "lam a,b,c,k:1", "proc a,b,c", "proc a,b,c,*d", "proc _1,_2,_3", "Method 3req", "obj 3req", "Module 3"]
    expect(leaks - allowed).to eq([])
  end

  it "D23b [S] Telemetry::Notifications never receives the context" do
    got = armory::Telemetry.new(sinks: []).send(:takes_context?, armory::Telemetry::Notifications)
    expect(got).to eq(false)
  end

  it "D24 [P] object with respond_to?(:call) and method_missing, no respond_to_missing?, boots" do
    sink = Class.new do
      attr_reader :got
      def respond_to?(name, priv = false) = name == :call || super
      def method_missing(name, *args) = name == :call ? (@got = args) : super
    end.new
    got = attempt { armory::Telemetry.build(sinks: [sink]).record(:s, a: 1); sink.got }
    obs("D24 mm", got)
    expect(got).to eq([:s, { a: 1 }])
  end

  it "D24 [P] Struct with a :method member (HTTP webhook sink) boots" do
    klass = Struct.new(:method, :url) { attr_accessor :got; def call(a, b) = self.got = [a, b] }
    sink = klass.new("POST", "http://x")
    got = attempt { armory::Telemetry.build(sinks: [sink]).record(:s, a: 1); sink.got }
    obs("D24 struct", got)
    expect(got).to eq([:s, { a: 1 }])
  end

  it "D24 [P] BasicObject-based sink defining respond_to? boots" do
    sink = Class.new(BasicObject) do
      attr_reader :got
      def respond_to?(name, _priv = false) = name == :call
      def call(a, b) = @got = [a, b]
    end.new
    got = attempt { armory::Telemetry.build(sinks: [sink]).record(:s, a: 1); sink.got }
    obs("D24 basic", got)
    expect(got).to eq([:s, { a: 1 }])
  end

  it "D25 [D] a sink that can never be called (4 required) boots, fails on every record" do
    calls, err = quiet { attempt { 2.times { armory::Telemetry.build(sinks: [->(a, b, c, d) {}]).record(:s) } } }
    obs("D25", [calls, err])
    expect(true).to eq(true)
  end

  # --- context mutation ---
  it "D26 [D] sink changing the raw context at the gate: what the resolver sees" do
    seen = []
    q = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :who, String, null: false, **(ArmoryEngine.supported? ? { resolve_legacy_instance_method: true } : {})
      define_method(:who) { context[:current_user].to_s.tap { |w| seen << w } }
    end
    plugin = armory::PersistedQueries
    sink = ->(_s, _d, c) { c[:current_user] = "admin" }
    s = Class.new(ArmoryEngine.base_schema) do
      query q
      use plugin, store: plugin::Store::Substitute.new("{ who }"), strict: false, sinks: [sink]
    end
    got, err = quiet { attempt { execute_query(s, "{ who }", context: { current_user: "bob" }).to_h } }
    obs("D26", [got, err[0, 80]])
    expect(true).to eq(true)
  end

  it "D26b [D] sink setting armory_allow_raw_query on a refused request in a shared hash" do
    plugin = armory::PersistedQueries
    log = []
    sink = ->(_s, _d, c) { c[:armory_allow_raw_query] = true }
    s = pq_schema(sinks: [sink])
    shared = {}
    a, err = quiet { attempt { execute_query(s, "{ secret }", root_value: plugin::Controls::Root.example(log), context: shared).to_h } }
    b, = quiet { attempt { execute_query(s, "{ secret }", root_value: plugin::Controls::Root.example(log), context: shared).to_h } }
    obs("D26b", [a, b, log, shared, err[0, 80]])
    expect(true).to eq(true)
  end

  it "D27 [D] sink changing current_user on :allowed: later decisions change" do
    sink = ->(signal, _d, c) { c[:current_user] = User.find_by(name: "bob") if signal == :allowed }
    q = "{ a: myInvoice { number } b: myAccount { name } }"
    got, err = quiet { attempt { run_q(auth_schema(sinks: [sink]), q, user: w.alice, my_invoice: w.a1, my_account: w.account_b) } }
    obs("D27", [got, err[0, 80]])
    expect(true).to eq(true)
  end

  # --- gate contexts ---
  def gate_ctx_probe(context, text: "{ invoices }")
    seen = []
    log = []
    s = pq_schema(strict: false, sinks: [->(sig, _d, c) { seen << [sig, c.class.name] }])
    out, err = quiet { attempt { execute_query(s, text, root_value: armory::PersistedQueries::Controls::Root.example(log), context: context).to_h } }
    [out, seen, log, err[0, 120]]
  end

  it "D28 [P] nil context" do
    got = gate_ctx_probe(nil)
    obs("D28 nil", got)
    expect(got[1]).to eq([[:raw_query_run, "GraphQL::Armory::Telemetry::ContextView"]])
    expect(got[2]).to eq([:invoices])
  end

  it "D28 [P] frozen Hash context" do
    got = gate_ctx_probe({ a: 1 }.freeze)
    obs("D28 frozen", got)
    expect(got[1].first.first).to eq(:raw_query_run)
  end

  it "D28 [P] Hash with default proc" do
    got = gate_ctx_probe(Hash.new { |_, k| k == :armory_allow_raw_query ? false : nil })
    obs("D28 defproc", got)
    expect(got[1].first.first).to eq(:raw_query_run)
  end

  it "D28 [D] non-Hash context object responding to [], and a plain Object" do
    ctx = Class.new { def [](_k) = nil; def key?(_k) = false; def fetch(_k, d = nil) = d }.new
    obs("D28 obj", gate_ctx_probe(ctx))
    obs("D28 Object", gate_ctx_probe(Object.new))
    expect(true).to eq(true)
  end

  it "D28 [S] multiplex: refused query never runs, its neighbour does, each records with its own context" do
    seen = []
    log = []
    s = pq_schema(sinks: [->(sig, d, c) { seen << [sig, d[:reason], c[:who]]; raise "boom" }])
    root = armory::PersistedQueries::Controls::Root.example(log)
    results = nil
    _, err = quiet do
      results = attempt { s.multiplex([{ query: "{ secret }", context: { who: 1 }, root_value: root }, { query: nil, context: { who: 2, operation_id: pq_id }, root_value: root }]).map(&:to_h) }
    end
    obs("D28 multi", [results, seen, log, err[0, 80]])
    expect(log).to eq([:invoices])
    expect(seen).to eq([[:operation_refused, :raw_query, 1], [:operation_persisted, nil, 2]])
    expect(results[0].dig("errors", 0, "extensions", "code")).to eq("RAW_QUERY_REFUSED")
  end

  # --- data ---
  it "D29 [S] attacker strings never in signal data on any refusal" do
    evil = "EVIL-'\"<script>"
    data = []
    sink = ->(s, d) { data << [s, d] }
    log = []
    ps = pq_schema(sinks: [sink])
    attempt { pq_run(ps, "{ #{evil} }", log) }
    attempt { pq_run(ps, "{ #{evil} }", log, operation_id: evil) }
    attempt { pq_run(ps, "query #{evil} { invoices }", log, operation_id: pq_id) }
    idss = ids_schema(sinks: [sink])
    [encoder.encode("#{evil}/1"), encoder.encode(evil), evil, encoder.encode("Invoice/#{evil}")].each { |id| attempt { idss.object_from_id(id, ctx_of(idss)) } }
    obs("D29", data)
    expect(data.to_s).not_to include("EVIL")
    expect(data).not_to eq([])
  end

  # --- warnings ---
  it "D31 [S] default warning: signal and class, never the message" do
    got, err = quiet { attempt { armory::Telemetry.build(sinks: [raises_on(error: -> { IOError.new("password=hunter2") })]).record(:denied) } }
    obs("D31", [got, err])
    expect(err).not_to include("hunter2")
    expect(err).to include("denied").and include("IOError")
  end

  it "D31b [S] anonymous error class: no message" do
    anon = Class.new(StandardError) { def message = "password=hunter2" }
    got, err = quiet { attempt { armory::Telemetry.build(sinks: [raises_on(error: -> { anon.new })]).record(:denied) } }
    obs("D31b", [got, err])
    expect(err).not_to include("hunter2")
    expect(got).to be_nil
  end

  it "D31c [S] a limiter's raising sink warns with the class only" do
    q = armory::RateLimits::Controls::Query.example
    store = armory::RateLimits::Store::Substitute.new
    store.fail_with(IOError.new("store down"), on: :all)
    limiter = armory::RateLimits::Points
    s = Class.new(ArmoryEngine.base_schema) do
      query q
      use limiter, store: store, limit: 10, sinks: [->(_s, _d) { raise IOError, "password=hunter2" }], on_store_error: ->(_e, _q) {}
    end
    _, err = quiet { attempt { execute_query(s, "{ cheap }", root_value: armory::RateLimits::Controls::Root.example, context: armory::RateLimits::Controls::Context.example).to_h } }
    obs("D31c", err)
    expect(err).not_to include("hunter2")
    expect(err).to include("rate_limit_store_failed")
  end

  it "D32 [S] a rate limiter's default on_store_error never prints the store error's message" do
    q = armory::RateLimits::Controls::Query.example
    store = armory::RateLimits::Store::Substitute.new
    store.fail_with(IOError.new("redis://:hunter2@host"), on: :all)
    limiter = armory::RateLimits::Points
    s = Class.new(ArmoryEngine.base_schema) { query q; use limiter, store: store, limit: 10 }
    _, err = quiet { attempt { execute_query(s, "{ cheap }", root_value: armory::RateLimits::Controls::Root.example, context: armory::RateLimits::Controls::Context.example).to_h } }
    obs("D32", err)
    expect(err).not_to include("hunter2")
  end

  it "D33 [S] on_sink_error not callable: value never printed" do
    secret = Struct.new(:key) { def inspect = "KEY=hunter2"; def to_s = inspect }.new("x")
    got = attempt { armory::Telemetry.build(sinks: [], on_sink_error: secret) }
    obs("D33", got)
    expect(got[1]).to eq("GraphQL::Armory::Telemetry::ConfigurationError")
    expect(got.to_s).not_to include("hunter2")
  end

  # --- refusal ---
  def pq_error(schema, text, **ctx)
    pq_run(schema, text, [], **ctx)["errors"]
  end

  it "D34 [S] each reason carries its code in the response" do
    s = pq_schema
    raw = pq_error(s, "{ secret }")
    unk = pq_error(s, "{ secret }", operation_id: "nope")
    mis = pq_error(s, "{ secret }", operation_id: pq_id)
    nonstr = pq_error(s, "{ secret }", operation_id: 123)
    obs("D34", [raw, unk, mis, nonstr])
    expect([raw, unk, mis, nonstr].map { |e| e[0].dig("extensions", "code") }).to eq(%w[RAW_QUERY_REFUSED UNKNOWN_OPERATION OPERATION_MISMATCH UNKNOWN_OPERATION])
    expect([raw, unk, mis].map(&:size)).to eq([1, 1, 1])
  end

  it "D35 [P] Schema.validate with a refused query: error shape" do
    s = pq_schema
    errs = attempt { s.validate("{ invoices }").map(&:to_h) }
    errs2 = attempt { s.validate("{ invoices }", context: { armory_allow_raw_query: true }).map(&:to_h) }
    errs3 = attempt { s.validate("{ nope }", context: { armory_allow_raw_query: true }).map(&:to_h) }
    obs("D35", [errs, errs2, errs3])
    expect(errs2).to eq([])
  end

  it "D36 [D] RefusalError with a message not in the map" do
    got = attempt { armory::PersistedQueries::RefusalError.new("custom").to_h }
    obs("D36", got)
    expect(true).to eq(true)
  end

  it "D36b [S] an operation id a client chose is never in the error, and the code is there" do
    errs = pq_error(pq_schema, "{ secret }", operation_id: "EVIL")
    obs("D36b", errs)
    expect(errs.to_s).not_to include("EVIL")
    expect(errs[0].dig("extensions", "code")).to eq("UNKNOWN_OPERATION")
  end

  it "D37 [S] validate:false: refusal stands, with its code" do
    log = []
    s = pq_schema
    got = attempt { execute_query(s, "{ secret }", root_value: armory::PersistedQueries::Controls::Root.example(log), context: {}, validate: false).to_h }
    obs("D37 validate:false", [got, log])
    expect(log).to eq([])
    expect(got.dig("errors", 0, "extensions", "code")).to eq("RAW_QUERY_REFUSED")
  end

  it "D37 [S] the schema's validate_max_errors: refusal stands, with its code" do
    log = []
    s = pq_schema
    s.validate_max_errors(1)
    got = attempt { execute_query(s, "{ secret }", root_value: armory::PersistedQueries::Controls::Root.example(log), context: {}).to_h }
    obs("D37 max", [got, log])
    expect(log).to eq([])
    expect(got.dig("errors", 0, "extensions", "code")).to eq("RAW_QUERY_REFUSED")
  end

  it "D28b [D] plain Object as context, no sinks" do
    log = []
    s = pq_schema(strict: false)
    obs("D28b", attempt { execute_query(s, "{ invoices }", root_value: armory::PersistedQueries::Controls::Root.example(log), context: Object.new).to_h })
    expect(true).to eq(true)
  end

  it "D38 [S] the error object answers the Error API" do
    s = pq_schema
    q = s.query_class.new(s, "{ secret }", context: {})
    e = q.static_errors.first
    got = { cls: e.class.name, msg: e.message, path: e.path, nodes: e.nodes, keys: e.to_h.keys, parent: e.is_a?(GraphQL::StaticValidation::Error), val: q.valid?, sanitized: q.sanitized_query_string }
    obs("D38", got)
    expect(e.to_h.keys).to include("message", "extensions")
    expect(q.valid?).to eq(false)
  end

  # --- rate limits ---
  def limited(limiter, store, **opts)
    q = armory::RateLimits::Controls::Query.example
    Class.new(ArmoryEngine.base_schema) do
      query q
      use limiter, store: store, soft: false, **opts
    end
  end

  def rl_run(schema, **ctx)
    execute_query(schema, "{ cheap }", root_value: armory::RateLimits::Controls::Root.example, context: armory::RateLimits::Controls::Context.example(**ctx)).to_h
  end

  def failing(on)
    store = armory::RateLimits::Store::Substitute.new
    store.fail_with(IOError.new("down"), on: on)
    store
  end

  it "D39 [S] Points: one signal, query runs, context is the query's" do
    seen = []
    handled = []
    s = limited(armory::RateLimits::Points, failing(:take), limit: 10, sinks: [->(sg, d, c) { seen << [sg, d, c.class.name, c[:ip]] }], on_store_error: ->(e, _q) { handled << e.class })
    got = attempt { rl_run(s, ip: "x") }
    obs("D39", [got, seen, handled])
    expect(got.dig("data", "cheap")).to eq("ok")
    expect(seen.size).to eq(1)
    expect(handled.size).to eq(1)
  end

  %i[acquire release].each do |on|
    it "D40 [S] Concurrency #{on} failing: one signal; query runs" do
      seen = []
      handled = []
      s = limited(armory::RateLimits::Concurrency, failing(on), limit: 10, sinks: [->(sg, d, c) { seen << [sg, d, c.class.name, c[:ip]] }], on_store_error: ->(e, _q) { handled << e.class })
      got = attempt { rl_run(s, ip: "x") }
      obs("D40 #{on}", [got, seen, handled])
      expect(got.dig("data", "cheap")).to eq("ok")
      expect(seen.size).to eq(1)
      expect(handled.size).to eq(1)
    end
  end

  it "D40 [S] Concurrency multiplex, release failing: one signal per query with its context" do
    seen = []
    s = limited(armory::RateLimits::Concurrency, failing(:release), limit: 10, sinks: [->(sg, _d, c) { seen << [sg, c[:who]] }], on_store_error: ->(_e, _q) {})
    root = armory::RateLimits::Controls::Root.example
    c = armory::RateLimits::Controls::Context
    got = attempt { s.multiplex([{ query: "{ cheap }", context: c.example(who: 1), root_value: root }, { query: "{ cheap }", context: c.example(who: 2), root_value: root }]).map(&:to_h) }
    obs("D40 multi", [got, seen])
    expect(seen).to contain_exactly([:rate_limit_store_failed, 1], [:rate_limit_store_failed, 2])
  end

  it "D41 [S] Time: take and post-run charge failing" do
    seen = []
    s = limited(armory::RateLimits::Time, failing(:take), limit: 1000, sinks: [->(sg, d, c) { seen << [sg, d, c[:ip]] }], on_store_error: ->(_e, _q) {})
    got = attempt { rl_run(s, ip: "x") }
    obs("D41 both", [got, seen])
    expect(got.dig("data", "cheap")).to eq("ok")
    expect(seen.size).to eq(2) # balance and charge

    seen.clear
    store = armory::RateLimits::Store::Substitute.new
    store.fail_with(IOError.new("down"), on: :take, times: 1)
    s = limited(armory::RateLimits::Time, store, limit: 1000, sinks: [->(sg, d, c) { seen << [sg, d, c[:ip]] }], on_store_error: ->(_e, _q) {})
    got = attempt { rl_run(s, ip: "x") }
    obs("D41 once", [got, seen])
    expect(seen.size).to eq(1)
  end

  it "D42 [S] on_store_error raising: sink heard first; error propagates" do
    %i[Points Concurrency Time].each do |c|
      seen = []
      s = limited(armory::RateLimits.const_get(c), failing(:all), limit: 10, sinks: [->(sg, _d) { seen << sg }], on_store_error: ->(_e, _q) { raise ArgumentError, "closed" })
      got = attempt { rl_run(s) }
      obs("D42 #{c}", [got, seen])
      expect(got[1]).to eq("ArgumentError")
      expect(seen).to include(:rate_limit_store_failed)
    end
  end

  it "D42b [S] raising sink does not stop on_store_error, and the request continues" do
    %i[Points Concurrency Time].each do |c|
      handled = []
      s = limited(armory::RateLimits.const_get(c), failing(:all), limit: 10, sinks: [raises_on], on_store_error: ->(e, _q) { handled << e.class })
      got, err = quiet { attempt { rl_run(s) } }
      obs("D42b #{c}", [got, handled, err[0, 120]])
      expect(got.dig("data", "cheap")).to eq("ok")
      expect(handled).not_to be_empty
    end
  end

  it "D43 [S] anonymous store error" do
    store = armory::RateLimits::Store::Substitute.new
    store.fail_with(Class.new(StandardError).new("x"), on: :all)
    seen = []
    s = limited(armory::RateLimits::Points, store, limit: 10, sinks: [->(sg, d) { seen << [sg, d] }], on_store_error: ->(_e, _q) {})
    got = attempt { rl_run(s) }
    obs("D43", [got, seen])
    expect(got.dig("data", "cheap")).to eq("ok")
    expect(seen.first.last[:error]).to start_with("#<Class:")
  end

  it "D44 [S] new stays inert; sinks: through new/build/use fires in all three" do
    %i[Points Concurrency Time].each do |c|
      klass = armory::RateLimits.const_get(c)
      expect(klass.new.instance_variable_get(:@soft)).to eq(false)
      seen = []
      store = failing(:all)
      klass.build(store: store, limit: 10, sinks: [->(s, _d) { seen << s }], on_store_error: ->(_e, _q) {})
      klass.new(store: store, limit: 10, sinks: [->(s, _d) { seen << s }], on_store_error: ->(_e, _q) {})
      schema = limited(klass, store, limit: 10, sinks: [->(s, _d) { seen << s }], on_store_error: ->(_e, _q) {})
      rl_run(schema)
      expect(seen).to include(:rate_limit_store_failed)
    end
  end

  it "D46 [S] hard refusal with a healthy store and a raising sink: still refused, no signal" do
    seen = []
    store = armory::RateLimits::Store::Substitute.new
    s = limited(armory::RateLimits::Points, store, limit: 1, sinks: [->(sg, _d) { seen << sg; raise "x" }])
    got = attempt { execute_query(s, "{ report }", root_value: armory::RateLimits::Controls::Root.example, context: armory::RateLimits::Controls::Context.example).to_h }
    obs("D46", [got, seen])
    expect(got["data"]).to be_nil
    expect(got.dig("errors", 0, "extensions", "code")).to eq("RATE_LIMITED")
  end

  it "D45 [S] limiter generic *args sink does not get the context" do
    seen = []
    s = limited(armory::RateLimits::Points, failing(:take), limit: 10, sinks: [->(*a) { seen << a.size }], on_store_error: ->(_e, _q) {})
    rl_run(s, token: "T")
    expect(seen).to eq([2])
  end

  # --- forwarding ---
  it "D47 [S] on_sink_error reaches Authorize.call, Scope.call, Lookup.build, Gate.build" do
    called = []
    hook = ->(_e, sig) { called << sig }
    sink = raises_on
    ctx = GraphQL::Query.new(auth_schema, "{ ping }", context: { current_user: w.alice }).context
    rule = armory::Authorization::Rule.new(:none, reason: "r")
    null = armory::Authorization::Adapters::Null.new
    armory::Authorization::Authorize.call(w.a1, rule, ctx, adapter: null, sinks: [sink], on_sink_error: hook)
    armory::Authorization::Scope.call([], rule, ctx, adapter: null, sinks: [sink], on_sink_error: hook)
    armory::Authorization::Authorize.build(ctx, adapter: null, sinks: [sink], on_sink_error: hook).(w.a1, armory::Authorization::Rule.new(:read), ctx)
    armory::Authorization::Scope.build(adapter: null, sinks: [sink], on_sink_error: hook).([], armory::Authorization::Rule.new(:read), ctx)
    armory::IDs::Lookup.build(encoder: encoder, sinks: [sink], on_sink_error: hook).object_for("forged", {})
    armory::PersistedQueries::Gate.build(store: armory::PersistedQueries::Store::Null.new, strict: true, sinks: [sink], on_sink_error: hook).call({}, "x", nil)
    obs("D47", called)
    expect(called).to eq(%i[bypassed bypassed denied scoped id_refused operation_refused])
  end

  it "D47b [S] on_sink_error through `use` on a parent reaches a child schema; a child `use` wins" do
    called = []
    parent = auth_schema(sinks: [raises_on], on_sink_error: ->(_e, s) { called << [:parent, s] })
    child = Class.new(parent)
    run_q(child, "{ ping }", user: w.alice)
    obs("D47b inherit", called)
    expect(called).to include([:parent, :bypassed])
    called.clear
    child2 = Class.new(parent)
    child2.use(armory::Authorization, adapter: :pundit, sinks: [raises_on], on_sink_error: ->(_e, s) { called << [:child, s] })
    run_q(child2, "{ ping }", user: w.alice)
    obs("D47b own", called)
    expect(called.map(&:first).uniq).to eq([:child])
  end

  it "D47c [S] Configuration without the keyword" do
    cfg = armory::Authorization::Configuration.new(adapter: :pundit)
    expect(cfg.on_sink_error).to be_nil
  end

  it "D48 [P] on_sink_error given to a limiter is refused, not ignored" do
    got = attempt { limited(armory::RateLimits::Points, failing(:take), limit: 10, on_sink_error: ->(_e, _s) {}) }
    obs("D48", got)
    expect(got[1]).to eq("ArgumentError")
  end

  it "D48b [S] sinks: on a limiter with a healthy store hear nothing" do
    seen = []
    s = limited(armory::RateLimits::Points, armory::RateLimits::Store::Substitute.new, limit: 10, sinks: [->(sg, _d) { seen << sg }])
    rl_run(s)
    expect(seen).to eq([])
  end

  # --- doc claims ---
  it "D49 [D] Substitute's fail_with says 'as a broken sink would': real Telemetry does not raise" do
    real, = quiet { attempt { armory::Telemetry.build(sinks: [raises_on]).record(:s) } }
    sub = armory::Telemetry::Substitute.new
    sub.fail_with(IOError.new("x"))
    fake = attempt { sub.record(:s) }
    obs("D49", [real, fake])
    expect(true).to eq(true)
  end

  it "D50 [S] sinks run in order around a failing one; raising hook stops the rest" do
    order = []
    t = armory::Telemetry.build(sinks: [->(_s, _d) { order << 1 }, ->(_s, _d) { order << 2; raise "x" }, ->(_s, _d) { order << 3 }], on_sink_error: ->(_e, _s) { order << :hook })
    t.record(:s)
    obs("D50", order)
    expect(order).to eq([1, 2, :hook, 3])
    order.clear
    t = armory::Telemetry.build(sinks: [->(_s, _d) { order << 1; raise "x" }, ->(_s, _d) { order << 2 }], on_sink_error: ->(_e, _s) { raise IOError })
    expect { t.record(:s) }.to raise_error(IOError)
    expect(order).to eq([1])
  end

  it "D51 [D] object_from_id with a nil context" do
    seen = []
    s = ids_schema(sinks: [->(sg, _d, c) { seen << [sg, c.class] }])
    got, err = quiet { attempt { s.object_from_id(encoder.encode("Invoice/1"), nil) } }
    obs("D51", [got, seen, err[0, 100]])
    expect(true).to eq(true)
  end

  it "D53 [S] on_sink_error raising on a field-level rule (denied notes, allowed object)" do
    s = auth_schema(sinks: [raises_on(:denied)], on_sink_error: ->(_e, _s) { raise IOError, "x" })
    got = attempt { run_q(s, denied_q, user: w.alice, my_invoice: w.a1) }
    obs("D53", got)
    expect(got.to_s).not_to include("secret A-1")
    expect(got[1]).to eq("IOError")
  end

  it "D53b [S] field-level denied + fail closed + rescue_from answering a value: no secret" do
    s = auth_schema(**closing(:denied) { IOError.new("x") })
    s.rescue_from(StandardError) { |_e, *| "handled" }
    got = attempt { run_q(s, denied_q, user: w.alice, my_invoice: w.a1) }
    obs("D53b", got)
    expect(got.to_s).not_to include("secret A-1")
  end

  it "D54 [P] sink writing a frozen context: swallowed, decision stands" do
    log = []
    s = pq_schema(sinks: [->(_s, _d, c) { c[:x] = 1 }])
    got, err = quiet { attempt { execute_query(s, "{ secret }", root_value: armory::PersistedQueries::Controls::Root.example(log), context: {}.freeze).to_h } }
    obs("D54", [got, log, err[0, 120]])
    expect(log).to eq([])
  end
end
