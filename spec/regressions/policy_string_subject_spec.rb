# frozen_string_literal: true

require "ostruct"
require "json"

class VpNote
  def text(tag: nil, filter: nil) = "hello"
  def upcase = "HELLO"
end
class VpLax; end
class VpBare; def upcase = "BARE"; end

class VpNotePolicy
  class Scope
    def initialize(user, scope) = (@user = user; @scope = scope)
    def resolve = @user == :ok ? @scope : []
  end
  def initialize(user, _record) = @user = user
  def read? = @user == :ok
  def export? = @user == :ok
  def manage? = @user == :ok
end

class VpLaxPolicy
  class Scope
    def initialize(_u, scope) = @scope = scope
    def resolve = @scope
  end
  def initialize(_u, _r); end
  def read? = true
  def export? = true
  def manage? = true
end

class VpAnswerPolicy
  class << self; attr_accessor :answer; end
  class Scope
    def initialize(_u, scope) = @scope = scope
    def resolve = @scope
  end
  def initialize(_u, _r); end
  def read? = self.class.answer
end

module VpNs; class LaxPolicy < VpLaxPolicy; end; end

class VpStrictString
  class Scope
    def initialize(_u, _s); end
    def resolve = []
  end
  def initialize(_u, _r); end
  def read? = false
end

class VpRoot
  def note = VpNote.new
  def notes = [VpNote.new]
  def text(v:) = v
  def texts(v:) = v
  def sym(v:) = v.to_sym
  def ostruct(json:) = OpenStruct.new(JSON.parse(json))
  def invoices = Invoice.all
  def via_ref(invoice:) = invoice
  def conn = [VpNote.new]
  def bare = VpBare.new
  def plain = "x"
  def r = "x"
end

RSpec.describe "verification of the String subject and bad answer change" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:adapter) { armory::Adapters::Pundit.new }
  let(:read) { armory::Rule.new(:read) }

  def base_argument
    @base_argument ||= begin
      plugin = armory
      Class.new(GraphQL::Schema::Argument) { include plugin::Base }
    end
  end

  def base_field
    @base_field ||= begin
      plugin = armory
      argument = base_argument
      Class.new(GraphQL::Schema::Field) do
        include plugin::Base
        argument_class argument
      end
    end
  end

  def base_object
    @base_object ||= begin
      plugin = armory
      field = base_field
      Class.new(GraphQL::Schema::Object) do
        include plugin::Base
        field_class field
      end
    end
  end

  def base_input
    plugin = armory
    arg = base_argument
    Class.new(GraphQL::Schema::InputObject) do
      include plugin::Base
      argument_class arg
    end
  end

  def type(name = "Note", **rule, &block)
    Class.new(base_object) do
      graphql_name name
      action = rule.key?(:action) ? rule.delete(:action) : :read
      authorize(action, **rule)
      class_eval(&block) if block
    end
  end

  def query_with(&block)
    Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root"
      class_eval(&block)
    end
  end

  def schema_of(query, plugin_options: { adapter: :pundit }, &block)
    plugin = armory
    Class.new(ArmoryEngine.base_schema) do
      query query
      use plugin, **plugin_options
      class_eval(&block) if block
    end
  end

  def note_schema(note_type)
    schema_of(query_with { field :note, note_type, authorize: :none, reason: "root" })
  end

  def run(schema, query, user)
    execute_query(schema, query, root_value: VpRoot.new, context: { current_user: user }).to_h
  end

  def with_const(name, value)
    Object.const_set(name, value)
    yield
  ensure
    Object.send(:remove_const, name)
  end

  def sql
    queries = []
    ActiveSupport::Notifications.subscribed(->(*, payload) { queries << payload[:sql] }, "sql.active_record") { yield }
    queries
  end

  def text_schema(**rule)
    text_type = type("Text", **rule) { field :upcase, String }
    schema_of(query_with do
      field(:text, text_type, authorize: :none, reason: "root") { argument :v, String }
      field(:texts, [text_type], authorize: :none, reason: "root") { argument :v, [String] }
    end)
  end

  describe "claim 1, String model" do
    it "[preservation] 1 a type's String model: query and audit" do
      schema = note_schema(type(model: "VpNote") { field :text, String })
      expect(run(schema, "{ note { text } }", :ok).dig("data", "note", "text")).to eq("hello")
      expect(run(schema, "{ note { text } }", :no).dig("data", "note")).to be_nil
      expect(armory::Audit.(schema).problems).to eq([])
    end

    it "[preservation] 2 a type's String model with visible_when:" do
      schema = note_schema(type(model: "VpNote", visible_when: :export) { field :text, String })
      expect(run(schema, '{ __type(name: "Note") { name } }', :ok).dig("data", "__type", "name")).to eq("Note")
      expect(run(schema, '{ __type(name: "Note") { name } }', :no).dig("data", "__type")).to be_nil
    end

    it "[preservation] 2b a field's visible_when: on a type with a String model" do
      schema = note_schema(type(model: "VpNote") { field :text, String, visible_when: :export })
      expect(run(schema, "{ note { text } }", :ok).dig("data", "note", "text")).to eq("hello")
      expect(run(schema, "{ note { text } }", :no)["errors"].first["message"]).to match(/text/)
    end

    it "[preservation] 3 an argument's String model with visible_when:" do
      schema = note_schema(type(model: VpNote) do
        field(:text, String) { argument :tag, String, required: false, model: "VpNote", visible_when: :export }
      end)
      expect(armory::Audit.(schema).problems).to eq([])
      expect(run(schema, '{ note { text(tag: "x") } }', :ok).dig("data", "note", "text")).to eq("hello")
      expect(run(schema, '{ note { text(tag: "x") } }', :no)["errors"].first["message"]).to match(/tag/)
    end

    it "[preservation] 3b an input object's argument with a String model and visible_when:" do
      input = Class.new(base_input) do
        graphql_name "Filter"
        argument :tag, String, required: false, model: "VpNote", visible_when: :export
      end
      schema = note_schema(type(model: VpNote) { field(:text, String) { argument :filter, input, required: false } })
      expect(run(schema, '{ note { text(filter: { tag: "x" }) } }', :ok).dig("data", "note", "text")).to eq("hello")
    end

    # The refused user must not see an argument the named model's policy hides. With a lax StringPolicy on the branch, `model:` is ignored.
    it "[preservation] 3d an argument's String model with visible_when: is not answered by StringPolicy" do
      schema = note_schema(type(model: VpNote) do
        field(:text, String) { argument :tag, String, required: false, model: "VpNote", visible_when: :export }
      end)
      with_const(:StringPolicy, VpLaxPolicy) do
        response = run(schema, '{ note { text(tag: "x") } }', :no)
        STDERR.puts "VP3d: #{response.inspect}"
        expect(response["errors"].first["message"]).to match(/tag/)
      end
    end

    it "[preservation] 3c an argument's Symbol model with visible_when: (control)" do
      schema = note_schema(type(model: VpNote) do
        field(:text, String) { argument :tag, String, required: false, model: :vp_note, visible_when: :export }
      end)
      expect(run(schema, '{ note { text(tag: "x") } }', :ok).dig("data", "note", "text")).to eq("hello")
    end

    it "[preservation] 4 an argument's String model with authorize:" do
      schema = note_schema(type(model: VpNote) do
        field(:text, String) { argument :tag, String, required: false, model: "VpNote", authorize: :manage }
      end)
      expect(armory::Audit.(schema).problems).to eq([])
      expect(run(schema, '{ note { text(tag: "x") } }', :ok).dig("data", "note", "text")).to eq("hello")
    end

    it "[preservation] 5 a resolver's String model stays a :model problem and a ConfigurationError" do
      plugin = armory
      resolver = Class.new(GraphQL::Schema::Resolver) do
        include plugin::Base
        graphql_name "R"
        type String, null: true
        authorize :read, model: "VpNote"
        def resolve = "x"
      end
      schema = schema_of(query_with { field :r, resolver: resolver })
      expect(armory::Audit.(schema).problems.map(&:kind)).to include(:model)
      expect { run(schema, "{ r }", :ok) }.to raise_error(armory::ConfigurationError)
    end

    it "[preservation] 6 a field has no model: option" do
      expect { type { field :text, String, model: "VpNote" } }.to raise_error(ArgumentError)
    end

    it "[preservation] 7 found_policy with a String" do
      expect(adapter.found_policy("VpNote")).to eq(VpNotePolicy)
    end

    it "[preservation] 7b no false :foreign_policy for an input argument with a String model under the same policy" do
      input = Class.new(base_input) do
        graphql_name "Filter"
        argument :tag, String, required: false, model: "VpNote", visible_when: :export
      end
      schema = note_schema(type(model: VpNote, policy: VpNotePolicy) { field(:text, String) { argument :filter, input, required: false } })
      expect(armory::Audit.(schema).problems).to eq([])
    end

    context "with records" do
      def invoice_schema
        invoice_type = type("Inv", model: "Invoice") { field :number, String }
        schema_of(query_with do
          field(:by_id, invoice_type, authorize: :none, reason: "root", find_by: :id) { argument :id, "GraphQL::Types::ID" }
          field(:via_ref, invoice_type, authorize: :none, reason: "root") { argument :invoice_id, "GraphQL::Types::ID", loads: invoice_type }
          field :invoices, [invoice_type], authorize: :none, reason: "root"
        end)
      end

      def ask(query, id, user)
        execute_query(invoice_schema, query, root_value: VpRoot.new, variables: { "id" => id.to_s }, context: { current_user: user }).to_h
      end

      it "[preservation] 8 loads: with a String model goes through the scope" do
        q = "query($id: ID!) { viaRef(invoiceId: $id) { number } }"
        expect(ask(q, world.a1.id, world.alice).dig("data", "viaRef", "number")).to eq("A-1")
        expect(ask(q, world.b1.id, world.alice).dig("data", "viaRef")).to be_nil
      end

      it "[preservation] 9 find_by: with a String model goes through the scope" do
        q = "query($id: ID!) { byId(id: $id) { number } }"
        expect(ask(q, world.a1.id, world.alice).dig("data", "byId", "number")).to eq("A-1")
        expect(ask(q, world.b1.id, world.alice).dig("data", "byId")).to be_nil
      end

      it "[preservation] 9b a relation under a String model is narrowed by the policy's Scope" do
        world
        response = execute_query(invoice_schema, "{ invoices { number } }", root_value: VpRoot.new, context: { current_user: world.alice }).to_h
        expect(response.dig("data", "invoices").map { |i| i["number"] }).to contain_exactly("A-1", "A-2")
      end
    end

    it "[preservation] 10 snake_case and missing Strings in check and scope" do
      expect(adapter.check(VpNote, armory::Rule.new(:read, model: "vp_note"))).to eq([])
      expect(adapter.check(VpNote, armory::Rule.new(:read, model: "VpNoSuch"))).to eq(["VpNoSuchPolicy not found"])
      expect(adapter.check("VpNote", read)).to eq([])
      expect(adapter.scope(:ok, :items, armory::Rule.new(:read, model: "vp_note"))).to eq(:items)
    end
  end

  describe "claim 1, String record" do
    it "[security] 11 a list of Strings with a String model: no String picks its policy" do
      with_const(:StringPolicy, VpStrictString) do
        response = run(text_schema(model: "VpLax"), '{ texts(v: ["VpLax"]) { upcase } }', :no)
        expect(Array(response.dig("data", "texts")).compact).to eq([])
      end
    end

    it "[security] 11b adapter.scope on an Array of Strings" do
      with_const(:StringPolicy, VpStrictString) do
        expect(adapter.scope(:no, ["VpLax", "vp_lax"], armory::Rule.new(:read, model: "VpLax"))).to eq([])
      end
    end

    it "[security] 12 a type wrapping the client's text: StringPolicy judges it" do
      with_const(:StringPolicy, VpStrictString) do
        response = run(text_schema(model: VpNote), '{ text(v: "VpLax") { upcase } }', :no)
        expect(response.dig("data", "text")).to be_nil
      end
    end


    it "[security] 12c a client String that looks like a snake_case policy" do
      with_const(:StringPolicy, VpStrictString) do
        expect(run(text_schema(model: VpNote), '{ text(v: "vp_lax") { upcase } }', :no).dig("data", "text")).to be_nil
      end
    end

    it "[security] 13 a String record equal to the String model still asks StringPolicy" do
      with_const(:StringPolicy, VpStrictString) do
        expect(run(text_schema(model: "VpLax"), '{ text(v: "VpLax") { upcase } }', :no).dig("data", "text")).to be_nil
      end
    end

    it "[security] 14 scope on a bare String" do
      expect { adapter.scope(:no, "VpLax", read) }.to raise_error(Pundit::NotDefinedError, "no policy found for String")
    end

    it "[report] 15 a Symbol the app derives from client text no longer serves past the declared model" do
      plugin_type = type("Sym", model: VpNote) { field :length, Integer }
      schema = schema_of(query_with { field(:sym, plugin_type, authorize: :none, reason: "root") { argument :v, String } })
      expect(run(schema, '{ sym(v: "vp_lax") { length } }', :no).dig("data", "sym", "length")).to be_nil
    end




  end

  describe "claim 2, bad answers" do
    around do |example|
      example.run
      VpAnswerPolicy.answer = nil
    end

    def answer_schema
      answer = type(model: VpNote, policy: VpAnswerPolicy) { field :text, String }
      schema_of(query_with do
        field :note, answer, authorize: :none, reason: "root"
        field :notes, [answer], authorize: :none, reason: "root"
      end)
    end

    def secret_struct
      Struct.new(:class) do
        def inspect = "SECRET"
        def to_s = "SECRET"
      end.new("SECRET")
    end


    it "[security] 19 a Struct with a class member through Integration" do
      VpAnswerPolicy.answer = secret_struct
      expect { run(answer_schema, "{ note { text } }", :ok) }.to raise_error(armory::AdapterError) { |e| expect(e.message).not_to include("SECRET") }
    end

    it "[security] 20 BasicObject through Integration" do
      VpAnswerPolicy.answer = Class.new(BasicObject) { def inspect = ::Kernel.raise("read it") }.new
      expect { run(answer_schema, "{ note { text } }", :ok) }.to raise_error(armory::AdapterError, /answered a #<Class/)
    end

    it "[security] 21 a Proc through Integration: not called, not quoted" do
      called = false
      VpAnswerPolicy.answer = proc { called = true }
      expect { run(answer_schema, "{ note { text } }", :ok) }.to raise_error(armory::AdapterError, /answered a Proc;/)
      expect(called).to eq(false)
    end

    it "[security] 23 rescue_from shows the safe message" do
      VpAnswerPolicy.answer = secret_struct
      plugin = armory
      answer = type(model: VpNote, policy: VpAnswerPolicy) { field :text, String }
      schema = schema_of(query_with { field :note, answer, authorize: :none, reason: "root" }) do
        rescue_from(plugin::AdapterError) { |error, *| raise GraphQL::ExecutionError, error.message }
      end
      response = run(schema, "{ note { text } }", :ok)
      expect(response["errors"].first["message"]).to include("answered a")
      expect(response.to_s).not_to include("SECRET")
    end

    it "[preservation] 24 scope on an Array with a bad answer: dropped silently by the adapter, no text, no query" do
      world
      VpAnswerPolicy.answer = Invoice.all
      out = nil
      queries = sql { out = adapter.scope(:ok, [VpNote.new], armory::Rule.new(:read, policy: VpAnswerPolicy)) }
      expect(out).to eq([])
      expect(queries).to eq([])
    end


    it "[preservation] 25 a list through Integration with a bad answer does not serve data" do
      VpAnswerPolicy.answer = secret_struct
      response = begin
        run(answer_schema, "{ notes { text } }", :ok)
      rescue armory::AdapterError => e
        e.message
      end
      expect(response.to_s).not_to include("hello")
      expect(response.to_s).not_to include("SECRET")
    end

    it "[preservation] 26 CanCan answers booleans, a block returning a relation is truthy and is not read" do
      world
      ability = Class.new do
        include CanCan::Ability
        def initialize(_user) = can(:read, VpNote) { |_note| Invoice.all }
      end
      cancan = armory::Adapters::CanCan.new(ability_class: ability)
      out = nil
      queries = sql { out = cancan.authorized?(ability.new(nil), VpNote.new, read) }
      expect(out).to eq(true)
      expect(queries).to eq([])
    end

    it "[security] 26b a custom adapter's bad answer through Authorize also names the class" do
      authorize = armory::Authorize.new(adapter: armory::Adapters::Substitute.new(allow: secret_struct))
      expect { authorize.(:s, read, {}) }.to raise_error(armory::AdapterError) { |e| expect(e.message).not_to include("SECRET") }
    end

  end

  describe "claim 3, the doc's limits" do
    def direct_connection(rule: { policy: VpNotePolicy, model: VpNote }, &block)
      plugin = armory
      field_klass = base_field
      note = type(model: VpNote) { field :text, String }
      edge = note.edge_type
      Class.new(GraphQL::Types::Relay::BaseConnection) do
        include plugin::Base
        field_class field_klass
        graphql_name "DocConnection"
        edge_type edge
        authorize :read, **rule
        class_eval(&block)
      end
    end

    def legacy = ArmoryEngine.supported? ? { resolve_legacy_instance_method: true } : {}

    def conn_schema(connection)
      schema_of(query_with { field :conn, connection, authorize: :none, reason: "root", connection: true })
    end

    it "[preservation] 29 direct BaseConnection: a missing action is silent, fails closed at runtime" do
      options = legacy
      connection = direct_connection do
        field :total, Integer, null: true, authorize: :misspelled, **options
        define_method(:total) { 1 }
      end
      schema = conn_schema(connection)
      expect(armory::Audit.(schema).problems).to eq([])
      %i[ok no].each do |user|
        begin
          STDERR.puts "VP29 #{user}: #{run(schema, "{ conn { total } }", user).inspect}"
        rescue StandardError => e
          STDERR.puts "VP29 #{user}: raised #{e.class}: #{e.message}"
        end
      end
      expect { run(schema, "{ conn { total } }", :ok) }.to raise_error(armory::AdapterError, /misspelled/)
    end

    it "[preservation] 29b direct BaseConnection, no policy named: closed, with a different error" do
      options = legacy
      connection = direct_connection(rule: { model: VpNote }) do
        field :total, Integer, null: true, authorize: :misspelled, **options
        define_method(:total) { 1 }
      end
      expect { run(conn_schema(connection), "{ conn { total } }", :ok) }.to raise_error(Pundit::NotDefinedError)
    end

    it "[preservation] 29c direct BaseConnection: authorize: :none is not listed among the bypasses" do
      options = legacy
      connection = direct_connection do
        field :total, Integer, null: true, authorize: :none, reason: "VP-NOT-LISTED", **options
        define_method(:total) { 1 }
      end
      schema = conn_schema(connection)
      expect(armory::Audit.(schema).bypasses.map(&:reason)).not_to include("VP-NOT-LISTED")
      STDERR.puts "VP29c no: #{run(schema, "{ conn { total } }", :no).inspect}"
      STDERR.puts "VP29c ok: #{run(schema, "{ conn { total } }", :ok).inspect}"
    end

    it "[preservation] 30 direct BaseConnection: :foreign_policy is still reported" do
      plugin = armory
      field_klass = base_field
      note = type(model: VpNote) { field :text, String }
      edge = note.edge_type
      parent = Class.new(GraphQL::Types::Relay::BaseConnection) do
        include plugin::Base
        field_class field_klass
        graphql_name "ParentConnection"
        edge_type edge
        field :total, Integer, null: true, authorize: :manage
      end
      child = Class.new(parent) do
        graphql_name "ChildConnection"
        authorize :read, policy: VpNotePolicy, model: VpLax
      end
      expect(armory::Audit.(conn_schema(child)).problems.map(&:kind)).to include(:foreign_policy)
    end

    it "[preservation] 31 direct BaseEdge: a missing action is silent, closed at runtime, :none not listed" do
      plugin = armory
      field_klass = base_field
      options = legacy
      note = type(model: VpNote) { field :text, String }
      edge = Class.new(GraphQL::Types::Relay::BaseEdge) do
        include plugin::Base
        field_class field_klass
        graphql_name "DocEdge"
        node_type note
        authorize :read, policy: VpNotePolicy, model: VpNote
        field :rank, Integer, null: true, authorize: :misspelled, **options
        field :open, Integer, null: true, authorize: :none, reason: "VP-EDGE", **options
        define_method(:rank) { 1 }
        define_method(:open) { 1 }
      end
      connection = Class.new(GraphQL::Types::Relay::BaseConnection) do
        graphql_name "DocConnection"
        edge_type edge, nodes_field: false
      end
      schema = conn_schema(connection)
      report = armory::Audit.(schema)
      expect(report.problems.map(&:to_s).join).not_to include("misspelled")
      expect(report.bypasses.map(&:reason)).not_to include("VP-EDGE")
      expect { run(schema, "{ conn { edges { rank } } }", :ok) }.to raise_error(armory::AdapterError, /misspelled/)
    end

    it "[preservation] 32 a missing action on a field of a bypassed type: audit silent, AdapterError for everyone" do
      bypassed = type("Doc", action: :none, reason: "public") { field :text, String, authorize: :misspelled }
      schema = schema_of(query_with { field :note, bypassed, authorize: :none, reason: "root" })
      expect(armory::Audit.(schema).problems).to eq([])
      %i[ok no].each do |user|
        expect { run(schema, "{ note { text } }", user) }.to raise_error(armory::AdapterError, /misspelled/)
      end
    end

    it "[preservation] 32b same, a record with no policy: NotDefinedError, not AdapterError" do
      bypassed = type("Doc", action: :none, reason: "public") { field :upcase, String, authorize: :misspelled }
      schema = schema_of(query_with { field :bare, bypassed, authorize: :none, reason: "root" })
      expect(armory::Audit.(schema).problems).to eq([])
      expect { run(schema, "{ bare { upcase } }", :ok) }.to raise_error(Pundit::NotDefinedError)
    end

    it "[preservation] 33 a missing action on a resolver's argument: audit silent, AdapterError for everyone" do
      plugin = armory
      arg = base_argument
      resolver = Class.new(GraphQL::Schema::Resolver) do
        include plugin::Base
        argument_class arg
        graphql_name "R"
        type String, null: true
        authorize :read, model: VpNote
        argument :tag, String, required: false, authorize: :misspelled
        def resolve(**) = "x"
      end
      schema = schema_of(query_with { field :r, resolver: resolver })
      expect(armory::Audit.(schema).problems).to eq([])
      expect { run(schema, '{ r(tag: "x") }', :ok) }.to raise_error(armory::AdapterError, /misspelled/)
      expect(run(schema, "{ r }", :ok).dig("data", "r")).to eq("x")
      STDERR.puts "VP33 user the resolver's rule refuses: #{run(schema, '{ r(tag: "x") }', :no).inspect}"
    end

    def shadowed(type_ref)
      field_klass = base_field
      parent = type("Base", model: VpNote) do
        field_class field_klass
        field(:text, String, null: true) { argument :filter, type_ref, required: false }
      end
      child = Class.new(parent) do
        graphql_name "Doc"
        field :text, String, null: true, override_reason: "as strict"
      end
      schema_of(query_with { field :note, child, authorize: :none, reason: "root" })
    end


    it "[preservation] 34b a shadowed argument type that is a missing constant name raises ArgumentError" do
      expect { armory::Audit.(shadowed("VpMissingConstant")) }.to raise_error(ArgumentError)
    end

    it "[preservation] 35 authorize: true inherited by a bypassed type: says denied, the rule runs" do
      field_klass = base_field
      parent = type("Base", model: VpNote) do
        field_class field_klass
        field :text, String, null: true, authorize: true
      end
      child = Class.new(parent) do
        graphql_name "Doc"
        authorize :none, reason: "public"
      end
      schema = schema_of(query_with { field :note, child, authorize: :none, reason: "root" })
      problem = armory::Audit.(schema).problems.find { |p| p.path == "Doc.text" }
      expect(problem.message).to match(/denied/)
      expect(run(schema, "{ note { text } }", :ok).dig("data", "note", "text")).to eq("hello")
      expect(run(schema, "{ note { text } }", :no).dig("data", "note", "text")).to be_nil
    end
  end
end
