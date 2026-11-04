# frozen_string_literal: true

require "delegate"
require "ostruct"

# Kept from the independent verification of PR #62 (per-query authorization caches): every answer must be the one main
# gave. Set PROBE_LOG=1 to print the "OUT" lines the verifier diffed between the branch and main.
module PcProbe
  LOG = []

  User = Struct.new(:account_id, :admin, :suspended) do
    def admin?
      admin == true
    end
  end

  class Policy
    attr_reader :user, :record

    def initialize(user, record)
      @user = user
      @record = record
      LOG << self.class
    end

    class Scope
      def initialize(user, scope)
        @user = user
        @scope = scope
      end

      def resolve
        @scope
      end
    end
  end

  class Doc
    attr_reader :account_id, :label

    def initialize(account_id, label)
      @account_id = account_id
      @label = label
    end

    def manage_label
      label
    end
  end

  class SecretDoc < Doc; end
  class PlainSubDoc < Doc; end

  class Stray
    attr_reader :account_id, :label

    def initialize(account_id, label)
      @account_id = account_id
      @label = label
    end
  end

  Bag = Struct.new(:class, :policy_class, :model_name, :account_id, :label) do
    def manage_label
      label
    end
  end

  class DocPolicy < Policy
    def read? = record.account_id == user.account_id
    def manage? = user.admin?
    def export? = user.admin?
  end

  class SecretDocPolicy < Policy
    def read? = user.admin? && record.account_id == user.account_id
    def manage? = false
    def export? = false
  end

  class BagPolicy < Policy
    def read? = record.account_id == user.account_id
  end

  class LaxPolicy < Policy
    def read? = true
    def manage? = true
    def export? = true
  end

  class DenyPolicy < Policy
    def read? = false
  end

  # Subclass of the gem's adapter with its own setting.
  class AdminOnlyPundit < GraphQL::Armory::Authorization::Adapters::Pundit
    def initialize(user_key: :current_user, admin_only: false)
      super(user_key: user_key)
      @admin_only = admin_only
    end

    def authorized?(user, subject, rule)
      return false if @admin_only && !user.admin?

      super
    end

    def scope(user, items, rule)
      return [] if @admin_only && !user.admin?

      super
    end
  end

  # Subclass whose constructor needs a setting.
  class TenantPundit < GraphQL::Armory::Authorization::Adapters::Pundit
    def initialize(tenant:, user_key: :current_user)
      super(user_key: user_key)
      @tenant = tenant
    end
  end

  # A wrapper adapter written with SimpleDelegator, adding a denial.
  class SuspensionGuard < SimpleDelegator
    def authorized?(user, subject, rule)
      return false if user.suspended

      __getobj__.authorized?(user, subject, rule)
    end

    def scope(user, items, rule)
      return [] if user.suspended

      __getobj__.scope(user, items, rule)
    end
  end

  # A custom adapter with no per_query.
  class PlainAdapter
    def actor(context) = context[:current_user]
    def authorized?(user, subject, _rule) = subject.account_id == user.account_id
    def scope(user, items, rule) = items.select { |item| authorized?(user, item, rule) }
    def check(_type, _rule) = []
  end

  # A custom adapter that happens to have a method called per_query, meaning something else.
  class StatsAdapter < PlainAdapter
    def per_query = 25
  end
end

class PcProbeThingPolicy < PcProbe::Policy
  def read? = true
end

RSpec.describe "PROBES: per-query authorization caches" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:alice) { PcProbe::User.new(1, false, false) }
  let(:carol) { PcProbe::User.new(1, true, false) }
  let(:bob) { PcProbe::User.new(2, false, false) }
  let(:suspended_alice) { PcProbe::User.new(1, false, true) }
  let(:doc_a) { PcProbe::Doc.new(1, "a") }
  let(:doc_b) { PcProbe::Doc.new(2, "b") }
  let(:secret_a) { PcProbe::SecretDoc.new(1, "secret") }
  let(:plain_a) { PcProbe::PlainSubDoc.new(1, "plain") }
  let(:stray_a) { PcProbe::Stray.new(1, "stray") }
  let(:read) { armory::Rule.new(:read) }
  let(:read_doc) { armory::Rule.new(:read, model: PcProbe::Doc) }

  before { PcProbe::LOG.clear }

  def emit(tag, value)
    STDOUT.puts "OUT #{tag} #{value.inspect}" if ENV["PROBE_LOG"]
  end

  def per_query(adapter)
    adapter.respond_to?(:per_query) ? adapter.per_query : adapter
  end

  def ask(adapter, user, subject, rule)
    PcProbe::LOG.clear
    answer = begin
      adapter.authorized?(user, subject, rule)
    rescue StandardError => error
      error.class
    end
    [answer, PcProbe::LOG.dup]
  end

  # Asks every step on one per-query copy, in order, and each step alone on a fresh adapter (no cache).
  def differential(tag, steps)
    copy = per_query(armory::Adapters::Pundit.new)
    cached = steps.map { |user, subject, rule| ask(copy, user, subject, rule) }
    fresh = steps.map { |user, subject, rule| ask(armory::Adapters::Pundit.new, user, subject, rule) }
    emit(tag, cached)
    expect(cached).to eq(fresh)
    cached
  end

  Root = Struct.new(:docs, :unscoped_docs, :doc, :export_doc, :things, :invoices, :denied_invoices, keyword_init: true)

  def legacy
    ArmoryEngine.supported? ? { resolve_legacy_instance_method: true } : {}
  end

  def build_schema(adapter: :pundit, sinks: [], mode: :null, doc_rule: { model: PcProbe::Doc }, doc_name: "PcDoc",
                   export: false, rescued: nil, default_action: nil, doc_type_out: nil)
    plugin = armory
    flags = legacy
    base_field = Class.new(GraphQL::Schema::Field) { include plugin::Base }
    base_object = Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class base_field
      default_action default_action if default_action
    end
    rule = doc_rule
    name = doc_name
    doc = Class.new(base_object) do
      graphql_name name
      authorize :read, **rule if rule
      field :label, String, null: true
      field :manage_label, String, null: true, authorize: :manage
    end
    doc_type_out << doc if doc_type_out
    export_t = Class.new(base_object) do
      graphql_name "PcExport"
      authorize :read, model: PcProbe::Doc, visible_when: :export
      field :label, String, null: true
    end
    invoice_t = Class.new(base_object) do
      graphql_name "PcInvoice"
      authorize :read, model: Invoice
      field :number, String, null: true
    end
    note_t = Class.new(base_object) do
      graphql_name "PcNote"
      authorize :read, model: Note
      field :body, String, null: true
    end
    credit_t = Class.new(base_object) do
      graphql_name "PcCredit"
      authorize :read, model: Credit
      field :account_id, Integer, null: true
    end
    denied_t = Class.new(base_object) do
      graphql_name "PcDeniedInvoice"
      authorize :read, model: Invoice, policy: PcProbe::DenyPolicy
      field :number, String, null: true
    end
    mem_t = Class.new(base_object) do
      graphql_name "PcInvoiceMem"
      authorize :read, model: Invoice, scope: :in_memory
      field :number, String, null: true
    end
    union = Class.new(GraphQL::Schema::Union) do
      graphql_name "PcThing"
      possible_types invoice_t, note_t, credit_t
    end
    types = { Invoice => invoice_t, Note => note_t, Credit => credit_t }
    query_t = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :docs, [doc, { null: true }], null: true, authorize: :none, reason: "x"
      field :unscoped_docs, [doc, { null: true }], null: true, authorize: :none, reason: "x", scope: false
      field :doc, doc, null: true, authorize: :none, reason: "x"
      field :export_doc, export_t, null: true, authorize: :none, reason: "x" if export
      field :things, [union, { null: true }], null: true, authorize: :none, reason: "x"
      field :invoices, [invoice_t, { null: true }], null: true, authorize: :none, reason: "x"
      field :denied_invoices, [denied_t, { null: true }], null: true, authorize: :none, reason: "x"
      field :invoice_mem, mem_t, null: true, authorize: :none, reason: "x", find_by: :id do
        argument :id, "GraphQL::Types::ID"
      end
      field :switch_user, String, null: true, authorize: :none, reason: "x", **flags

      def switch_user
        context[:current_user] = context[:other_user]
        "switched"
      end
    end
    Class.new(base_schema) do
      query query_t
      use plugin, adapter: adapter, on_unauthorized: mode, sinks: sinks
      define_singleton_method(:resolve_type) { |_type, object, _context| types.fetch(object.class) }
      rescue_from(StandardError) { |error, *| rescued << error.class; nil } if rescued
    end
  end

  def run(schema, query, user, **root)
    execute_query(schema, query, root_value: Root.new(**root), context: { current_user: user }).to_h
  rescue StandardError => error
    { "raised" => error.class.name, "message" => error.message[0, 160] }
  end

  def labels(result, key = "unscopedDocs")
    data = result.dig("data", key)
    return result unless data

    data.is_a?(Array) ? data.map { |item| item && item["label"] } : data["label"]
  end

  describe "adapter level" do
    it "01 [security] a stricter subclass mixed with parent records, both orders, asks declared and own policies" do
      steps = [alice, carol].flat_map do |user|
        [doc_a, secret_a, doc_a, secret_a, secret_a, doc_a].map { |subject| [user, subject, read_doc] }
      end
      cached = differential("01", steps)
      expect(cached.map(&:first)).to eq([true, false, true, false, false, true, true, true, true, true, true, true])
      expect(cached[1].last).to eq([PcProbe::DocPolicy, PcProbe::SecretDocPolicy])
    end

    it "02 [security] a subclass with no policy runs under the declared one; a stranger raises before and after" do
      steps = [plain_a, stray_a, doc_a, stray_a, plain_a, stray_a].map { |subject| [alice, subject, read_doc] } +
              [[alice, plain_a, read], [alice, doc_a, read], [alice, plain_a, read]]
      cached = differential("02", steps)
      expect(cached.map(&:first)).to eq([true, Pundit::NotDefinedError, true, Pundit::NotDefinedError, true, Pundit::NotDefinedError,
                                         Pundit::NotDefinedError, true, Pundit::NotDefinedError])
    end

    it "03 [security] a relation and a record of the same model get the same policies" do
      world = Dummy::World.build
      rule = armory::Rule.new(:read, model: Invoice)
      steps = [Invoice.where(account_id: world.account_a.id), world.a1, world.b1, Invoice.all, world.b1].map { |subject| [world.alice, subject, rule] }
      cached = differential("03", steps)
      expect(cached.map(&:first)[1..2]).to eq([true, false])
    end

    it "04 [security] the model's class as subject and an instance share a target but keep their answers" do
      export = armory::Rule.new(:export, model: PcProbe::Doc)
      steps = [alice, carol].flat_map do |user|
        [PcProbe::Doc, doc_a, PcProbe::SecretDoc, secret_a, PcProbe::Doc].map { |subject| [user, subject, export] }
      end
      cached = differential("04", steps)
      expect(cached.map(&:first)).to eq([false, false, false, false, false, true, true, false, false, true])
    end

    it "05 [security] a record's singleton policy_class or extended module is never asked" do
      lax = secret_a.dup
      lax.define_singleton_method(:policy_class) { PcProbe::LaxPolicy }
      extended = PcProbe::SecretDoc.new(1, "ext").extend(Module.new { def policy_class = PcProbe::LaxPolicy })
      steps = [lax, secret_a, extended, doc_a, lax].map { |subject| [alice, subject, read_doc] } +
              [lax, secret_a].map { |subject| [alice, subject, read] }
      cached = differential("05", steps)
      expect(cached.map(&:first)).to eq([false, false, false, true, false, false, false])
      expect(cached.flat_map(&:last)).not_to include(PcProbe::LaxPolicy)
    end

    it "06 [security] Struct and OpenStruct members named class, policy_class, model_name name no policy" do
      foreign_bag = PcProbe::Bag.new(PcProbe::Doc, PcProbe::LaxPolicy, "Lax", 2, "bag-b")
      own_bag = PcProbe::Bag.new(PcProbe::SecretDoc, PcProbe::DenyPolicy, "Deny", 1, "bag-a")
      open = OpenStruct.new(class: PcProbe::Doc, policy_class: PcProbe::LaxPolicy, model_name: "Doc", account_id: 1)
      steps = [foreign_bag, own_bag, open, foreign_bag, open, own_bag].flat_map { |subject| [[alice, subject, read], [alice, subject, read_doc]] }
      cached = differential("06", steps)
      expect(cached.map(&:first)).to eq([false, false, true, true, Pundit::NotDefinedError, Pundit::NotDefinedError,
                                         false, false, Pundit::NotDefinedError, Pundit::NotDefinedError, true, true])
      expect(cached.flat_map(&:last)).not_to include(PcProbe::LaxPolicy)
    end

    it "07 [security] String, Symbol and Class spellings of one model are kept apart" do
      rules = [armory::Rule.new(:read, model: PcProbe::Doc), armory::Rule.new(:read, model: "PcProbe::Doc"), armory::Rule.new(:read, model: :"PcProbe::Doc")]
      steps = [plain_a, secret_a, stray_a, doc_a, plain_a].flat_map { |subject| rules.map { |rule| [alice, subject, rule] } } +
              rules.reverse.map { |rule| [alice, plain_a, rule] }
      cached = differential("07", steps)
      expect(cached.first(3).map(&:first)).to eq([true, Pundit::NotDefinedError, Pundit::NotDefinedError])
      expect(cached.last(3).map(&:first)).to eq([Pundit::NotDefinedError, Pundit::NotDefinedError, true])
    end

    it "08 [security] a Note under model Invoice is asked of InvoicePolicy and NotePolicy" do
      world = Dummy::World.build
      note_a = Note.create!(account: world.account_a, body: "na")
      note_b = Note.create!(account: world.account_b, body: "nb")
      credit_a = Credit.create!(account: world.account_a)
      rule = armory::Rule.new(:read, model: Invoice)
      steps = [world.a1, note_a, credit_a, note_b, world.b1, note_a].map { |subject| [world.alice, subject, rule] }
      cached = differential("08", steps)
      expect(cached.map(&:first)).to eq([true, true, true, false, false, true])
    end

    it "09 [security] Symbol subjects: the model's own Symbol is headless, another Symbol or a String raises, any order" do
      rule = armory::Rule.new(:read, model: :pc_probe_thing)
      steps = [:other, :pc_probe_thing, :other, "pc_probe_thing", :pc_probe_thing, :PcProbeThing].map { |subject| [alice, subject, rule] } +
              [[alice, :pc_probe_thing, read], [alice, :pc_probe_thing, rule]]
      cached = differential("09", steps)
      expect(cached.map(&:first)).to eq([Pundit::NotDefinedError, true, Pundit::NotDefinedError, Pundit::NotDefinedError, true,
                                         Pundit::NotDefinedError, Pundit::NotDefinedError, true])
    end

    it "10 [security] a String record under a String model raises every time" do
      rule = armory::Rule.new(:read, model: "PcProbe::Doc")
      steps = [["PcProbe::Doc"], [doc_a], ["PcProbe::Doc"], ["x"]].map { |(subject)| [alice, subject, rule] }
      cached = differential("10", steps)
      expect(cached.map(&:first)).to eq([Pundit::NotDefinedError, true, Pundit::NotDefinedError, Pundit::NotDefinedError])
    end

    it "11 [security] policy: answers alone whatever was found for the same model" do
      named = armory::Rule.new(:read, model: PcProbe::Doc, policy: PcProbe::LaxPolicy)
      steps = [[alice, secret_a, read_doc], [alice, secret_a, named], [alice, secret_a, read_doc], [alice, stray_a, named], [alice, stray_a, read_doc]]
      cached = differential("11", steps)
      expect(cached.map(&:first)).to eq([false, true, false, true, Pundit::NotDefinedError])
    end

    it "12 [security] one copy, several users: answers follow the user" do
      steps = [[alice, doc_b, read_doc], [bob, doc_b, read_doc], [alice, doc_b, read_doc], [bob, doc_a, read_doc], [carol, secret_a, read_doc], [alice, secret_a, read_doc]]
      cached = differential("12", steps)
      expect(cached.map(&:first)).to eq([false, true, false, false, true, false])
    end

    it "13 [preservation] per_query: the configured adapter keeps nothing, the copy keeps user_key, nothing new is public" do
      emit("13 public", armory::Adapters::Pundit.public_instance_methods(false).sort)
      emit("13 private", armory::Adapters::Pundit.private_instance_methods(false).sort)
      adapter = armory::Adapters::Pundit.new(user_key: "viewer")
      skip "no per_query on this tree" unless adapter.respond_to?(:per_query)

      copy = adapter.per_query
      copy.authorized?(alice, doc_a, read_doc)
      expect(adapter.instance_variable_get(:@found)).to be_nil
      expect(copy.actor({ "viewer" => alice })).to equal(alice)
      expect(copy).not_to respond_to(:found=)
      expect(copy.method(:per_query).owner).to eq(armory::Adapters::Pundit)
      expect(armory::Adapters::Pundit.private_method_defined?(:policies_for)).to be(true)
    end

    it "36 [preservation] equal rules hash alike and share a memo entry" do
      first = armory::Rule.new(:read, model: PcProbe::Doc, reason: nil)
      second = armory::Rule.new(:read).with_model(PcProbe::Doc)
      memo = armory::Memo.new
      calls = 0
      2.times { [first, second].each { |rule| memo.fetch(doc_a, rule) { calls += 1 } } }
      emit("36", [first.hash == second.hash, first.eql?(second), calls, armory::Rule.instance_method(:hash).owner])
      expect(first.hash).to eq(second.hash)
      expect({ first => 1 }[second]).to eq(1)
      expect(calls).to eq(1)
    end

    it "37 [preservation] a String model mutated after the rule is built answers like a fresh adapter" do
      model = +"PcProbe::Doc"
      rule = armory::Rule.new(:read, model: model)
      copy = per_query(armory::Adapters::Pundit.new)
      before = [ask(copy, alice, plain_a, rule), ask(armory::Adapters::Pundit.new, alice, plain_a, rule)]
      model.replace("PcProbe::Stray")
      after = [ask(copy, alice, plain_a, rule), ask(armory::Adapters::Pundit.new, alice, plain_a, rule)]
      twin = armory::Rule.new(:read, model: "PcProbe::Stray")
      emit("37", [before, after, rule == twin, rule.hash == twin.hash])
      expect(before.first).to eq(before.last)
      expect(after.first).to eq(after.last)
    end

    # Pending: Rule computes its hash when built, so a member with no #hash (an undocumented `subject:`) raises. Advisory.
    xit "42 [preservation] a rule whose member has no #hash can still be built" do
      outcome = begin
        armory::Rule.new(:read, subject: BasicObject.new)
        :built
      rescue StandardError => error
        error.class
      end
      emit("42", outcome)
      expect(outcome).to eq(:built)
    end
  end

  describe "adapters around or beside Pundit" do
    it "14 [security] a Pundit subclass with its own setting keeps it in every query" do
      schema = build_schema(adapter: PcProbe::AdminOnlyPundit.new(admin_only: true))
      full = [alice, carol].map { |user| run(schema, "{ doc { label } unscopedDocs { label } docs { label } }", user, doc: doc_a, docs: [doc_a], unscoped_docs: [doc_a]) }
      emit("14", full)
      expect(full[0]["data"]).to eq("doc" => nil, "unscopedDocs" => [nil], "docs" => [])
      expect(full[1]["data"]).to eq("doc" => { "label" => "a" }, "unscopedDocs" => [{ "label" => "a" }], "docs" => [{ "label" => "a" }])
    end

    it "15 [security] a SimpleDelegator wrapper that adds a denial still decides" do
      schema = build_schema(adapter: PcProbe::SuspensionGuard.new(armory::Adapters::Pundit.new))
      full = [suspended_alice, alice].map { |user| run(schema, "{ doc { label } unscopedDocs { label } docs { label } }", user, doc: doc_a, docs: [doc_a], unscoped_docs: [doc_a]) }
      emit("15", full)
      expect(full[0]["data"]).to eq("doc" => nil, "unscopedDocs" => [nil], "docs" => [])
      expect(full[1]["data"]).to eq("doc" => { "label" => "a" }, "unscopedDocs" => [{ "label" => "a" }], "docs" => [{ "label" => "a" }])
    end

    it "16 [preservation] a Pundit subclass whose constructor needs a setting still serves" do
      schema = build_schema(adapter: PcProbe::TenantPundit.new(tenant: "t1"))
      result = run(schema, "{ doc { label } }", alice, doc: doc_a)
      emit("16", result)
      expect(result["data"]).to eq("doc" => { "label" => "a" })
    end

    it "17 [preservation] a custom adapter with an unrelated per_query method is still the adapter" do
      schema = build_schema(adapter: PcProbe::StatsAdapter.new)
      result = run(schema, "{ doc { label } }", alice, doc: doc_a)
      emit("17", result)
      expect(result["data"]).to eq("doc" => { "label" => "a" })
    end

    it "31 [preservation] CanCanCan is not wrapped and answers the same" do
      world = Dummy::World.build
      schema = IntegrationSchema.build(adapter: :cancan, flawed: false)
      results = [world.alice, world.bob].map do |user|
        execute_query(schema, "{ invoices { number } }", root_value: IntegrationSchema::Root.new(invoices: Invoice.all), context: { current_user: user }).to_h
      end
      emit("31", results)
      expect(results[0].dig("data", "invoices").map { |i| i["number"] }).to contain_exactly("A-1", "A-2")
      expect(results[1].dig("data", "invoices").map { |i| i["number"] }).to contain_exactly("B-1")
      next unless armory::Integration.respond_to?(:query_adapter)

      context = GraphQL::Query.new(schema, "{ ping }", context: { current_user: world.alice }).context
      expect(armory::Integration.query_adapter(context)).to be(schema.armory_configuration.adapter)
    end

    it "32 [preservation] the Substitute is not wrapped and records every question" do
      adapter = armory::Adapters::Substitute.new(allow: true, actor: alice)
      schema = build_schema(adapter: adapter)
      result = run(schema, "{ unscopedDocs { label } docs { label } }", alice, docs: [doc_a, doc_b], unscoped_docs: [doc_a, doc_b])
      asked = adapter.asked.map { |_, subject, rule| [subject.respond_to?(:label) ? subject.label : subject.to_s, rule.action, rule.model] }
      emit("32", [result, asked.sort_by(&:to_s), adapter.scoped_for.size])
      expect(labels(result)).to eq(%w[a b])
      expect(asked.map(&:first)).to include("a", "b")
      expect(adapter.scoped_for.size).to eq(1)
    end

    it "33 [preservation] the Null adapter denies" do
      result = run(build_schema(adapter: armory::Adapters::Null.new), "{ unscopedDocs { label } docs { label } doc { label } }", carol, docs: [doc_a], unscoped_docs: [doc_a], doc: doc_a)
      emit("33", result)
      expect(result["data"]).to eq("unscopedDocs" => [nil], "docs" => [], "doc" => nil)
    end

    it "34 [preservation] a custom adapter with no per_query works" do
      result = run(build_schema(adapter: PcProbe::PlainAdapter.new), "{ unscopedDocs { label } docs { label } }", alice, docs: [doc_a, doc_b], unscoped_docs: [doc_a, doc_b])
      emit("34", result)
      expect(result["data"]).to eq("unscopedDocs" => [{ "label" => "a" }, nil], "docs" => [{ "label" => "a" }])
    end
  end

  describe "schema level" do
    let(:mixed) { [doc_a, secret_a, doc_b, plain_a, PcProbe::Bag.new(PcProbe::Doc, PcProbe::LaxPolicy, "Doc", 2, "bag")] }

    it "18 [security] a list of a parent model mixing a stricter subclass and a forged Struct" do
      schema = build_schema
      results = [alice, carol, bob].map { |user| run(schema, "{ unscopedDocs { label } docs { label } }", user, docs: mixed, unscoped_docs: mixed) }
      emit("18", results)
      expect(labels(results[0])).to eq(["a", nil, nil, "plain", nil])
      expect(labels(results[1])).to eq(["a", "secret", nil, "plain", nil])
      expect(labels(results[2])).to eq([nil, nil, "b", nil, "bag"])
      expect(labels(results[0], "docs")).to eq(%w[a plain])
      expect(labels(results[1], "docs")).to eq(%w[a secret plain])
    end

    it "19 [security] a union list mixing Invoice, Note and Credit records" do
      world = Dummy::World.build
      note_a = Note.create!(account: world.account_a, body: "na")
      note_b = Note.create!(account: world.account_b, body: "nb")
      credit_a = Credit.create!(account: world.account_a)
      credit_b = Credit.create!(account: world.account_b)
      things = [world.a1, note_a, credit_b, note_b, world.b1, credit_a, note_a]
      query = "{ things { __typename ... on PcInvoice { number } ... on PcNote { body } ... on PcCredit { accountId } } }"
      schema = build_schema
      results = [world.alice, world.bob].map { |user| run(schema, query, user, things: things) }
      emit("19", results.map { |r| r.dig("data", "things")&.map { |t| t&.reject { |k, _| k == "accountId" } } || r })
      alice_things = results[0].dig("data", "things")
      expect(alice_things.map { |t| t && t["__typename"] }).to eq(["PcInvoice", "PcNote", nil, nil, nil, "PcCredit", "PcNote"])
      bob_things = results[1].dig("data", "things")
      expect(bob_things.map { |t| t && t["__typename"] }).to eq([nil, nil, "PcCredit", "PcNote", "PcInvoice", nil, nil])
    end

    it "20 [security] 21 a rule declared, then changed, between queries applies from the next query" do
      holder = []
      schema = build_schema(doc_rule: nil, doc_type_out: holder)
      type = holder.first
      outcomes = [run(schema, "{ doc { label } }", alice, doc: doc_a)]
      type.authorize :read, model: PcProbe::Doc
      outcomes << run(schema, "{ doc { label } }", alice, doc: doc_a)
      type.authorize :manage, model: PcProbe::Doc
      outcomes << run(schema, "{ doc { label } }", alice, doc: doc_a)
      outcomes << run(schema, "{ doc { label } }", carol, doc: doc_a)
      emit("20", outcomes)
      expect(outcomes.map { |o| o.dig("data", "doc") }).to eq([nil, { "label" => "a" }, nil, { "label" => "a" }])
    end

    it "22 [security] a type whose model cannot be found falls back to the record's own policy" do
      schema = build_schema(doc_rule: {}, doc_name: "PcNoSuchModelAnywhere")
      list = [doc_a, secret_a, doc_b]
      results = [alice, carol].map { |user| run(schema, "{ unscopedDocs { label } docs { label } }", user, docs: list, unscoped_docs: list) }
      orphan = run(schema, "{ doc { label } }", carol, doc: plain_a)
      emit("22", [results, orphan])
      expect(labels(results[0])).to eq(["a", nil, nil])
      expect(labels(results[1])).to eq(["a", "secret", nil])
      expect(labels(results[1], "docs")).to eq(%w[a secret])
    end

    it "23 [security] 24 sequential queries and a multiplex with two users keep their own answers" do
      schema = build_schema
      docs = [doc_a, doc_b, secret_a]
      sequential = [alice, bob, alice, carol].map { |user| labels(run(schema, "{ unscopedDocs { label } }", user, unscoped_docs: docs)) }
      queries = [alice, bob, carol].map { |user| { query: "{ unscopedDocs { label } }", root_value: Root.new(unscoped_docs: docs), context: { current_user: user } } }
      multiplexed = ArmoryEngine.next? ? schema.multiplex_next(queries) : schema.multiplex(queries)
      runs = [multiplexed]
      runs << GraphQL::Execution::Next.run_all(schema, queries, context: {}) if ArmoryEngine.next?
      got = runs.map { |results| results.map { |r| labels(r.to_h) } }
      emit("23", [sequential, got])
      expect(sequential).to eq([["a", nil, nil], [nil, "b", nil], ["a", nil, nil], ["a", nil, "secret"]])
      got.each { |each| expect(each).to eq([["a", nil, nil], [nil, "b", nil], ["a", nil, "secret"]]) }
      next unless armory::Integration.respond_to?(:query_adapter) && multiplexed.all? { |r| r.respond_to?(:context) }

      copies = multiplexed.map { |r| r.context.namespace(:armory)[:adapter] }
      expect(copies.compact.map(&:object_id).uniq.size).to eq(3)
      expect(schema.armory_configuration.adapter.instance_variable_get(:@found)).to be_nil
    end

    it "25 [security] concurrent queries in threads keep each user's answers and the shared adapter stays empty" do
      schema = build_schema
      docs = [doc_a, doc_b, secret_a, plain_a]
      run(schema, "{ unscopedDocs { label } }", alice, unscoped_docs: docs)
      threads = Array.new(8) do |index|
        user = [alice, bob, carol, suspended_alice][index % 4]
        Thread.new { Array.new(15) { labels(run(schema, "{ unscopedDocs { label } docs { label } }", user, unscoped_docs: docs, docs: docs)) } }
      end
      seen = threads.map(&:value).map(&:uniq)
      emit("25", seen)
      expected = { 0 => ["a", nil, nil, "plain"], 1 => [nil, "b", nil, nil], 2 => ["a", nil, "secret", "plain"], 3 => ["a", nil, nil, "plain"] }
      seen.each_with_index { |answers, index| expect(answers).to eq([expected[index % 4]]) }
      expect(schema.armory_configuration.adapter.instance_variable_get(:@found)).to be_nil
    end

    it "26 [security] the user changed in the middle of a query answers as on main" do
      schema = build_schema
      docs = [doc_a, doc_b]
      query = "{ first: unscopedDocs { label } switchUser second: unscopedDocs { label } d: doc { label } }"
      result = execute_query(schema, query, root_value: Root.new(unscoped_docs: docs, doc: PcProbe::Doc.new(2, "late-b")), context: { current_user: alice, other_user: bob }).to_h
      emit("26", result)
      expect(result.dig("data", "first")).to eq([{ "label" => "a" }, nil]) unless ArmoryEngine.next?
      expect(result["data"]).not_to be_nil
    end

    it "27 [security] the scope and the check agree: arrays, relations, in-memory find_by, loads:, policy:" do
      schema = build_schema
      docs = mixed
      both = [alice, carol].map { |user| run(schema, "{ unscopedDocs { label } docs { label } }", user, docs: docs, unscoped_docs: docs) }
      both.each { |result| expect(labels(result).compact).to eq(labels(result, "docs")) }
      world = Dummy::World.build
      relation = run(schema, "{ invoices { number } deniedInvoices { number } }", world.alice, invoices: Invoice.all, denied_invoices: Invoice.all)
      mem = [world.a1, world.b1].map do |invoice|
        execute_query(schema, "query($id: ID!) { invoiceMem(id: $id) { number } }", variables: { "id" => invoice.id.to_s }, root_value: Root.new, context: { current_user: world.alice }).to_h
      end
      loaded = [world.a1, world.b1].map { |invoice| load_by(world.alice, invoice.id).to_h }
      emit("27", [both, relation, mem, loaded])
      expect(relation.dig("data", "invoices").map { |i| i["number"] }).to contain_exactly("A-1", "A-2")
      expect(relation.dig("data", "deniedInvoices").compact).to eq([])
      expect(mem.map { |r| r.dig("data", "invoiceMem") }).to eq([{ "number" => "A-1" }, nil])
      expect(loaded.map { |r| r.dig("data", "invoiceViaRef") }).to eq([{ "number" => "A-1", "internalNotes" => nil }, nil])
    end

    it "28 [security] a policy reloaded between queries applies to the next query" do
      define = lambda do |allow|
        Object.send(:remove_const, :PcReloadDoc) if Object.const_defined?(:PcReloadDoc, false)
        Object.send(:remove_const, :PcReloadDocPolicy) if Object.const_defined?(:PcReloadDocPolicy, false)
        Object.const_set(:PcReloadDoc, Class.new(PcProbe::Doc))
        Object.const_set(:PcReloadDocPolicy, Class.new(PcProbe::Policy) { define_method(:read?) { allow } })
        Object.const_get(:PcReloadDoc)
      end
      schema = build_schema(doc_rule: {}, doc_name: "PcReloadDoc")
      old_class = define.(true)
      first = run(schema, "{ doc { label } }", alice, doc: old_class.new(1, "old"))
      new_class = define.(false)
      second = [run(schema, "{ doc { label } }", alice, doc: new_class.new(1, "new")), run(schema, "{ doc { label } }", alice, doc: old_class.new(1, "old"))]
      emit("28", [first, second])
      expect(first.dig("data", "doc")).to eq("label" => "old")
      expect(second.map { |r| r.dig("data", "doc") }).to eq([nil, nil])
    ensure
      Object.send(:remove_const, :PcReloadDoc) if Object.const_defined?(:PcReloadDoc, false)
      Object.send(:remove_const, :PcReloadDocPolicy) if Object.const_defined?(:PcReloadDocPolicy, false)
    end

    it "29 [preservation] telemetry records the same signals" do
      signals = []
      schema = build_schema(sinks: [->(signal, data) { signals << [signal, data] }])
      result = run(schema, "{ unscopedDocs { label manageLabel } docs { label } }", alice, docs: mixed, unscoped_docs: mixed)
      emit("29", [result, signals])
      expect(signals.count { |signal, _| signal == :denied }).to be >= 3
    end

    it "30 [preservation] observe: still serves and records a refused read" do
      signals = []
      schema = build_schema(doc_rule: { model: PcProbe::Doc, observe: "rollout" }, sinks: [->(signal, data) { signals << [signal, data] }])
      result = run(schema, "{ doc { label } unscopedDocs { label } }", alice, doc: doc_b, unscoped_docs: [doc_b, doc_a, secret_a])
      emit("30", [result, signals])
      expect(result.dig("data", "doc")).to eq("label" => "b")
      expect(signals.map(&:first)).to include(:observed)
    end

    it "35 [security] visible_when hides per user and leaves the record checks alone" do
      schema = build_schema(export: true)
      query = "{ exportDoc { label } unscopedDocs { label } }"
      results = [alice, carol, alice].map { |user| run(schema, query, user, export_doc: doc_a, unscoped_docs: [doc_a, secret_a]) }
      emit("35", results)
      expect(results[0]["data"]).to be_nil
      expect(results[1]["data"]).to eq("exportDoc" => { "label" => "a" }, "unscopedDocs" => [{ "label" => "a" }, { "label" => "secret" }])
      expect(results[2]["data"]).to be_nil
    end

    it "38 [security] a field rule over records of several classes in one query" do
      schema = build_schema
      results = [carol, alice].map { |user| run(schema, "{ unscopedDocs { label manageLabel } }", user, unscoped_docs: [doc_a, secret_a, plain_a, doc_a]) }
      emit("38", results)
      expect(results[0].dig("data", "unscopedDocs")).to eq([{ "label" => "a", "manageLabel" => "a" }, { "label" => "secret", "manageLabel" => nil },
                                                           { "label" => "plain", "manageLabel" => "plain" }, { "label" => "a", "manageLabel" => "a" }])
      expect(results[1].dig("data", "unscopedDocs").map { |d| d && d["manageLabel"] }).to eq([nil, nil, nil, nil])
    end

    it "39 [security] a record with no policy fails every time it appears" do
      rescued = []
      schema = build_schema(rescued: rescued)
      other = PcProbe::Stray.new(1, "other")
      result = run(schema, "{ unscopedDocs { label } }", alice, unscoped_docs: [doc_a, stray_a, other, stray_a])
      emit("39", [result, rescued])
      expect(labels(result)).to eq(["a", nil, nil, nil])
      expect(rescued).to eq([Pundit::NotDefinedError] * 3)
    end

    it "40 [security] what a refused user really gets, per mode" do
      world = Dummy::World.build
      outcomes = %i[null error].map { |mode| lookup(world.alice, world.b1.id, mode: mode).to_h } +
                 %i[null error].map { |mode| as(world.alice, "{ myInvoice { number } }", mode: mode, my_invoice: world.b1).to_h }
      emit("40", outcomes)
      expect(outcomes[0]["data"]).to eq("invoice" => nil)
      expect(outcomes[1]["data"]).to eq("invoice" => nil)
      expect(outcomes[2]["data"]).to eq("myInvoice" => nil)
      expect(outcomes[3]["errors"].first.dig("extensions", "code")).to eq("NOT_FOUND")
      expect(outcomes.to_s).not_to include("B-1")
    end
  end
end
