# frozen_string_literal: true

require "ostruct"
require "json"
require "set"
require "delegate"
require "active_support/ordered_options"

# Probes for "a record's Pundit policy comes from its class". SECRET in a refused user's response is a leak.
class PfcStrictBase
  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve
      return @scope if @user == :admin

      @scope.respond_to?(:none) ? @scope.none : []
    end
  end

  def initialize(user, _record) = @user = user
  def read? = @user == :admin
  def update? = @user == :admin
end

class PfcLaxBase
  class Scope
    def initialize(_user, scope) = @scope = scope
    def resolve = @scope
  end

  def initialize(_user, _record); end
  def read? = true
  def update? = true
end

class PfcPublic; def secret = "SECRET"; end
class PfcPublicPolicy < PfcLaxBase; end
class PfcLaxPolicy < PfcLaxBase; end
class PfcStrictPolicy < PfcStrictBase; end
class PfcModuleTargetPolicy < PfcLaxBase; end

class PfcDoc; def secret = "SECRET"; end
class PfcDocPolicy < PfcStrictBase; end

PfcStruct = Struct.new(:secret, :policy_class, :model_name, :klass, keyword_init: true)
class PfcStructPolicy < PfcStrictBase; end

class PfcGhost
  def initialize(answers) = @answers = answers
  def respond_to_missing?(_name, _private = false) = true
  def method_missing(name, *) = @answers[name]
end
class PfcGhostPolicy < PfcStrictBase; end

class ActiveSupportOrderedOptionsPolicy < PfcStrictBase; end
module ActiveSupport; class OrderedOptionsPolicy < PfcStrictBase; end; end

class PfcKlassRecord
  def secret = "SECRET"
  def klass = PfcPublic
end
class PfcKlassRecordPolicy < PfcStrictBase; end

class PfcEchoRecord
  def klass = PfcPublic
  def echo(flag: nil) = flag ? "SECRET" : "open"
end
class PfcEchoRecordPolicy < PfcStrictBase; end

class PfcClassStrictWithKlass
  def self.policy_class = PfcStrictPolicy
  def secret = "SECRET"
  def klass = PfcPublic
end

class PfcKlassArg
  def secret = "SECRET"
  def klass(_required) = PfcPublic
end
class PfcKlassArgPolicy < PfcLaxBase; end

# Class-level ways of naming a policy.
class PfcClassPolicied; def self.policy_class = PfcLaxPolicy; def secret = "SECRET"; end
class PfcClassPoliciedChild < PfcClassPolicied; end

class PfcInstanceStrict
  def policy_class = PfcStrictPolicy
  def secret = "SECRET"
end
class PfcInstanceStrictPolicy < PfcLaxBase; end

class PfcModelNamedByString; def self.model_name = "PfcPublic"; def secret = "SECRET"; end

module PfcNs
  class Thing; def secret = "SECRET"; end
  class ThingPolicy < PfcLaxBase; end
end

class PfcDecorator < SimpleDelegator; end
class PfcDecoratorWithPolicy < SimpleDelegator; end
class PfcDecoratorWithPolicyPolicy < PfcLaxBase; end
class PfcDecoratorStrict < SimpleDelegator; end
class PfcDecoratorStrictPolicy < PfcStrictBase; end
class PfcDecoratorDraper < SimpleDelegator
  def self.model_name = ActiveModel::Name.new(PfcDoc)
end

class PfcDocSub < PfcDoc; end
class PfcDocSubPolicy < PfcLaxBase; end

class PfcBasic < BasicObject
  def self.policy_class = ::PfcLaxPolicy
  def secret = "SECRET"
end

# Active Record shapes.
ActiveRecord::Base.connection.create_table(:pfc_notes, force: true) do |t|
  t.string :secret
  t.string :kind
  t.string :klass
end
ActiveRecord::Base.connection.create_table(:pfc_stis, force: true) do |t|
  t.string :type
  t.string :secret
  t.integer :pfc_owner_id
end
ActiveRecord::Base.connection.create_table(:pfc_owners, force: true) { |t| t.string :name }
ActiveRecord::Base.connection.create_table(:pfc_links, force: true) do |t|
  t.string :secret
  t.integer :klass_id
end

# A column named klass holding text.
class PfcNote < ActiveRecord::Base; end
class PfcNotePolicy < PfcStrictBase; end

# The ordinary polymorphic helper: a client wrote `kind` when it created the record.
class PfcReport < ActiveRecord::Base
  self.table_name = "pfc_notes"
  self.ignored_columns += ["klass"]
  def klass = kind.constantize
end
class PfcReportPolicy < PfcStrictBase; end

class PfcLink < ActiveRecord::Base
  belongs_to :klass, class_name: "PfcOwner", optional: true
end
class PfcLinkPolicy < PfcStrictBase; end

class PfcOwner < ActiveRecord::Base
  has_many :stis, class_name: "PfcSti", foreign_key: :pfc_owner_id
end
class PfcOwnerPolicy < PfcLaxBase; end

class PfcSti < ActiveRecord::Base
  def self.policy_class = PfcLaxPolicy
end
class PfcStiChild < PfcSti; end

class PfcOwnPolicied < ActiveRecord::Base; self.table_name = "pfc_stis"; end
class PfcOwnPoliciedPolicy < PfcLaxBase; end
class PfcOwnPoliciedChild < PfcOwnPolicied; end

module PfcNs
  class Row < ActiveRecord::Base; self.table_name = "pfc_stis"; end
  class RowPolicy < PfcLaxBase; end
end

RSpec.describe "PROBE: a record's policy comes from its class" do
  # Global names Pundit would find for every spec in the process: they live only during each example here.
  around do |example|
    policies = { OpenStructPolicy: PfcStrictBase, HashPolicy: PfcStrictBase, SetPolicy: PfcStrictBase, NilClassPolicy: PfcLaxBase }
    policies.each { |name, base| Object.const_set(name, Class.new(base)) }
    example.run
  ensure
    policies.each_key { |name| Object.send(:remove_const, name) }
  end

  let(:armory) { GraphQL::Armory::Authorization }
  let(:adapter) { armory::Adapters::Pundit.new }
  let(:base_argument) do
    plugin = armory
    Class.new(GraphQL::Schema::Argument) { include plugin::Base }
  end
  let(:base_field) do
    plugin = armory
    argument = base_argument
    Class.new(GraphQL::Schema::Field) do
      include plugin::Base
      argument_class argument
    end
  end
  let(:base_object) do
    plugin = armory
    field = base_field
    Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class field
    end
  end

  def doc_type(model:, name: "Doc", **rule, &block)
    Class.new(base_object) do
      graphql_name name
      authorize :read, model: model, **rule
      field :secret, String, null: true
      class_eval(&block) if block
    end
  end

  def schema_of(type)
    plugin = armory
    query_class = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :doc, type, null: true, authorize: :none, reason: "x"
      field :docs, [type], null: true, authorize: :none, reason: "x"
    end
    Class.new(base_schema) do
      use plugin, adapter: :pundit
      query query_class
    end
  end

  # What a user sees, or the exception's class when the query blew up (closed).
  def fetch(type, record, user: :someone)
    root = Struct.new(:doc, :docs).new(record, nil)
    result = execute_query(schema_of(type), "{ doc { secret } }", root_value: root, context: { current_user: user }).to_h
    result.dig("data", "doc", "secret")
  rescue StandardError => error
    puts "RAISED #{error.class}: #{error.message[0, 90]} @ #{error.backtrace.first(2).join(" < ")[0, 170]}"
    error.class
  end

  def fetch_list(type, records, user: :someone)
    root = Struct.new(:doc, :docs).new(nil, records)
    result = execute_query(schema_of(type), "{ docs { secret } }", root_value: root, context: { current_user: user }).to_h
    Array(result.dig("data", "docs")).compact.map { |doc| doc["secret"] }
  rescue StandardError => error
    error.class
  end

  def audit(type)
    armory::Audit.(schema_of(type))
  end

  def asks(subject, rule = armory::Rule.new(:read), user: :someone)
    adapter.authorized?(user, subject, rule)
  rescue StandardError => error
    error.class
  end

  def show(label, value)
    puts "OUT #{label} => #{value.inspect}"
    value
  end

  context "client-shaped" do
    it "S01 security OpenStruct policy_class text" do
      expect(show("S01", fetch(doc_type(model: OpenStruct), OpenStruct.new(policy_class: "PfcLaxPolicy", secret: "SECRET")))).to be_nil
    end

    it "S02 security OpenStruct model_name text" do
      expect(show("S02", fetch(doc_type(model: OpenStruct), OpenStruct.new(model_name: "PfcPublic", secret: "SECRET")))).to be_nil
    end

    it "S03 security OpenStruct klass text" do
      expect(show("S03", fetch(doc_type(model: OpenStruct), OpenStruct.new(klass: "PfcPublic", secret: "SECRET")))).to be_nil
    end

    it "S04 security OpenStruct class text never picks a policy" do
      expect(show("S04", fetch(doc_type(model: OpenStruct), OpenStruct.new(class: "PfcPublic", secret: "SECRET")))).not_to eq("SECRET")
    end

    it "S05 security OpenStruct is_a? key" do
      expect(show("S05", fetch(doc_type(model: OpenStruct), OpenStruct.new("is_a?": true, policy_class: "PfcLaxPolicy", secret: "SECRET")))).not_to eq("SECRET")
    end

    it "S06 security OpenStruct respond_to? key" do
      expect(show("S06", fetch(doc_type(model: OpenStruct), OpenStruct.new(policy_class: "PfcLaxPolicy", secret: "SECRET", "respond_to?": true)))).not_to eq("SECRET")
    end

    it "S07 security Hash with every key" do
      record = { policy_class: "PfcLaxPolicy", model_name: "PfcPublic", klass: "PfcPublic", class: "PfcPublic", secret: "SECRET" }
      expect(show("S07", fetch(doc_type(model: Hash), record))).to be_nil
    end

    it "S08 security Struct members with text" do
      record = PfcStruct.new(secret: "SECRET", policy_class: "PfcLaxPolicy", model_name: "PfcPublic", klass: "PfcPublic")
      expect(show("S08", fetch(doc_type(model: PfcStruct), record))).to be_nil
    end

    it "S09 security method_missing object answering text" do
      record = PfcGhost.new(policy_class: "PfcLaxPolicy", model_name: "PfcPublic", klass: "PfcPublic", secret: "SECRET")
      expect(show("S09", fetch(doc_type(model: PfcGhost), record))).not_to eq("SECRET")
    end

    it "S10 security OpenStruct policy_class holding a Module" do
      expect(show("S10", fetch(doc_type(model: OpenStruct), OpenStruct.new(policy_class: PfcLaxPolicy, secret: "SECRET")))).to be_nil
    end

    it "S11 security real JSON through object_class: OpenStruct" do
      json = '{"policy_class":"PfcLaxPolicy","model_name":"PfcPublic","klass":"PfcPublic","secret":"SECRET"}'
      expect(show("S11", fetch(doc_type(model: OpenStruct), JSON.parse(json, object_class: OpenStruct)))).to be_nil
    end

    it "S12 security OrderedOptions keys" do
      record = ActiveSupport::OrderedOptions.new
      record[:policy_class] = "PfcLaxPolicy"
      record[:klass] = "PfcPublic"
      record[:secret] = "SECRET"
      expect(show("S12", fetch(doc_type(model: ActiveSupport::OrderedOptions), record))).not_to eq("SECRET")
    end

    it "S13 security a list of OpenStructs naming a policy" do
      records = [OpenStruct.new(policy_class: "PfcLaxPolicy", model_name: "PfcPublic", secret: "SECRET")]
      expect(show("S13", fetch_list(doc_type(model: OpenStruct), records))).to eq([])
    end

    it "S14 security OpenStruct klass from a lookup on client text" do
      kinds = { "public" => PfcPublic, "doc" => PfcDoc }
      record = OpenStruct.new(klass: kinds.fetch("public"), secret: "SECRET")
      expect(show("S14", fetch(doc_type(model: OpenStruct), record))).to be_nil
    end

    it "S15 security Struct klass from a lookup on client text" do
      record = PfcStruct.new(secret: "SECRET", klass: "PfcPublic".then { |text| Object.const_get(text) })
      expect(show("S15", fetch(doc_type(model: PfcStruct), record))).to be_nil
    end

    it "S16 security method_missing object klass from a lookup" do
      record = PfcGhost.new(klass: PfcPublic, secret: "SECRET")
      expect(show("S16", fetch(doc_type(model: PfcGhost), record))).not_to eq("SECRET")
    end


    it "S18 security bypass with an OpenStruct class key does not serve through telemetry" do
      type = Class.new(base_object) do
        graphql_name "Doc"
        authorize :read, model: OpenStruct, policy: PfcLaxPolicy
        field :secret, String, null: true
      end
      expect(show("S18", fetch(type, OpenStruct.new(class: 1, secret: "SECRET")))).to be_a(Object)
    end
  end

  context "the klass exemption" do
    it "S20 security AR column klass holding text" do
      record = PfcNote.create!(secret: "SECRET", klass: "PfcPublic")
      expect(show("S20", fetch(doc_type(model: PfcNote), record))).to be_nil
    end

    it "S21 security AR `def klass = kind.constantize` with a client-set kind" do
      record = PfcReport.create!(secret: "SECRET", kind: "PfcPublic")
      expect(show("S21", fetch(doc_type(model: PfcReport), record))).to be_nil
    end

    it "S22 security an ordinary record whose klass answers another model" do
      expect(show("S22", fetch(doc_type(model: PfcKlassRecord), PfcKlassRecord.new))).to be_nil
    end

    it "S23 security AR belongs_to :klass" do
      owner = PfcOwner.create!(name: "x")
      record = PfcLink.create!(secret: "SECRET", klass_id: owner.id)
      expect(show("S23", fetch(doc_type(model: PfcLink), record))).to be_nil
    end

    it "S24 security self.policy_class strict and a klass naming a laxer one" do
      expect(show("S24", fetch(doc_type(model: PfcClassStrictWithKlass), PfcClassStrictWithKlass.new))).to be_nil
    end

    it "S25 security field authorize: on such a record" do
      plain = Class.new(base_object) do
        graphql_name "Doc"
        authorize :none, reason: "public"
        field :secret, String, null: true, authorize: :read
      end
      answer = fetch(plain, PfcKlassRecord.new)
      expect(show("S25", answer)).not_to eq("SECRET")
    end

    it "S26 security a list of such records" do
      expect(show("S26", fetch_list(doc_type(model: PfcKlassRecord), [PfcKlassRecord.new]))).to eq([])
    end

    it "S27 security mutation with loads: of such a record" do
      PfcReport.delete_all
      record = PfcReport.create!(secret: "SECRET", kind: "PfcPublic")
      ran = []
      plugin = armory
      arg_class = base_argument
      field_klass = base_field
      object = base_object
      report_type = Class.new(object) do
        graphql_name "Report"
        authorize :read, model: PfcReport, policy: PfcLaxPolicy
        field :secret, String, null: true
      end
      mutation = Class.new(GraphQL::Schema::RelayClassicMutation) do
        include plugin::Base
        graphql_name "Edit"
        argument_class arg_class
        field_class field_klass
        object_class object
        authorize :update, model: PfcReport
        argument :report_id, GraphQL::Types::ID, required: true, loads: report_type
        field :ok, GraphQL::Types::Boolean, null: true, authorize: :none, reason: "x"
        define_method(:resolve) do |report:|
          ran << report
          { ok: true }
        end
      end
      mutation_class = Class.new(object) do
        graphql_name "Mutation"
        authorize :none, reason: "root", covers_fields: true
        field :edit, mutation: mutation
      end
      query_class = Class.new(object) do
        graphql_name "Query"
        authorize :none, reason: "root", covers_fields: true
        field :report, report_type, null: true, authorize: :none, reason: "x"
      end
      schema = Class.new(base_schema) do
        use plugin, adapter: :pundit
        query query_class
        mutation mutation_class
      end
      query = %(mutation { edit(input: { reportId: "#{record.id}" }) { ok } })
      begin
        execute_query(schema, query, context: { current_user: :someone }).to_h
      rescue StandardError => error
        show("S27 raised", error.class)
      end
      expect(show("S27 mutation ran for a refused user", ran.size)).to eq(0)
    end

    it "S28 security argument authorize: on such a record" do
      plain = Class.new(base_object) do
        graphql_name "Doc"
        authorize :none, reason: "public"
        field :echo, String, null: true, authorize: :none, reason: "x" do
          argument :flag, String, required: false, authorize: :read, model: PfcEchoRecord
        end
      end
      root = Struct.new(:doc, :docs).new(PfcEchoRecord.new, nil)
      answer =
        begin
          execute_query(schema_of(plain), %({ doc { echo(flag: "x") } }), root_value: root, context: { current_user: :someone }).to_h.dig("data", "doc", "echo")
        rescue StandardError => error
          puts "RAISED S28 #{error.class}: #{error.message[0, 120]}"
          error.class
        end
      expect(show("S28", answer)).not_to eq("SECRET")
    end

    it "K20 preservation a klass with a required argument still finds the class's policy" do
      expect(show("K20", asks(PfcKlassArg.new))).to eq(true)
    end

    it "K21 preservation an AR record loaded without the klass column" do
      PfcNote.create!(secret: "SECRET", klass: "x")
      record = PfcNote.select(:id, :secret).first
      expect(show("K21", asks(record))).to eq(false)
    end

    it "K22 preservation client text that makes klass raise answers a denial, not an exception" do
      record = PfcReport.create!(secret: "SECRET", kind: "NoSuchConstantAtAll")
      expect(show("K22", asks(record))).to eq(false)
    end
  end

  context "other paths" do
    it "S30 security adapter.scope with a client-shaped non-Array" do
      answer =
        begin
          adapter.scope(:someone, OpenStruct.new(policy_class: "PfcLaxPolicy", model_name: "PfcPublic"), armory::Rule.new(:read))
        rescue StandardError => error
          error.class
        end
      expect(show("S30", answer)).not_to be_a(OpenStruct)
    end

    it "S31 security a connection over an Array of OpenStructs" do
      type = doc_type(model: OpenStruct)
      plugin = armory
      query_class = Class.new(base_object) do
        graphql_name "Query"
        authorize :none, reason: "root", covers_fields: true
        field :docs, type.connection_type, null: true, authorize: :none, reason: "x"
      end
      schema = Class.new(base_schema) do
        use plugin, adapter: :pundit
        query query_class
      end
      root = Struct.new(:docs).new([OpenStruct.new(policy_class: "PfcLaxPolicy", secret: "SECRET")])
      result = execute_query(schema, "{ docs { nodes { secret } } }", root_value: root, context: { current_user: :someone }).to_h
      expect(show("S31", result.dig("data", "docs", "nodes"))).to eq([])
    end

    it "S32 security find_by on a table whose records answer klass" do
      record = PfcReport.create!(secret: "SECRET", kind: "PfcPublic")
      type = doc_type(model: PfcReport, name: "Report")
      plugin = armory
      query_class = Class.new(base_object) do
        graphql_name "Query"
        authorize :none, reason: "root", covers_fields: true
        field :report, type, null: true, find_by: :id, authorize: :none, reason: "x"
      end
      schema = Class.new(base_schema) do
        use plugin, adapter: :pundit
        query query_class
      end
      result = execute_query(schema, %({ report(id: "#{record.id}") { secret } }), context: { current_user: :someone }).to_h
      expect(show("S32", result.dig("data", "report"))).to be_nil
    end

    it "K30 preservation visible_when asks the model's class" do
      expect(show("K30", asks(PfcDoc, armory::Rule.new(:read), user: :admin))).to eq(true)
    end

    it "K32 preservation owners on the real classes" do
      type = doc_type(model: PfcDoc)
      owners = {
        authorized: type.method(:authorized?).owner,
        scope_items: type.method(:scope_items).owner,
        policy_subject: adapter.method(:policy_subject).owner,
        adapter: schema_of(type).armory_configuration.adapter.class
      }
      show("K32", owners)
      expect(owners[:authorized]).to eq(armory::Integration::Object)
      expect(owners[:scope_items]).to eq(armory::Integration::Object)
      expect(owners[:adapter]).to eq(armory::Adapters::Pundit)
    end
  end

  context "regressions" do
    let(:read) { armory::Rule.new(:read) }

    it "K40 preservation AR relation with no rule.model" do
      expect(show("K40", adapter.scope(:someone, PfcOwner.all, read).to_sql)).to eq(PfcOwner.all.to_sql)
    end

    it "K41 preservation association relation and CollectionProxy" do
      owner = PfcOwner.create!(name: "o")
      expect(show("K41a", adapter.scope(:someone, owner.stis, read).class.name)).to eq("ActiveRecord::Associations::CollectionProxy")
      expect(show("K41b", adapter.scope(:someone, owner.stis.where(secret: "x"), read).to_sql)).to include("x")
    end

    it "K42 preservation STI subclass inherits self.policy_class" do
      expect(show("K42", asks(PfcStiChild.new))).to eq(true)
      expect(adapter.scope(:someone, PfcStiChild.all, read).to_sql).to eq(PfcStiChild.all.to_sql)
    end

    it "K43 preservation STI subclass with no policy of its own raises, like main" do
      expect(show("K43", asks(PfcOwnPoliciedChild.new))).to eq(Pundit::NotDefinedError)
    end

    it "K44 preservation anonymous subclass inherits self.policy_class" do
      expect(show("K44", asks(Class.new(PfcClassPolicied).new))).to eq(true)
    end

    it "K45 preservation anonymous class with no policy raises NotDefined and quotes nothing" do
      record = Class.new { def inspect = "LEAK" }.new
      error = begin
        adapter.authorized?(:someone, record, read)
      rescue Pundit::NotDefinedError => e
        e
      end
      expect(error).to be_a(Pundit::NotDefinedError)
      expect(show("K45", error.message)).not_to include("LEAK")
    end

    it "K46 preservation namespaced models" do
      expect(show("K46a", asks(PfcNs::Thing.new))).to eq(true)
      expect(show("K46b", asks(PfcNs::Row.new))).to eq(true)
      expect(adapter.scope(:someone, PfcNs::Row.all, read).to_sql).to eq(PfcNs::Row.all.to_sql)
    end

    it "K47 preservation nil root with a NilClassPolicy" do
      expect(show("K47", asks(nil))).to eq(true)
    end

    it "K49 preservation empty Array" do
      expect(show("K49", adapter.scope(:someone, [], read))).to eq([])
    end

    it "K50 preservation an Array of mixed classes is asked per item" do
      kept = adapter.scope(:someone, [PfcPublic.new, PfcDoc.new], read)
      expect(show("K50", kept.map(&:class))).to eq([PfcPublic])
    end

    it "K51 preservation Set and Enumerator" do
      with_model = adapter.scope(:someone, Set[PfcDoc.new], armory::Rule.new(:read, model: PfcDoc))
      show("K51 model", with_model.class)
      no_model = begin
        adapter.scope(:someone, Set[PfcDoc.new], read)
      rescue StandardError => error
        error.class
      end
      enum = begin
        adapter.scope(:someone, [PfcDoc.new].each, read)
      rescue StandardError => error
        error.class
      end
      show("K51 set", no_model)
      show("K51 enum", enum)
      expect(no_model).to eq([]).or eq(Set[]).or eq(Pundit::NotDefinedError)
      expect(enum).to eq(Pundit::NotDefinedError)
    end

    it "K52 preservation Data with a class member" do
      data = Data.define(:class, :secret)
      Object.const_set(:PfcDataClass, data) unless defined?(PfcDataClass)
      Object.const_set(:PfcDataClassPolicy, Class.new(PfcStrictBase)) unless defined?(PfcDataClassPolicy)
      expect(show("K52", asks(PfcDataClass.new(class: "PfcPublic", secret: "x")))).to eq(false)
    end

    it "K53 preservation Struct with a class member" do
      Object.const_set(:PfcStructClass, Struct.new(:class, :secret)) unless defined?(PfcStructClass)
      Object.const_set(:PfcStructClassPolicy, Class.new(PfcStrictBase)) unless defined?(PfcStructClassPolicy)
      expect(show("K53", asks(PfcStructClass.new("PfcPublic", "x")))).to eq(false)
    end

    it "K54 preservation policy: wins over klass and OpenStruct keys" do
      rule = armory::Rule.new(:read, policy: PfcStrictPolicy)
      expect(show("K54a", asks(PfcKlassRecord.new, rule))).to eq(false)
      expect(show("K54b", asks(OpenStruct.new(policy_class: "PfcLaxPolicy"), rule))).to eq(false)
    end

    it "K55 preservation self.model_name, ActiveModel::Name and String" do
      expect(show("K55a", asks(PfcModelNamedByString.new))).to eq(true)
      expect(show("K55b", asks(PfcDecoratorDraper.new(PfcDoc.new)))).to eq(false)
    end

    it "K56 preservation a relation as a subject of authorized?" do
      expect(show("K56", asks(PfcOwner.all))).to eq(true)
    end

    it "K57 preservation BasicObject proxy with class-level policy_class" do
      answer = asks(PfcBasic.new)
      show("K57", answer)
      expect([true, NoMethodError]).to include(answer)
    end

  end

  context "audit against runtime" do


    it "S72 security a record whose klass names a laxer policy, audit ok" do
      type = doc_type(model: PfcKlassRecord)
      leaked = fetch(type, PfcKlassRecord.new)
      show("S72", [audit(type).ok?, leaked])
      expect(audit(type).ok? && leaked == "SECRET").to be(false)
    end

    it "K73 preservation self.policy_class: audit and runtime agree" do
      type = doc_type(model: PfcClassPolicied)
      show("K73", [audit(type).ok?, fetch(type, PfcClassPolicied.new)])
      expect(audit(type).ok?).to be(true)
      expect(fetch(type, PfcClassPolicied.new)).to eq("SECRET")
    end

    it "K74 preservation instance policy_class is no longer asked, as documented" do
      type = doc_type(model: PfcInstanceStrict)
      show("K74", [audit(type).ok?, fetch(type, PfcInstanceStrict.new)])
      expect(fetch(type, PfcInstanceStrict.new)).to eq("SECRET")
    end
  end

  context "upgrade paths the docs state" do
    it "K80 preservation move an instance policy_class to self.policy_class" do
      moved = Class.new(PfcInstanceStrict) do
        def self.policy_class = PfcStrictPolicy
        def self.name = "PfcMoved"
      end
      expect(show("K80", asks(moved.new))).to eq(false)
      expect(asks(moved.new, user: :admin)).to eq(true)
    end

    it "K81 preservation policy: on the type's authorize" do
      type = doc_type(model: PfcInstanceStrict, policy: PfcStrictPolicy)
      expect(show("K81", fetch(type, PfcInstanceStrict.new))).to be_nil
      expect(fetch(type, PfcInstanceStrict.new, user: :admin)).to eq("SECRET")
      expect(fetch_list(type, [PfcInstanceStrict.new])).to eq([])
    end

    it "K82 preservation a decorator with its own policy" do
      expect(show("K82", asks(PfcDecoratorWithPolicy.new(PfcDoc.new)))).to eq(true)
    end

    it "K83 preservation a decorator with none raises and quotes nothing" do
      record = Class.new(PfcDoc) { def inspect = "LEAK" }.new
      error = begin
        adapter.authorized?(:someone, PfcDecorator.new(record), armory::Rule.new(:read))
      rescue Pundit::NotDefinedError => e
        e
      end
      expect(error).to be_a(Pundit::NotDefinedError)
      expect(show("K83", error.message)).not_to include("LEAK")
    end

    it "K84 preservation a decorator with policy:" do
      rule = armory::Rule.new(:read, policy: PfcStrictPolicy)
      expect(show("K84", asks(PfcDecorator.new(PfcDoc.new), rule))).to eq(false)
    end

    it "K85 preservation a decorator wrapping an AR record that defines klass asks the decorator's class" do
      expect(show("K85", asks(PfcDecoratorWithPolicy.new(PfcNote.new(klass: "x"))))).to eq(true)
    end

    it "K85b preservation a decorator around a record whose klass is a Module" do
      expect(show("K85b", asks(PfcDecoratorStrict.new(PfcKlassRecord.new)))).to eq(false)
    end

    it "K86 preservation a relation asks the class in klass" do
      expect(show("K86", adapter.scope(:someone, PfcNote.all, armory::Rule.new(:read)).to_a)).to eq([])
    end
  end
end
