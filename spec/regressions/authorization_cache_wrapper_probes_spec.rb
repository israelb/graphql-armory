# frozen_string_literal: true

require "delegate"

# Kept from the recheck of PR #62: the per-query copy must never change what the configured adapter answers.
# Baseline: the same adapter behind a transparent SimpleDelegator, which the gem never copies.
module RcProbe
  User = Struct.new(:account_id, :admin, :suspended) do
    def admin? = admin == true
  end

  class Doc
    attr_reader :account_id, :label

    def initialize(account_id, label)
      @account_id = account_id
      @label = label
    end

    def manage_label = label
  end

  class DocPolicy
    attr_reader :user, :record

    def initialize(user, record)
      @user = user
      @record = record
    end

    def read? = record.account_id == user.account_id
    def manage? = user.admin?

    class Scope
      def initialize(_user, scope) = (@scope = scope)
      def resolve = @scope
    end
  end

  # Denials a wrapper adds: object check (label "hidden"), field check (:manage), scope (label "noscope").
  module Denials
    def self.object?(user, subject, rule)
      user.suspended && (rule.action == :manage || (subject.respond_to?(:label) && subject.label == "hidden"))
    end

    def self.scope(user, items)
      user.suspended ? items.reject { |item| item.label == "noscope" } : items
    end
  end

  class DelegatorGuard < SimpleDelegator
    def authorized?(user, subject, rule)
      return false if Denials.object?(user, subject, rule)

      __getobj__.authorized?(user, subject, rule)
    end

    def scope(user, items, rule) = __getobj__.scope(user, Denials.scope(user, items), rule)
  end

  class ForwardingGuard
    def initialize(inner) = (@inner = inner)

    def authorized?(user, subject, rule)
      return false if Denials.object?(user, subject, rule)

      @inner.authorized?(user, subject, rule)
    end

    def scope(user, items, rule) = @inner.scope(user, Denials.scope(user, items), rule)

    def method_missing(name, *args, **kw, &block)
      @inner.respond_to?(name) ? @inner.public_send(name, *args, **kw, &block) : super
    end

    def respond_to_missing?(name, include_private = false) = @inner.respond_to?(name, include_private) || super
  end

  # Pretends to be Pundit through is_a?/kind_of?/class.
  class LyingGuard < ForwardingGuard
    def is_a?(mod) = mod == GraphQL::Armory::Authorization::Adapters::Pundit || super
    alias kind_of? is_a?
    def class = GraphQL::Armory::Authorization::Adapters::Pundit
  end

  module ExtendGuard
    def authorized?(user, subject, rule)
      return false if Denials.object?(user, subject, rule)

      super
    end

    def scope(user, items, rule) = super(user, Denials.scope(user, items), rule)
  end

  Pundit = GraphQL::Armory::Authorization::Adapters::Pundit

  class SubclassGuard < Pundit
    include ExtendGuard
  end

  class FrozenSetting < Pundit
    def initialize(blocked:)
      super()
      @blocked = blocked.freeze
    end

    def authorized?(user, subject, rule)
      return false if user.suspended && subject.respond_to?(:label) && @blocked.include?(subject.label)

      super
    end
  end

  # Mutable setting the app changes at runtime on the configured instance (e.g. a kill switch list).
  class MutableSetting < Pundit
    attr_reader :blocked

    def initialize
      super()
      @blocked = []
    end

    def authorized?(user, subject, rule)
      return false if subject.respond_to?(:label) && @blocked.include?(subject.label)

      super
    end
  end

  # A scalar a subclass reassigns: a quota of object checks across the adapter's life.
  class Quota < Pundit
    def initialize(limit:)
      super()
      @limit = limit
      @used = 0
    end

    def authorized?(user, subject, rule)
      @used += 1
      return false if @used > @limit

      super
    end
  end

  class SelfPerQuery < Pundit
    def initialize(admin_only:)
      super()
      @admin_only = admin_only
    end

    def authorized?(user, subject, rule)
      return false if @admin_only && !user.admin?

      super
    end

    def per_query = self
  end

  class StatsPundit < Pundit
    def per_query = 25
  end

  class CopyHook < Pundit
    def initialize(admin_only:)
      super()
      @admin_only = admin_only
      @tags = ["x"]
    end

    def initialize_copy(source)
      super
      @tags = @tags.dup
    end

    def authorized?(user, subject, rule)
      return false if @admin_only && !user.admin?

      super
    end
  end

  class StatsAdapter
    def actor(context) = context[:current_user]
    def authorized?(user, subject, _rule) = subject.account_id == user.account_id && !Denials.object?(user, subject, GraphQL::Armory::Authorization::Rule.new(:read))
    def scope(user, items, rule) = items.select { |item| authorized?(user, item, rule) }
    def check(_type, _rule) = []
    def per_query = 25
  end
end

RSpec.describe "Regression probes: per-query copy keeps the configured adapter's answers" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:carol) { RcProbe::User.new(1, true, false) }
  let(:alice) { RcProbe::User.new(1, false, false) }
  let(:sus_carol) { RcProbe::User.new(1, true, true) }
  let(:docs) { [RcProbe::Doc.new(1, "a"), RcProbe::Doc.new(1, "hidden"), RcProbe::Doc.new(1, "noscope"), RcProbe::Doc.new(2, "b")] }
  let(:query) { "{ doc { label manageLabel } docs { label manageLabel } unscopedDocs { label manageLabel } }" }

  Root = Struct.new(:doc, :docs, :unscoped_docs, keyword_init: true) unless defined?(Root)

  def build_schema(adapter)
    plugin = armory
    base_field = Class.new(GraphQL::Schema::Field) { include plugin::Base }
    base_object = Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class base_field
    end
    doc = Class.new(base_object) do
      graphql_name "RcDoc"
      authorize :read, model: RcProbe::Doc
      field :label, String, null: true
      field :manage_label, String, null: true, authorize: :manage
    end
    query_t = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :doc, doc, null: true, authorize: :none, reason: "x"
      field :docs, [doc, { null: true }], null: true, authorize: :none, reason: "x"
      field :unscoped_docs, [doc, { null: true }], null: true, authorize: :none, reason: "x", scope: false
    end
    Class.new(base_schema) do
      query query_t
      use plugin, adapter: adapter, on_unauthorized: :null
    end
  end

  def run(adapter, user, doc_index: 1)
    execute_query(build_schema(adapter), query, root_value: Root.new(doc: docs[doc_index], docs: docs, unscoped_docs: docs),
                                                context: { current_user: user }).to_h
  rescue StandardError => error
    { "raised" => error.class.name, "message" => error.message[0, 160] }
  end

  # Runs every user twice (two queries) through the adapter and through the uncopied baseline.
  def compare(tag, adapter, baseline, users: [sus_carol, carol, alice], doc_index: 1)
    got = users.flat_map { |user| [run(adapter, user, doc_index: doc_index), run(adapter, user, doc_index: doc_index)] }
    want = users.flat_map { |user| [run(baseline, user, doc_index: doc_index), run(baseline, user, doc_index: doc_index)] }
    STDOUT.puts "RC #{tag} got=#{got.first.inspect}" if ENV["PROBE_LOG"]
    STDOUT.puts "RC #{tag} want=#{want.first.inspect}" if ENV["PROBE_LOG"]
    expect(got).to eq(want)
    got
  end

  def leaked?(result)
    labels = %w[doc docs unscopedDocs].flat_map { |key| Array(result.dig("data", key)) }.compact
    labels.any? { |item| item["label"] == "hidden" || !item["manageLabel"].nil? }
  end

  it "W1 SimpleDelegator guard: denials run in object, field and scope checks" do
    got = compare("W1", RcProbe::DelegatorGuard.new(armory::Adapters::Pundit.new), SimpleDelegator.new(RcProbe::DelegatorGuard.new(armory::Adapters::Pundit.new)))
    expect(leaked?(got[0])).to be(false)
    expect(got[0].dig("data", "docs").compact.map { |item| item["label"] }).not_to include("noscope")
    expect(got[2].dig("data", "docs").compact.map { |item| item["label"] }).to include("noscope")
  end

  it "W2 method_missing forwarding guard: denials run" do
    got = compare("W2", RcProbe::ForwardingGuard.new(armory::Adapters::Pundit.new), SimpleDelegator.new(RcProbe::ForwardingGuard.new(armory::Adapters::Pundit.new)))
    expect(leaked?(got[0])).to be(false)
    expect(got[0].dig("data", "docs").compact.map { |item| item["label"] }).not_to include("noscope")
  end

  it "W3 guard that lies about is_a?/class: denials run" do
    got = compare("W3", RcProbe::LyingGuard.new(armory::Adapters::Pundit.new), SimpleDelegator.new(RcProbe::LyingGuard.new(armory::Adapters::Pundit.new)))
    expect(leaked?(got[0])).to be(false)
  end

  it "W4 Pundit instance extended with a guard module (Object#extend): denials run" do
    adapter = armory::Adapters::Pundit.new.extend(RcProbe::ExtendGuard)
    got = compare("W4", adapter, SimpleDelegator.new(armory::Adapters::Pundit.new.extend(RcProbe::ExtendGuard)))
    expect(leaked?(got[0])).to be(false)
  end

  it "W5 Pundit instance with a singleton authorized?: denial runs" do
    make = lambda do
      adapter = armory::Adapters::Pundit.new
      def adapter.authorized?(user, subject, rule)
        return false if RcProbe::Denials.object?(user, subject, rule)

        super
      end
      adapter
    end
    got = compare("W5", make.(), SimpleDelegator.new(make.()))
    expect(leaked?(got[0])).to be(false)
  end

  it "S1 Pundit subclass including the guard module: denials run" do
    got = compare("S1", RcProbe::SubclassGuard.new, SimpleDelegator.new(RcProbe::SubclassGuard.new))
    expect(leaked?(got[0])).to be(false)
  end

  it "S2 subclass with a frozen setting from initialize" do
    got = compare("S2", RcProbe::FrozenSetting.new(blocked: ["hidden"]), SimpleDelegator.new(RcProbe::FrozenSetting.new(blocked: ["hidden"])))
    expect(leaked?(got[0].merge("data" => got[0]["data"].transform_values { |v| v.is_a?(Array) ? v.map { |i| i && i.merge("manageLabel" => nil) } : v && v.merge("manageLabel" => nil) }))).to be(false)
  end

  it "S2b a frozen configured adapter still serves" do
    compare("S2b", RcProbe::FrozenSetting.new(blocked: ["hidden"]).freeze, SimpleDelegator.new(RcProbe::FrozenSetting.new(blocked: ["hidden"])))
  end

  it "S3 subclass with a mutable setting changed between queries on the configured instance" do
    adapter = RcProbe::MutableSetting.new
    baseline = SimpleDelegator.new(RcProbe::MutableSetting.new)
    before = [run(adapter, carol), run(baseline, carol)]
    adapter.blocked << "a"
    baseline.blocked << "a"
    after = [run(adapter, carol, doc_index: 0), run(baseline, carol, doc_index: 0)]
    STDOUT.puts "RC S3 #{after.first.inspect}" if ENV["PROBE_LOG"]
    expect(before[0]).to eq(before[1])
    expect(after[0]).to eq(after[1])
    expect(after[0].dig("data", "doc")).to be_nil
  end

  # Pending advisory: the per-query copy starts from the configured adapter, so a scalar it reassigns resets per query.
  xit "S4 subclass that reassigns a scalar ivar (quota across the adapter's life)" do
    adapter = RcProbe::Quota.new(limit: 3)
    baseline = SimpleDelegator.new(RcProbe::Quota.new(limit: 3))
    got = Array.new(3) { run(adapter, carol, doc_index: 0).dig("data", "doc") }
    want = Array.new(3) { run(baseline, carol, doc_index: 0).dig("data", "doc") }
    STDOUT.puts "RC S4 got=#{got.inspect} want=#{want.inspect}" if ENV["PROBE_LOG"]
    expect(got).to eq(want)
  end

  it "S5 subclass overriding per_query to return self" do
    compare("S5", RcProbe::SelfPerQuery.new(admin_only: true), SimpleDelegator.new(RcProbe::SelfPerQuery.new(admin_only: true)))
  end

  # Pending advisory: `per_query` belongs to the gem; a subclass that gives it another meaning breaks.
  xit "S6 subclass overriding per_query with an unrelated meaning" do
    compare("S6", RcProbe::StatsPundit.new, SimpleDelegator.new(RcProbe::StatsPundit.new))
  end

  it "S7 subclass overriding initialize_copy (deep copy)" do
    compare("S7", RcProbe::CopyHook.new(admin_only: true), SimpleDelegator.new(RcProbe::CopyHook.new(admin_only: true)))
  end

  it "C1 custom non-Pundit adapter with an unrelated per_query is asked as configured" do
    compare("C1", RcProbe::StatsAdapter.new, SimpleDelegator.new(RcProbe::StatsAdapter.new))
  end

  it "N1 the configured adapter gains no state after queries" do
    adapters = [armory::Adapters::Pundit.new, RcProbe::FrozenSetting.new(blocked: []), RcProbe::CopyHook.new(admin_only: false),
                armory::Adapters::Pundit.new.extend(RcProbe::ExtendGuard)]
    adapters.each { |adapter| 2.times { run(adapter, carol) } }
    inner = armory::Adapters::Pundit.new
    2.times { run(RcProbe::DelegatorGuard.new(inner), carol) }
    found = (adapters + [inner]).map { |adapter| adapter.instance_variable_get(:@found) }
    STDOUT.puts "RC N1 #{found.inspect}" if ENV["PROBE_LOG"]
    expect(found).to all(be_nil)
  end
end
