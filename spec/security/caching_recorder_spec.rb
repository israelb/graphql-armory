# frozen_string_literal: true

require "spec_helper"
require "graphql/armory/caching/recorder/shared_writes"
require "graphql/armory/caching/recorder/log"
require "graphql/armory/caching/context_methods"

# The recorder is the cache's tripwire for context inputs (docs/response-caching.md, "Inputs you must declare"). Each
# example is a way an answer could depend on a context value the cache key does not hold, and shows the recorder
# reporting it, so the gate refuses to store that answer.
RSpec.describe "Caching: the context recorder sees what the answer read" do
  let(:caching) { GraphQL::Armory::Caching }
  let(:all) { caching::Recorder::ALL }

  def legacy = ArmoryEngine.supported? ? { resolve_legacy_instance_method: true } : {}

  def build_schema(context_class: GraphQL::Query::Context)
    options = legacy
    child = Class.new(GraphQL::Schema::Object) do
      graphql_name "Child"
      field :value, String, null: true, **options
      def value = object[:value]&.call(context)&.to_s
      def self.visible?(context) = super && !context[:hide_child]
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

  def multiplex(queries, schema: build_schema)
    options = queries.map { |context, root| { query: "{ probe }", context: context, root_value: root } }
    results = ArmoryEngine.next? ? schema.multiplex_next(options) : schema.multiplex(options)
    results.each { |result| expect(result.to_h["errors"]).to be_nil }
    results.map { |result| caching::RecordKeys.recorder(result.query.context) }
  end

  def recorder_of(context) = caching::RecordKeys.recorder(context)

  def machinery = recorder_of(run).uncovered([])

  describe "from the context's construction on" do
    it "records a read an app context class makes in its own initialize" do
      early = Class.new(GraphQL::Query::Context) do
        def initialize(...)
          super
          @tenant = self[:tenant]
        end
      end

      expect(recorder_of(run(schema: build_schema(context_class: early), context: { tenant: 1 })).uncovered(machinery)).to eq([:tenant])
    end

    it "records a read an app visible? makes during validation, before any resolver runs" do
      context = run("{ parent { value } }", context: { hide_child: false })

      expect(recorder_of(context).uncovered(machinery)).to include(:hide_child)
    end
  end

  describe "writes" do
    it "reports a write to a key the answer read before, so the stored answer would not match its key" do
      log = recorder_of(run(context: { locale: "en" }, probe: ->(c) { c[:locale] == "en" && (c[:locale] = "fr") }))

      expect(log.forbidden_writes(machinery)).to eq([:locale])
    end

    it "does not exempt a read of the provided value outside the subtree a scoped_set! covers" do
      read = nil
      context = run("{ parent { value } probe }", context: { locale: "en" },
                                                   parent: ->(c) { c.scoped_set!(:locale, "fr") },
                                                   probe: ->(c) { read = c[:locale] })

      # The Interpreter scopes the value to `parent`'s subtree, so `probe` reads the provided "en": an input.
      # Execution::Next keeps no path, so the scoped value is everywhere and `probe` reads the query's own "fr".
      expect(recorder_of(context).uncovered(machinery).include?(:locale)).to be(read == "en")
      expect(read).to eq("en") unless ArmoryEngine.next?
    end

    it "counts a resolver's read of a record a limiter wrote inside a neutral block as an input" do
      context = run(probe: lambda { |c|
        caching.neutral(c) { c[:rate_limit_points] = { remaining: c[:current_user] ? 9 : 99 } }
        c[:rate_limit_points][:remaining]
      })

      expect(recorder_of(context).uncovered(machinery)).to eq([:rate_limit_points])
    end

    it "keeps recording writes inside a neutral block" do
      log = recorder_of(run(probe: ->(c) { caching.neutral(c) { c[:current_user] = :someone_else } }))

      expect(log.forbidden_writes([:current_user])).to eq([:current_user])
    end
  end

  describe "queries of one multiplex built from one provided Hash" do
    it "shows a sibling's write of a key this query read in this query's forbidden writes" do
      shared = { locale: "en" }
      writer, reader = multiplex([[shared, { probe: ->(c) { c[:locale] = "fr" } }], [shared, { probe: ->(c) { c[:locale] } }]])

      expect(reader.forbidden_writes(machinery)).to eq([:locale])
      expect(writer.forbidden_writes(machinery)).to eq([])
    end

    it "shows a sibling's write of a key this query's key covers, even unread" do
      shared = { current_user: :alice }
      _writer, other = multiplex([[shared, { probe: ->(c) { c[:current_user] = :mallory } }], [shared, { probe: ->(_c) { "public" } }]])

      expect(other.forbidden_writes([*machinery, :current_user])).to eq([:current_user])
      expect(other.forbidden_writes(machinery)).to eq([])
    end

    it "shows a write the sibling made to a key it had read in every sibling's forbidden writes" do
      shared = { locale: "en" }
      writer, other = multiplex([[shared, { probe: ->(c) { c[:locale] && (c[:locale] = "fr") } }], [shared, { probe: ->(_c) { "x" } }]])

      expect(writer.forbidden_writes(machinery)).to eq([:locale])
      expect(other.forbidden_writes(machinery)).to eq([:locale])
    end

    it "shows a sibling's read of the whole Hash as :all in this query's uncovered reads" do
      shared = {}
      exposer, other = multiplex([[shared, { probe: ->(c) { c.namespace(nil)[:locale] = "fr" } }], [shared, { probe: ->(_c) { "x" } }]])

      expect(exposer.uncovered(machinery)).to eq([all])
      expect(other.uncovered(machinery)).to eq([all])
    end

    it "keeps queries apart when their Hashes are equal but not the same object" do
      _writer, reader = multiplex([[{ locale: "en" }, { probe: ->(c) { c[:locale] = "fr" } }], [{ locale: "en" }, { probe: ->(c) { c[:locale] } }]])

      expect(reader.forbidden_writes(machinery)).to eq([])
      expect(reader.uncovered(machinery)).to eq([:locale])
    end
  end

  describe "neutral readers" do
    it "do not hide reads another fiber makes while their block runs" do
      log = caching::Recorder::Log.new
      log.neutral { Fiber.new { log.read(:locale) }.resume }

      expect(log.uncovered([])).to eq([:locale])
    end
  end

  describe "app context classes" do
    let(:app) do
      Class.new(GraphQL::Query::Context) do
        def current_user = @provided_values[:current_user]
      end
    end

    it "reads through an accessor that bypasses the recorded methods, which is why the accessor must be declared" do
      context = run(schema: build_schema(context_class: app), context: { current_user: :alice }, probe: ->(c) { c.current_user })

      expect(recorder_of(context).uncovered(machinery)).to eq([])
      expect(caching::ContextMethods.undeclared(app, {})).to eq([:current_user])
      expect(caching::ContextMethods.undeclared(app, { current_user: "the viewer: covered by viewer:" })).to eq([])
    end
  end
end
