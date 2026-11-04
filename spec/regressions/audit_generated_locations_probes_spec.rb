# frozen_string_literal: true

# Kept from the independent verification of PR #63: the audit's location fallback for generated types.
# Labels: [feature] differs from 0.1.0.pre11 (location now set); [preservation] must stay as it was.
# Every probe prints "OBS <name> <value>" so configurations and branches can be diffed.
require "timeout"
require "tmpdir"

module Probe
  ARM = GraphQL::Armory::Authorization
  L = {}
  REL = File.expand_path(__FILE__).delete_prefix("#{Dir.pwd}/")

  def self.at(key) = "#{REL}:#{L.fetch(key)}"
  def self.obs(name, value) = puts("OBS #{name} #{value.inspect}")
  def self.loc(thing) = ARM::Location.of(thing)

  class BaseField < GraphQL::Schema::Field; include ARM::Base; end

  class BaseObject < GraphQL::Schema::Object
    include ARM::Base
    field_class BaseField
    default_action :read
  end

  class BareObject < GraphQL::Schema::Object # no default_action: types with no rule are reported
    include ARM::Base
    field_class BaseField
  end

  class BaseMutation < GraphQL::Schema::Mutation
    include ARM::Base
    object_class BaseObject
    field_class BaseField
  end

  class BaseRelay < GraphQL::Schema::RelayClassicMutation
    include ARM::Base
    object_class BaseObject
    field_class BaseField
  end

  L[:plain] = __LINE__ + 1
  class PlainMutation < BaseMutation
    field :ok, GraphQL::Types::Boolean, null: false, authorize: :none, reason: "r"
  end

  L[:relay] = __LINE__ + 1
  class RelayMutation < BaseRelay
    field :ok, GraphQL::Types::Boolean, null: false, authorize: :none, reason: "r"
  end

  class AuthMutation < BaseMutation
    L[:auth_rule] = __LINE__ + 1
    authorize :none, reason: "r"
    field :ok, GraphQL::Types::Boolean, null: false, authorize: :none, reason: "r"
  end

  L[:explicit_payload] = __LINE__ + 1
  class ExplicitPayload < BaseObject
    field :ok, GraphQL::Types::Boolean, null: false, authorize: :none, reason: "r"
  end

  L[:explicit] = __LINE__ + 1
  class ExplicitMutation < BaseMutation
    payload_type ExplicitPayload
  end

  L[:parent] = __LINE__ + 1
  class ParentMutation < BaseMutation
    field :ok, GraphQL::Types::Boolean, null: false, authorize: :none, reason: "r"
  end

  L[:child] = __LINE__ + 1
  class ChildMutation < ParentMutation
  end

  L[:parent_explicit] = __LINE__ + 1
  class ParentExplicitMutation < BaseMutation
    payload_type ExplicitPayload
  end

  L[:child_explicit] = __LINE__ + 1
  class ChildExplicitMutation < ParentExplicitMutation
  end

  L[:invoice] = __LINE__ + 1
  class Invoice < BaseObject
    graphql_name "ProbeInvoice"
    field :id, GraphQL::Types::ID, null: false, authorize: :none, reason: "r"
  end

  L[:authed] = __LINE__ + 1
  class Authed < BaseObject
    graphql_name "ProbeAuthed"
    L[:authed_rule] = __LINE__ + 1
    authorize :none, reason: "r"
    field :id, GraphQL::Types::ID, null: false, authorize: :none, reason: "r"
  end

  L[:custom_conn] = __LINE__ + 1
  class CustomConnection < GraphQL::Types::Relay::BaseConnection; end

  L[:custom_edge] = __LINE__ + 1
  class CustomEdge < GraphQL::Types::Relay::BaseEdge; end

  L[:with_custom] = __LINE__ + 1
  class WithCustom < BaseObject
    graphql_name "ProbeWithCustom"
    connection_type_class CustomConnection
    edge_type_class CustomEdge
    field :id, GraphQL::Types::ID, null: false, authorize: :none, reason: "r"
  end

  L[:node_iface] = __LINE__ + 1
  module NodeIface
    include GraphQL::Schema::Interface
    graphql_name "ProbeNodeIface"
    field :id, GraphQL::Types::ID, null: false
  end

  L[:pick] = __LINE__ + 1
  class Pick < GraphQL::Schema::Union
    graphql_name "ProbePick"
    possible_types Invoice, Authed
  end

  L[:mutation_root] = __LINE__ + 1
  class MutationRoot < BaseObject
    graphql_name "Mutation"
    field :plain, mutation: PlainMutation, authorize: :none, reason: "r"
    field :relay, mutation: RelayMutation, authorize: :none, reason: "r"
    field :explicit, mutation: ExplicitMutation, authorize: :none, reason: "r"
  end

  def self.anon(base = BaseObject, name = "ProbeAnon#{rand(10**9)}", &block)
    Class.new(base) do
      graphql_name name
      class_eval(&block) if block
    end
  end

  def self.query_for(*connection_fields)
    Class.new(BaseObject) do
      graphql_name "Query"
      authorize :none, reason: "root"
      field :ping, String, null: false, authorize: :none, reason: "r"
      connection_fields.each_with_index { |type, i| field :"c#{i}", type, null: false, authorize: :none, reason: "r" }
    end
  end

  def self.build_schema(plugin: true, mutation: MutationRoot, extra_query: [])
    query = query_for(Invoice.connection_type, Authed.connection_type, *extra_query)
    Class.new(GraphQL::Schema) do
      use GraphQL::Execution::Next if defined?(GraphQL::Execution::Next) && ENV["GRAPHQL_ARMORY_ENGINE"] == "next"
      query query
      mutation mutation if mutation
      use ARM, adapter: ARM::Adapters::Substitute.new if plugin
    end
  end
end

RSpec.describe "Regression probes: generated_from" do
  describe "1. payloads" do
    it "[feature] Mutation: payload points at the mutation class" do
      result = Probe.loc(Probe::PlainMutation.payload_type)
      Probe.obs("m_plain", result)
      expect(result).to eq(Probe.at(:plain))
    end

    it "[feature] RelayClassicMutation: payload points at the mutation class" do
      result = Probe.loc(Probe::RelayMutation.payload_type)
      Probe.obs("m_relay", result)
      expect(result).to eq(Probe.at(:relay))
    end

    it "[feature] a mutation with an authorize line gives that line" do
      result = Probe.loc(Probe::AuthMutation.payload_type)
      Probe.obs("m_auth", result)
      expect(result).to eq(Probe.at(:auth_rule))
    end

    it "[preservation] payload_type given explicitly and named keeps its own line" do
      result = Probe.loc(Probe::ExplicitMutation.payload_type)
      Probe.obs("m_explicit", result)
      expect(result).to eq(Probe.at(:explicit_payload))
    end

    it "[preservation] explicit anonymous payload (no .mutation) is nil" do
      payload = Probe.anon
      mutation = Class.new(Probe::BaseMutation) { graphql_name "ProbeExplicitAnon" }
      mutation.payload_type(payload)
      result = Probe.loc(mutation.payload_type)
      Probe.obs("m_explicit_anon", result)
      expect(result).to be_nil
    end

    it "[preservation] a mutation that is itself anonymous gives nil, not a raise" do
      mutation = Class.new(Probe::BaseMutation) do
        graphql_name "ProbeAnonMutation"
        field :ok, GraphQL::Types::Boolean, null: false, authorize: :none, reason: "r"
      end
      result = Probe.loc(mutation.payload_type)
      Probe.obs("m_anon", result)
      expect(result).to be_nil
    end

    it "[feature] an anonymous mutation WITH authorize gives its authorize line" do
      line = nil
      mutation = Class.new(Probe::BaseMutation) do
        graphql_name "ProbeAnonAuthMutation"
        line = __LINE__ + 1
        authorize :none, reason: "r"
        field :ok, GraphQL::Types::Boolean, null: false, authorize: :none, reason: "r"
      end
      result = Probe.loc(mutation.payload_type)
      Probe.obs("m_anon_auth", result)
      expect(result).to eq("#{Probe::REL}:#{line}")
    end

    [true, false].each do |nullable|
      it "[feature] null: #{nullable} payload field: type located at the mutation" do
        root = Class.new(Probe::BaseObject) do
          graphql_name "Mutation"
          field :plain, mutation: Probe::PlainMutation, null: nullable, authorize: :none, reason: "r"
        end
        schema = Probe.build_schema(mutation: root)
        result = Probe.loc(schema.types["PlainMutationPayload"])
        Probe.obs("m_null_#{nullable}", result)
        expect(result).to eq(Probe.at(:plain))
      end
    end

    it "[feature] subclass inheriting parent settings: child payload points at the child" do
      child = Probe.loc(Probe::ChildMutation.payload_type)
      parent = Probe.loc(Probe::ParentMutation.payload_type)
      Probe.obs("m_child", [child, parent])
      expect(child).to eq(Probe.at(:child))
      expect(parent).to eq(Probe.at(:parent))
    end

    it "[feature] subclass of a mutation with an explicit named payload: whichever payload_type answers is located correctly" do
      payload = Probe::ChildExplicitMutation.payload_type
      result = Probe.loc(payload)
      Probe.obs("m_child_explicit", [payload.name, result])
      expect(result).to eq(payload.name ? Probe.at(:explicit_payload) : Probe.at(:child_explicit))
    end

    it "[preservation] anonymous subclass of an authorizing named mutation is nil, not the parent's line (advisory)" do
      sub = Class.new(Probe::AuthMutation) { graphql_name "ProbeAnonSub" }
      result = Probe.loc(sub.payload_type)
      Probe.obs("m_anon_sub", result)
      expect(result).to be_nil
    end

    it "[preservation] Subscription payload is not claimed (nil on both)" do
      sub = Class.new(GraphQL::Schema::Subscription) do
        graphql_name "ProbeSub"
        object_class Probe::BaseObject
        field :ok, GraphQL::Types::Boolean, null: false
      end
      result = Probe.loc(sub.payload_type)
      Probe.obs("subscription", result)
      expect(result).to be_nil
    end
  end

  describe "2. connections and edges" do
    it "[feature] Type.connection_type -> type line" do
      result = Probe.loc(Probe::Invoice.connection_type)
      Probe.obs("conn", result)
      expect(result).to eq(Probe.at(:invoice))
    end

    it "[feature] Type.edge_type -> type line" do
      result = Probe.loc(Probe::Invoice.edge_type)
      Probe.obs("edge", result)
      expect(result).to eq(Probe.at(:invoice))
    end

    it "[feature] node type with authorize: connection and edge give the authorize line" do
      result = [Probe.loc(Probe::Authed.connection_type), Probe.loc(Probe::Authed.edge_type)]
      Probe.obs("conn_auth", result)
      expect(result).to eq([Probe.at(:authed_rule), Probe.at(:authed_rule)])
    end

    it "[preservation] custom connection/edge class with a constant keeps its own line" do
      result = [Probe.loc(Probe::CustomConnection), Probe.loc(Probe::CustomEdge)]
      Probe.obs("custom_own", result)
      expect(result).to eq([Probe.at(:custom_conn), Probe.at(:custom_edge)])
    end

    it "[feature] connection_type_class/edge_type_class overrides: generated subclass points at the node type" do
      result = [Probe.loc(Probe::WithCustom.connection_type), Probe.loc(Probe::WithCustom.edge_type)]
      Probe.obs("custom_generated", result)
      expect(result).to eq([Probe.at(:with_custom), Probe.at(:with_custom)])
    end

    it "[feature] interface node type" do
      result = [Probe.loc(Probe::NodeIface.connection_type), Probe.loc(Probe::NodeIface.edge_type)]
      Probe.obs("iface", result)
      expect(result).to eq([Probe.at(:node_iface), Probe.at(:node_iface)])
    end

    it "[feature] union node type" do
      result = Probe.loc(Probe::Pick.connection_type)
      Probe.obs("union", result)
      expect(result).to eq(Probe.at(:pick))
    end

    it "[feature] connection of a connection resolves through to the first source with a location" do
      inner = Probe::Invoice.connection_type
      edge = Class.new(GraphQL::Types::Relay::BaseEdge) { graphql_name "ProbeInnerEdge"; node_type(inner) }
      cc = Class.new(GraphQL::Types::Relay::BaseConnection) { graphql_name "ProbeOuterConn"; edge_type(edge) }
      result = [Probe.loc(cc), Probe.loc(edge)]
      Probe.obs("conn_of_conn", result)
      expect(result).to eq([Probe.at(:invoice), Probe.at(:invoice)])
    end

    it "[preservation] connection of an anonymous node type with no rule is nil" do
      node = Probe.anon
      result = [Probe.loc(node.connection_type), Probe.loc(node.edge_type)]
      Probe.obs("anon_node", result)
      expect(result).to eq([nil, nil])
    end

    it "[feature] anonymous node type WITH authorize: connection gives that line" do
      line = nil
      node = Probe.anon do
        line = __LINE__ + 1
        authorize :none, reason: "r"
      end
      result = Probe.loc(node.connection_type)
      Probe.obs("anon_node_auth", result)
      expect(result).to eq("#{Probe::REL}:#{line}")
    end

    it "[preservation] anonymous subclass of a named node type gives nil for its connection (advisory)" do
      node = Class.new(Probe::Invoice) { graphql_name "ProbeInvoiceSub" }
      result = Probe.loc(node.connection_type)
      Probe.obs("anon_sub_node", result)
      expect(result).to be_nil
    end

    it "[preservation] a cycle between connections terminates with nil" do
      x = Class.new(GraphQL::Types::Relay::BaseConnection) { graphql_name "CycX" }
      y = Class.new(GraphQL::Types::Relay::BaseConnection) { graphql_name "CycY" }
      x.instance_variable_set(:@node_type, y)
      y.instance_variable_set(:@node_type, x)
      result = Timeout.timeout(5) { [Probe.loc(x), Probe.loc(y)] }
      Probe.obs("cycle2", result)
      expect(result).to eq([nil, nil])
    end

    it "[preservation] self-cycles (node_type itself, payload.mutation itself) terminate with nil" do
      x = Class.new(GraphQL::Types::Relay::BaseConnection) { graphql_name "CycSelf" }
      x.instance_variable_set(:@node_type, x)
      payload = Probe.anon
      payload.mutation(payload)
      result = Timeout.timeout(5) { [Probe.loc(x), Probe.loc(payload)] }
      Probe.obs("cycle_self", result)
      expect(result).to eq([nil, nil])
    end

    it "[feature] a cycle that leads to a located class still finds it" do
      x = Class.new(GraphQL::Types::Relay::BaseConnection) { graphql_name "CycZ" }
      y = Class.new(GraphQL::Types::Relay::BaseConnection) { graphql_name "CycW" }
      x.instance_variable_set(:@node_type, y)
      y.instance_variable_set(:@node_type, Probe::Invoice)
      result = Probe.loc(x)
      Probe.obs("cycle_found", result)
      expect(result).to eq(Probe.at(:invoice))
    end

    it "[preservation] a 20_000-long chain of anonymous nodes terminates quickly with nil" do
      head = (1..20_000).reduce(Probe.anon) do |node, _|
        c = Class.new(GraphQL::Types::Relay::BaseConnection)
        c.instance_variable_set(:@node_type, node)
        c
      end
      result = Timeout.timeout(10) { Probe.loc(head) }
      Probe.obs("long_chain", result)
      expect(result).to be_nil
    end

    it "[advisory] a source generating a FRESH class on every call loops forever (pathological, not graphql-ruby)" do
      make = nil
      make = lambda do
        Class.new(GraphQL::Types::Relay::BaseConnection) do
          define_singleton_method(:node_type) { make.call }
        end
      end
      outcome = begin
        Timeout.timeout(3) { Probe.loc(make.call) }
      rescue Timeout::Error
        :hang
      end
      Probe.obs("generator", outcome)
      expect([nil, :hang]).to include(outcome)
    end
  end

  describe "3. unexpected values never raise" do
    def thing(mutation: :none, node_type: :none)
      Class.new do
        define_singleton_method(:mutation) { mutation.respond_to?(:call) ? mutation.call : mutation } unless mutation == :none
        define_singleton_method(:node_type) { node_type.respond_to?(:call) ? node_type.call : node_type } unless node_type == :none
      end
    end

    {
      "mutation nil" => { mutation: nil },
      "node_type nil" => { node_type: nil },
      "mutation String" => { mutation: "Probe::Invoice" },
      "node_type String" => { node_type: "Probe::Invoice" },
      "mutation object" => { mutation: Object.new },
      "node_type object" => { node_type: Object.new },
      "mutation Integer" => { mutation: 42 },
      "mutation Symbol" => { mutation: :invoice },
      "mutation raises StandardError" => { mutation: -> { raise "boom" } },
      "node_type raises StandardError" => { node_type: -> { raise "boom" } },
      "node_type raises NotImplementedError" => { node_type: -> { raise NotImplementedError } },
      "mutation raises ArgumentError" => { mutation: -> { raise ArgumentError } },
      "mutation BasicObject" => { mutation: BasicObject.new },
      "node_type anonymous Module" => { node_type: Module.new },
      "mutation Array of classes" => { mutation: [Probe::Invoice] }
    }.each do |label, args|
      it "[preservation] #{label} -> nil, never raises" do
        result = Probe.loc(thing(**args))
        Probe.obs("odd #{label}", result)
        expect(result).to be_nil
      end
    end

    it "[preservation] source whose name / armory_rule_location / respond_to? raise -> nil" do
      bad_name = Class.new { def self.name = raise("n") }
      bad_rule = Class.new { def self.armory_rule_location = raise("r") }
      bad_resp = Class.new { def self.respond_to?(*) = raise("q") }
      results = [bad_name, bad_rule, bad_resp].map { |src| Probe.loc(thing(mutation: src)) }
      Probe.obs("odd sources", results)
      expect(results).to eq([nil, nil, nil])
    end

    # Changed after the verification: only an object type is followed, and only to a mutation, since a schema also
    # answers `mutation` (with its root type).
    it "[preservation] something that is not an object type is not followed, even to a named class" do
      result = Probe.loc(thing(mutation: Probe::Invoice))
      Probe.obs("odd named source", result)
      expect(result).to be_nil
    end

    it "[preservation] a node_type that returns a class whose own mutation raises -> nil" do
      inner = Class.new { def self.mutation = raise("deep") }
      result = Probe.loc(thing(node_type: inner))
      Probe.obs("odd deep", result)
      expect(result).to be_nil
    end

    it "[preservation] the audit's :plugin problem on an anonymous schema without the plugin has no location" do
      report = Probe::ARM::Audit.(Probe.build_schema(plugin: false))
      problem = report.problems.find { |pr| pr.kind == :plugin }
      Probe.obs("plugin_problem_loc", problem&.location)
      expect(problem).not_to be_nil
      expect(problem.location).to be_nil
    end

    it "[preservation] Location.of(anonymous schema with a named Mutation root) is nil" do
      result = Probe.loc(Probe.build_schema(plugin: false))
      Probe.obs("schema_loc", result)
      expect(result).to be_nil
    end
  end

  describe "4. the audit end to end" do
    def summary(report)
      report.problems.map { |pr| [pr.kind.to_s, pr.path, pr.message] }
    end

    [true, false].each do |bare|
      it "[preservation] same problems and order (#{bare ? 'bare types' : 'default_action types'}); report equal once '(at ...)' is removed" do
        extra = bare ? [Class.new(Probe::BareObject) { graphql_name "ProbeBare"; field :x, String, null: false }.connection_type] : []
        report = Probe::ARM::Audit.(Probe.build_schema(extra_query: extra))
        Probe.obs("problems bare=#{bare}", summary(report))
        Probe.obs("bypasses bare=#{bare}", report.bypasses.map { |b| [b.path, b.reason] })
        Probe.obs("printed_stripped bare=#{bare}", report.to_s.gsub(/ \(at [^()]*\)/, ""))
        Probe.obs("located bare=#{bare}", (report.problems + report.bypasses).select(&:location).map { |x| [x.path, x.location] })
        Probe.obs("unlocated bare=#{bare}", (report.problems + report.bypasses).reject(&:location).map(&:path))
        expect(report.to_s).not_to match(/ \(at [^()]*\) \(at /)
      end
    end

    it "[preservation] baseline ignores location: accepts every problem, passes" do
      bare = Class.new(Probe::BareObject) { graphql_name "ProbeBare2"; field :x, String, null: false }
      report = Probe::ARM::Audit.(Probe.build_schema(extra_query: [bare.connection_type]))
      baseline = Probe::ARM::Audit::Baseline.from(report)
      Probe.obs("baseline entries", baseline.entries.map(&:to_h))
      result = baseline.(report)
      Probe.obs("baseline passes", [result.passes?, result.new_problems.size, result.gone.size, result.grown.size])
      expect(result.passes?).to be(true)
    end

    it "[preservation] a schema built from SDL still gives nil for every location and does not raise" do
      sdl = <<~SDL
        type Query { items(first: Int): ItemConnection! }
        type Mutation { make(input: MakeInput!): MakePayload }
        input MakeInput { name: String }
        type MakePayload { item: Item }
        type Item { id: ID! }
        type ItemEdge { node: Item cursor: String! }
        type ItemConnection { edges: [ItemEdge] nodes: [Item] pageInfo: PageInfo! }
        type PageInfo { hasNextPage: Boolean! hasPreviousPage: Boolean! startCursor: String endCursor: String }
      SDL
      report = Probe::ARM::Audit.(GraphQL::Schema.from_definition(sdl))
      Probe.obs("sdl", [report.problems.map(&:path), (report.problems + report.bypasses).map(&:location).uniq])
      expect((report.problems + report.bypasses).map(&:location).compact).to eq([])
    end

    it "[feature] the audit locates generated payload/connection/edge entries only on a node's or mutation's line" do
      bare = Class.new(Probe::BareObject) { graphql_name "ProbeBare3"; field :x, String, null: false }
      report = Probe::ARM::Audit.(Probe.build_schema(extra_query: [bare.connection_type]))
      lines = (report.problems + report.bypasses).select { |x| x.path.match?(/^[A-Za-z]*(Connection|Edge|Payload)$/) }.map { |x| [x.path, x.location] }
      Probe.obs("generated_in_report", lines)
      located = lines.select { |_, l| l }
      allowed = [Probe.at(:invoice), Probe.at(:authed), Probe.at(:plain), Probe.at(:relay), Probe.at(:explicit_payload)]
      expect(located.map(&:last).uniq - allowed).to eq([])
    end
  end

  describe "5. paths" do
    it "[feature] relative to the start directory, even after Dir.chdir" do
      result = Dir.chdir(Dir.tmpdir) { Probe.loc(Probe::Invoice.connection_type) }
      Probe.obs("relative", result)
      expect(result).to eq(Probe.at(:invoice))
      expect(result).not_to start_with("/")
    end

    it "[feature] a source outside the start directory stays absolute" do
      Dir.mktmpdir do |dir|
        file = File.join(dir, "outside.rb")
        File.write(file, "module Probe\n  class Outside < BaseObject\n    graphql_name 'ProbeOutside'\n  end\nend\n")
        load file
        result = Probe.loc(Probe::Outside.connection_type)
        Probe.obs("outside", result&.sub(dir, "<TMP>"))
        expect(result).to eq("#{file}:2")
      end
    end
  end
end

RSpec.describe "Regression probes: generated_from: connection entries in a real report" do
  it "[feature] a connection that adds a field is listed at its node type's line; edge likewise" do
    conn_base = Class.new(GraphQL::Types::Relay::BaseConnection) do
      include Probe::ARM::Base
      field_class Probe::BaseField
      graphql_name "ProbeTotalConn"
      Probe::ARM::Authorization rescue nil
      authorize :none, reason: "counts", covers_fields: true
      field :total_count, Integer, null: false, authorize: :none, reason: "r"
    end
    node = Class.new(Probe::BareObject) do
      graphql_name "ProbeCounted"
      connection_type_class conn_base
      field :x, String, null: false
    end
    line = nil
    node_line = Probe.loc(node.connection_type)
    report = Probe::ARM::Audit.(Probe.build_schema(extra_query: [node.connection_type]))
    rows = (report.problems + report.bypasses).select { |x| x.path.match?(/^ProbeCounted(Connection|Edge)/) }.map { |x| [x.path, x.location] }
    Probe.obs("real_report_conn", [node_line, rows])
    expect(node_line).to be_nil # node is anonymous with no rule: nil is right, never a wrong line
    expect(rows.reject { |path, _| path.include?(".") }.map(&:last).compact).to eq([])
  end
end
