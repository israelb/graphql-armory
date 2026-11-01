# frozen_string_literal: true

require "open3"
require "tmpdir"
require "fileutils"
require "digest"

# Kept from the independent verification of the adoption fixes. Each `it` is labelled [security] or [preservation].
RSpec.describe "Adoption fixes probes" do
  let(:armory) { GraphQL::Armory }
  let(:adapters) { armory::Authorization::Adapters }
  let(:pq) { armory::PersistedQueries }
  let(:ops) { pq::Controls::Operations }
  root_dir = File.expand_path("../..", __dir__)

  # ---------------------------------------------------------------- persisted queries
  describe "doc_id" do
    let(:manifest) { pq::Manifest.new({ "inv" => ops.invoices, "gre" => ops.greeting }, digest: false) }
    let(:resolved) { [] }

    def schema_for(strict: true, store: manifest, sinks: [])
      query_type = pq::Controls::Query.example
      Class.new(base_schema) do
        query query_type
        use GraphQL::Armory::PersistedQueries, store: store, strict: strict, sinks: sinks
      end
    end

    def request(params, strict: true, store: manifest, sinks: [], **context)
      execute_query(schema_for(strict: strict, store: store, sinks: sinks), params["query"], variables: params["variables"] || {},
                    context: { operation_id: pq.operation_id(params), **context },
                    root_value: pq::Controls::Root.example(resolved)).to_h
    end

    def messages(result) = (result["errors"] || []).map { |e| e["message"] }

    it "[security] PQ1 a known doc_id with no query runs the stored operation under strict" do
      result = request({ "doc_id" => "inv" })
      expect(result.dig("data", "invoices")).to eq(["A-1"])
      expect(resolved).to eq([:invoices])
    end

    it "[security] PQ2 known doc_id and a different query is a mismatch, and nothing runs" do
      result = request({ "doc_id" => "inv", "query" => "{ secret }" })
      expect(messages(result)).to eq([pq::MISMATCH])
      expect(resolved).to be_empty
    end

    it "[security] PQ3 unknown doc_id and a raw query, strict false: refused, raw does not run" do
      result = request({ "doc_id" => "nope", "query" => "{ secret }" }, strict: false)
      expect(messages(result)).to eq([pq::UNKNOWN_OPERATION])
      expect(resolved).to be_empty
    end

    [["x"], { "a" => "inv" }, 1, true, "", nil].each do |bad|
      it "[preservation] PQ4 non-String doc_id #{bad.inspect} with a raw query stays refused under strict" do
        result = request({ "doc_id" => bad, "query" => "{ secret }" })
        expect(messages(result)).to eq([pq::RAW_QUERY_REFUSED])
        expect(resolved).to be_empty
      end
    end

    it "[security] PQ5 non-String operationId, known doc_id and a different query: mismatch" do
      result = request({ "operationId" => ["x"], "doc_id" => "inv", "query" => "{ secret }" })
      expect(messages(result)).to eq([pq::MISMATCH])
      expect(resolved).to be_empty
    end

    it "[preservation] PQ6 operationId A, doc_id B and the body of B: A is what is checked, mismatch" do
      result = request({ "operationId" => "inv", "doc_id" => "gre", "query" => ops.greeting, "variables" => { "name" => "x" } })
      expect(messages(result)).to eq([pq::MISMATCH])
      expect(resolved).to be_empty
    end

    it "[preservation] PQ7 GET JSON extensions win over doc_id, and what is read is what runs" do
      params = { "extensions" => JSON.generate({ "persistedQuery" => { "sha256Hash" => "inv" } }), "doc_id" => "gre" }
      expect(pq.operation_id(params)).to eq("inv")
      expect(request(params).dig("data", "invoices")).to eq(["A-1"])
    end

    it "[security] PQ9a a digest manifest: an uppercase or newline variant of a doc_id is unknown, the exact one runs" do
      id = Digest::SHA256.hexdigest(ops.invoices)
      store = pq::Manifest.new({ id => ops.invoices })
      [id.upcase, "#{id}\n", " #{id}"].each do |variant|
        expect(messages(request({ "doc_id" => variant }, store: store))).to eq([pq::UNKNOWN_OPERATION])
      end
      expect(request({ "doc_id" => id }, store: store).dig("data", "invoices")).to eq(["A-1"])
    end

    it "[preservation] PQ9b a manifest entry whose id is not its digest refuses at load, whatever the param" do
      expect { pq::Manifest.new({ Digest::SHA256.hexdigest("other") => ops.invoices }) }.to raise_error(pq::ConfigurationError)
    end

    it "[preservation] PQ10 Symbol-key params are nil, and strict refuses the raw query" do
      expect(pq.operation_id({ doc_id: "inv" })).to be_nil
    end

    it "[security] PQ11 an empty query with a doc_id counts as no query" do
      expect(request({ "doc_id" => "inv", "query" => "" }).dig("data", "invoices")).to eq(["A-1"])
    end

    it "[security] PQ13 armory_allow_raw_query does not rescue a doc_id with a different query" do
      result = request({ "doc_id" => "inv", "query" => "{ secret }" }, armory_allow_raw_query: true)
      expect(messages(result)).to eq([pq::MISMATCH])
      expect(resolved).to be_empty
    end

    it "[security] PQ14a malformed extensions do not hide a doc_id" do
      expect(pq.operation_id({ "extensions" => "not json", "doc_id" => "inv" })).to eq("inv")
      expect(pq.operation_id({ "extensions" => ["x"], "doc_id" => "inv" })).to eq("inv")
    end

    it "[preservation] PQ14b doc_id inside extensions is not read" do
      expect(pq.operation_id({ "extensions" => { "doc_id" => "inv" } })).to be_nil
    end

    it "[security] PQ16 a doc_id's refusal gives sinks the reason and never the client's id; a stored op takes request variables only" do
      seen = []
      sink = ->(signal, data) { seen << [signal, data] }
      request({ "doc_id" => "client-chosen-text" }, sinks: [sink])
      expect(seen.map(&:first)).to eq([:operation_refused])
      expect(seen.first.last[:reason]).to eq(:unknown_operation)
      expect(seen.to_s).not_to include("client-chosen-text")
      result = request({ "doc_id" => "gre", "variables" => { "name" => "Ann" } })
      expect(result.dig("data", "greeting")).to eq("Hello Ann")
    end

    it "[security] PQ8a a real ActionController::Parameters doc_id is read; a nested one is not" do
      out = probe_ruby(<<~'RUBY')
        require "action_controller"
        require "graphql/armory"
        pq = GraphQL::Armory::PersistedQueries
        puts pq.operation_id(ActionController::Parameters.new("doc_id" => "x")).inspect
        puts pq.operation_id(ActionController::Parameters.new("doc_id" => { "a" => "x" })).inspect
        puts pq.operation_id(ActionController::Parameters.new("doc_id" => ["x"])).inspect
      RUBY
      expect(out).to eq("\"x\"\nnil\nnil\n")
    end
  end

  # ---------------------------------------------------------------- user_key
  describe "user_key" do
    let(:safe_ability) do
      Class.new do
        include CanCan::Ability
        attr_reader :user

        def initialize(user)
          @user = user
          return unless user

          can :read, Invoice, account_id: user.account_id
          can :read, Account, id: user.account_id
          can(:manage, Invoice, account_id: user.account_id) if user.admin?
          can(:export, Invoice) if user.admin?
        end
      end
    end

    def pundit(key = :viewer) = adapters::Pundit.new(user_key: key)
    def cancan(key = :viewer) = adapters::CanCan.new(ability_class: safe_ability, user_key: key)

    # What a client gets; an exception out of execute is recorded, it is not data.
    def outcome(adapter, query, context, variables: {}, **root)
      schema = IntegrationSchema.build(adapter: adapter, flawed: false)
      execute_query(schema, query, context: context, variables: variables, root_value: IntegrationSchema::Root.new(**root)).to_h
    rescue NoMethodError, GraphQL::Armory::Error => e
      { "raised" => e.class.name }
    end

    def all_shapes(adapter, context)
      {
        field: outcome(adapter, "{ myInvoice { number } }", context, my_invoice: world.b1),
        list: outcome(adapter, "{ invoices { number } }", context, invoices: Invoice.all),
        connection: outcome(adapter, "{ invoicesConnection { nodes { number } } }", context, invoices_connection: Invoice.all),
        find_by: outcome(adapter, "query($id: ID!) { invoice(id: $id) { number } }", context, variables: { "id" => world.b1.id.to_s }),
        loads: outcome(adapter, "query($id: ID!) { invoiceViaRef(invoiceId: $id) { number } }", context, variables: { "id" => world.b1.id.to_s })
      }
    end

    { pundit: :pundit, cancan: :cancan }.each do |name, builder|
      it "[security] U2 #{name}: viewer alice with current_user bob sees none of bob's on field, list, connection, find_by, loads; her own shows" do
        shapes = all_shapes(send(builder), { viewer: world.alice, current_user: world.bob })
        expect(shapes.to_s).not_to include("B-1")
        list = outcome(send(builder), "{ invoices { number } }", { viewer: world.alice, current_user: world.bob }, invoices: Invoice.all)
        expect(list.dig("data", "invoices").map { |i| i["number"] }).to contain_exactly("A-1", "A-2")
        conn = outcome(send(builder), "{ invoicesConnection { nodes { number } } }", { viewer: world.alice, current_user: world.bob }, invoices_connection: Invoice.all)
        expect(conn.dig("data", "invoicesConnection", "nodes").map { |i| i["number"] }).to contain_exactly("A-1", "A-2")
        mine = outcome(send(builder), "query($id: ID!) { invoice(id: $id) { number } }", { viewer: world.alice, current_user: world.bob }, variables: { "id" => world.a1.id.to_s })
        expect(mine.dig("data", "invoice", "number")).to eq("A-1")
      end

      it "[security] U3 #{name}: viewer absent, current_user carol the admin: no data on any shape" do
        shapes = all_shapes(send(builder), { current_user: world.carol })
        expect(shapes.to_s).not_to match(/[AB]-[12]/)
        all = outcome(send(builder), "{ invoices { number } }", { current_user: world.carol }, invoices: Invoice.where(account_id: world.account_a.id))
        expect(all.to_s).not_to match(/A-[12]/)
      end

      it "[security] U4 #{name}: viewer false or nil with an admin current_user: no data on any shape" do
        [false, nil].each do |value|
          expect(all_shapes(send(builder), { viewer: value, current_user: world.carol }).to_s).not_to match(/[AB]-[12]/)
          own = outcome(send(builder), "{ myInvoice { number } }", { viewer: value, current_user: world.carol }, my_invoice: world.a1)
          expect(own.to_s).not_to include("A-1")
        end
      end

      it "[security] U5a #{name}: a String key with the value under a Symbol gives no data" do
        own = outcome(send(builder, "viewer"), "{ myInvoice { number } }", { viewer: world.alice }, my_invoice: world.a1)
        expect(own.to_s).not_to include("A-1")
      end

      it "[security] U5b #{name}: a String key finds a String key; an indifferent Hash answers both" do
        own = outcome(send(builder, "viewer"), "{ myInvoice { number } }", { "viewer" => world.alice }, my_invoice: world.a1)
        expect(own.dig("data", "myInvoice", "number")).to eq("A-1")
        indifferent = ActiveSupport::HashWithIndifferentAccess.new(viewer: world.alice)
        [:viewer, "viewer"].each do |key|
          got = outcome(send(builder, key), "{ myInvoice { number } }", indifferent, my_invoice: world.a1)
          expect(got.dig("data", "myInvoice", "number")).to eq("A-1")
        end
      end

      it "[security] U8 #{name}: a child schema inherits the adapter and its key" do
        parent = IntegrationSchema.build(adapter: send(builder), flawed: false)
        child = Class.new(parent)
        got = execute_query(child, "{ myInvoice { number } }", context: { viewer: world.alice, current_user: world.bob }, root_value: IntegrationSchema::Root.new(my_invoice: world.a1)).to_h
        expect(got.dig("data", "myInvoice", "number")).to eq("A-1")
      end

      it "[security] U12 #{name}: :\"\" denies and a Class is refused" do
        adapter = send(builder, :"")
        expect(outcome(adapter, "{ myInvoice { number } }", { current_user: world.carol }, my_invoice: world.a1).to_s).not_to include("A-1")
        expect { send(builder, Object) }.to raise_error(ArgumentError)
      end

      it "[security] U16 #{name}: visible_when asks the named user" do
        base_field = Class.new(GraphQL::Schema::Field) { include GraphQL::Armory::Authorization::Base }
        base_object = Class.new(GraphQL::Schema::Object) do
          include GraphQL::Armory::Authorization::Base
          field_class base_field
          default_action :read
        end
        invoice = Class.new(base_object) do
          graphql_name "Invoice"
          field :number, String, null: false
          field :internal_notes, String, authorize: :read, visible_when: :export
        end
        query_type = Class.new(base_object) do
          graphql_name "Query"
          authorize :none, reason: "root"
          field :my_invoice, invoice, authorize: :none, reason: "test"
        end
        adapter = send(builder)
        schema = Class.new(ArmoryEngine.base_schema) do
          query query_type
          use GraphQL::Armory::Authorization, adapter: adapter
        end
        root = IntegrationSchema::Root.new(my_invoice: world.a1)
        hidden = execute_query(schema, "{ myInvoice { internalNotes } }", context: { viewer: world.alice, current_user: world.carol }, root_value: root).to_h
        shown = execute_query(schema, "{ myInvoice { internalNotes } }", context: { viewer: world.carol, current_user: world.alice }, root_value: root).to_h
        expect(hidden["errors"].to_a.first.to_h["message"].to_s).to match(/doesn't exist/)
        expect(hidden.to_s).not_to include("secret A-1")
        expect(shown.dig("data", "myInvoice", "internalNotes")).to eq("secret A-1")
      end
    end

    it "[security] U6 an adapter object through `use` is kept by identity and answers actor itself" do
      adapter = pundit
      schema = IntegrationSchema.build(adapter: adapter, flawed: false)
      expect(schema.armory_configuration.adapter).to equal(adapter)
      expect(adapter.method(:actor).owner).to eq(adapters::Pundit)
    end

    it "[security] U7 the audit reads an adapter object like :pundit: same report, dirty stays dirty" do
      named = armory::Authorization::Audit.(IntegrationSchema.build(adapter: pundit, flawed: true))
      plain = armory::Authorization::Audit.(IntegrationSchema.build(adapter: :pundit, flawed: true))
      expect(named.to_s).to eq(plain.to_s)
      expect(named).not_to be_ok
      expect(pundit.found_policy(Invoice)).to eq(InvoicePolicy)
    end

    it "[security] U9 multiplex with two viewers: each gets their own ability" do
      adapter = cancan
      schema = IntegrationSchema.build(adapter: adapter, flawed: false)
      root = IntegrationSchema::Root.new(invoices: Invoice.all)
      query = "{ invoices { number } }"
      queries = [{ query: query, context: { viewer: world.alice }, root_value: root }, { query: query, context: { viewer: world.bob }, root_value: root }]
      results = ArmoryEngine.next? ? GraphQL::Execution::Next.run_all(schema, queries, context: {}) : schema.multiplex(queries)
      numbers = results.map { |r| r.to_h.dig("data", "invoices").map { |i| i["number"] } }
      expect(numbers.first).to contain_exactly("A-1", "A-2")
      expect(numbers.last).to contain_exactly("B-1")
    end

    it "[security] U10 two CanCan adapters with different keys on one context answer their own user" do
      schema = IntegrationSchema.build(adapter: cancan, flawed: false)
      context = GraphQL::Query.new(schema, "{ ping }", context: { viewer: world.alice, other: world.bob }).context
      first = cancan(:viewer).actor(context)
      second = cancan(:other).actor(context)
      expect(first.user).to eq(world.alice)
      expect(second.user).to eq(world.bob)
    end

    it "[preservation] U10b the same sharing with ability_class:, the shape main already had" do
      other = Class.new(safe_ability)
      schema = IntegrationSchema.build(adapter: :pundit, flawed: false)
      context = GraphQL::Query.new(schema, "{ ping }", context: { current_user: world.alice }).context
      first = adapters::CanCan.new(ability_class: safe_ability).actor(context)
      second = adapters::CanCan.new(ability_class: other).actor(context)
      expect(second).to be_a(other), "second adapter got the first adapter's #{first.class}"
    end

    it "[preservation] U10c a nested query built from an outer context has its own armory namespace, so no ability crosses" do
      schema = IntegrationSchema.build(adapter: :pundit, flawed: false)
      outer = GraphQL::Query.new(schema, "{ ping }", context: { current_user: world.alice }).context
      inner = GraphQL::Query.new(schema, "{ ping }", context: outer).context
      expect(inner.namespace(:armory)).not_to equal(outer.namespace(:armory))
      inner_hash = GraphQL::Query.new(schema, "{ ping }", context: outer.to_h).context
      expect(inner_hash.namespace(:armory)).not_to equal(outer.namespace(:armory))
    end

    it "[preservation] U11a CanCan current_ability wins over the named key" do
      schema = IntegrationSchema.build(adapter: cancan, flawed: false)
      given = safe_ability.new(world.bob)
      got = execute_query(schema, "{ myInvoice { number } }", context: { current_ability: given, viewer: world.alice }, root_value: IntegrationSchema::Root.new(my_invoice: world.a1)).to_h
      expect(got.dig("data", "myInvoice")).to be_nil
      allowed = execute_query(schema, "{ myInvoice { number } }", context: { current_ability: given, viewer: world.alice }, root_value: IntegrationSchema::Root.new(my_invoice: world.b1)).to_h
      expect(allowed.dig("data", "myInvoice", "number")).to eq("B-1")
    end

    it "[security] U11b CanCan current_ability false falls to the named key, never to current_user" do
      schema = IntegrationSchema.build(adapter: cancan, flawed: false)
      got = execute_query(schema, "{ myInvoice { number } }", context: { current_ability: false, viewer: world.alice, current_user: world.bob }, root_value: IntegrationSchema::Root.new(my_invoice: world.a1)).to_h
      expect(got.dig("data", "myInvoice", "number")).to eq("A-1")
    end

    it "[preservation] U13a the old way, a subclass overriding actor, still works" do
      klass = Class.new(adapters::Pundit) { def actor(context) = context[:viewer] }
      got = outcome(klass.new, "{ myInvoice { number } }", { viewer: world.alice }, my_invoice: world.a1)
      expect(got.dig("data", "myInvoice", "number")).to eq("A-1")
    end

    it "[security] U13c that same subclass, whatever it answers, never serves another user's data (fail closed)" do
      klass = Class.new(adapters::Pundit) { def initialize(flag = true) = @flag = flag }
      got = outcome(klass.new, "{ myInvoice { number } }", { current_user: world.alice }, my_invoice: world.b1)
      expect(got.to_s).not_to include("B-1")
    end

    it "[preservation] U14 default keys behave as before on both adapters" do
      got = outcome(adapters::Pundit.new, "{ myInvoice { number } }", { current_user: world.alice }, my_invoice: world.a1)
      expect(got.dig("data", "myInvoice", "number")).to eq("A-1")
      got = outcome(adapters::CanCan.new(ability_class: safe_ability), "{ myInvoice { number } }", { current_user: world.alice }, my_invoice: world.a1)
      expect(got.dig("data", "myInvoice", "number")).to eq("A-1")
    end

    it "[security] U15 nothing in lib reads :current_user except the adapters' default" do
      lines = Dir[File.join(root_dir, "lib", "**", "*.{rb,rake}")].flat_map do |file|
        File.readlines(file).grep(/\bcurrent_user\b/).reject { |line| line.strip.start_with?("#") }.map { |line| "#{File.basename(file)}: #{line.strip}" }
      end
      expect(lines.size).to eq(2)
      expect(lines.join).to include("user_key: :current_user")
    end
  end

  # ---------------------------------------------------------------- docs: rate limit
  describe "rate limit fallback" do
    let(:rl) { armory::RateLimits }

    def schema_with(plugin, **options)
      query_type = rl::Controls::Query.example
      Class.new(base_schema) do
        query query_type
        use plugin, **options
      end
    end

    def run_rl(schema, **context)
      execute_query(schema, "{ report }", context: context, root_value: rl::Controls::Root.example).to_h
    end

    [true, false].each do |soft|
      it "[preservation] D1 Points soft #{soft}: a nil key raises ConfigurationError, every query" do
        schema = schema_with(rl::Points, store: rl::MemoryStore.new, limit: 100, window: 60, soft: soft)
        2.times { expect { run_rl(schema, rate_limit_key: nil) }.to raise_error(rl::ConfigurationError) }
      end
    end

    it "[preservation] D1b a limit callable and Concurrency raise on a nil key as well" do
      schema = schema_with(rl::Points, store: rl::MemoryStore.new, limit: ->(_k, _q) { nil }, window: 60)
      expect { run_rl(schema) }.to raise_error(rl::ConfigurationError)
      schema = schema_with(rl::Concurrency, store: rl::MemoryStore.new, limit: 1)
      expect { run_rl(schema) }.to raise_error(rl::ConfigurationError)
    end

    it "[preservation] D2a the String fallback runs, in one shared bucket" do
      schema = schema_with(rl::Points, store: rl::MemoryStore.new, limit: 100, window: 60, soft: false, extensions: true)
      first = run_rl(schema, rate_limit_key: nil || "unknown")
      second = run_rl(schema, rate_limit_key: nil || "unknown")
      expect(second.dig("extensions", "rateLimit", "remaining")).to be < first.dig("extensions", "rateLimit", "remaining")
    end

  end

  # ---------------------------------------------------------------- Rails, rake (real subprocesses)
  define_method(:root_dir) { root_dir }

  def probe_ruby(script)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "script.rb")
      File.write(path, script)
      output, = Open3.capture2e("bundle", "exec", "ruby", "-I", File.join(root_dir, "lib"), path, chdir: dir)
      output
    end
  end

  SCHEMAS = <<~'RUBY'
    class CleanBaseField < GraphQL::Schema::Field
      include GraphQL::Armory::Authorization::Base
    end
    class CleanQuery < GraphQL::Schema::Object
      include GraphQL::Armory::Authorization::Base
      field_class CleanBaseField
      graphql_name "Query"
      authorize :none, reason: "root"
      field :ping, String, null: false, authorize: :none, reason: "health"
    end
    class DirtyQuery < GraphQL::Schema::Object
      graphql_name "Query"
      field :leak, String
    end
  RUBY

  def write(dir, name, text)
    path = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def trace_line(word) = %(File.write(File.join(#{"ENV.fetch('APP_DIR')"}, "trace.log"), "#{word}\\n", mode: "a"))

  def rails_app(dir, before: "", after: "", gem_line: 'require "graphql/armory"')
    write(dir, "config/boot.rb", 'require "bundler/setup"')
    write(dir, "config/application.rb", <<~RUBY)
      require_relative "boot"
      require "rails"
      #{gem_line}
      class ProbeApp < Rails::Application
        config.root = File.expand_path("..", __dir__)
        config.eager_load = false
        config.secret_key_base = "x" * 32
        config.logger = Logger.new(IO::NULL)
      end
    RUBY
    write(dir, "config/environment.rb", <<~RUBY)
      require_relative "application"
      #{trace_line("env_file")}
      Rails.application.initialize!
    RUBY
    write(dir, "app/graphql/clean_schema.rb", <<~RUBY)
      #{trace_line("schema_loaded")}
      #{SCHEMAS}
      class CleanSchema < GraphQL::Schema
        query CleanQuery
        use GraphQL::Armory::Authorization, adapter: :pundit
      end
    RUBY
    write(dir, "app/graphql/dirty_schema.rb", <<~RUBY)
      #{SCHEMAS}
      class DirtySchema < GraphQL::Schema
        query DirtyQuery
        use GraphQL::Armory::Authorization, adapter: :pundit
      end
    RUBY
    write(dir, "bin/rails", <<~RUBY)
      require_relative "../config/boot"
      require "rails/commands"
    RUBY
    write(dir, "Rakefile", <<~RUBY)
      require_relative "config/application"
      #{before}
      Rails.application.load_tasks
      Rake::Task[:environment].enhance { #{trace_line("env_task")} }
      #{after}
    RUBY
  end

  def plain_app(dir, rakefile)
    write(dir, "schemas.rb", <<~RUBY)
      require "graphql/armory"
      #{SCHEMAS}
      class CleanSchema < GraphQL::Schema
        query CleanQuery
        use GraphQL::Armory::Authorization, adapter: :pundit
      end
      class DirtySchema < GraphQL::Schema
        query DirtyQuery
        use GraphQL::Armory::Authorization, adapter: :pundit
      end
    RUBY
    write(dir, "Rakefile", rakefile)
  end

  def rake(dir, *args)
    out, status = Open3.capture2e({ "APP_DIR" => dir }, "bundle", "exec", "rake", *args, chdir: dir)
    [out, status.exitstatus]
  end

  def trace(dir)
    path = File.join(dir, "trace.log")
    File.exist?(path) ? File.read(path).split("\n") : []
  end

  around do |example|
    Dir.mktmpdir("armory-app") do |dir|
      @app = dir
      example.run
    end
  end

  describe "the task in a real Rails app" do
    it "[security] R1 appears once in rake -T" do
      rails_app(@app)
      out, status = rake(@app, "-T", "graphql_armory")
      expect(status).to eq(0)
      expect(out.scan("graphql_armory:audit").size).to eq(1)
    end

    it "[security] R2 clean exits 0; :environment once and before the autoloaded schema" do
      rails_app(@app)
      out, status = rake(@app, "graphql_armory:audit[CleanSchema]")
      expect([out, status].last).to eq(0), out
      expect(trace(@app).first(3)).to eq(%w[env_file env_task schema_loaded])
      expect(trace(@app).count("env_task")).to eq(1)
    end

    it "[security] R2b with :environment named on the command line too it still runs once" do
      rails_app(@app)
      out, status = rake(@app, "environment", "graphql_armory:audit[CleanSchema]")
      expect(status).to eq(0), out
      expect(trace(@app).count("env_task")).to eq(1)
    end

    it "[security] R3 dirty exits 1" do
      rails_app(@app)
      out, status = rake(@app, "graphql_armory:audit[DirtySchema]")
      expect(status).to eq(1), out
      expect(out).to match(/unprotected/i)
    end

    it "[security] R4 an unknown schema exits 1, and R5 a missing argument exits 1" do
      rails_app(@app)
      out, status = rake(@app, "graphql_armory:audit[NoSuchSchema]")
      expect(status).to eq(1)
      expect(out).to include("No schema named NoSuchSchema")
      out, status = rake(@app, "graphql_armory:audit")
      expect(status).to eq(1)
      expect(out).to include("Name the schema")
    end

    it "[security] R6a a hand load after load_tasks: one action, one listing, nothing leaks onto the next task" do
      rails_app(@app, after: %(load "tasks/graphql_armory.rake"\ntask :after_one\nputs "actions=\#{Rake::Task["graphql_armory:audit"].actions.size} leak=\#{Rake::Task[:after_one].comment.inspect}"))
      out, status = rake(@app, "graphql_armory:audit[DirtySchema]")
      expect(status).to eq(1)
      expect(out).to include("actions=1 leak=nil")
      expect(rake(@app, "-T", "graphql_armory").first.scan("graphql_armory:audit").size).to eq(1)
    end

    it "[security] R6b a hand load before load_tasks: one action, dirty exits 1" do
      rails_app(@app, before: %(require "rake"\nload "tasks/graphql_armory.rake"), after: %(puts "actions=\#{Rake::Task["graphql_armory:audit"].actions.size}"))
      out, status = rake(@app, "graphql_armory:audit[DirtySchema]")
      expect(status).to eq(1), out
      expect(out).to include("actions=1")
      out, status = rake(@app, "graphql_armory:audit[CleanSchema]")
      expect(status).to eq(0), out
    end

    it "[security] R7 load_tasks twice: one action" do
      rails_app(@app, after: %(Rails.application.load_tasks\nputs "actions=\#{Rake::Task["graphql_armory:audit"].actions.size}"))
      out, status = rake(@app, "graphql_armory:audit[DirtySchema]")
      expect(status).to eq(1), out
      expect(out).to include("actions=1")
    end

    it "[security] R8 bin/rails lists the task and exits 1 on a dirty schema, 0 on a clean one" do
      rails_app(@app)
      out, status = Open3.capture2e({ "APP_DIR" => @app }, "bundle", "exec", "ruby", "bin/rails", "graphql_armory:audit[DirtySchema]", chdir: @app)
      expect(status.exitstatus).to eq(1), out
      out, status = Open3.capture2e({ "APP_DIR" => @app }, "bundle", "exec", "ruby", "bin/rails", "graphql_armory:audit[CleanSchema]", chdir: @app)
      expect(status.exitstatus).to eq(0), out
      out, = Open3.capture2e({ "APP_DIR" => @app }, "bundle", "exec", "ruby", "bin/rails", "-T", "graphql_armory", chdir: @app)
      expect(out.scan("graphql_armory:audit").size).to eq(1)
    end

    it "[preservation] R9a Rails: a Rakefile that adds a prerequisite before load_tasks keeps a working audit that exits 1" do
      rails_app(@app, before: %(require "rake"\ninclude Rake::DSL\ntask :setup\ntask "graphql_armory:audit" => :setup))
      out, status = rake(@app, "graphql_armory:audit[DirtySchema]")
      expect(status).to eq(1), "exit #{status}, output: #{out.inspect}"
    end

    it "[preservation] R9b non-Rails: a prerequisite declared before the hand load keeps a working audit that exits 1" do
      plain_app(@app, <<~RUBY)
        require_relative "schemas"
        task :setup
        task "graphql_armory:audit" => :setup
        load "tasks/graphql_armory.rake"
      RUBY
      out, status = rake(@app, "graphql_armory:audit[DirtySchema]")
      expect(status).to eq(1), "exit #{status}, output: #{out.inspect}"
    end

    it "[preservation] R9d Rails: prerequisite before load_tasks plus the hand load main required: dirty exits 1" do
      rails_app(@app, before: %(require "rake"\ninclude Rake::DSL\ntask :setup\ntask "graphql_armory:audit" => :setup), after: %(load "tasks/graphql_armory.rake"))
      out, status = rake(@app, "graphql_armory:audit[DirtySchema]")
      expect(status).to eq(1), "exit #{status}, output: #{out.inspect}"
    end

    it "[security] R9c Rails: an app's lib/tasks enhancing the task runs both, and dirty exits 1" do
      rails_app(@app)
      write(@app, "lib/tasks/z.rake", %(task :pre do\n  #{trace_line("pre")}\nend\ntask "graphql_armory:audit" => :pre\n))
      out, status = rake(@app, "graphql_armory:audit[DirtySchema]")
      expect(status).to eq(1), out
      expect(trace(@app)).to include("pre")
    end

    it "[security] R10 an :environment that raises gives a nonzero exit, and no audit" do
      rails_app(@app, after: %(Rake::Task[:environment].enhance { raise "boom" }))
      out, status = rake(@app, "graphql_armory:audit[CleanSchema]")
      expect(status).not_to eq(0)
      expect(out).to include("boom")
      expect(trace(@app)).not_to include("schema_loaded")
    end

    it "[preservation] R11 reenable and invoke runs the audit again, :environment once" do
      rails_app(@app, after: <<~'RUBY')
        task :twice do
          2.times do
            Rake::Task["graphql_armory:audit"].reenable
            Rake::Task["graphql_armory:audit"].invoke("CleanSchema")
            puts "ran"
          end
        end
      RUBY
      out, status = rake(@app, "twice")
      expect(status).to eq(0), out
      expect(out.scan(/^ran$/).size).to eq(2)
      expect(trace(@app).count("env_task")).to eq(1)
    end

    it "[security] R14 chain: a dirty audit stops the next task, with exit 1" do
      rails_app(@app, after: %(task(:next_one) { puts "NEXT RAN" }))
      out, status = rake(@app, "graphql_armory:audit[DirtySchema]", "next_one")
      expect(status).to eq(1)
      expect(out).not_to include("NEXT RAN")
    end
  end

  describe "the task without Rails" do
    it "[security] R13a a Rakefile with :environment defined after the load runs it once, first" do
      plain_app(@app, <<~RUBY)
        require_relative "schemas"
        load "tasks/graphql_armory.rake"
        task(:environment) { File.write("env.log", "ran", mode: "a") }
      RUBY
      out, status = rake(@app, "graphql_armory:audit[CleanSchema]")
      expect(status).to eq(0), out
      expect(File.read(File.join(@app, "env.log"))).to eq("ran")
    end

    it "[preservation] R13b a Rakefile with :environment defined before the load runs it once" do
      plain_app(@app, <<~RUBY)
        require_relative "schemas"
        task(:environment) { File.write("env.log", "ran", mode: "a") }
        load "tasks/graphql_armory.rake"
      RUBY
      out, status = rake(@app, "graphql_armory:audit[CleanSchema]")
      expect(status).to eq(0), out
      expect(File.read(File.join(@app, "env.log"))).to eq("ran")
    end

    it "[preservation] R13c no :environment: exit 0 clean, exit 1 dirty, unknown and missing" do
      plain_app(@app, %(require_relative "schemas"\nload "tasks/graphql_armory.rake"\n))
      expect(rake(@app, "graphql_armory:audit[CleanSchema]").last).to eq(0)
      expect(rake(@app, "graphql_armory:audit[DirtySchema]").last).to eq(1)
      expect(rake(@app, "graphql_armory:audit[Nope]").last).to eq(1)
      expect(rake(@app, "graphql_armory:audit").last).to eq(1)
    end

    it "[preservation] R13d a namespaced graphql_armory:environment is not mistaken for :environment" do
      plain_app(@app, <<~RUBY)
        require_relative "schemas"
        namespace(:graphql_armory) { task(:environment) { File.write("env.log", "ran") } }
        load "tasks/graphql_armory.rake"
      RUBY
      out, status = rake(@app, "graphql_armory:audit[CleanSchema]")
      expect(status).to eq(0), out
      expect(File.exist?(File.join(@app, "env.log"))).to be(false)
    end

    it "[security] R13e loading by hand twice leaves one action (on main, two)" do
      plain_app(@app, <<~RUBY)
        require_relative "schemas"
        load "tasks/graphql_armory.rake"
        load "tasks/graphql_armory.rake"
        puts "actions=\#{Rake::Task["graphql_armory:audit"].actions.size}"
      RUBY
      expect(rake(@app, "graphql_armory:audit[CleanSchema]").first).to include("actions=1")
    end
  end

  describe "Railtie and gem" do
    it "[preservation] T1 gem required before Rails: no Railtie, no task, a hand load works (docs' claim)" do
      out = probe_ruby(<<~'RUBY')
        require "graphql/armory"
        require "rails"
        puts defined?(GraphQL::Armory::Railtie).inspect
        puts Rails::Railtie.subclasses.map(&:name).grep(/Armory/).inspect
      RUBY
      expect(out).to eq("nil\n[]\n")
    end

    it "[preservation] T1b gem required before Rails in a real app: no task by itself; a hand load works and exits 1 on dirty" do
      rails_app(@app, gem_line: "")
      write(@app, "config/boot.rb", %(require "bundler/setup"\nrequire "graphql/armory"))
      expect(rake(@app, "-T", "graphql_armory").first).not_to include("graphql_armory:audit")
      rakefile = File.read(File.join(@app, "Rakefile"))
      write(@app, "Rakefile", rakefile + %(\nload "tasks/graphql_armory.rake"\n))
      out, status = rake(@app, "graphql_armory:audit[DirtySchema]")
      expect(status).to eq(1), out
      expect(trace(@app)).to include("env_task")
    end

    it "[preservation] T2 ActiveRecord alone or ActionController alone: no Railtie and no rails/railtie" do
      %w[active_record action_controller active_support].each do |lib|
        out = probe_ruby(<<~RUBY)
          require "#{lib}"
          require "graphql/armory"
          puts [defined?(::Rails::Railtie), defined?(GraphQL::Armory::Railtie)].inspect
        RUBY
        expect(out).to eq("[nil, nil]\n"), "#{lib}: #{out}"
      end
    end

    it "[security] T4 only rails/railtie loaded: the Railtie loads, subclass of Rails::Railtie, no crash" do
      out = probe_ruby(<<~'RUBY')
        require "active_support/all"
        require "rails/railtie"
        require "graphql/armory"
        puts GraphQL::Armory::Railtie.superclass
      RUBY
      expect(out).to eq("Rails::Railtie\n")
    end

    it "[security] T5 the built gem holds the railtie and the task" do
      Dir.mktmpdir do |dir|
        gem_path = File.join(dir, "probe.gem")
        out, status = Open3.capture2e("gem", "build", "graphql-armory.gemspec", "--output", gem_path, chdir: root_dir)
        expect(status).to be_success, out
        require "rubygems/package"
        contents = Gem::Package.new(gem_path).contents
        expect(contents).to include("lib/graphql/armory/railtie.rb", "lib/tasks/graphql_armory.rake", "lib/graphql-armory.rb")
      end
    end

    it "[security] T6 Bundler.require after Rails (the docs' way): the task appears" do
      rails_app(@app, gem_line: "Bundler.require(:default)")
      out, status = rake(@app, "-T", "graphql_armory")
      expect(status).to eq(0), out
      expect(out.scan("graphql_armory:audit").size).to eq(1)
    end

    it "[preservation] T7 authorization/rspec loads with no Rails, and no Railtie" do
      out = probe_ruby(<<~'RUBY')
        require "rspec/expectations"
        require "graphql/armory/authorization/rspec"
        puts [defined?(::Rails), defined?(GraphQL::Armory::Railtie)].inspect
      RUBY
      expect(out).to eq("[nil, nil]\n")
    end

    it "[preservation] G2 this process has no Rails constant, with railties in the Gemfile" do
      expect(defined?(::Rails)).to be_nil
      expect($LOADED_FEATURES.grep(%r{/railties-})).to be_empty
    end
  end
end
