# frozen_string_literal: true

require "json"
require "tmpdir"

# Probes for PR #42 (fix/audit-parent-mutation-fields). Written from the diff and docs/authorization.md, before reading the PR's specs.
# Every probe is labelled security (the feature must change its outcome) or preservation.
module PayloadProbeModels
  class Inv; end
end

RSpec.describe "payload audit probes" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:inv) { PayloadProbeModels::Inv }
  let(:refused) { armory::Adapters::Substitute.new(allow: false) }
  let(:allowed) { armory::Adapters::Substitute.new(allow: true) }
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
    bf = base_field
    Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class bf
    end
  end
  let(:base_payload) do
    Class.new(base_object) { authorize :none, reason: "covered by the mutation", covers_fields: true }
  end
  let(:base_mutation) do
    plugin = armory
    bf = base_field
    ba = base_argument
    bp = base_payload
    Class.new(GraphQL::Schema::Mutation) do
      include plugin::Base
      argument_class ba
      field_class bf
      object_class bp
    end
  end
  let(:base_relay_mutation) do
    plugin = armory
    bf = base_field
    ba = base_argument
    bp = base_payload
    Class.new(GraphQL::Schema::RelayClassicMutation) do
      include plugin::Base
      argument_class ba
      field_class bf
      object_class bp
    end
  end
  let(:base_subscription) do
    plugin = armory
    bf = base_field
    ba = base_argument
    bp = base_payload
    Class.new(GraphQL::Schema::Subscription) do
      include plugin::Base
      argument_class ba
      field_class bf
      object_class bp
    end
  end

  def mut(name, parent = base_mutation, &block)
    Class.new(parent) do
      graphql_name name
      class_eval(&block) if block
      define_method(:resolve) { |**| { secret: "S", errors: nil, other: "O" } } unless method_defined?(:resolve, false)
    end
  end

  def approve_mut(name = "A", parent = base_mutation)
    model = inv
    mut(name, parent) do
      authorize :approve, model: model
      field :secret, String, null: true, hash_key: :secret
    end
  end

  def root(name, &block)
    Class.new(base_object) do
      graphql_name name
      authorize :none, reason: "root", covers_fields: true
      field :ping, String, null: true, hash_key: :ping
      class_eval(&block) if block
    end
  end

  def schema_for(query_class, mutation_class = nil, adapter: refused, orphans: [], subscription_class: nil, &setup)
    plugin = armory
    Class.new(base_schema) do
      use plugin, adapter: adapter
      query query_class
      mutation mutation_class if mutation_class
      subscription subscription_class if subscription_class
      orphan_types(*orphans) unless orphans.empty?
      class_eval(&setup) if setup
    end
  end

  def resolve_type_to(type)
    proc { define_singleton_method(:resolve_type) { |_abstract, _object, _context| type } }
  end

  def audit(schema)
    armory::Audit.(schema)
  end

  def run_query(schema, text, root_value: {}, **options)
    execute_query(schema, text, root_value: root_value, context: {}, **options).to_h
  end

  def log(tag, report, extra = nil)
    kinds = report.problems.map { |problem| "#{problem.kind}@#{problem.path}" }
    STDOUT.puts "LOG|#{ENV['GRAPHQL_ARMORY_ENGINE']}|#{tag}|ok=#{report.ok?}|#{kinds.join(',')}|#{extra}"
  end

  # The invariant: a refused user reads the data with this query, so the audit must not say ok.
  def expect_exposure_reported(tag, schema, text, root_value)
    report = audit(schema)
    response = run_query(schema, text, root_value: root_value)
    log(tag, report, response.to_json)
    expect(response.to_json).to include('"S"'), "shape never served the data: #{response.to_json}"
    expect(report.ok?).to eq(false), "refused user read #{response.to_json} while the audit said ok; bypasses=#{report.bypasses.map(&:path)}"
  end

  # What the audit says about a denied payload field against what really answers for an allowed user.
  def expect_audit_matches_runtime(tag, schema, text, path, served:)
    report = audit(schema)
    response = run_query(schema, text)
    log(tag, report, response.to_json)
    data = response.to_json
    expect(data.include?('"S"')).to eq(served), "expected served=#{served}, got #{data}"
    flagged = report.problems.any? { |problem| problem.kind == :field_without_rule && problem.path == path }
    expect(flagged).to eq(!served), "denied=#{!served} but flagged=#{flagged}: #{report}"
  end

  S = { p: { secret: "S" } }.freeze

  # ---- 1. Reach a payload with no rule run ----------------------------------------------------------------------------

  it "S01 security: direct field returning a generated payload" do
    payload = approve_mut.payload_type
    query = root("Query") { field :p, payload, null: true, hash_key: :p }
    expect_exposure_reported("S01", schema_for(query), "{ p { secret } }", S)
  end

  it "S02 security: a list of the payload" do
    payload = approve_mut.payload_type
    query = root("Query") { field :p, [payload], null: true, hash_key: :p }
    expect_exposure_reported("S02", schema_for(query), "{ p { secret } }", { p: [{ secret: "S" }] })
  end

  it "S03 security: a non-null payload" do
    payload = approve_mut.payload_type
    query = root("Query") { field :p, payload, null: false, hash_key: :p }
    expect_exposure_reported("S03", schema_for(query), "{ p { secret } }", S)
  end

  it "S04 security: a connection of the payload" do
    payload = approve_mut.payload_type
    query = root("Query") { field :p, payload.connection_type, null: true, hash_key: :p }
    expect_exposure_reported("S04", schema_for(query), "{ p { nodes { secret } } }", { p: [{ secret: "S" }] })
  end

  it "S05 security: a connection with edges only, reached through an Edge" do
    payload = approve_mut.payload_type
    query = root("Query") { field :p, payload.connection_type, null: true, hash_key: :p }
    expect_exposure_reported("S05", schema_for(query), "{ p { edges { node { secret } } } }", { p: [{ secret: "S" }] })
  end

  it "S06 security: an interface the payload implements" do
    payload = approve_mut.payload_type
    bf = base_field
    iface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Result"
      field_class bf
      field :secret, String, null: true, hash_key: :secret
    end
    payload.implements(iface)
    query = root("Query") { field :p, iface, null: true, hash_key: :p }
    expect_exposure_reported("S06", schema_for(query, orphans: [payload], &resolve_type_to(payload)), "{ p { secret } }", S)
  end

  it "S07 security: a union member" do
    payload = approve_mut.payload_type
    union = Class.new(GraphQL::Schema::Union) do
      graphql_name "Res"
      possible_types payload
    end
    query = root("Query") { field :p, union, null: true, hash_key: :p }
    expect_exposure_reported("S07", schema_for(query, &resolve_type_to(payload)), "{ p { ... on APayload { secret } } }", S)
  end

  it "S08 security: a subclass of the payload" do
    payload = approve_mut.payload_type
    sub = Class.new(payload) { graphql_name "SubP" }
    query = root("Query") { field :p, sub, null: true, hash_key: :p }
    expect_exposure_reported("S08", schema_for(query), "{ p { secret } }", S)
  end

  it "S09 security: an interface's field returning the payload, on an implementer" do
    payload = approve_mut.payload_type
    bf = base_field
    iface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Holder"
      field_class bf
      field :p, payload, null: true, hash_key: :p
    end
    query = root("Query") { implements iface }
    expect_exposure_reported("S09", schema_for(query), "{ p { secret } }", S)
  end

  it "S10 security: a field naming its type with type:" do
    payload = approve_mut.payload_type
    query = root("Query") { field :p, type: payload, null: true, hash_key: :p }
    expect_exposure_reported("S10", schema_for(query), "{ p { secret } }", S)
  end

  it "S11 security: a plain Base resolver whose type is another mutation's payload" do
    payload = approve_mut.payload_type
    plugin = armory
    bf = base_field
    resolver = Class.new(GraphQL::Schema::Resolver) do
      include plugin::Base
      authorize :none, reason: "public lookup"
      type payload, null: true
      define_method(:resolve) { { secret: "S" } }
    end
    query = root("Query") { field :p, resolver: resolver }
    _ = bf
    expect_exposure_reported("S11", schema_for(query), "{ p { secret } }", {})
  end

  it "S12 security: payload_type shared with a :none mutation (the own_payload? exemption)" do
    a = approve_mut
    payload = a.payload_type
    b = mut("B") do
      authorize :none, reason: "public"
      payload_type payload
    end
    mutation = root("Mutation") do
      field :a, mutation: a
      field :b, mutation: b
    end
    expect_exposure_reported("S12", schema_for(root("Query"), mutation), "mutation { b { secret } }", {})
  end

  it "S13 security: payload_type reused by a mutation with no Base at all" do
    a = approve_mut
    payload = a.payload_type
    bf = base_field
    b = Class.new(GraphQL::Schema::Mutation) do
      graphql_name "B"
      field_class bf
      payload_type payload
      define_method(:resolve) { |**| { secret: "S" } }
    end
    mutation = root("Mutation") do
      field :a, mutation: a
      field :b, mutation: b
    end
    expect_exposure_reported("S13", schema_for(root("Query"), mutation), "mutation { b { secret } }", {})
  end

  it "S14 observation: a mutation with its own laxer rule reuses a stricter mutation's payload" do
    a = approve_mut
    payload = a.payload_type
    model = inv
    b = mut("B") do
      authorize :read, model: model
      payload_type payload
    end
    mutation = root("Mutation") do
      field :a, mutation: a
      field :b, mutation: b
    end
    report = audit(schema_for(root("Query"), mutation))
    log("S14", report)
    expect(report).to be_ok
  end

  it "S15 security: a Base mutation on graphql-ruby's default field class, payload reused by a query" do
    plugin = armory
    bp = base_payload
    model = inv
    a = Class.new(GraphQL::Schema::Mutation) do
      include plugin::Base
      object_class bp
      graphql_name "A"
      authorize :approve, model: model
      field :secret, String, null: true, hash_key: :secret
      define_method(:resolve) { |**| { secret: "S" } }
    end
    payload = a.payload_type
    query = root("Query") { field :p, payload, null: true, hash_key: :p }
    mutation = root("Mutation") { field :a, mutation: a }
    expect_exposure_reported("S15", schema_for(query, mutation), "{ p { secret } }", S)
  end

  it "S16 security: fields on a non-Base parent, Base child with a rule, payload reused by a query" do
    plugin = armory
    bf = base_field
    bp = base_payload
    model = inv
    parent = Class.new(GraphQL::Schema::Mutation) do
      field_class bf
      object_class bp
      graphql_name "Par"
      field :secret, String, null: true, hash_key: :secret
    end
    child = Class.new(parent) do
      include plugin::Base
      graphql_name "A"
      authorize :approve, model: model
      define_method(:resolve) { |**| { secret: "S" } }
    end
    payload = child.payload_type
    query = root("Query") { field :p, payload, null: true, hash_key: :p }
    mutation = root("Mutation") { field :a, mutation: child }
    expect_exposure_reported("S16", schema_for(query, mutation), "{ p { secret } }", S)
  end

  it "S17 security: every field inherited from a :none+covers parent, child has a rule, payload reused by a query" do
    model = inv
    parent = mut("Par") do
      authorize :none, reason: "base", covers_fields: true
      field :secret, String, null: true, hash_key: :secret
    end
    child = mut("A", parent) { authorize :approve, model: model }
    payload = child.payload_type
    query = root("Query") { field :p, payload, null: true, hash_key: :p }
    mutation = root("Mutation") { field :a, mutation: child }
    expect_exposure_reported("S17", schema_for(query, mutation), "{ p { secret } }", S)
  end

  it "S18 security: a hand-built payload holding fields copied from a mutation" do
    a = approve_mut
    copied = a.fields["secret"]
    hand = Class.new(base_payload) do
      graphql_name "Hand"
      add_field(copied, method_conflict_warning: false)
    end
    query = root("Query") { field :p, hand, null: true, hash_key: :p }
    expect_exposure_reported("S18", schema_for(query), "{ p { secret } }", S)
  end

  it "S19 security: the payload nested under another type" do
    payload = approve_mut.payload_type
    holder = Class.new(base_payload) do
      graphql_name "Holder"
      field :p, payload, null: true, hash_key: :p
    end
    query = root("Query") { field :h, holder, null: true, hash_key: :h }
    expect_exposure_reported("S19", schema_for(query), "{ h { p { secret } } }", { h: S })
  end

  it "S20 security: a hand-written shared payload_type reused by a query" do
    shared = Class.new(base_payload) do
      graphql_name "Shared"
      field :secret, String, null: true, hash_key: :secret
    end
    model = inv
    a = mut("A") do
      authorize :approve, model: model
      payload_type shared
    end
    query = root("Query") { field :p, shared, null: true, hash_key: :p }
    mutation = root("Mutation") { field :a, mutation: a }
    expect_exposure_reported("S20", schema_for(query, mutation), "{ p { secret } }", S)
  end

  it "S21 security: a subscription's payload reused by a query" do
    model = inv
    sub = Class.new(base_subscription) do
      graphql_name "Sub"
      authorize :read, model: model
      field :secret, String, null: true, hash_key: :secret
    end
    payload = sub.payload_type
    query = root("Query") { field :p, payload, null: true, hash_key: :p }
    subscription = root("Subscription") { field :s, subscription: sub }
    expect_exposure_reported("S21", schema_for(query, subscription_class: subscription), "{ p { secret } }", S)
  end

  it "S22 security: a plain field on the mutation root returning the payload" do
    a = approve_mut
    payload = a.payload_type
    mutation = root("Mutation") do
      field :a, mutation: a
      field :peek, payload, null: true, hash_key: :p
    end
    expect_exposure_reported("S22", schema_for(root("Query"), mutation), "mutation { peek { secret } }", S)
  end

  it "S23 security: a mutation field whose return type is overridden with another mutation's payload" do
    a = approve_mut
    payload = a.payload_type
    public_one = mut("Pub") { authorize :none, reason: "public" }
    mutation = root("Mutation") do
      field :a, mutation: a
      field :pub, payload, null: true, resolver: public_one
    end
    expect_exposure_reported("S23", schema_for(root("Query"), mutation), "mutation { pub { secret } }", {})
  end

  it "S24 security: a :none mutation whose payload_type subclasses another mutation's payload" do
    a = approve_mut
    sub = Class.new(a.payload_type) { graphql_name "SubP" }
    b = mut("B") do
      authorize :none, reason: "public"
      payload_type sub
    end
    mutation = root("Mutation") do
      field :a, mutation: a
      field :b, mutation: b
    end
    expect_exposure_reported("S24", schema_for(root("Query"), mutation), "mutation { b { secret } }", {})
  end

  it "S25 security: an interface whose membership of the payload is hidden with no request" do
    payload = approve_mut.payload_type
    bf = base_field
    iface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Result"
      field_class bf
      field :secret, String, null: true, hash_key: :secret
    end
    hidden = Class.new(GraphQL::Schema::TypeMembership) do
      define_method(:visible?) { |context| context.respond_to?(:key?) && context.key?(:staff) }
    end
    iface.type_membership_class(hidden) if iface.respond_to?(:type_membership_class)
    payload.implements(iface)
    query = root("Query") { field :p, iface, null: true, hash_key: :p }
    schema = schema_for(query, orphans: [payload], &resolve_type_to(payload))
    report = audit(schema)
    response = execute_query(schema, "{ p { secret } }", root_value: S, context: { staff: true }).to_h
    log("S25", report, response.to_json)
    expect(response.to_json).to include('"S"')
    expect(report.ok?).to eq(false), "refused user read #{response.to_json} while the audit said ok"
  end

  it "S26 security: a dynamic Schema::Visibility schema, payload behind an interface" do
    payload = approve_mut.payload_type
    bf = base_field
    iface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Result"
      field_class bf
      field :secret, String, null: true, hash_key: :secret
    end
    payload.implements(iface)
    query = root("Query") { field :p, iface, null: true, hash_key: :p }
    rt = resolve_type_to(payload)
    schema = schema_for(query, orphans: [payload]) do
      use GraphQL::Schema::Visibility, dynamic: true
      class_eval(&rt)
    end
    expect_exposure_reported("S26", schema, "{ p { secret } }", S)
  end

  it "S27 security: a payload with one bypassed field and one covered field" do
    model = inv
    a = mut("A") do
      authorize :approve, model: model
      field :other, String, null: true, hash_key: :other, authorize: :none, reason: "public"
      field :secret, String, null: true, hash_key: :secret
    end
    payload = a.payload_type
    query = root("Query") { field :p, payload, null: true, hash_key: :p }
    expect_exposure_reported("S27", schema_for(query), "{ p { secret } }", S)
  end

  it "S28 security: a RelayClassicMutation's payload" do
    a = approve_mut("A", base_relay_mutation)
    payload = a.payload_type
    query = root("Query") { field :p, payload, null: true, hash_key: :p }
    expect_exposure_reported("S28", schema_for(query), "{ p { secret } }", S)
  end

  it "S29 security: a query field with extras and a non-Base field class" do
    payload = approve_mut.payload_type
    query = root("Query") do
      field_class GraphQL::Schema::Field
      field :p, payload, null: true, hash_key: :p, extras: [:lookahead]
    end
    expect_exposure_reported("S29", schema_for(query), "{ p { secret } }", S)
  end

  it "S30 security: a mutation with a rule reached from the query root through resolver: of a different mutation's subclass with :none" do
    a = approve_mut
    child = mut("Kid", a) { authorize :none, reason: "kid is open" }
    payload = child.payload_type
    query = root("Query") { field :p, payload, null: true, hash_key: :p }
    expect_exposure_reported("S30", schema_for(query), "{ p { secret } }", S)
  end

  it "S31 security: a query field late-bound by a type name" do
    a = approve_mut
    payload = a.payload_type
    late = GraphQL::Schema::LateBoundType.new("APayload")
    query = root("Query") { field :p, late, null: true, hash_key: :p }
    mutation = root("Mutation") { field :a, mutation: a }
    plugin = armory
    adapter = refused
    schema = Class.new(base_schema) do
      use plugin, adapter: adapter
      mutation mutation
      orphan_types payload
      query query
    end
    expect_exposure_reported("S31", schema, "{ p { secret } }", S)
  end

  def hidden_payload
    payload = approve_mut.payload_type
    payload.define_singleton_method(:visible?) { |context| context[:staff] == true }
    payload
  end

  def staff_run(tag, schema, text)
    report = audit(schema)
    response = execute_query(schema, text, root_value: S, context: { staff: true }).to_h
    log(tag, report, response.to_json)
    expect(response.to_json).to include('"S"'), "not served: #{response.to_json}"
    expect(report.ok?).to eq(false), "refused user read #{response.to_json} while the audit said ok"
  end

  it "S32 security: dynamic Schema::Visibility, a payload hidden with no request, behind an interface" do
    payload = hidden_payload
    bf = base_field
    iface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Result"
      field_class bf
      field :secret, String, null: true, hash_key: :secret, authorize: :none, reason: "the interface's"
    end
    payload.implements(iface)
    query = root("Query") { field :p, iface, null: true, hash_key: :p }
    rt = resolve_type_to(payload)
    schema = schema_for(query, orphans: [payload]) do
      use GraphQL::Schema::Visibility, dynamic: true
      class_eval(&rt)
    end
    staff_run("S32", schema, "{ p { secret } }")
  end

  it "S33 security: dynamic Schema::Visibility, a payload hidden with no request, in a union" do
    payload = hidden_payload
    union = Class.new(GraphQL::Schema::Union) do
      graphql_name "Res"
      possible_types payload
    end
    query = root("Query") { field :p, union, null: true, hash_key: :p }
    rt = resolve_type_to(payload)
    schema = schema_for(query) do
      use GraphQL::Schema::Visibility, dynamic: true
      class_eval(&rt)
    end
    staff_run("S33", schema, "{ p { ... on APayload { secret } } }")
  end

  it "S34 security: the warden (no Visibility), a payload hidden with no request, in a union" do
    payload = hidden_payload
    union = Class.new(GraphQL::Schema::Union) do
      graphql_name "Res"
      possible_types payload
    end
    query = root("Query") { field :p, union, null: true, hash_key: :p }
    staff_run("S34", schema_for(query, &resolve_type_to(payload)), "{ p { ... on APayload { secret } } }")
  end

  it "S35 security: an interface sharing no field with the payload, reached through a fragment" do
    payload = approve_mut.payload_type
    bf = base_field
    iface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Result"
      field_class bf
      field :at, String, null: true, authorize: :none, reason: "public", hash_key: :at
    end
    payload.implements(iface)
    query = root("Query") { field :p, iface, null: true, hash_key: :p }
    expect_exposure_reported("S35", schema_for(query, orphans: [payload], &resolve_type_to(payload)), "{ p { ... on APayload { secret } } }", S)
  end

  # ---- 3/5. Audit against the real run of a mutation: allowed user, so the mutation runs ---------------------------------

  def run_mut(tag, klass, path, served:, adapter: allowed)
    mutation = root("Mutation") { field :m, mutation: klass }
    schema = schema_for(root("Query"), mutation, adapter: adapter)
    expect_audit_matches_runtime(tag, schema, "mutation { m { secret } }", path, served: served)
  end

  it "D01 security: field on a parent with no rule, child with a rule" do
    model = inv
    parent = mut("Par") { field :secret, String, null: true, hash_key: :secret }
    child = mut("M", parent) { authorize :approve, model: model }
    run_mut("D01", child, "MPayload.secret", served: false)
  end

  it "D02 security: field on a :none parent with no covers, child with a rule" do
    model = inv
    parent = mut("Par") do
      authorize :none, reason: "x"
      field :secret, String, null: true, hash_key: :secret
    end
    child = mut("M", parent) { authorize :approve, model: model }
    run_mut("D02", child, "MPayload.secret", served: false)
  end

  it "D03 preservation: field on a :none+covers parent, child with a rule" do
    model = inv
    parent = mut("Par") do
      authorize :none, reason: "x", covers_fields: true
      field :secret, String, null: true, hash_key: :secret
    end
    child = mut("M", parent) { authorize :approve, model: model }
    run_mut("D03", child, "MPayload.secret", served: true)
  end

  it "D04 security: field on a grandparent with no rule, parent and child with rules" do
    model = inv
    grand = mut("Grand") { field :secret, String, null: true, hash_key: :secret }
    parent = mut("Par", grand) { authorize :approve, model: model }
    child = mut("M", parent) { authorize :approve, model: model }
    run_mut("D04", child, "MPayload.secret", served: false)
  end

  it "D05 preservation: field on a parent with a rule, child inherits" do
    model = inv
    parent = mut("Par") do
      authorize :approve, model: model
      field :secret, String, null: true, hash_key: :secret
    end
    run_mut("D05", mut("M", parent), "MPayload.secret", served: true)
  end

  it "D06 security: child :none, no covers, field of its own" do
    child = mut("M") do
      authorize :none, reason: "x"
      field :secret, String, null: true, hash_key: :secret
    end
    run_mut("D06", child, "MPayload.secret", served: false)
  end

  it "D07 preservation: child :none with covers, field of its own" do
    child = mut("M") do
      authorize :none, reason: "x", covers_fields: true
      field :secret, String, null: true, hash_key: :secret
    end
    run_mut("D07", child, "MPayload.secret", served: true)
  end

  it "D08 security: authorize: true, child :none" do
    child = mut("M") do
      authorize :none, reason: "x", covers_fields: true
      field :secret, String, null: true, hash_key: :secret, authorize: true
    end
    run_mut("D08", child, "MPayload.secret", served: false)
  end

  it "D09 security: authorize: true on a parent with no rule, child with a rule" do
    model = inv
    parent = mut("Par") { field :secret, String, null: true, hash_key: :secret, authorize: true }
    child = mut("M", parent) { authorize :approve, model: model }
    run_mut("D09", child, "MPayload.secret", served: false)
  end

  it "D10 preservation: authorize: true with a rule on the owner" do
    model = inv
    child = mut("M") do
      authorize :approve, model: model
      field :secret, String, null: true, hash_key: :secret, authorize: true
    end
    run_mut("D10", child, "MPayload.secret", served: true)
  end

  it "D11 preservation: field on a parent with a rule, child :none serves it, documented open on purpose" do
    model = inv
    parent = mut("Par") do
      authorize :approve, model: model
      field :secret, String, null: true, hash_key: :secret
    end
    child = mut("M", parent) { authorize :none, reason: "open" }
    run_mut("D11", child, "MPayload.secret", served: true)
  end

  it "D12 preservation: a child redefining a parent's field, parent has no rule" do
    model = inv
    parent = mut("Par") { field :secret, String, null: true, hash_key: :secret }
    child = mut("M", parent) do
      authorize :approve, model: model
      field :secret, String, null: true, hash_key: :secret
    end
    run_mut("D12", child, "MPayload.secret", served: true)
  end

  it "D13 preservation: field on a parent with no rule declaring authorize: :none" do
    model = inv
    parent = mut("Par") { field :secret, String, null: true, hash_key: :secret, authorize: :none, reason: "public" }
    child = mut("M", parent) { authorize :approve, model: model }
    run_mut("D13", child, "MPayload.secret", served: true)
  end

  it "D14 security: on_denied: :errors with the errors field on a parent with no rule" do
    model = inv
    parent = mut("Par") { field :errors, GraphQL::Types::JSON, null: true, hash_key: :errors }
    child = mut("M", parent) do
      authorize :approve, model: model, on_denied: :errors
      field :secret, String, null: true, hash_key: :secret
    end
    mutation = root("Mutation") { field :m, mutation: child }
    schema = schema_for(root("Query"), mutation, adapter: refused)
    report = audit(schema)
    response = run_query(schema, "mutation { m { errors } }")
    log("D14", report, response.to_json)
    expect(response.dig("data", "m", "errors")).to be_nil
    expect(report.problems.map(&:path)).to include("MPayload.errors")
  end

  it "D15 preservation: on_denied: :errors with the errors field on the child" do
    model = inv
    child = mut("M") do
      authorize :approve, model: model, on_denied: :errors
      field :errors, GraphQL::Types::JSON, null: true, hash_key: :errors
    end
    mutation = root("Mutation") { field :m, mutation: child }
    schema = schema_for(root("Query"), mutation, adapter: refused)
    report = audit(schema)
    response = run_query(schema, "mutation { m { errors } }")
    log("D15", report, response.to_json)
    expect(response.dig("data", "m", "errors").to_json).to include("FORBIDDEN")
    expect(report).to be_ok
  end

  it "D16 security: a RelayClassicMutation with its field on a parent with no rule" do
    model = inv
    parent = mut("Par", base_relay_mutation) { field :secret, String, null: true, hash_key: :secret }
    child = mut("M", parent) { authorize :approve, model: model }
    mutation = root("Mutation") { field :m, mutation: child }
    schema = schema_for(root("Query"), mutation, adapter: allowed)
    expect_audit_matches_runtime("D16", schema, "mutation { m(input: {}) { secret } }", "MPayload.secret", served: false)
  end

  it "D17 preservation: clientMutationId is served and clean" do
    model = inv
    child = mut("M", base_relay_mutation) do
      authorize :approve, model: model
      field :secret, String, null: true, hash_key: :secret
    end
    mutation = root("Mutation") { field :m, mutation: child }
    schema = schema_for(root("Query"), mutation, adapter: allowed)
    report = audit(schema)
    response = run_query(schema, 'mutation { m(input: {clientMutationId: "cid"}) { clientMutationId secret } }')
    log("D17", report, response.to_json)
    expect(response.dig("data", "m", "clientMutationId")).to eq("cid")
    expect(report).to be_ok
  end

  xit "D18 observation: authorize: true on a non-Base mutation's field is denied; what does the audit say" do
    bf = base_field
    bp = base_payload
    klass = Class.new(GraphQL::Schema::Mutation) do
      field_class bf
      object_class bp
      graphql_name "M"
      field :secret, String, null: true, hash_key: :secret, authorize: true
      define_method(:resolve) { |**| { secret: "S" } }
    end
    mutation = root("Mutation") { field :m, mutation: klass }
    schema = schema_for(root("Query"), mutation, adapter: allowed)
    report = audit(schema)
    response = run_query(schema, "mutation { m { secret } }")
    log("D18", report, response.to_json)
    expect(report.ok?).to eq(false), "denied at runtime, audit ok: #{response.to_json}"
  end

  xit "D19 observation: a mutation with no Base at all and no rule, audit vs run" do
    bf = base_field
    bp = base_payload
    klass = Class.new(GraphQL::Schema::Mutation) do
      field_class bf
      object_class bp
      graphql_name "M"
      field :secret, String, null: true, hash_key: :secret
      define_method(:resolve) { |**| { secret: "S" } }
    end
    mutation = root("Mutation") { field :m, mutation: klass }
    schema = schema_for(root("Query"), mutation, adapter: refused)
    report = audit(schema)
    response = run_query(schema, "mutation { m { secret } }")
    log("D19", report, response.to_json)
    expect(report.ok?).to eq(false), "refused user read #{response.to_json} while the audit said ok"
  end

  xit "D20 observation: a field on an object_class parent :none no covers, generated payload parent covers" do
    model = inv
    base = Class.new(base_object) do
      authorize :none, reason: "x"
      field :secret, String, null: true, hash_key: :secret
    end
    covering = Class.new(base) { authorize :none, reason: "y", covers_fields: true }
    klass = mut("M") do
      object_class covering
      authorize :approve, model: model
    end
    mutation = root("Mutation") { field :m, mutation: klass }
    schema = schema_for(root("Query"), mutation, adapter: allowed)
    report = audit(schema)
    response = run_query(schema, "mutation { m { secret } }")
    log("D20", report, response.to_json)
    expect(response.dig("data", "m", "secret")).to be_nil
    expect(report.ok?).to eq(false), "denied at runtime, audit ok: #{response.to_json}"
  end

  # ---- Subscriptions ------------------------------------------------------------------------------------------------------

  it "D21 security: a subscription's field on a parent with no rule is reported" do
    model = inv
    parent = Class.new(base_subscription) do
      graphql_name "Par"
      field :secret, String, null: true, hash_key: :secret
    end
    child = Class.new(parent) do
      graphql_name "M"
      authorize :read, model: model
    end
    subscription = root("Subscription") { field :s, subscription: child }
    field = child.payload_type.fields["secret"]
    report = audit(schema_for(root("Query"), subscription_class: subscription))
    log("D21", report)
    expect(field.armory_denied_by_owner?).to eq(true) if field.respond_to?(:armory_denied_by_owner?)
    expect(report.problems.map(&:path)).to include("MPayload.secret")
  end

  it "D22 preservation: a subscription with its own rule and field is clean" do
    model = inv
    child = Class.new(base_subscription) do
      graphql_name "M"
      authorize :read, model: model
      field :secret, String, null: true, hash_key: :secret
    end
    subscription = root("Subscription") { field :s, subscription: child }
    report = audit(schema_for(root("Query"), subscription_class: subscription))
    log("D22", report)
    expect(report).to be_ok
  end

  # ---- 4. False positives -------------------------------------------------------------------------------------------------

  it "F01 preservation: field :x, mutation: M used twice" do
    a = approve_mut
    mutation = root("Mutation") do
      field :a, mutation: a
      field :again, mutation: a
    end
    report = audit(schema_for(root("Query"), mutation))
    log("F01", report)
    expect(report).to be_ok
  end

  it "F02 preservation: resolver: M on the mutation root" do
    a = approve_mut
    mutation = root("Mutation") { field :a, resolver: a }
    report = audit(schema_for(root("Query"), mutation))
    log("F02", report)
    expect(report).to be_ok
  end

  it "F03 preservation: a shared payload_type by two mutations with rules" do
    shared = Class.new(base_payload) do
      graphql_name "Shared"
      field :secret, String, null: true, hash_key: :secret
    end
    model = inv
    a = mut("A") do
      authorize :approve, model: model
      payload_type shared
    end
    b = mut("B") do
      authorize :approve, model: model
      payload_type shared
    end
    mutation = root("Mutation") do
      field :a, mutation: a
      field :b, mutation: b
    end
    report = audit(schema_for(root("Query"), mutation))
    log("F03", report)
    expect(report).to be_ok
  end

  it "F04 preservation: the install template's base mutation and base classes" do
    plugin = armory
    bf = base_field
    ba = base_argument
    bp = base_payload
    input = Class.new(GraphQL::Schema::InputObject) { include plugin::Base; argument_class ba }
    tpl = Class.new(GraphQL::Schema::RelayClassicMutation) do
      include plugin::Base
      argument_class ba
      field_class bf
      input_object_class input
      object_class bp
    end
    model = inv
    child = mut("M", tpl) do
      authorize :approve, model: model
      argument :name, String, required: false
      field :secret, String, null: true, hash_key: :secret
    end
    mutation = root("Mutation") { field :m, mutation: child }
    schema = schema_for(root("Query"), mutation, adapter: allowed)
    report = audit(schema)
    response = run_query(schema, "mutation { m(input: {name: \"n\"}) { secret } }")
    log("F04", report, response.to_json)
    expect(response.dig("data", "m", "secret")).to eq("S")
    expect(report).to be_ok
  end

  it "F05 preservation: a payload that holds Query and a field returning an ordinary object" do
    query = root("Query")
    other = Class.new(base_payload) do
      graphql_name "Other"
      field :v, String, null: true, hash_key: :v
    end
    model = inv
    a = mut("A") do
      authorize :approve, model: model
      field :query, query, null: true
      field :other, other, null: true, hash_key: :other
    end
    mutation = root("Mutation") { field :a, mutation: a }
    report = audit(schema_for(query, mutation))
    log("F05", report)
    expect(report).to be_ok
  end

  it "F06 preservation: a schema with no mutations" do
    report = audit(schema_for(root("Query")))
    log("F06", report)
    expect(report).to be_ok
  end

  it "F07 preservation: observe: on an object's field keeps its own report and adds nothing" do
    model = inv
    thing = Class.new(base_object) do
      graphql_name "Thing"
      authorize :read, model: model
      field :v, String, null: true, hash_key: :v, authorize: :manage, observe: "rollout"
    end
    a = approve_mut
    query = root("Query") { field :t, thing, null: true, hash_key: :t }
    mutation = root("Mutation") { field :a, mutation: a }
    report = audit(schema_for(query, mutation))
    log("F07", report)
    expect(report.problems.map(&:kind).uniq).to eq([:observed])
  end

  it "F08 preservation: an unused mutation's payload reachable nowhere adds nothing" do
    approve_mut
    report = audit(schema_for(root("Query")))
    log("F08", report)
    expect(report).to be_ok
  end

  it "F09 preservation: null_session shape, no actor at all, refused and clean" do
    a = approve_mut
    mutation = root("Mutation") { field :a, mutation: a }
    schema = schema_for(root("Query"), mutation, adapter: armory::Adapters::Substitute.new(allow: false, actor: nil))
    report = audit(schema)
    response = run_query(schema, "mutation { a { secret } }")
    log("F09", report, response.to_json)
    expect(response.to_json).not_to include('"S"')
    expect(report).to be_ok
  end

  it "F10 preservation: the mutation's own payload reached by its own field through a union-free subclass mutation" do
    a = approve_mut
    child = mut("Kid", a)
    mutation = root("Mutation") do
      field :a, mutation: a
      field :kid, mutation: child
    end
    report = audit(schema_for(root("Query"), mutation))
    log("F10", report)
    expect(report).to be_ok
  end

  xit "F11 observation: an interface every payload implements, query field returning other implementers only" do
    bf = base_field
    iface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Stamped"
      field_class bf
      field :at, String, null: true, authorize: :none, reason: "public", hash_key: :at
    end
    a = approve_mut
    a.payload_type.implements(iface)
    plain = Class.new(base_payload) do
      graphql_name "Plain"
      implements iface
    end
    query = root("Query") { field :stamped, iface, null: true, hash_key: :s }
    mutation = root("Mutation") { field :a, mutation: a }
    report = audit(schema_for(query, mutation, orphans: [plain], &resolve_type_to(plain)))
    log("F11", report)
    expect(report).to be_ok
  end

  # ---- 7. Audit robustness ---------------------------------------------------------------------------------------------

  it "R01 preservation: a shadowed field whose constant type never resolved, with a mutation in the schema" do
    a = approve_mut
    parent = Class.new(base_payload) do
      graphql_name "ParObj"
      field :x, "PayloadProbeModels::NoSuchType", null: true
    end
    child = Class.new(parent) do
      graphql_name "Kid"
      field :x, String, null: true, hash_key: :x, override_reason: "narrowed"
    end
    query = root("Query") { field :k, child, null: true, hash_key: :k }
    mutation = root("Mutation") { field :a, mutation: a }
    report = audit(schema_for(query, mutation))
    log("R01", report)
    expect(report.problems.map(&:kind)).not_to include(:payload_outside_mutation)
  end

  it "R02 preservation: the same shadowed field with no mutation in the schema (control)" do
    parent = Class.new(base_payload) do
      graphql_name "ParObj"
      field :x, "PayloadProbeModels::NoSuchType", null: true
    end
    child = Class.new(parent) do
      graphql_name "Kid"
      field :x, String, null: true, hash_key: :x, override_reason: "narrowed"
    end
    query = root("Query") { field :k, child, null: true, hash_key: :k }
    report = audit(schema_for(query))
    log("R02", report)
    expect(report.problems.map(&:kind)).not_to include(:payload_outside_mutation)
  end

  it "R03 preservation: static Schema::Visibility profiles with a field returning an interface and a mutation" do
    a = approve_mut
    bf = base_field
    iface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Result"
      field_class bf
      field :v, String, null: true, authorize: :none, reason: "public", hash_key: :v
    end
    plain = Class.new(base_payload) do
      graphql_name "Plain"
      implements iface
    end
    query = root("Query") { field :r, iface, null: true, hash_key: :r }
    mutation = root("Mutation") { field :a, mutation: a }
    rt = resolve_type_to(plain)
    schema = schema_for(query, mutation, orphans: [plain]) do
      use GraphQL::Schema::Visibility, profiles: { public: {} }
      class_eval(&rt)
    end
    report = audit(schema)
    log("R03", report)
    expect(report).to be_ok
  end

  it "R04 security: static Schema::Visibility profiles, payload behind an interface" do
    a = approve_mut
    payload = a.payload_type
    bf = base_field
    iface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Result"
      field_class bf
      field :secret, String, null: true, hash_key: :secret
    end
    payload.implements(iface)
    query = root("Query") { field :r, iface, null: true, hash_key: :r }
    rt = resolve_type_to(payload)
    schema = schema_for(query, orphans: [payload]) do
      use GraphQL::Schema::Visibility, profiles: { public: {} }
      class_eval(&rt)
    end
    report = audit(schema)
    log("R04", report)
    expect(report.ok?).to eq(false)
  end

  it "R05 security: payload behind a union with static visibility profiles" do
    payload = approve_mut.payload_type
    union = Class.new(GraphQL::Schema::Union) do
      graphql_name "Res"
      possible_types payload
    end
    query = root("Query") { field :p, union, null: true, hash_key: :p }
    rt = resolve_type_to(payload)
    schema = schema_for(query) do
      use GraphQL::Schema::Visibility, profiles: { public: {} }
      class_eval(&rt)
    end
    report = audit(schema)
    log("R05", report)
    expect(report.ok?).to eq(false)
  end

  it "R07 observation: cost on a large schema" do
    b = base_payload
    types = Array.new(1500) do |i|
      Class.new(b) do
        graphql_name "T#{i}"
        field :a, String, null: true, hash_key: :a
        field :b, String, null: true, hash_key: :b
        field :c, String, null: true, hash_key: :c
      end
    end
    a = approve_mut
    query = root("Query") do
      types.each_with_index { |type, i| field :"t#{i}", type, null: true, hash_key: :"t#{i}" }
    end
    mutation = root("Mutation") { field :a, mutation: a }
    schema = schema_for(query, mutation)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    report = audit(schema)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    STDOUT.puts "COST|#{elapsed.round(2)}s"
    expect(report).to be_ok
  end

  it "R08 preservation: a baseline accepts the new kind and fails on a new reuse" do
    payload = approve_mut.payload_type
    query = root("Query") { field :p, payload, null: true, hash_key: :p }
    report = audit(schema_for(query))
    expect(report.problems.map(&:kind)).to include(:payload_outside_mutation)
    expect(report.reach_of(report.problems.first)).to include("field:Query.p:APayload")
    baseline = armory::Audit::Baseline.from(report)
    expect(baseline.entries.map(&:kind)).to include("payload_outside_mutation")
    second = root("Query") do
      field :p, payload, null: true, hash_key: :p
      field :q, payload, null: true, hash_key: :q
    end
    report2 = audit(schema_for(second))
    Dir.mktmpdir do |dir|
      path = File.join(dir, "b.json")
      armory::Audit::Baseline.write(report, path)
      loaded = armory::Audit::Baseline.load(path)
      expect(loaded.(report).passes?).to eq(true)
      compared = loaded.(report2)
      STDOUT.puts "BASE|#{compared.passes?}|#{compared.new_problems.map(&:path)}"
      expect(compared.passes?).to eq(false)
      expect(compared.new_problems.map(&:path)).to eq(["Query.q"])
    end
  end

  it "R09 observation: message order for an interface with several payloads depends on load order" do
    bf = base_field
    build = lambda do |first_name, second_name|
      first = approve_mut(first_name).payload_type
      second = approve_mut(second_name).payload_type
      iface = Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Result"
        field_class bf
        field :at, String, null: true, authorize: :none, reason: "public", hash_key: :at
      end
      first.implements(iface)
      second.implements(iface)
      query = root("Query") { field :r, iface, null: true, hash_key: :r }
      schema_for(query, orphans: [first, second]) { define_singleton_method(:resolve_type) { |*| first } }
    end
    one = audit(build.call("A", "B")).problems.find { |problem| problem.kind == :payload_outside_mutation }
    two = audit(build.call("B", "A")).problems.find { |problem| problem.kind == :payload_outside_mutation }
    STDOUT.puts "ORDER|#{one&.message&.slice(0, 40)}|#{two&.message&.slice(0, 40)}"
    expect(one.message).to eq(two.message)
  end

  it "R10 preservation: static Schema::Visibility profiles, a query and one mutation with a rule, nothing else" do
    a = approve_mut
    mutation = root("Mutation") { field :a, mutation: a }
    schema = schema_for(root("Query"), mutation) { use GraphQL::Schema::Visibility, profiles: { public: {} } }
    report = audit(schema)
    log("R10", report)
    expect(report).to be_ok
  end

  # ---- 6. Differential: every declared/owner combination, compared between the branch and main ------------------------------

  it "X01 preservation: armory_rule_for and Field#authorized? table (compare DIFF lines between copies)" do
    plugin = armory
    model = inv
    bf = base_field
    bare_object = base_object
    declare = proc do
      field :n, String, null: true, hash_key: :n
      field :t, String, null: true, hash_key: :t, authorize: true
      field :c, String, null: true, hash_key: :c, authorize: :none, reason: "x"
      field :a, String, null: true, hash_key: :a, authorize: :manage
    end
    res_base = Class.new(GraphQL::Schema::Resolver) do
      include plugin::Base
      type String, null: true
      authorize :read, model: model
      define_method(:resolve) { "r" }
    end
    res_plain = Class.new(GraphQL::Schema::Resolver) do
      type String, null: true
      define_method(:resolve) { "r" }
    end
    owners = {}
    owners["ObjRule"] = Class.new(bare_object) { graphql_name "ObjRule"; authorize :read, model: model; class_eval(&declare) }
    owners["ObjNone"] = Class.new(bare_object) { graphql_name "ObjNone"; authorize :none, reason: "x"; class_eval(&declare) }
    owners["ObjCov"] = Class.new(bare_object) { graphql_name "ObjCov"; authorize :none, reason: "x", covers_fields: true; class_eval(&declare) }
    owners["ObjNil"] = Class.new(bare_object) { graphql_name "ObjNil"; class_eval(&declare) }
    owners["ObjPlain"] = Class.new(GraphQL::Schema::Object) { field_class bf; graphql_name "ObjPlain"; class_eval(&declare) }
    owners["ObjRes"] = Class.new(bare_object) do
      graphql_name "ObjRes"
      authorize :none, reason: "x"
      field :rb, resolver: res_base
      field :rp, resolver: res_plain
    end
    owners["MutRule"] = mut("MutRule") { authorize :approve, model: model; class_eval(&declare) }
    owners["MutNone"] = mut("MutNone") { authorize :none, reason: "x"; class_eval(&declare) }
    owners["MutCov"] = mut("MutCov") { authorize :none, reason: "x", covers_fields: true; class_eval(&declare) }
    owners["MutNil"] = mut("MutNil") { class_eval(&declare) }
    owners["MutPlain"] = Class.new(GraphQL::Schema::Mutation) { field_class bf; graphql_name "MutPlain"; class_eval(&declare) }
    iface_of = lambda do |name|
      Module.new do
        include GraphQL::Schema::Interface
        graphql_name name
        field_class bf
        field :n, String, null: true, hash_key: :n
        field :a, String, null: true, hash_key: :a, authorize: :manage
        field :c, String, null: true, hash_key: :c, authorize: :none, reason: "x"
      end
    end
    open_iface = iface_of.call("IfaceCovered")
    bypass_iface = iface_of.call("IfaceBypassed")
    owners["IfaceCovered"] = open_iface
    owners["IfaceBypassed"] = bypass_iface
    impl = Class.new(bare_object) { graphql_name "Impl"; authorize :read, model: model; implements open_iface }
    impl_bypass = Class.new(bare_object) { graphql_name "ImplB"; authorize :none, reason: "x"; implements bypass_iface }
    query = root("Query")
    mutation_owners = owners.select { |key, _| key.start_with?("Mut") }
    mutation = root("Mutation") { mutation_owners.each { |key, klass| field key.downcase.to_sym, mutation: klass } }
    objects = owners.select { |key, _| key.start_with?("Obj") }.values
    [["allow", allowed], ["refuse", refused]].each do |label, adapter|
      schema = schema_for(query, mutation, adapter: adapter, orphans: [*objects, impl, impl_bypass]) { define_singleton_method(:resolve_type) { |*| nil } }
      context = GraphQL::Query.new(schema, "{ ping }").context
      owners.each do |name, owner|
        owner.own_fields.each_value do |field|
          field = Array(field).first
          decision = begin
            rule = field.send(:armory_rule_for, owner, context)
            rule.respond_to?(:action) ? "Rule(#{rule.action})" : rule.inspect
          rescue StandardError => error
            "raise #{error.class}"
          end
          answer = begin
            field.authorized?(PayloadProbeModels::Inv.new, {}, context)
          rescue StandardError => error
            "raise #{error.class}"
          end
          answer = answer.first if answer.is_a?(Array)
          STDOUT.puts "DIFF|#{ENV['GRAPHQL_ARMORY_ENGINE']}|#{label}|#{name}.#{field.original_name}|#{decision}|#{answer}"
          next unless field.respond_to?(:armory_denied_by_owner?) && [nil, true].include?(field.armory_declared)

          STDOUT.puts "DENIED|#{label}|#{name}.#{field.original_name}|denied=#{field.armory_denied_by_owner?}|rule=#{decision}"
        end
      end
    end
  end

  it "X02 preservation: who answers authorized? on a payload field and on the mutation" do
    a = approve_mut
    field = a.payload_type.fields["secret"]
    owners = [field.method(:authorized?).owner, a.instance_method(:authorized?).owner, a.payload_type.method(:authorized?).owner]
    STDOUT.puts "OWNER|#{owners.inspect}|field.owner=#{field.owner.graphql_name}"
    expect(field.method(:authorized?).owner).to eq(armory::Integration::Field)
    expect(a.instance_method(:authorized?).owner).to eq(armory::Integration::Resolver)
    expect(field.owner).to eq(a)
  end
end
