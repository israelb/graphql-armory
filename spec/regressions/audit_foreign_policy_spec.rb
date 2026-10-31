# frozen_string_literal: true

require "json"
require "fileutils"

class ArmoryProbeDoc
  def notes(**) = "SECRET"
end

class ArmoryProbeDocPolicy
  class Scope
    def initialize(_user, scope) = @scope = scope
    def resolve = @scope
  end

  def initialize(_user, _record); end
  def read? = true
  def manage? = true
end

class ArmoryProbeStrictPolicy < ArmoryProbeDocPolicy
  def manage? = false
end

# A model whose found policy is the very policy the type names, and that policy refuses.
class ArmoryProbeSame
  def notes(**) = "SECRET"
end

class ArmoryProbeSamePolicy < ArmoryProbeDocPolicy
  def manage? = false
end

P_AUTH = GraphQL::Armory::Authorization

class ProbeArg < GraphQL::Schema::Argument
  include P_AUTH::Base
end

class ProbeField < GraphQL::Schema::Field
  include P_AUTH::Base
  argument_class ProbeArg
end

class ProbeFieldNoArgClass < GraphQL::Schema::Field
  include P_AUTH::Base
end

class ProbePlainField < GraphQL::Schema::Field
  argument_class ProbeArg
end

class ProbeObject < GraphQL::Schema::Object
  include P_AUTH::Base
  field_class ProbeField
end

class ProbeInput < GraphQL::Schema::InputObject
  include P_AUTH::Base
  argument_class ProbeArg
end

class ProbeResolver < GraphQL::Schema::Resolver
  include P_AUTH::Base
  argument_class ProbeArg
end

class ArmoryProbeMutualA < ProbeInput
  graphql_name "MutualA"
  argument :b, "ArmoryProbeMutualB", required: false
end

class ArmoryProbeMutualB < ProbeInput
  graphql_name "MutualB"
  argument :a, ArmoryProbeMutualA, required: false
  argument :raw, GraphQL::Types::Boolean, required: false, authorize: :manage, model: ArmoryProbeDoc
end

RSpec.describe "foreign_policy probes" do
  bool = GraphQL::Types::Boolean
  doc = ArmoryProbeDoc
  strict = ArmoryProbeStrictPolicy

  def rule_input(name = "Filter")
    Class.new(ProbeInput) do
      graphql_name name
      argument :raw, GraphQL::Types::Boolean, required: false, authorize: :manage, model: ArmoryProbeDoc
    end
  end

  def doc_type(parent = ProbeObject, policy: ArmoryProbeStrictPolicy, model: ArmoryProbeDoc, &block)
    Class.new(parent) do
      graphql_name "Doc"
      authorize :read, policy: policy, model: model
      class_eval(&block) if block
    end
  end

  def parent_type(model: ArmoryProbeDoc, **rule, &block)
    Class.new(ProbeObject) do
      graphql_name "Parent"
      authorize :read, model: model, **rule
      class_eval(&block) if block
    end
  end

  def interface_with(name = "Noted", field_klass = ProbeField, &block)
    Module.new do
      include GraphQL::Schema::Interface
      graphql_name name
      field_class field_klass
      module_eval(&block) if block
    end
  end

  def schema_of(type, extra: nil)
    query_class = Class.new(ProbeObject) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :doc, type, null: true, authorize: :none, reason: "x"
    end
    Class.new(base_schema) do
      use P_AUTH, adapter: :pundit
      query query_class
      class_eval(&extra) if extra
    end
  end

  # Runs the audit and, when given, the query as a refused user. Logs everything to compare configurations.
  def observe(schema, query = nil, dig: %w[data doc notes], record: ArmoryProbeDoc.new)
    report = begin
      P_AUTH::Audit.(schema)
    rescue StandardError, NotImplementedError => error
      error
    end
    out = if report.is_a?(Exception)
            { audit_crash: "#{report.class}: #{report.message[0, 180]}", foreign: [], kinds: [], ok: false }
          else
            problems = report.problems
            { foreign: problems.select { |pb| pb.kind == :foreign_policy }.map(&:path), kinds: problems.map(&:kind).uniq, ok: report.ok? }
          end
    if query
      begin
        root = dig.first(2) == %w[data doc] ? Struct.new(:doc).new(record) : record
        res = execute_query(schema, query, root_value: root, context: { current_user: :someone }).to_h
        out[:served] = res.dig(*dig)
        out[:errors] = res["errors"]&.map { |entry| entry["message"][0, 80] }
      rescue StandardError => error
        out[:run_crash] = "#{error.class}: #{error.message[0, 160]}"
      end
    end
    desc = RSpec.current_example.description
    puts "INFO #{desc} => #{out.inspect}"
    unless report.is_a?(Exception)
      dump = { desc: desc, problems: report.problems.map { |pb| [pb.kind, pb.path, pb.message.gsub(/0x\h+/, "0x")] }, bypasses: report.bypasses.map { |by| [by.path, by.reason] } }
    end
    out
  end

  def expect_foreign(out, path)
    expect(out).to include(foreign: include(path))
  end

  def expect_no_foreign(out)
    expect(out).not_to include(:audit_crash)
    expect(out[:foreign]).to eq([]), "false alarm: #{out.inspect}"
  end

  # --- 1. Misses
  it "[security] M1 nested input two levels" do
    inner = rule_input("Inner")
    outer = Class.new(ProbeInput) { graphql_name "Outer"; argument :inner, inner, required: false }
    type = doc_type { field(:notes, String, null: true) { argument :filter, outer, required: false } }
    expect_foreign(observe(schema_of(type), "{ doc { notes(filter: { inner: { raw: true } }) } }"), "Doc.notes(raw)")
  end

  it "[security] M2 self-referencing input" do
    input = Class.new(ProbeInput) { graphql_name "Rec"; argument :child, self, required: false; argument :raw, bool, required: false, authorize: :manage, model: doc }
    type = doc_type { field(:notes, String, null: true) { argument :filter, input, required: false } }
    expect_foreign(observe(schema_of(type), "{ doc { notes(filter: { child: { raw: true } }) } }"), "Doc.notes(raw)")
  end

  it "[security] M3 list and non-null wrapped input" do
    input = rule_input
    type = doc_type { field(:notes, String, null: true) { argument :filters, [input], required: true } }
    expect_foreign(observe(schema_of(type), "{ doc { notes(filters: [{ raw: true }]) } }"), "Doc.notes(raw)")
  end

  it "[security] M4 mutually recursive inputs" do
    type = doc_type { field(:notes, String, null: true) { argument :filter, ArmoryProbeMutualA, required: false } }
    expect_foreign(observe(schema_of(type), "{ doc { notes(filter: { b: { raw: true } }) } }"), "Doc.notes(raw)")
  end

  it "[security] M5 visible_when on an inherited field" do
    parent = parent_type { field :notes, String, null: true, visible_when: :manage }
    expect_foreign(observe(schema_of(doc_type(parent)), "{ doc { notes } }"), "Doc.notes")
  end

  it "[security] M6 visible_when on an inherited field's argument" do
    parent = parent_type { field(:notes, String, null: true) { argument :raw, bool, required: false, visible_when: :manage, model: doc } }
    expect_foreign(observe(schema_of(doc_type(parent)), "{ doc { notes(raw: true) } }"), "Doc.notes(raw)")
  end

  it "[security] M6b visible_when on an input object's argument" do
    input = Class.new(ProbeInput) { graphql_name "Vis"; argument :raw, bool, required: false, visible_when: :manage, model: doc }
    type = doc_type { field(:notes, String, null: true) { argument :filter, input, required: false } }
    expect_foreign(observe(schema_of(type), "{ doc { notes(filter: { raw: true }) } }"), "Doc.notes(raw)")
  end

  it "[security] M7 authorize: true on a parent, policy on the child" do
    parent = Class.new(ProbeObject) { graphql_name "Parent"; authorize :manage, model: doc; field :notes, String, null: true, authorize: true }
    expect_foreign(observe(schema_of(doc_type(parent)), "{ doc { notes } }"), "Doc.notes")
  end

  it "[security] M8 interface inherited through an interface" do
    inner = interface_with("Inner") { field :notes, String, null: true, authorize: :manage }
    outer = interface_with("Outer") { implements inner }
    type = doc_type { implements outer }
    expect_foreign(observe(schema_of(type), "{ doc { notes } }"), "Doc.notes")
  end

  it "[security] M10 authorize: true on an interface (denied at runtime; read the message)" do
    iface = interface_with { field :notes, String, null: true, authorize: true }
    type = doc_type { implements iface }
    out = observe(schema_of(type), "{ doc { notes } }")
    expect(out[:kinds]).to include(:foreign_policy)
    expect(out[:served]).to be_nil
  end

  it "[security] M11 subclass inherits policy: without redeclaring, rule on grandparent" do
    grand = parent_type { field :notes, String, null: true, authorize: :manage }
    middle = Class.new(grand) { graphql_name "Middle"; authorize :read, policy: strict, model: doc }
    child = Class.new(middle) { graphql_name "Doc" }
    expect_foreign(observe(schema_of(child), "{ doc { notes } }"), "Doc.notes")
  end

  it "[security] M12 type reached only through orphan_types" do
    iface = interface_with("Hidden") do
      field :notes, String, null: true, authorize: :manage
    end
    type = Class.new(ProbeObject) { graphql_name "Orphan"; authorize :read, policy: strict, model: doc; implements iface }
    query_class = Class.new(ProbeObject) { graphql_name "Query"; authorize :none, reason: "root", covers_fields: true; field :x, iface, null: true, authorize: :none, reason: "x" }
    schema = Class.new(base_schema) { use P_AUTH, adapter: :pundit; query query_class; orphan_types type }
    expect_foreign(observe(schema), "Orphan.notes")
  end

  it "[security] M14 duplicate definitions on one interface, the rule on the first" do
    iface = interface_with do
      field :notes, String, null: true, authorize: :manage
      field :notes, String, null: true
    end
    type = doc_type { implements iface }
    expect_foreign(observe(schema_of(type)), "Doc.notes")
  end


  def mutation_schema(mutation)
    root = Class.new(ProbeObject) { graphql_name "M"; authorize :read, policy: ArmoryProbeStrictPolicy, model: ArmoryProbeDoc; field :do_it, mutation: mutation }
    schema_of(doc_type, extra: proc { mutation root })
  end

  it "[security] M16 a plain Mutation's argument under a root naming policy:" do
    mut = Class.new(GraphQL::Schema::Mutation) do
      graphql_name "DoIt"
      argument_class ProbeArg
      argument :raw, bool, required: false, authorize: :manage, model: doc
      field :result, String, null: true
      def resolve(**) = Struct.new(:result).new("SECRET")
    end
    expect_foreign(observe(mutation_schema(mut), "mutation { doIt(raw: true) { result } }", dig: %w[data doIt result]), "M.do_it(raw)")
  end

  it "[security] M16b a RelayClassicMutation's argument under a root naming policy:" do
    mut = Class.new(GraphQL::Schema::RelayClassicMutation) do
      graphql_name "DoIt"
      argument_class ProbeArg
      argument :raw, bool, required: false, authorize: :manage, model: doc
      field :result, String, null: true
      def resolve(**) = Struct.new(:result).new("SECRET")
    end
    expect_foreign(observe(mutation_schema(mut), "mutation { doIt(input: { raw: true }) { result } }", dig: %w[data doIt result]), "M.do_it(raw)")
  end

  it "[security] M17 Base field, plain argument class, Base input with a rule" do
    input = rule_input
    type = doc_type do
      field_class ProbeFieldNoArgClass
      field(:notes, String, null: true) { argument :filter, input, required: false }
    end
    expect_foreign(observe(schema_of(type), "{ doc { notes(filter: { raw: true }) } }"), "Doc.notes(raw)")
  end

  it "[security] M18 plain field class on a parent, Base argument with a rule" do
    parent = parent_type do
      field_class ProbePlainField
      field(:notes, String, null: true) { argument :raw, bool, required: false, authorize: :manage, model: doc }
    end
    expect_foreign(observe(schema_of(doc_type(parent)), "{ doc { notes(raw: true) } }"), "Doc.notes(raw)")
  end

  it "[security] M18b plain field class on the type itself, Base input with a rule" do
    input = rule_input
    type = doc_type do
      field_class ProbePlainField
      field(:notes, String, null: true) { argument :filter, input, required: false }
    end
    expect_foreign(observe(schema_of(type), "{ doc { notes(filter: { raw: true }) } }"), "Doc.notes(raw)")
  end

  def base_resolver(&block)
    Class.new(ProbeResolver) do
      graphql_name "Notes"
      type String, null: true
      authorize :read, policy: ArmoryProbeStrictPolicy, model: ArmoryProbeDoc
      def resolve(**) = "SECRET"
      class_eval(&block) if block
    end
  end

  it "[security] M19 field rule on a parent, with a Base resolver" do
    resolver = base_resolver
    parent = parent_type { field :notes, resolver: resolver, authorize: :manage }
    expect_foreign(observe(schema_of(doc_type(parent)), "{ doc { notes } }"), "Doc.notes")
  end

  it "[security] M20 Base resolver with an input object rule" do
    input = rule_input
    resolver = base_resolver { argument :filter, input, required: false }
    type = doc_type { field :notes, resolver: resolver }
    expect_foreign(observe(schema_of(type), "{ doc { notes(filter: { raw: true }) } }"), "Doc.notes(raw)")
  end

  it "[security] M21 bypassed type naming policy:, field rule on an interface" do
    iface = interface_with { field :notes, String, null: true, authorize: :manage }
    type = Class.new(ProbeObject) { graphql_name "Doc"; authorize :none, reason: "public", policy: strict, model: doc, covers_fields: true; implements iface }
    expect_foreign(observe(schema_of(type), "{ doc { notes } }"), "Doc.notes")
  end

  it "[security] M22 connection subclass naming policy:, rule on its parent" do
    node = doc_type
    parent_conn = Class.new(GraphQL::Types::Relay::BaseConnection) do
      include P_AUTH::Base
      field_class ProbeField
      graphql_name "ParentConn"
      edge_type(node.edge_type)
      field :notes, String, null: true, authorize: :manage
    end
    conn = Class.new(parent_conn) { graphql_name "DocConn"; authorize :read, policy: strict, model: doc }
    out = observe(schema_of(conn))
    expect(out[:foreign]).to include("DocConn.notes")
  end

  it "[security] M17b Base argument, plain input, then a Base input with a rule" do
    inner = rule_input("InnerRuled")
    plain = Class.new(GraphQL::Schema::InputObject) { graphql_name "PlainMiddle"; argument :inner, inner, required: false }
    type = doc_type { field(:notes, String, null: true) { argument :filter, plain, required: false } }
    expect_foreign(observe(schema_of(type), "{ doc { notes(filter: { inner: { raw: true } }) } }"), "Doc.notes(raw)")
  end

  it "[security] M18c interface with graphql-ruby's default field class, Base input with a rule" do
    input = rule_input
    iface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Noted"
      field(:notes, String, null: true) { argument :filter, input, required: false }
    end
    type = doc_type { implements iface }
    expect_foreign(observe(schema_of(type), "{ doc { notes(filter: { raw: true }) } }"), "Doc.notes(raw)")
  end

  it "[security] M19b field rule on an interface, with a Base resolver" do
    resolver = base_resolver
    iface = interface_with { field :notes, resolver: resolver, authorize: :manage }
    type = doc_type { implements iface }
    expect_foreign(observe(schema_of(type), "{ doc { notes } }"), "Doc.notes")
  end

  it "[security] M20b Base mutation with an input object rule, under a root naming policy:" do
    input = rule_input
    mut = Class.new(GraphQL::Schema::Mutation) do
      include P_AUTH::Base
      graphql_name "DoIt"
      argument_class ProbeArg
      authorize :read, policy: strict, model: doc
      argument :filter, input, required: false
      field :result, String, null: true
      def resolve(**) = Struct.new(:result).new("SECRET")
    end
    expect_foreign(observe(mutation_schema(mut), "mutation { doIt(filter: { raw: true }) { result } }", dig: %w[data doIt result]), "M.do_it(raw)")
  end

  it "[security] M21b bypassed type naming policy:, no covers_fields, rule on a parent" do
    parent = parent_type { field :notes, String, null: true, authorize: :manage }
    type = Class.new(parent) { graphql_name "Doc"; authorize :none, reason: "public", policy: strict, model: doc }
    expect_foreign(observe(schema_of(type), "{ doc { notes } }"), "Doc.notes")
  end

  # --- 2. False alarms
  it "[preservation] F1 authorize: :none on an interface and on a parent" do
    iface = interface_with { field :a, String, null: true, authorize: :none, reason: "public" }
    parent = parent_type { field :b, String, null: true, authorize: :none, reason: "public" }
    expect_no_foreign(observe(schema_of(doc_type(parent) { implements iface })))
  end

  it "[preservation] F2 Base resolver with its own rule on a parent and on the type" do
    resolver = base_resolver
    parent = parent_type { field :a, resolver: resolver }
    expect_no_foreign(observe(schema_of(doc_type(parent) { field :b, resolver: resolver })))
  end

  it "[preservation] F2b Base resolver's own argument rule" do
    resolver = base_resolver { argument :raw, bool, required: false, authorize: :manage, model: doc }
    expect_no_foreign(observe(schema_of(doc_type { field :notes, resolver: resolver })))
  end

  it "[preservation] F3 child overriding with the same policy class" do
    parent = parent_type(policy: strict) { field :notes, String, null: true, authorize: :manage }
    type = doc_type(parent) { field :notes, String, null: true, authorize: :manage, override_reason: "same" }
    expect_no_foreign(observe(schema_of(type), "{ doc { notes } }"))
  end

  it "[preservation] F5 connections, edges, Node, global_id_field, connection args" do
    type = doc_type do
      implements GraphQL::Types::Relay::Node
      global_id_field :id
      field :notes, String, null: true
    end
    query_class = Class.new(ProbeObject) do
      graphql_name "Query"
      authorize :read, policy: strict, model: doc
      field :docs, type.connection_type, null: true
      field :nodes_list, [type], null: true
    end
    schema = Class.new(base_schema) { use P_AUTH, adapter: :pundit; query query_class }
    out = observe(schema)
    expect_no_foreign(out)
  end

  it "[preservation] F5b no finding on introspection in a policy schema (BaseObject names the policy)" do
    base = Class.new(ProbeObject) { authorize :read, policy: strict, model: doc }
    type = Class.new(base) { graphql_name "Doc"; field :notes, String, null: true, authorize: :manage }
    query_class = Class.new(base) { graphql_name "Query"; field :doc, type, null: true; field :docs, type.connection_type, null: true }
    schema = Class.new(base_schema) { use P_AUTH, adapter: :pundit; query query_class }
    expect_no_foreign(observe(schema))
  end

  it "[preservation] F8 interface rule; the found policy IS the named policy" do
    iface = interface_with { field :notes, String, null: true, authorize: :manage }
    type = doc_type(policy: ArmoryProbeSamePolicy, model: ArmoryProbeSame) { implements iface }
    out = observe(schema_of(type), "{ doc { notes } }", record: ArmoryProbeSame.new)
    expect(out[:served]).to be_nil
    expect_no_foreign(out)
  end

  it "[preservation] F8b input rule; the found policy IS the named policy" do
    input = Class.new(ProbeInput) { graphql_name "Same"; argument :raw, bool, required: false, authorize: :manage, model: ArmoryProbeSame }
    type = doc_type(policy: ArmoryProbeSamePolicy, model: ArmoryProbeSame) { field(:notes, String, null: true) { argument :filter, input, required: false } }
    out = observe(schema_of(type), "{ doc { notes(filter: { raw: true }) } }", record: ArmoryProbeSame.new)
    expect(out[:served]).to be_nil
    expect_no_foreign(out)
  end

  it "[preservation] F8c parent with no policy: rule; the found policy IS the named policy on the child" do
    parent = parent_type(model: ArmoryProbeSame) { field :notes, String, null: true, authorize: :manage }
    type = doc_type(parent, policy: ArmoryProbeSamePolicy, model: ArmoryProbeSame)
    out = observe(schema_of(type), "{ doc { notes } }", record: ArmoryProbeSame.new)
    expect(out[:served]).to be_nil
    expect_no_foreign(out)
  end


  # --- 3. Crashes and loading
  def shadowed_with(&args)
    parent = parent_type { field(:notes, String, null: true, &args) }
    doc_type(parent) { field :notes, String, null: true, override_reason: "probe" }
  end


  it "[preservation] C2 shadowed field with an unresolved LateBoundType argument" do
    type = shadowed_with { argument :x, GraphQL::Schema::LateBoundType.new("NoSuchType"), required: false }
    out = observe(schema_of(type))
    expect(out).not_to include(:audit_crash)
  end


  it "[preservation] C2c LateBoundType argument resolved by the schema" do
    input = rule_input("Late")
    type = doc_type do
      field(:other, String, null: true, authorize: :none, reason: "x") { argument :l, input, required: false }
      field(:notes, String, null: true) { argument :f, GraphQL::Schema::LateBoundType.new("Late"), required: false }
    end
    out = observe(schema_of(type))
    expect(out).not_to include(:audit_crash)
    expect(out[:foreign]).to include("Doc.notes(raw)")
  end

  it "[preservation] C3 plain input with plain args, plain field class, loads: argument" do
    plain_input = Class.new(GraphQL::Schema::InputObject) { graphql_name "PlainIn"; argument :s, String, required: false }
    target = doc_type
    holder = Class.new(ProbeObject) do
      graphql_name "Holder"
      authorize :read, policy: strict, model: doc
      field(:a, String, null: true) { argument :f, plain_input, required: false }
      field(:b, String, null: true) { argument :doc_id, GraphQL::Types::ID, required: false, loads: target, as: :the_doc }
    end
    out = observe(schema_of(holder))
    expect(out).not_to include(:audit_crash)
    expect_no_foreign(out)
  end

  it "[preservation] C2d shadowed field, LateBoundType naming a real type used elsewhere" do
    input = rule_input("Late")
    parent = parent_type { field(:notes, String, null: true) { argument :f, GraphQL::Schema::LateBoundType.new("Late"), required: false } }
    type = doc_type(parent) do
      field :notes, String, null: true, override_reason: "probe"
      field(:other, String, null: true) { argument :l, input, required: false }
    end
    out = observe(schema_of(type))
    expect(out).not_to include(:audit_crash)
  end

  it "[preservation] C2e LateBoundType argument under Schema::Visibility, not shadowed" do
    input = rule_input("Late")
    type = doc_type do
      field(:other, String, null: true) { argument :l, input, required: false }
      field(:notes, String, null: true) { argument :f, GraphQL::Schema::LateBoundType.new("Late"), required: false }
    end
    out = observe(schema_of(type, extra: proc { use GraphQL::Schema::Visibility, dynamic: true }))
    expect(out).not_to include(:audit_crash)
  end

  # --- 4. The advice
  it "[preservation] A1 rule moved to the class that names the policy clears and refuses" do
    iface = interface_with { field :other, String, null: true }
    type = doc_type do
      implements iface
      field :notes, String, null: true, authorize: :manage
    end
    out = observe(schema_of(type), "{ doc { notes } }")
    expect_no_foreign(out)
    expect(out[:served]).to be_nil
  end

  it "[preservation] A2 policy: moved to the parent clears and refuses" do
    parent = parent_type(policy: strict) { field :notes, String, null: true, authorize: :manage }
    child = Class.new(parent) { graphql_name "Doc" }
    out = observe(schema_of(child), "{ doc { notes } }")
    expect_no_foreign(out)
    expect(out[:served]).to be_nil
  end





  it "[preservation] A5 input rule moved to the field's own argument clears and refuses" do
    type = doc_type { field(:notes, String, null: true) { argument :raw, bool, required: false, authorize: :manage, model: doc } }
    out = observe(schema_of(type), "{ doc { notes(raw: true) } }")
    expect_no_foreign(out)
    expect(out[:served]).to be_nil
  end

  it "[preservation] A6 plain resolver turned into a Base resolver naming the policy clears and refuses" do
    resolver = base_resolver { argument :raw, bool, required: false, authorize: :manage, model: doc }
    out = observe(schema_of(doc_type { field :notes, resolver: resolver }), "{ doc { notes(raw: true) } }")
    expect_no_foreign(out)
    expect(out[:served]).to be_nil
  end

  # --- 5. Preservation dump: no policy: anywhere, every shape above
  it "[preservation] P1 no-policy schema dump (diff the jsonl A vs B on the host)" do
    input = rule_input
    iface = interface_with { field :iface_notes, String, null: true, authorize: :manage }
    parent = parent_type { field(:par_notes, String, null: true, authorize: :manage) { argument :raw, bool, required: false, authorize: :manage, model: doc } }
    type = Class.new(parent) do
      graphql_name "Doc"
      authorize :read, model: doc
      implements iface
      field(:notes, String, null: true) { argument :filter, input, required: false }
    end
    expect(observe(schema_of(type))[:foreign]).to eq([])
  end

  it "[preservation] P2 the dummy schemas of the suite" do
    schemas = ObjectSpace.each_object(Class).select { |klass| klass < GraphQL::Schema && klass.name }.sort_by(&:name)
    dump = schemas.map do |schema|
      report = P_AUTH::Audit.(schema)
      [schema.name, report.problems.map { |pb| [pb.kind, pb.path, pb.message.gsub(/0x\h+/, "0x")] }, report.bypasses.map { |by| [by.path, by.reason] }]
    end
    puts "INFO P2 schemas=#{schemas.map(&:name).inspect} foreign=#{dump.sum { |_, problems, _| problems.count { |kind, _, _| kind == :foreign_policy } }}"
    expect(dump.flat_map { |_, problems, _| problems.select { |kind, _, _| kind == :foreign_policy } }).to eq([])
  end
end
