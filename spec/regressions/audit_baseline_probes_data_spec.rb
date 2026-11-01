# frozen_string_literal: true

require "tmpdir"

# What the identity gaps of audit_baseline_probes_spec.rb do at run time: the file passes and a refused user gets the data.
class ProbeAnything
  VALUES = { ssn: "123-45", secret: "s3cret", all_users: "everyone" }.freeze
  def respond_to_missing?(*) = true
  def method_missing(name, *) = VALUES.fetch(name) { self }
end unless defined?(ProbeAnything)

RSpec.describe "Audit baseline probes, run time" do
  z = GraphQL::Armory::Authorization

  around { |example| Dir.mktmpdir("baseline-data") { |dir| @path = File.join(dir, "b.json"); example.run } }

  before { skip "no Audit::Baseline in this copy" unless defined?(GraphQL::Armory::Authorization::Audit::Baseline) }

  define_method(:fc) { @fc ||= Class.new(GraphQL::Schema::Field) { include z::Base } }
  define_method(:armored) do |&extra|
    klass = fc
    Class.new(GraphQL::Schema::Object) { include z::Base; field_class klass; graphql_name "Query"; authorize :none, reason: "probe", covers_fields: true; class_eval(&extra) if extra }
  end
  define_method(:schema_of) { |root| Class.new(ArmoryEngine.base_schema) { query root; use z, adapter: :pundit } }
  define_method(:accept) { |schema| z::Audit::Baseline.write(z::Audit.(schema), @path) }
  define_method(:judge) { |schema| z::Audit::Baseline.load(@path).(z::Audit.(schema)) }
  define_method(:run_it) { |schema, query, **ctx| execute_query(schema, query, root_value: ProbeAnything.new, context: { current_user: nil, **ctx }).to_h }

  it "[security] D3 ignored_rule type: new field passes the file and is served" do
    klass = fc
    conn = lambda do |extra|
      base = Class.new(GraphQL::Schema::Object) { include z::Base; field_class klass }
      Class.new(base) do
        include GraphQL::Types::Relay::ConnectionBehaviors
        graphql_name "FooConnection"
        authorize :read, model: String
        field :count_all, String
        def count_all = "1"
        class_eval(&extra) if extra
      end
    end
    root = ->(type) { armored { field :foo, type, null: true, connection: false; def foo = :record } }
    accept(schema_of(root.(conn.(nil))))
    changed = schema_of(root.(conn.(proc { field(:secret, String); def secret = "s3cret" })))
    expect(judge(changed).passes?).to be(false)
  end

  it "[security] D7 second class of an accepted graphql_name: passes the file and serves its new field" do
    a = Class.new(GraphQL::Schema::Object) { graphql_name "Invoice"; field(:total, String); def self.visible?(context) = !context[:admin] }
    b = Class.new(GraphQL::Schema::Object) { graphql_name "Invoice"; field(:ssn, String); def ssn = "123-45"; def self.visible?(context) = !!context[:admin] }
    accept(schema_of(armored { field :a, a, null: true }))
    changed = schema_of(armored { field :a, a, null: true; field :b, b, null: true; def a = :r; def b = :r })
    expect(judge(changed).passes?).to be(false)
  end

  it "[security] D9 new explicit bypass implementer: passes the file, its inherited field is served" do
    iface = Module.new { include GraphQL::Schema::Interface; graphql_name "Thing"; field(:secret, String) }
    klass = fc
    type = ->(name) { Class.new(GraphQL::Schema::Object) { include z::Base; field_class klass; graphql_name name; implements iface; authorize :none, reason: "x"; def secret = "s3cret" } }
    one = type.("One")
    accept(schema_of(armored { field :one, one, null: true }))
    two = type.("Two")
    changed = schema_of(armored { field :one, one, null: true; field :two, two, null: true; def two = :r })
    result = judge(changed)
    expect(result.passes?).to be(false)
  end

  it "[security] D10 new type with a real rule under an accepted own_check on its base: passes the file, a refused user gets it" do
    Object.const_set(:ProbeRec, Class.new) unless defined?(::ProbeRec)
    unless defined?(::ProbeRecPolicy)
      Object.const_set(:ProbeRecPolicy, Class.new { def initialize(_user, _record); end; def read? = false })
    end
    unless defined?(::ProbeLaxBase)
      Object.const_set(:ProbeLaxBase, Class.new(GraphQL::Schema::Object) { include z::Base; def self.authorized?(_o, _c) = true })
    end
    klass = fc
    kid = lambda do |name|
      Class.new(::ProbeLaxBase) { field_class klass; graphql_name name; authorize :read, model: ProbeRec; field(:secret, String); def secret = "s3cret" }
    end
    foo = kid.("FooK")
    accept(schema_of(armored { field :foo, foo, null: true }))
    expect(z::Audit::Baseline.load(@path).entries.map(&:kind)).to include("own_check")
    bar = kid.("BarK")
    changed = schema_of(armored { field :foo, foo, null: true; field :bar, bar, null: true; def bar = ProbeRec.new })
    result = judge(changed)
    expect(result.passes?).to be(false), result.to_s
  end
end
