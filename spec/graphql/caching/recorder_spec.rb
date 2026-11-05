# frozen_string_literal: true

require "spec_helper"
require "graphql/armory/caching/recorder/shared_writes"
require "graphql/armory/caching/recorder/log"
require "graphql/armory/caching/context_methods"

# The real recorder (`Recorder::Log`) and the context class that feeds it (`Recorder::Context`), read through real
# queries: what each read and write method records, what is an input, and what a write forbids.
RSpec.describe "GraphQL::Armory::Caching recorder" do
  let(:caching) { GraphQL::Armory::Caching }
  let(:all) { caching::Recorder::ALL }

  def legacy = ArmoryEngine.supported? ? { resolve_legacy_instance_method: true } : {}

  # `{ probe }` calls the root's `probe` with the context; `{ parent { value } }` calls `parent` at the parent's path and
  # `value` below it, so a value set with `scoped_set!` in `parent` is visible in `value`.
  def build_schema(context_class: GraphQL::Query::Context)
    options = legacy
    child = Class.new(GraphQL::Schema::Object) do
      graphql_name "Child"
      field :value, String, null: true, **options
      def value = object[:value]&.call(context)&.to_s
    end
    query_type = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :probe, String, null: true, **options
      field :parent, child, null: true, **options
      def probe = object[:probe]&.call(context)&.to_s

      def parent
        object[:parent]&.call(context)
        object
      end
    end
    wrapped = GraphQL::Armory::Caching::Recorder::Context.wrap(context_class)
    Class.new(base_schema) do
      query query_type
      context_class wrapped
    end
  end

  def run(document = "{ probe }", schema: build_schema, context: {}, **root)
    result = execute_query(schema, document, context: context, root_value: root)
    expect(result.to_h["errors"]).to be_nil
    result.query.context
  end

  def recorder_of(context) = caching::RecordKeys.recorder(context)

  # What a run that reads nothing itself records: graphql-ruby's own machinery keys, covered by the gate.
  def machinery = recorder_of(run).uncovered([])

  def uncovered(**probes) = recorder_of(run(**probes)).uncovered(machinery)

  describe "the context class" do
    it "gives every query a Log, stored in its namespace" do
      context = run

      expect(recorder_of(context)).to be_a(caching::Recorder::Log)
      expect(recorder_of(run)).not_to be(recorder_of(context))
    end

    it "reads nothing but graphql-ruby's machinery keys on a plain run" do
      expect(machinery).not_to include(all)
      expect(machinery - %i[trace visibility_profile current_object current_arguments current_field current_path]).to eq([])
    end

    it "records a key read through [], present or absent" do
      expect(uncovered(context: { locale: "en" }, probe: ->(c) { c[:locale] })).to eq([:locale])
      expect(uncovered(probe: ->(c) { c[:flags] })).to eq([:flags])
    end

    it "records a key read through fetch, present, absent with a default, or with a block" do
      expect(uncovered(context: { locale: "en" }, probe: ->(c) { c.fetch(:locale) })).to eq([:locale])
      expect(uncovered(probe: ->(c) { c.fetch(:flags, "none") })).to eq([:flags])
      expect(uncovered(probe: ->(c) { c.fetch(:flags) { "none" } })).to eq([:flags])
    end

    it "records the first key of dig" do
      expect(uncovered(context: { prefs: { theme: "dark" } }, probe: ->(c) { c.dig(:prefs, :theme) })).to eq([:prefs])
      expect(uncovered(probe: ->(c) { c.dig(:missing, :theme) })).to eq([:missing])
    end

    it "records a key asked with key?, present or absent" do
      expect(uncovered(context: { beta: true }, probe: ->(c) { c.key?(:beta) })).to eq([:beta])
      expect(uncovered(probe: ->(c) { c.key?(:beta) })).to eq([:beta])
    end

    it "records the whole context read through to_h" do
      expect(uncovered(probe: ->(c) { c.to_h.size })).to eq([all])
    end

    it "records the whole context read through to_hash" do
      expect(uncovered(probe: ->(c) { c.to_hash.size })).to eq([all])
    end

    it "records the whole context read through namespace(nil), and not through another namespace" do
      expect(uncovered(probe: ->(c) { c.namespace(nil).size })).to eq([all])
      expect(uncovered(probe: ->(c) { c.namespace(:app_state)[:seen] = true })).to eq([])
    end

    it "records the whole context read through scoped_context, not graphql-ruby's own use of it in fetch" do
      expect(uncovered(probe: ->(c) { c.scoped_context.merged_context.size })).to eq([all])

      fetched = uncovered(context: { locale: "en" }, probe: lambda { |c|
        c.scoped_set!(:locale, "fr")
        c.fetch(:locale)
      })
      expect(fetched).not_to include(all)
    end

    it "records writes through []=, delete, scoped_merge! and scoped_set!" do
      written = recorder_of(run(context: { a: 1, b: 2 }, probe: lambda { |c|
        c[:a] = 0
        c.delete(:b)
        c.scoped_merge!(c: 3)
        c.scoped_set!(:d, 4)
      }))

      expect(written.forbidden_writes(%i[a b c d])).to eq(%i[a b c d])
      expect(written.forbidden_writes([])).to eq([])
    end

    it "records writes through the Scoped object of context.scoped" do
      skip "Execution::Next keeps no current path, so context.scoped cannot set" if ArmoryEngine.next?

      written = recorder_of(run(probe: lambda { |c|
        c.scoped.set!(:e, 5)
        c.scoped.merge!(f: 6)
      }))

      expect(written.forbidden_writes(%i[e f])).to eq(%i[e f])
    end

    it "does not count a read of a key this query wrote earlier as an input" do
      expect(uncovered(probe: ->(c) { (c[:tmp] = 1) && c[:tmp] })).to eq([])
      expect(uncovered(context: { tmp: 0 }, probe: ->(c) { c.delete(:tmp) && c.key?(:tmp) })).to eq([])
    end

    it "does not count a read answered by this query's own scoped_set! as an input" do
      context = run("{ parent { value } }", parent: ->(c) { c.scoped_set!(:locale, "fr") }, value: ->(c) { c[:locale] })

      expect(recorder_of(context).uncovered(machinery)).to eq([])
    end

    it "forbids a write to a key read earlier, and not one read only after its own write" do
      read_first = recorder_of(run(context: { locale: "en" }, probe: ->(c) { c[:locale] && (c[:locale] = "fr") }))
      written_first = recorder_of(run(probe: ->(c) { (c[:tmp] = 1) && c[:tmp] && (c[:tmp] = 2) }))

      expect(read_first.forbidden_writes([])).to eq([:locale])
      expect(written_first.forbidden_writes([])).to eq([])
    end

    it "forbids a write to a covered key" do
      expect(recorder_of(run(probe: ->(c) { c[:locale] = "fr" })).forbidden_writes([:locale])).to eq([:locale])
    end

    it "records nothing a neutral block reads, and again after it" do
      context = run(context: { request_id: "r1", locale: "en" }, probe: lambda { |c|
        caching.neutral(c) { c[:request_id] }
        c[:locale]
      })

      expect(recorder_of(context).uncovered(machinery)).to eq([:locale])
    end

    it "answers the dataloader in the context, or a fresh one each time, before the multiplex is bound" do
      schema = build_schema
      provided = schema.dataloader_class.new
      with_one = GraphQL::Query.new(schema, "{ probe }", context: { dataloader: provided }).context
      without = GraphQL::Query.new(schema, "{ probe }").context

      expect(with_one.dataloader).to be(provided)
      expect(without.dataloader).to be_a(schema.dataloader_class)
      expect(without.dataloader).not_to be(without.dataloader)
      expect(recorder_of(with_one).uncovered([])).not_to include(:dataloader)
    end

    it "answers the multiplex's dataloader once the multiplex is bound" do
      seen = []
      context = run(probe: ->(c) { seen << c.dataloader << c.dataloader })

      expect(seen.uniq.size).to eq(1)
      expect(seen.first).to be(context.query.multiplex.dataloader)
    end

    it "records through an app context class once it is wrapped" do
      app = Class.new(GraphQL::Query::Context) do
        def locale = self[:locale]
      end
      context = run(schema: build_schema(context_class: app), context: { locale: "en" }, probe: ->(c) { c.locale })

      expect(context).to be_a(app)
      expect(recorder_of(context).uncovered(machinery)).to eq([:locale])
    end
  end

  describe "Recorder::Context.wrap" do
    it "answers the same wrapper for a class, from several threads at once" do
      klass = Class.new(GraphQL::Query::Context)
      wrappers = Array.new(8) { Thread.new { caching::Recorder::Context.wrap(klass) } }.map(&:value)

      expect(wrappers.uniq.size).to eq(1)
      expect(caching::Recorder::Context.wrap(wrappers.first)).to be(wrappers.first)
    end

    it "wraps again a subclass of a wrapper, so its own overrides are recorded too" do
      wrapper = caching::Recorder::Context.wrap(Class.new(GraphQL::Query::Context))
      sub = Class.new(wrapper) do
        def [](key) = key == :alias ? super(:locale) : super
      end

      rewrapped = caching::Recorder::Context.wrap(sub)
      context = run(schema: build_schema(context_class: sub), context: { locale: "en" }, probe: ->(c) { c[:alias] })

      expect(rewrapped).not_to be(sub)
      expect(rewrapped.superclass).to be(sub)
      expect(recorder_of(context).uncovered(machinery)).to eq(%i[alias locale])
    end

    it "refuses a class that is not a GraphQL::Query::Context" do
      expect { caching::Recorder::Context.wrap(Class.new) }.to raise_error(ArgumentError)
    end
  end

  describe "Recorder::Log" do
    let(:log) { caching::Recorder::Log.new }

    it "is useful at once: it records reads and writes with nothing shared" do
      log.read(:locale)
      log.write(:locale)

      expect(log.uncovered([])).to eq([:locale])
      expect(log.forbidden_writes([])).to eq([:locale])
    end

    it "answers :all first, then the uncovered keys in the order read" do
      log.read(:b)
      log.read(:a)
      log.read(:b)
      log.read_all

      expect(log.uncovered([])).to eq([all, :b, :a])
      expect(log.uncovered([:b])).to eq([all, :a])
    end

    it "keeps neutrality across nested blocks and ends it when a block raises" do
      expect do
        log.neutral do
          log.neutral { log.read(:inner) }
          log.read(:outer)
          raise ArgumentError
        end
      end.to raise_error(ArgumentError)
      log.read(:after)

      expect(log.uncovered([])).to eq([:after])
    end

    it "answers the block's value from neutral, nested or not, and through Caching.neutral" do
      expect(log.neutral { log.neutral { :key_for_alice } }).to eq(:key_for_alice)

      seen = nil
      run(context: { current_user: :alice }, probe: ->(c) { seen = caching.neutral(c) { c[:current_user] } })
      expect(seen).to eq(:alice)
    end

    it "does not make a key written inside a neutral block a key this query wrote" do
      log.neutral { log.write(:rate_limit_points) }
      log.read(:rate_limit_points)

      expect(log.uncovered([])).to eq([:rate_limit_points])
      expect(log.forbidden_writes([])).to eq([])
      expect(log.forbidden_writes([:rate_limit_points])).to eq([:rate_limit_points])
    end

    it "records nothing read through read_all inside a neutral block" do
      log.neutral { log.read_all }

      expect(log.uncovered([])).to eq([])
    end
  end

  describe "ContextMethods" do
    let(:methods) { caching::ContextMethods }

    def app_class
      Class.new(GraphQL::Query::Context) do
        def current_user = @provided_values[:current_user]
        def [](key) = super
        def tenant = nil

        private

        def helper = nil
      end
    end

    it "lists the public methods an app's context class adds, not graphql-ruby's or its overrides" do
      expect(methods.added(app_class)).to eq(%i[current_user tenant])
      expect(methods.added(GraphQL::Query::Context)).to eq([])
    end

    it "lists them through the wrapper too, and not the wrapper's own" do
      expect(methods.added(caching::Recorder::Context.wrap(app_class))).to eq(%i[current_user tenant])
    end

    it "answers the ones not declared" do
      expect(methods.undeclared(app_class, { tenant: "reads nothing" })).to eq([:current_user])
      expect(methods.undeclared(app_class, %w[current_user tenant])).to eq([])
      expect(methods.undeclared(app_class, nil)).to eq(%i[current_user tenant])
    end

    it "lists method_missing, public or private, and methods of included modules" do
      dynamic = Module.new { def plan = nil }
      klass = Class.new(GraphQL::Query::Context) do
        include dynamic

        private

        def method_missing(name, *) = name == :viewer ? self[:viewer] : super
        def respond_to_missing?(name, all = false) = name == :viewer || super
      end

      expect(methods.added(klass)).to eq(%i[method_missing plan])
    end

    it "refuses a class that is not a GraphQL::Query::Context" do
      expect { methods.added(Class.new) }.to raise_error(ArgumentError)
    end
  end
end
