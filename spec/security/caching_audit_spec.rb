# frozen_string_literal: true

require "rake"
require "graphql/armory/caching/audit"
require "graphql/armory/caching/rspec"

# The cache audit reads the schema's classes, never runs a query, and says where a declaration would serve one viewer's
# answer to another, or where a check it cannot read stands on the path of a shared answer.
RSpec.describe GraphQL::Armory::Caching::Audit do
  let(:caching) { GraphQL::Armory::Caching }
  let(:controls) { caching::Controls }
  let(:old) { "2024-06-01" }
  let(:new) { "2025-01-01" }

  # What `use GraphQL::Armory::Caching` installs, as the audit reads it: a stand-in with the same attributes.
  def configuration(**overrides)
    values = { viewer: :current_user, anonymous: :uncacheable, anonymous_reason: nil, neutral_keys: {}, context_methods: {},
               max_ttl: 3600, max_viewer_ttl: 300 }.merge(overrides)
    Struct.new(*values.keys, keyword_init: true).new(**values)
  end

  def audit(schema, configuration: self.configuration, **options)
    described_class.new(configuration: configuration, **options).(schema)
  end

  def found(report, kind = nil)
    report.problems.select { |problem| kind.nil? || problem.kind == kind }.map { |problem| [problem.kind, problem.path] }
  end

  def bases
    auth = GraphQL::Armory::Authorization::Base
    cache = caching::Base
    argument = Class.new(GraphQL::Schema::Argument) { include auth }
    field = Class.new(GraphQL::Schema::Field) do
      include auth
      include cache
      argument_class(argument)
    end
    object = Class.new(GraphQL::Schema::Object) do
      include auth
      include cache
      field_class(field)
      default_action :read
    end
    interface = Module.new do
      include GraphQL::Schema::Interface
      include cache
      field_class(field)
    end
    { argument: argument, field: field, object: object, interface: interface }
  end

  def public_type(base, name, &block)
    Class.new(base) do
      graphql_name name
      authorize :none, reason: "public test data", covers_fields: true
      cache_fields ttl: 60, scope: :public, reason: "the same for everyone"
      class_eval(&block) if block
    end
  end

  def query_over(base, &block)
    Class.new(base) do
      graphql_name "Query"
      authorize :none, reason: "root type"
      cache_fields ttl: 60, scope: :public, reason: "root fields: their types decide"
      class_eval(&block)
    end
  end

  def schema_of(query, mutation: nil, subscription: nil, orphans: [], directives: [], persisted: true)
    adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: true)
    manifest = controls::Operations.manifest
    Class.new(GraphQL::Schema) do
      query(query)
      mutation(mutation) if mutation
      subscription(subscription) if subscription
      orphan_types(*orphans) unless orphans.empty?
      directives(*directives) unless directives.empty?
      use GraphQL::Armory::Authorization, adapter: adapter
      use GraphQL::Armory::PersistedQueries, store: manifest, strict: true if persisted
    end
  end

  describe "Controls::Schema" do
    it "reports nothing once caching is installed, and lists every public declaration with its reason" do
      report = audit(controls::Schema.example)

      expect(report.problems).to eq([])
      expect(report).to be_ok
      expect(report.declarations.map { |declared| [declared.kind, declared.path, declared.reason] }).to eq(
        [[:public, "Money", "prices are the same for every viewer and tenant"],
         [:public, "Product", "the catalog is the same for every viewer and tenant"],
         [:public, "Product.price", "the catalog is the same for every viewer and tenant"],
         [:public, "Query", "root fields: the types they return decide"]]
      )
    end

    it "reports only :plugin when the schema never installed caching, which it truly lacks" do
      report = described_class.(controls::Schema.example)

      expect(found(report)).to eq([[:plugin, "Schema"]])
      expect(report.problems.first.message).to include("use GraphQL::Armory::Caching")
    end
  end

  describe "installing" do
    it "reads the configuration the schema installed, through armory_caching" do
      schema = controls::Schema.example
      installed = configuration(viewer: nil)
      schema.define_singleton_method(:armory_caching) { installed }

      expect(found(described_class.(schema), :viewer_unconfigured)).to eq([[:viewer_unconfigured, "Invoice"], [:viewer_unconfigured, "Query.invoices"]])
      expect(found(described_class.(schema), :plugin)).to eq([])
    end

    it "is inert with no configuration: it says caching is not installed" do
      expect(found(described_class.new.(controls::Schema.example))).to eq([[:plugin, "Schema"]])
    end

    it "reports :plugin when caching is installed without PersistedQueries" do
      b = bases
      product = public_type(b[:object], "Product") { field :name, String }
      schema = schema_of(query_over(b[:object]) { field :products, [product] }, persisted: false)

      report = audit(schema)
      expect(found(report)).to eq([[:plugin, "Schema"]])
      expect(report.problems.first.message).to include("PersistedQueries")
    end

    it "says nothing of a schema that uses no part of caching" do
      query = Class.new(GraphQL::Schema::Object) do
        graphql_name "Query"
        field :ping, String
      end
      schema = Class.new(GraphQL::Schema) { query(query) }

      expect(described_class.(schema)).to be_ok
    end
  end

  describe ":public_over_rule" do
    it "reports a public declaration whose type has a rule, and the list that returns it" do
      b = bases
      invoice = Class.new(b[:object]) do
        graphql_name "Invoice"
        authorize :read
        cache_fields ttl: 60, scope: :public, reason: "wrongly public"
        field :number, String
      end
      schema = schema_of(query_over(b[:object]) { field :invoices, [invoice] })

      report = audit(schema)
      expect(found(report)).to eq([[:public_over_rule, "Invoice.number"], [:public_over_rule, "Query.invoices"]])
      expect(report.problems.map(&:message)).to all(include("Invoice"))
    end

    it "reports a field rule, observe:, visible_when:, an argument rule, loads: and find_by: under a public declaration" do
      b = bases
      product = public_type(b[:object], "Product") do
        field :name, String
        field :cost, Integer, authorize: :manage
        field :margin, Integer, authorize: :manage, observe: "rollout"
        field :notes, String, authorize: :none, reason: "public", visible_when: :export
        field :sku, String do
          argument :internal, GraphQL::Types::Boolean, required: false, authorize: :manage
        end
      end
      query = query_over(b[:object]) do
        field :products, [product]
        field :product, product do
          argument :product_id, GraphQL::Types::ID, loads: product
        end
        field :product_by, product, find_by: :id do
          argument :id, GraphQL::Types::ID
        end
      end

      report = audit(schema_of(query))
      expect(found(report)).to eq(
        [[:public_over_rule, "Product.cost"], [:public_over_rule, "Product.margin"], [:public_over_rule, "Product.notes"],
         [:public_over_rule, "Product.sku"], [:public_over_rule, "Query.product"], [:public_over_rule, "Query.productBy"]]
      )
      messages = report.problems.to_h { |problem| [problem.path, problem.message] }
      expect(messages).to include("Product.margin" => include("observe:"), "Product.notes" => include("visible_when:"),
                                  "Product.sku" => include("argument internal"), "Query.product" => include("loads:"),
                                  "Query.productBy" => include("find_by:"))
    end

    it "reports a type rule's visible_when: on a bypassed type" do
      b = bases
      product = Class.new(b[:object]) do
        graphql_name "Product"
        authorize :none, reason: "public", covers_fields: true, visible_when: :browse
        cache_fields ttl: 60, scope: :public, reason: "the same for everyone"
        field :name, String
      end
      report = audit(schema_of(query_over(b[:object]) { field :products, [product] }))

      expect(found(report)).to include([:public_over_rule, "Product.name"], [:public_over_rule, "Query.products"])
    end

    it "follows an interface to its possible types, orphans included, and a connection to its nodes" do
      b = bases
      node = Module.new do
        include GraphQL::Schema::Interface
        include GraphQL::Armory::Caching::Base
        graphql_name "Node"
        field :name, String
      end
      node.field_class(b[:field])
      product = public_type(b[:object], "Product") { implements node }
      invoice = Class.new(b[:object]) do
        graphql_name "Invoice"
        implements node
        authorize :read
        cache_fields ttl: 30
      end
      query = query_over(b[:object]) do
        field :node, node
        field :products, product.connection_type
        field :invoices, invoice.connection_type, cache: { ttl: 30, scope: :viewer }
        field :catalog, product.connection_type
      end
      report = audit(schema_of(query, orphans: [invoice, product]))

      expect(found(report)).to eq([[:public_over_rule, "Query.node"]])
      expect(report.problems.first.message).to include("Invoice")
    end

    it "reports a connection whose node has a rule" do
      b = bases
      invoice = Class.new(b[:object]) do
        graphql_name "Invoice"
        authorize :read
        cache_fields ttl: 30
        field :number, String
      end
      report = audit(schema_of(query_over(b[:object]) { field :invoices, invoice.connection_type }))

      expect(found(report)).to eq([[:public_over_rule, "Query.invoices"]])
    end

    it "reports a field of a version the latest one no longer serves" do
      versioning = GraphQL::Armory::Versioning
      mods = [versioning::Base, GraphQL::Armory::Authorization::Base, caching::Base]
      field_class = Class.new(GraphQL::Schema::Field) { mods.each { |mod| include mod } }
      object = Class.new(GraphQL::Schema::Object) do
        mods.each { |mod| include mod }
        field_class(field_class)
      end
      product = public_type(object, "Product") do
        field :name, String
        field :cost, Integer, authorize: :manage, removed: "2025-01-01"
      end
      query = query_over(object) { field :products, [product] }
      labels = [old, new]
      adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: true)
      manifest = controls::Operations.manifest
      schema = Class.new(GraphQL::Schema) do
        query(query)
        use GraphQL::Schema::Visibility
        use versioning, versions: labels, default: :latest
        use GraphQL::Armory::Authorization, adapter: adapter
        use GraphQL::Armory::PersistedQueries, store: manifest, strict: true
      end

      expect(found(audit(schema))).to eq([[:public_over_rule, "Product.cost"]])
    end
  end

  describe ":own_check" do
    def schema_with_checks
      b = bases
      product = public_type(b[:object], "Product") do
        field :name, String
        def self.authorized?(object, context)
          super
        end

        def self.scope_items(items, context)
          super
        end
      end
      invoice = Class.new(b[:object]) do
        graphql_name "Invoice"
        authorize :read
        cache_fields ttl: 30
        field :number, String
        def self.authorized?(object, context)
          super
        end
      end
      query = query_over(b[:object]) do
        field :products, [product]
        field :invoices, [invoice], cache: { ttl: 30, scope: :viewer }
      end
      [schema_of(query), product, invoice]
    end

    it "reports the app's own check on a class a public declaration reaches, never on one only viewer answers reach" do
      schema, = schema_with_checks

      report = audit(schema)
      expect(found(report)).to eq([[:own_check, "Product.authorized?"], [:own_check, "Product.scope_items"]])
      expect(report.problems.first.location).to include("caching_audit_spec.rb")
    end

    it "lists one declared in own_checks: with its reason, and reports a declaration that names nothing" do
      schema, product, invoice = schema_with_checks

      report = audit(schema, own_checks: { product => { authorized?: "reads only the record's class", scope_items: "orders by name" },
                                           invoice => { wrap: "no such check" } })
      expect(found(report)).to eq([[:own_check, "Invoice wrap"]])
      expect(report.declarations.select { |declared| declared.kind == :own_check }.map { |declared| [declared.path, declared.reason] })
        .to eq([["Product.authorized?", "reads only the record's class"], ["Product.scope_items", "orders by name"]])
    end

    it "refuses own_checks: that do not map a class to check names and reasons" do
      expect { described_class.new(own_checks: { "Product" => { authorized?: "x" } }) }.to raise_error(ArgumentError, /own_checks/)
      expect { described_class.new(own_checks: { Object => { resolve: "x" } }) }.to raise_error(ArgumentError, /own_checks/)
      expect { described_class.new(own_checks: { Object => { wrap: " " } }) }.to raise_error(ArgumentError, /own_checks/)
    end
  end

  describe ":context_class" do
    def schema_with_context(context)
      schema = controls::Schema.example
      schema.context_class(context)
      schema
    end

    it "reports an override of a recorded method that does not call super, and a public method nobody declared" do
      context = Class.new(GraphQL::Query::Context) do
        def [](key)
          @provided_values[key]
        end

        def fetch(key, *rest)
          super
        end

        def tenant
          self[:tenant]
        end
      end

      report = audit(schema_with_context(context))
      expect(found(report).map(&:first)).to eq(%i[context_class context_class])
      expect(report.problems.map(&:path)).to contain_exactly(end_with("#[]"), end_with("#tenant"))
    end

    it "lists a public method declared in context_methods: with its reason, and reports one declared that does not exist" do
      context = Class.new(GraphQL::Query::Context) do
        def tenant
          self[:tenant]
        end
      end

      report = audit(schema_with_context(context), configuration: configuration(context_methods: { tenant: "reads through []", region: "gone" }))
      expect(found(report)).to eq([[:context_class, "context_methods: :region"]])
      expect(report.declarations.select { |declared| declared.kind == :context_method }.map { |declared| [declared.path, declared.reason] })
        .to eq([["context_methods: :tenant", "reads through []"]])
    end
  end

  describe ":viewer_unconfigured" do
    it "reports each viewer declaration when viewer: is not set" do
      report = audit(controls::Schema.example, configuration: configuration(viewer: nil))

      expect(found(report)).to eq([[:viewer_unconfigured, "Invoice"], [:viewer_unconfigured, "Query.invoices"]])
    end
  end

  describe ":ttl" do
    it "reports a TTL above max_ttl:, and a viewer TTL above max_viewer_ttl:" do
      report = audit(controls::Schema.example, configuration: configuration(max_ttl: 100, max_viewer_ttl: 10))

      expect(found(report)).to eq([[:ttl, "Invoice"], [:ttl, "Product"], [:ttl, "Query"], [:ttl, "Query.invoices"]])
      expect(report.problems.find { |problem| problem.path == "Invoice" }.message).to include("max_viewer_ttl: 10")
    end
  end

  describe ":ignored" do
    it "reports declarations on a mutation and a subscription field, which are never used" do
      b = bases
      product = public_type(b[:object], "Product") { field :name, String }
      mutation = Class.new(b[:object]) do
        graphql_name "Mutation"
        authorize :none, reason: "test"
        cache_fields ttl: 60
        field :touch, GraphQL::Types::Boolean, cache: false
      end
      subscription = Class.new(b[:object]) do
        graphql_name "Subscription"
        authorize :none, reason: "test"
        field :ticked, GraphQL::Types::Boolean, cache: { ttl: 5 }
      end
      schema = schema_of(query_over(b[:object]) { field :products, [product] }, mutation: mutation, subscription: subscription)

      expect(found(audit(schema))).to eq([[:ignored, "Mutation"], [:ignored, "Mutation.touch"], [:ignored, "Subscription.ticked"]])
    end
  end

  describe ":incomplete" do
    it "reports a field's declaration its type cannot complete" do
      b = bases
      product = Class.new(b[:object]) do
        graphql_name "Product"
        authorize :none, reason: "public", covers_fields: true
        field :name, String, cache: { tags: ["catalog"] }
      end
      report = audit(schema_of(query_over(b[:object]) { field :products, [product] }))

      expect(found(report)).to eq([[:incomplete, "Product.name"]])
      expect(report.problems.first.message).to include("ttl:")
    end
  end

  describe ":directive" do
    def directive(name, safe: nil)
      Class.new(GraphQL::Schema::Directive) do
        include GraphQL::Armory::Caching::Base
        graphql_name name
        locations GraphQL::Schema::Directive::FIELD
        cache_safe reason: safe if safe
      end
    end

    it "is information about an executable directive without cache_safe, failing ok? only when strict, and lists the safe ones" do
      b = bases
      product = public_type(b[:object], "Product") { field :name, String }
      schema = schema_of(query_over(b[:object]) { field :products, [product] },
                         directives: [directive("upper"), directive("hint", safe: "a client hint, data unchanged")])

      report = audit(schema)
      expect(found(report)).to eq([[:directive, "@upper"]])
      expect(report.problems.first).to be_information
      expect(report).to be_ok
      expect(report.to_s).to include("Information:")
      expect(audit(schema, strict: true)).not_to be_ok
      expect(report.declarations.select { |declared| declared.kind == :cache_safe }.map { |declared| [declared.path, declared.reason] })
        .to eq([["@hint", "a client hint, data unchanged"]])
    end
  end

  describe "declarations of the installed configuration" do
    it "lists anonymous: :shared, each neutral_keys: and each context_methods: entry with its reason" do
      installed = configuration(anonymous: :shared, anonymous_reason: "a public storefront",
                                neutral_keys: { request_id: "logging only" })
      report = audit(controls::Schema.example, configuration: installed)

      listed = report.declarations.reject { |declared| declared.kind == :public }.map { |declared| [declared.kind, declared.path, declared.reason] }
      expect(listed).to eq([[:anonymous, "anonymous: :shared", "a public storefront"], [:neutral_key, "neutral_keys: :request_id", "logging only"]])
      expect(report.declarations).to all(have_attributes(reason: be_a(String)))
      expect(report.to_s).to include("neutral_keys: :request_id (neutral_key): logging only")
    end
  end

  describe "the rake task and the matcher" do
    let(:application) { Rake::Application.new }

    before do
      query = Class.new(GraphQL::Schema::Object) do
        graphql_name "Query"
        field :ping, String
      end
      Object.const_set(:CacheCleanSchema, Class.new(GraphQL::Schema) { query(query) })
      Object.const_set(:CacheFlawedSchema, controls::Schema.example)
    end

    after do
      Object.send(:remove_const, :CacheCleanSchema)
      Object.send(:remove_const, :CacheFlawedSchema)
      Rake.application = Rake::Application.new
    end

    def run(name)
      out = StringIO.new
      [described_class::Command.new(out: out).(name), out.string]
    end

    it "answers 0 for a clean schema and 1 for problems, a missing schema or none named" do
      expect(run("CacheCleanSchema")).to eq([0, "No problems.\n"])
      status, text = run("CacheFlawedSchema")
      expect([status, text]).to match([1, include("Schema (plugin)")])
      expect(run("NoSuchCacheSchema")).to eq([1, "No schema named NoSuchCacheSchema\n"])
      expect(run(nil)).to eq([1, "Name the schema: rake \"graphql_armory:cache:audit[YourSchema]\"\n"])
    end

    it "is graphql_armory:cache:audit and exits 1 on problems" do
      Rake.application = application
      load File.expand_path("../../lib/tasks/graphql_armory.rake", __dir__)
      task = application["graphql_armory:cache:audit"]

      expect { task.invoke("CacheCleanSchema") }.to output(/\ANo problems/).to_stdout
      task.reenable
      expect { expect { task.invoke("CacheFlawedSchema") }.to output(/plugin/).to_stdout }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end

    it "matches have_safe_cache_declarations on what the audit says" do
      expect(CacheCleanSchema).to have_safe_cache_declarations
      expect(CacheFlawedSchema).not_to have_safe_cache_declarations
    end
  end
end
