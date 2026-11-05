# frozen_string_literal: true

require "stringio"
require "rake"

# Independent verification probes for API versioning increment 3a (Versioning::Audit).
# Each `it` is labelled "security" or "preservation". A probe that needs Versioning::Audit skips where it does not
# exist (origin/main): those are new-feature probes.

# Named classes for the Authorization audit / Location comparison (locations come from constants).
module VerifyAuditLocations
  Plugin = GraphQL::Armory::Authorization
  BaseArgument = Class.new(GraphQL::Schema::Argument) { include Plugin::Base }
  BaseField = Class.new(GraphQL::Schema::Field) do
    include Plugin::Base
    argument_class BaseArgument
  end

  class BaseObject < GraphQL::Schema::Object
    include Plugin::Base
    field_class BaseField
  end

  class NoRule < BaseObject
    field :name, String, null: true
  end

  class Bypassed < BaseObject
    authorize :none, reason: "public"
    field :secret, String, null: true
    field :other, NoRule, null: true
  end

  class Query < BaseObject
    authorize :none, reason: "root", covers_fields: true
    field :bypassed, Bypassed, null: true
    field :find, String, null: true, load_through_scope: false do
      argument :thing_id, GraphQL::Types::ID, loads: NoRule
    end
  end
end

RSpec.describe "Versioning audit 3a: verification probes" do
  VA_OLDV = "2024-06-01"
  VA_NEWV = "2025-01-01"

  def vv = GraphQL::Armory::Versioning
  def cerr = GraphQL::Armory::Versioning::ConfigurationError

  def audit!(schema)
    skip "new feature: Versioning::Audit does not exist here" unless defined?(GraphQL::Armory::Versioning::Audit)
    GraphQL::Armory::Versioning::Audit.(schema)
  end

  def kinds(report) = report.problems.map { |problem| [problem.kind, problem.path] }.uniq

  def run(schema, text, version, root: nil, variables: {}, context: {})
    execute_query(schema, text, root_value: root, variables: variables, context: { armory_version: version }.merge(context)).to_h
  end

  def messages(result) = Array(result["errors"]).map { |error| error["message"] }

  # A root object answering each name with its value, whatever the arguments (both engines call methods on it).
  def obj(**values)
    Class.new do
      values.each { |name, value| define_method(name) { |**_args| value } }
    end.new
  end

  def schema_over(query_type, visibility, use_first: false, sinks: [], on_sink_error: nil, extra: [], dirs: [], sub: nil,
                  mutation_type: nil, adapter: nil, always_visible: false)
    plugin = { visibility: GraphQL::Schema::Visibility, warden: GraphQL::Schema::Warden }.fetch(visibility)
    labels = vv::Controls::Versions::LABELS
    retired = vv::Controls::Versions::RETIRED
    Class.new(ArmoryEngine.base_schema) do
      use plugin if use_first
      query(query_type)
      mutation(mutation_type) if mutation_type
      subscription(sub) if sub
      extra_types(*extra) unless extra.empty?
      directives(*dirs) unless dirs.empty?
      use plugin unless use_first
      use GraphQL::Armory::Versioning, versions: labels, retired: retired, default: :latest, sinks: sinks, on_sink_error: on_sink_error
      use GraphQL::Armory::Authorization, adapter: adapter if adapter
      use GraphQL::Schema::AlwaysVisible if always_visible
      def self.resolve_type(_abstract, object, _context) = object.type
    end
  end

  # A real app names its base interface (Types::BaseInterface), which gives it a graphql_name; `anonymous_interface: true`
  # keeps it anonymous, as graphql-ruby allows.
  def bases(authorization: nil, anonymous_interface: false)
    mod = GraphQL::Armory::Versioning::Base
    auth = GraphQL::Armory::Authorization::Base
    mods = case authorization
           when nil then [mod]
           when :after then [mod, auth]
           when :before then [auth, mod]
           end
    membership = Class.new(GraphQL::Schema::TypeMembership) { include mod }
    argument = Class.new(GraphQL::Schema::Argument) { mods.each { |m| include m } }
    field = Class.new(GraphQL::Schema::Field) { mods.each { |m| include m }; argument_class(argument) }
    object = Class.new(GraphQL::Schema::Object) { mods.each { |m| include m }; field_class(field) }
    interface = Module.new do
      include GraphQL::Schema::Interface
      include mod
      graphql_name "BaseInterface" unless anonymous_interface
      field_class(field)
      type_membership_class(membership)
    end
    union = Class.new(GraphQL::Schema::Union) { include mod; type_membership_class(membership) }
    value = Class.new(GraphQL::Schema::EnumValue) { include mod }
    enum = Class.new(GraphQL::Schema::Enum) { include mod; enum_value_class(value) }
    input = Class.new(GraphQL::Schema::InputObject) { include mod; argument_class(argument) }
    resolver = Class.new(GraphQL::Schema::Resolver) { include mod; argument_class(argument) }
    { membership: membership, argument: argument, field: field, object: object, interface: interface, union: union,
      value: value, enum: enum, input: input, resolver: resolver }
  end

  def kind_enum(b) = Class.new(b[:enum]) { graphql_name "Kind"; value "OLD"; value "NEW", added: "2025-01-01" }

  %i[visibility warden].each do |vis|
    context "with #{vis}" do
      # ---------------------------------------------------------------- (a) lazy refusals, never queried
      it "security S02: argument shadowing a parent's input field is refused at runtime and reported" do
        b = bases
        parent_in = Class.new(b[:input]) { graphql_name "FilterBase"; argument :code, String, required: false }
        child_in = Class.new(parent_in) { graphql_name "Filter"; argument :code, String, required: false, added: "2025-01-01" }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :ping, String, null: true
          field :search, String, null: true do
            argument :filter, child_in, required: false
          end
        end
        schema = schema_over(query, vis)
        expect { run(schema, '{ search(filter: { code: "x" }) }', VA_NEWV, root: obj(search: "s")) }.to raise_error(cerr, /shadows/)
        report = audit!(schema)
        expect(report.ok?).to be(false)
        expect(kinds(report)).to include([:refused, "Filter.code"])
      end

      it "security S03: enum value shadowing a parent's is refused at runtime and reported" do
        b = bases
        parent_e = Class.new(b[:enum]) { graphql_name "KindBase"; value "A"; value "B" }
        child_e = Class.new(parent_e) { graphql_name "Kind"; value "A", added: "2025-01-01" }
        query = Class.new(b[:object]) { graphql_name "Query"; field :ping, String, null: true; field :kind, child_e, null: true }
        schema = schema_over(query, vis)
        expect { run(schema, '{ __type(name: "Kind") { enumValues { name } } }', VA_NEWV) }.to raise_error(cerr, /shadows/)
        report = audit!(schema)
        expect(report.ok?).to be(false)
        expect(kinds(report).map(&:first)).to include(:refused)
      end

      [false, true].each do |use_first|
        it "security S04: schema directive argument with a lifecycle (registered: #{!use_first}, use_first: #{use_first})" do
          b = bases
          eager = nil
          tag = Class.new(GraphQL::Schema::Directive) do
            graphql_name "tag"
            locations(GraphQL::Schema::Directive::OBJECT)
            argument_class(b[:argument])
            argument :label, String, required: false, added: "2025-01-01"
          end
          thing = begin
            Class.new(b[:object]) { graphql_name "Thing"; directive tag; field :x, String, null: true }
          rescue StandardError => error
            eager = error
            Class.new(b[:object]) { graphql_name "Thing"; field :x, String, null: true }
          end
          query = Class.new(b[:object]) { graphql_name "Query"; field :ping, String, null: true; field :thing, thing, null: true }
          schema = schema_over(query, vis, use_first: use_first, dirs: use_first ? [] : [tag])
          warn "S04 #{vis} use_first=#{use_first}: applied eagerly raised #{eager.class}: #{eager&.message}" if eager
          in_schema = schema.directives.values.include?(tag)
          runtime = begin
            run(schema, "{ __schema { directives { name args { name } } } }", VA_NEWV)
            "no error"
          rescue StandardError => error
            "#{error.class}: #{error.message}"
          end
          sdl = begin
            schema.to_definition(context: { armory_version: VA_NEWV })
            "no error"
          rescue StandardError => error
            "#{error.class}: #{error.message}"
          end
          warn "S04 #{vis} use_first=#{use_first}: in schema.directives=#{in_schema} introspection=#{runtime} sdl=#{sdl}"
          report = audit!(schema)
          warn "S04 #{vis} use_first=#{use_first}: report=#{report.problems.map(&:to_s)}"
          refused_at_runtime = runtime != "no error" || sdl != "no error"
          expect(report.ok?).to be(false) if refused_at_runtime
        end
      end

      it "security S05: schema directive argument whose type reaches a versioned enum value" do
        b = bases
        kind = kind_enum(b)
        tag = Class.new(GraphQL::Schema::Directive) do
          graphql_name "tag"
          locations(GraphQL::Schema::Directive::OBJECT)
          argument_class(b[:argument])
          argument :kind, kind, required: false
        end
        query = Class.new(b[:object]) { graphql_name "Query"; field :ping, String, null: true }
        schema = schema_over(query, vis, dirs: [tag])
        runtime = begin
          schema.to_definition(context: { armory_version: VA_NEWV })
          "no error"
        rescue StandardError => error
          "#{error.class}: #{error.message}"
        end
        warn "S05 #{vis}: sdl=#{runtime}"
        report = audit!(schema)
        expect(report.ok?).to be(false) if runtime != "no error"
        expect(kinds(report)).to include([:refused, "tag.kind"]).or include([:refused, "@tag.kind"]) if runtime != "no error"
      end

      it "security S06: a versioned membership overridden by an inherited one is reported" do
        b = bases
        arch = Module.new { include b[:interface]; graphql_name "Archivable"; field :archived, GraphQL::Types::Boolean, null: true }
        parent = Class.new(b[:object]) { graphql_name "Parent"; implements arch }
        child = Class.new(parent) { graphql_name "Child"; implements arch, added: "2025-01-01" }
        query = Class.new(b[:object]) { graphql_name "Query"; field :ping, String, null: true; field :child, child, null: true }
        schema = schema_over(query, vis)
        expect { run(schema, "{ child { archived } }", VA_OLDV, root: obj(child: obj(archived: true))) }.to raise_error(cerr, /another membership/)
        report = audit!(schema)
        expect(report.ok?).to be(false)
        expect(kinds(report)).to include([:refused, "Child"])
      end

      it "security S07: an interface membership whose field another interface declares is reported" do
        b = bases
        named = Module.new { include b[:interface]; graphql_name "Named"; field :title, String, null: true }
        titled = Module.new { include b[:interface]; graphql_name "Titled"; field :title, String, null: true }
        report_t = Class.new(b[:object]) { graphql_name "Report"; implements named; implements titled, added: "2025-01-01" }
        query = Class.new(b[:object]) { graphql_name "Query"; field :ping, String, null: true; field :report, report_t, null: true }
        schema = schema_over(query, vis)
        expect { run(schema, "{ report { title } }", VA_OLDV, root: obj(report: obj(title: "t"))) }.to raise_error(cerr, /also declared by Named/)
        report = audit!(schema)
        expect(report.ok?).to be(false)
        expect(kinds(report)).to include([:refused, "Report"])
      end

      it "security S08: a type wider than its parent is reported" do
        b = bases
        parent = Class.new(b[:object]) { graphql_name "ThingBase"; lifecycle added: "2025-01-01"; field :a, String, null: true }
        child = Class.new(parent) { graphql_name "Thing"; lifecycle added: "2024-06-01" }
        query = Class.new(b[:object]) { graphql_name "Query"; field :ping, String, null: true; field :thing, child, null: true }
        schema = schema_over(query, vis)
        expect { run(schema, "{ thing { a } }", VA_OLDV, root: obj(thing: obj(a: "a"))) }.to raise_error(cerr, /its parent ThingBase does not/)
        report = audit!(schema)
        expect(report.ok?).to be(false)
        expect(kinds(report)).to include([:refused, "Thing"])
      end

      it "security S08b: a resolver wider than its parent resolver is reported" do
        b = bases
        parent = Class.new(b[:resolver]) do
          graphql_name "CalcBase"
          lifecycle added: "2025-01-01"
          type String, null: true
          def resolve = "calc"
        end
        child = Class.new(parent) { graphql_name "Calc"; lifecycle added: "2024-06-01" }
        query = Class.new(b[:object]) { graphql_name "Query"; field :ping, String, null: true; field :calc, resolver: child }
        schema = schema_over(query, vis)
        expect { run(schema, "{ calc }", VA_OLDV, root: obj(ping: "p")) }.to raise_error(cerr, /its parent CalcBase does not/)
        report = audit!(schema)
        expect(report.ok?).to be(false)
      end

      it "security S09: a late-bound name with type twins is reported under Schema" do
        b = bases
        m1 = Class.new(b[:object]) { graphql_name "Money"; lifecycle removed: "2025-01-01"; field :cents, Integer, null: true }
        m2 = Class.new(b[:object]) { graphql_name "Money"; lifecycle added: "2025-01-01"; field :amount, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :a, m1, null: true
          field :b, m2, null: true
          field :c, GraphQL::Schema::LateBoundType.new("Money"), null: true
        end
        schema = schema_over(query, vis)
        expect { run(schema, "{ __typename }", VA_OLDV) }.to raise_error(cerr, /names Money by name/)
        report = audit!(schema)
        expect(report.ok?).to be(false)
        expect(report.problems.map { |problem| [problem.kind, problem.path] }).to include([:refused, "Schema"])
      end

      it "security S10: an argument loading an abstract type with a versioned membership is reported" do
        b = bases
        arch = Module.new { include b[:interface]; graphql_name "Archivable"; field :archived, GraphQL::Types::Boolean, null: true }
        inv = Class.new(b[:object]) { graphql_name "Invoice"; implements arch, added: "2025-01-01"; field :number, String, null: true }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :invoice, inv, null: true
          field :archive, GraphQL::Types::Boolean, null: true do
            argument :item_id, GraphQL::Types::ID, required: true, loads: arch
          end
        end
        schema = schema_over(query, vis)
        text = vis == :warden ? "{ __typename }" : '{ archive(itemId: "1") }'
        expect { run(schema, text, VA_OLDV) }.to raise_error(cerr, /it loads Archivable/)
        report = audit!(schema)
        expect(report.ok?).to be(false)
      end

      it "security S11: overlapping twins of a field, an argument and an enum value are each reported" do
        b = bases
        kind = Class.new(b[:enum]) { graphql_name "Kind"; value "A"; value "A", added: "2025-01-01", value: :a2 }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :ping, String, null: true
          field :total, Integer, null: true, removed: "2025-01-01"
          field :total, Integer, null: true
          field :find, String, null: true do
            argument :x, Integer, required: false
            argument :x, String, required: false, added: "2025-01-01"
          end
          field :kind, kind, null: true
        end
        schema = schema_over(query, vis)
        expect { run(schema, "{ total }", VA_OLDV, root: obj(total: 1)) }.to raise_error(cerr, /defined more than once/)
        expect { run(schema, "{ find }", VA_NEWV, root: obj(find: "f")) }.to raise_error(cerr, /defined more than once/)
        report = audit!(schema)
        expect(report.ok?).to be(false)
        expect(kinds(report)).to include([:refused, "Query.total"], [:refused, "Query.find.x"], [:refused, "Kind.A"])
      end

      it "security S12: subscription argument twins are reported under Schema" do
        b = bases
        sub = Class.new(b[:object]) do
          graphql_name "Subscription"
          field :updated, String, null: true do
            argument :x, Integer, required: false, removed: "2025-01-01"
            argument :x, String, required: false, added: "2025-01-01"
          end
        end
        query = Class.new(b[:object]) { graphql_name "Query"; field :ping, String, null: true }
        schema = schema_over(query, vis, sub: sub)
        expect { run(schema, "{ ping }", VA_OLDV, root: obj(ping: "p")) }.to raise_error(cerr, /subscription trigger/)
        report = audit!(schema)
        expect(report.ok?).to be(false)
        expect(kinds(report)).to include([:refused, "Schema"])
      end

      it "security S15: AlwaysVisible is reported under Schema" do
        query = vv::Controls::Query.example
        schema = schema_over(query, vis, always_visible: true)
        expect { run(schema, "{ __typename }", VA_OLDV) }.to raise_error(cerr, /AlwaysVisible/)
        report = audit!(schema)
        expect(report.ok?).to be(false)
      end

      it "security S16: an executable directive argument default naming a value outside the version" do
        b = bases
        kind = kind_enum(b)
        mode = Class.new(GraphQL::Schema::Directive) do
          graphql_name "mode"
          locations(GraphQL::Schema::Directive::FIELD)
          argument_class(b[:argument])
          argument :kind, kind, required: false, default_value: "NEW"
        end
        query = Class.new(b[:object]) { graphql_name "Query"; field :ping, String, null: true }
        schema = schema_over(query, vis, dirs: [mode])
        runtime = begin
          run(schema, "{ ping @mode }", VA_OLDV, root: obj(ping: "p")).inspect
        rescue StandardError => error
          "#{error.class}: #{error.message}"
        end
        warn "S16 #{vis}: #{runtime}"
        expect(runtime).to match(/default_value names Kind.NEW/)
        report = audit!(schema)
        expect(report.ok?).to be(false)
      end

      # ---------------------------------------------------------------- (a) hidden by the user
      it "security S20: an app visible? ahead of the plugin that answers false with no user (documented as not checked)" do
        b = bases
        parent = Class.new(b[:object]) { graphql_name "AdminBase"; lifecycle added: "2025-01-01"; field :a, String, null: true }
        admin = Class.new(parent) do
          graphql_name "Admin"
          lifecycle added: "2024-06-01"
          def self.visible?(context) = context[:current_user] ? super : false
        end
        query = Class.new(b[:object]) { graphql_name "Query"; field :ping, String, null: true; field :admin, admin, null: true }
        schema = schema_over(query, vis)
        expect { run(schema, "{ admin { a } }", VA_OLDV, root: obj(admin: obj(a: "a")), context: { current_user: :admin }) }
          .to raise_error(cerr, /parent AdminBase does not/)
        report = audit!(schema)
        warn "S20 #{vis}: ok?=#{report.ok?} problems=#{report.problems.map(&:to_s)}"
        expect(report.to_s).to include("your own visible? methods")
      end

      %i[before after].each do |order|
        it "security S22/S23: Authorization visible_when (Base #{order} Versioning's) does not hide a refusal" do
          b = bases(authorization: order)
          kind = kind_enum(b)
          adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: false)
          parent = Class.new(b[:object]) { graphql_name "ThingBase"; authorize :read, model: ::Struct; lifecycle added: "2025-01-01"; field :a, String, null: true }
          thing = Class.new(parent) { graphql_name "Thing"; authorize :read, model: ::Struct, visible_when: :export; lifecycle added: "2024-06-01" }
          query = Class.new(b[:object]) do
            graphql_name "Query"
            authorize :read, model: ::Struct
            field :ping, String, null: true
            field :thing, thing, null: true
            field :pick, String, null: true, visible_when: :export do
              argument :kind, kind, required: false, default_value: "NEW"
            end
          end
          schema = schema_over(query, vis, adapter: adapter)
          report = audit!(schema)
          warn "S22 #{vis} #{order}: #{report.problems.map(&:to_s)}"
          expect(report.ok?).to be(false)
          expect(kinds(report)).to include([:refused, "Thing"], [:refused, "Query.pick.kind"])
        end
      end

      # ---------------------------------------------------------------- (b) leaks
      it "security S30a: an argument whose visible? answers true without super" do
        b = bases
        leaky = Class.new(b[:argument]) { def visible?(context) = keyword == :old || super }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :search, String, null: true do
            argument_class leaky
            argument :old, String, required: false, removed: "2025-01-01"
          end
        end
        schema = schema_over(query, vis)
        expect(run(schema, '{ search(old: "x") }', VA_NEWV, root: obj(search: "served"))).to eq("data" => { "search" => "served" })
        report = audit!(schema)
        expect(report.ok?).to be(false)
        expect(kinds(report)).to include([:outside_lifecycle, "Query.search.old"])
      end

      it "security S30b: an enum value whose visible? answers true without super" do
        b = bases
        leaky = Class.new(b[:value]) { def visible?(context) = graphql_name == "LEGACY" || super }
        kind = Class.new(b[:enum]) { graphql_name "Kind"; enum_value_class(leaky); value "A"; value "LEGACY", removed: "2025-01-01" }
        query = Class.new(b[:object]) { graphql_name "Query"; field :kind, kind, null: true }
        schema = schema_over(query, vis)
        names = run(schema, '{ __type(name: "Kind") { enumValues { name } } }', VA_NEWV)["data"]["__type"]["enumValues"].map { |v| v["name"] }
        expect(names).to include("LEGACY")
        report = audit!(schema)
        expect(report.ok?).to be(false)
        expect(kinds(report)).to include([:outside_lifecycle, "Kind.LEGACY"])
      end

      it "security S30c: an object type whose visible? answers true without super" do
        b = bases
        legacy = Class.new(b[:object]) do
          graphql_name "Legacy"
          lifecycle removed: "2025-01-01"
          def self.visible?(_context) = true
          field :x, String, null: true
        end
        query = Class.new(b[:object]) { graphql_name "Query"; field :ping, String, null: true; field :legacy, legacy, null: true }
        schema = schema_over(query, vis)
        result = run(schema, "{ legacy { x } }", VA_NEWV, root: obj(legacy: obj(x: "served")))
        warn "S30c #{vis}: #{result}"
        report = audit!(schema)
        expect(report.ok?).to be(false) if result["data"]
        expect(kinds(report)).to include([:outside_lifecycle, "Legacy"]) if result["data"]
      end

      it "security S30d: an interface membership whose visible? answers true without super" do
        b = bases
        leaky = Class.new(b[:membership]) { def visible?(_context) = true }
        arch = Module.new { include b[:interface]; graphql_name "Archivable"; type_membership_class(leaky); field :archived, GraphQL::Types::Boolean, null: true }
        inv = Class.new(b[:object]) { graphql_name "Invoice"; implements arch, added: "2025-01-01"; field :number, String, null: true }
        query = Class.new(b[:object]) { graphql_name "Query"; field :invoice, inv, null: true }
        schema = schema_over(query, vis)
        names = run(schema, '{ __type(name: "Invoice") { interfaces { name } } }', VA_OLDV)["data"]["__type"]["interfaces"].map { |t| t["name"] }
        warn "S30d #{vis}: interfaces in old=#{names}"
        report = audit!(schema)
        if names.include?("Archivable")
          expect(report.ok?).to be(false)
          expect(kinds(report)).to include([:outside_lifecycle, "Invoice.Archivable"])
        end
      end

      it "security S30e: a union membership whose visible? answers true without super" do
        b = bases
        leaky = Class.new(b[:membership]) { def visible?(_context) = true }
        contract = Class.new(b[:object]) { graphql_name "Contract"; field :party, String, null: true }
        memo = Class.new(b[:object]) { graphql_name "Memo"; field :body, String, null: true }
        doc = Class.new(b[:union]) { graphql_name "Doc"; type_membership_class(leaky); possible_types memo; possible_types contract, added: "2025-01-01" }
        query = Class.new(b[:object]) { graphql_name "Query"; field :doc, doc, null: true; field :contract, contract, null: true }
        schema = schema_over(query, vis)
        names = run(schema, '{ __type(name: "Doc") { possibleTypes { name } } }', VA_OLDV)["data"]["__type"]["possibleTypes"].map { |t| t["name"] }
        warn "S30e #{vis}: possibleTypes in old=#{names}"
        report = audit!(schema)
        if names.include?("Contract")
          expect(report.ok?).to be(false)
          expect(kinds(report)).to include([:outside_lifecycle, "Contract.Doc"])
        end
      end

      it "security S31: Warden fallback to an interface's definition (documented as not checked)" do
        b = bases
        named = Module.new { include b[:interface]; graphql_name "Totaled"; field :total, Integer, null: true }
        inv = Class.new(b[:object]) { graphql_name "Invoice"; implements named; field :total, Integer, null: true, removed: "2025-01-01" }
        query = Class.new(b[:object]) { graphql_name "Query"; field :invoice, inv, null: true }
        schema = schema_over(query, vis)
        result = run(schema, "{ invoice { total } }", VA_NEWV, root: obj(invoice: obj(total: 7)))
        report = audit!(schema)
        warn "S31 #{vis}: new=#{result} ok?=#{report.ok?} #{report.problems.map(&:to_s)}"
        expect(report.to_s).to include("under the Warden")
      end

      it "security S32: a type outside its lifecycle reachable only by name" do
        b = bases
        hidden = Class.new(b[:object]) do
          graphql_name "Hidden"
          lifecycle added: "2025-01-01"
          def self.visible?(_context) = true
          field :x, String, null: true
        end
        query = Class.new(b[:object]) { graphql_name "Query"; field :ping, String, null: true; field :hidden, hidden, null: true, added: "2025-01-01" }
        schema = schema_over(query, vis)
        result = run(schema, '{ __type(name: "Hidden") { name fields { name } } }', VA_OLDV)
        frag = run(schema, "query { ping ... on Query { ping } } fragment F on Hidden { x }", VA_OLDV, root: obj(ping: "p"))
        report = audit!(schema)
        warn "S32 #{vis}: __type=#{result} frag=#{messages(frag)} ok?=#{report.ok?} #{report.problems.map(&:to_s)}"
        expect(report.ok?).to be(false) if result.dig("data", "__type")
      end

      it "security S33: an interface field inherited by an implementer, visible? true without super" do
        b = bases
        leaky = Class.new(b[:field]) { def visible?(context) = original_name == :old || super }
        named = Module.new { include b[:interface]; graphql_name "Olden"; field_class(leaky); field :old, String, null: true, removed: "2025-01-01" }
        inv = Class.new(b[:object]) { graphql_name "Invoice"; implements named; field :number, String, null: true }
        query = Class.new(b[:object]) { graphql_name "Query"; field :invoice, inv, null: true }
        schema = schema_over(query, vis)
        expect(run(schema, "{ invoice { old } }", VA_NEWV, root: obj(invoice: obj(old: "served")))).to eq("data" => { "invoice" => { "old" => "served" } })
        report = audit!(schema)
        expect(report.ok?).to be(false)
        expect(kinds(report)).to include([:outside_lifecycle, "Olden.old"])
      end

      it "security S34: an input object field, visible? true without super" do
        b = bases
        leaky = Class.new(b[:argument]) { def visible?(context) = keyword == :code || super }
        filter = Class.new(b[:input]) { graphql_name "Filter"; argument_class(leaky); argument :code, String, required: false, removed: "2025-01-01" }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :search, String, null: true do
            argument :filter, filter, required: false
          end
        end
        schema = schema_over(query, vis)
        expect(run(schema, '{ search(filter: { code: "x" }) }', VA_NEWV, root: obj(search: "served"))).to eq("data" => { "search" => "served" })
        report = audit!(schema)
        expect(report.ok?).to be(false)
        expect(kinds(report)).to include([:outside_lifecycle, "Filter.code"])
      end

      it "security S35: an executable directive argument, visible? true without super" do
        b = bases
        leaky = Class.new(b[:argument]) { def visible?(context) = keyword == :old || super }
        tagged = Class.new(GraphQL::Schema::Directive) do
          graphql_name "tagged"
          locations(GraphQL::Schema::Directive::FIELD)
          argument_class(leaky)
          argument :old, Integer, required: false, removed: "2025-01-01"
        end
        query = Class.new(b[:object]) { graphql_name "Query"; field :ping, String, null: true }
        schema = schema_over(query, vis, dirs: [tagged])
        served = run(schema, "{ ping @tagged(old: 1) }", VA_NEWV, root: obj(ping: "served"))
        args = run(schema, "{ __schema { directives { name args { name } } } }", VA_NEWV)["data"]["__schema"]["directives"]
               .find { |d| d["name"] == "tagged" }&.dig("args")&.map { |a| a["name"] }
        warn "S35 #{vis}: request=#{served} introspected args=#{args.inspect}"
        report = audit!(schema)
        warn "S35 #{vis}: ok?=#{report.ok?} #{report.problems.map(&:to_s)}"
        expect(report.ok?).to be(false) if served["data"] || Array(args).include?("old")
      end

      it "security S35c: an executable directive argument outside its lifecycle, no app code" do
        b = bases
        tagged = Class.new(GraphQL::Schema::Directive) do
          graphql_name "tagged"
          locations(GraphQL::Schema::Directive::FIELD)
          argument_class(b[:argument])
          argument :old, Integer, required: false, removed: "2025-01-01"
          argument :fresh, Integer, required: false, added: "2025-01-01"
        end
        query = Class.new(b[:object]) { graphql_name "Query"; field :ping, String, null: true }
        schema = schema_over(query, vis, dirs: [tagged])
        served_new = run(schema, "{ ping @tagged(old: 1) }", VA_NEWV, root: obj(ping: "served"))
        served_old = run(schema, "{ ping @tagged(fresh: 1) }", VA_OLDV, root: obj(ping: "served"))
        warn "S35c #{vis}: new with old=#{served_new} old with fresh=#{served_old}"
        expect(served_new["data"]).to be_nil
        expect(served_old["data"]).to be_nil
        report = audit!(schema)
        expect(report.ok?).to be(true)
      end

      it "security S36: an enum value outside the version is not accepted as input (runtime, literal and variable)" do
        skip "graphql 2.4 with json 3.1 cannot print a literal in its own validation error" unless ArmoryJsonPrinting.prints_strings?
        b = bases
        kind = kind_enum(b)
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :pick, String, null: true do
            argument :kind, kind, required: false
          end
        end
        schema = schema_over(query, vis)
        literal = run(schema, "{ pick(kind: NEW) }", VA_OLDV, root: obj(pick: "served"))
        variable = run(schema, "query($k: Kind) { pick(kind: $k) }", VA_OLDV, root: obj(pick: "served"), variables: { "k" => "NEW" })
        expect(literal["data"]).to be_nil
        expect(variable["data"]).to be_nil
      end

      # ---------------------------------------------------------------- noise
      it "security N02: a realistic consistent schema is ok" do
        b = bases(authorization: :after)
        adapter = GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: true)
        arch = Module.new { include b[:interface]; graphql_name "Archivable"; field :archived, GraphQL::Types::Boolean, null: true }
        status = Class.new(b[:enum]) { graphql_name "Status"; value "PAID"; value "VOID", added: "2024-06-01"; value "CANCELLED", removed: "2025-01-01" }
        filter = Class.new(b[:input]) do
          graphql_name "InvoiceFilter"
          argument :status, status, required: false
          argument :since, String, required: false, added: "2025-01-01"
        end
        inv = Class.new(b[:object]) do
          graphql_name "Invoice"
          authorize :read, model: ::Struct
          implements arch, added: "2025-01-01"
          implements GraphQL::Types::Relay::Node
          field :number, String, null: true
          field :total, Integer, null: true, removed: "2025-01-01"
          field :total, String, null: true, added: "2025-01-01"
          field :secret, String, null: true, visible_when: :export
          field :status, status, null: true
        end
        contract = Class.new(b[:object]) { graphql_name "Contract"; authorize :read, model: ::Struct; lifecycle added: "2025-01-01"; field :party, String, null: true }
        doc = Class.new(b[:union]) { graphql_name "Doc"; possible_types inv; possible_types contract, added: "2025-01-01" }
        payload_base = b[:object]
        input_base = b[:input]
        field_base = b[:field]
        arg_base = b[:argument]
        create = Class.new(GraphQL::Schema::RelayClassicMutation) do
          include GraphQL::Armory::Versioning::Base
          graphql_name "CreateInvoice"
          object_class payload_base
          input_object_class input_base
          field_class field_base
          argument_class arg_base
          lifecycle added: "2025-01-01"
          argument :number, String, required: true
          argument :note, String, required: false, added: "2025-01-01"
          field :invoice, inv, null: true
          def resolve(**) = { invoice: nil }
        end
        mutation = Class.new(b[:object]) { graphql_name "Mutation"; authorize :read, model: ::Struct; field :create_invoice, mutation: create }
        query = Class.new(b[:object]) do
          graphql_name "Query"
          authorize :read, model: ::Struct
          include GraphQL::Types::Relay::HasNodeField
          field :invoices, inv.connection_type, null: true do
            argument :filter, filter, required: false
            argument :first_page, Integer, required: false, added: "2024-06-01"
          end
          field :doc, doc, null: true
          field :archivable, arch, null: true
          field :contract, contract, null: true
        end
        schema = schema_over(query, vis, mutation_type: mutation, adapter: adapter)
        begin
          intro = run(schema, GraphQL::Introspection::INTROSPECTION_QUERY, VA_OLDV)
          expect(intro["errors"]).to be_nil
        rescue ArgumentError => error
          # graphql 2.4 with json 3.x: JSON.generate(quirks_mode:) when printing a default; environment, not the PR.
          raise unless error.message.include?("quirks_mode")

          warn "N02 #{vis}: introspection skipped on this graphql/json pair: #{error.message}"
        end
        report = audit!(schema)
        warn "N02 #{vis}: #{report.problems.map(&:to_s)}" unless report.ok?
        expect(report.ok?).to be(true)
      end

      it "security N03: an object inheriting `implements` from a parent class is ok" do
        b = bases
        arch = Module.new { include b[:interface]; graphql_name "Archivable"; field :archived, GraphQL::Types::Boolean, null: true }
        record = Class.new(b[:object]) { graphql_name "Record"; implements arch; field :id, GraphQL::Types::ID, null: true }
        inv = Class.new(record) { graphql_name "Invoice"; field :number, String, null: true }
        query = Class.new(b[:object]) { graphql_name "Query"; field :invoice, inv, null: true }
        schema = schema_over(query, vis)
        expect(run(schema, '{ __type(name: "Invoice") { interfaces { name } } }', VA_OLDV)["data"]["__type"]["interfaces"]).to eq([{ "name" => "Archivable" }])
        report = audit!(schema)
        warn "N03 #{vis}: #{report.problems.map(&:to_s)}" unless report.ok?
        expect(report.ok?).to be(true)
      end

      it "security N04: a field added in a version whose argument defaults to a value added with it is ok" do
        skip "graphql 2.4 with json 3.1 cannot print a default value in introspection" unless ArmoryJsonPrinting.prints_strings?
        b = bases
        kind = kind_enum(b)
        query = Class.new(b[:object]) do
          graphql_name "Query"
          field :ping, String, null: true
          field :pick, String, null: true, added: "2025-01-01" do
            argument :kind, kind, required: false, default_value: "NEW"
          end
        end
        schema = schema_over(query, vis)
        expect(run(schema, GraphQL::Introspection::INTROSPECTION_QUERY, VA_OLDV)["errors"]).to be_nil
        expect { schema.to_definition(context: { armory_version: VA_OLDV }) }.not_to raise_error
        expect(run(schema, "{ ping }", VA_OLDV, root: obj(ping: "p"))).to eq("data" => { "ping" => "p" })
        expect(run(schema, "{ pick }", VA_NEWV, root: obj(pick: "p"))).to eq("data" => { "pick" => "p" })
        report = audit!(schema)
        # The legacy Warden asks the argument while it decides whether Kind is reachable: `__type(name: "Kind")` is refused
        # in 2024-06-01, and the audit says so. Schema::Visibility answers null without asking it.
        if vis == :warden
          expect { run(schema, '{ __type(name: "Kind") { name } }', VA_OLDV) }
            .to raise_error(GraphQL::Armory::Versioning::ConfigurationError, /default_value names Kind.NEW/)
          expect(report.problems.map(&:kind)).to eq([:refused])
        else
          expect(run(schema, '{ __type(name: "Kind") { name } }', VA_OLDV)).to eq("data" => { "__type" => nil })
          expect(report.ok?).to be(true)
        end
      end

      it "security A01: an anonymous base interface module does not crash the audit" do
        b = bases(anonymous_interface: true)
        arch = Module.new { include b[:interface]; graphql_name "Archivable"; field :archived, GraphQL::Types::Boolean, null: true }
        inv = Class.new(b[:object]) { graphql_name "Invoice"; implements arch; field :number, String, null: true }
        query = Class.new(b[:object]) { graphql_name "Query"; field :invoice, inv, null: true }
        schema = schema_over(query, vis)
        expect(run(schema, "{ invoice { number archived } }", VA_OLDV, root: obj(invoice: obj(number: "n", archived: true))))
          .to eq("data" => { "invoice" => { "number" => "n", "archived" => true } })
        outcome = begin
          audit!(schema).ok?
        rescue GraphQL::RequiredImplementationMissingError => error
          "raised #{error.class}: #{error.message}"
        end
        warn "A01 #{vis}: #{outcome.inspect}"
        expect(outcome).to be(true)
      end

      # ---------------------------------------------------------------- telemetry
      it "security T02: a raising sink neither crashes the audit nor gets called" do
        calls = []
        sink = ->(signal, _data) { calls << signal; raise "boom" }
        schema = schema_over(vv::Controls::Query.example, vis, sinks: [sink])
        report = audit!(schema)
        expect(report.ok?).to be(true)
        expect(calls).to eq([])
      end

      # ---------------------------------------------------------------- memoization / order
      def wider_schema(vis)
        b = bases
        parent = Class.new(b[:object]) { graphql_name "ThingBase"; lifecycle added: "2025-01-01"; field :a, String, null: true }
        child = Class.new(parent) { graphql_name "Thing"; lifecycle added: "2024-06-01" }
        query = Class.new(b[:object]) { graphql_name "Query"; field :ping, String, null: true; field :thing, child, null: true }
        schema_over(query, vis)
      end

      it "security M01: queries first, then the audit, gives the same report as a fresh audit" do
        skip "new feature" unless defined?(GraphQL::Armory::Versioning::Audit)
        fresh = audit!(wider_schema(vis)).to_s
        used = wider_schema(vis)
        [VA_OLDV, VA_NEWV].each { |version| run(used, "{ ping }", version, root: obj(ping: "p")) }
        begin
          run(used, "{ thing { a } }", VA_OLDV, root: obj(thing: obj(a: "a")))
        rescue cerr
          nil
        end
        run(used, "{ thing { a } }", VA_NEWV, root: obj(thing: obj(a: "a")))
        expect(audit!(used).to_s).to eq(fresh)
        expect(audit!(used).to_s).to eq(fresh)
      end

      it "security M02: the audit first changes no later runtime answer" do
        schema = wider_schema(vis)
        audit!(schema)
        expect { run(schema, "{ thing { a } }", VA_OLDV, root: obj(thing: obj(a: "a"))) }.to raise_error(cerr, /parent ThingBase/)
        expect(run(schema, "{ thing { a } }", VA_NEWV, root: obj(thing: obj(a: "a")))).to eq("data" => { "thing" => { "a" => "a" } })
        controls = vv::Controls::Schema.example(visibility: vis, base: ArmoryEngine.base_schema)
        audit!(controls)
        expect(messages(run(controls, "{ invoice { tags } }", VA_OLDV, root: vv::Controls::Root.example))).to eq(["Field 'tags' doesn't exist on type 'Invoice'"])
        expect(run(controls, "{ invoice { total } }", VA_OLDV, root: vv::Controls::Root.example)).to eq("data" => { "invoice" => { "total" => 100 } })
      end

      # ---------------------------------------------------------------- report shape
      it "security R01: one problem per path across versions, with a location in this file" do
        b = bases
        kind = Class.new(b[:enum]) { graphql_name "Kind"; value "A"; value "A", value: :a2 }
        query = Class.new(b[:object]) { graphql_name "Query"; field :kind, kind, null: true }
        report = audit!(schema_over(query, vis))
        warn "R01 #{vis}:\n#{report}"
        expect(report.problems.count { |problem| problem.path == "Kind.A" }).to eq(1)
        expect(report.to_s).to match(/\A1 problem:\n  Kind\.A \(refused\): .*\n\nNot checked yet: .*\.\n\z/)
      end
    end
  end

  # ---------------------------------------------------------------- preservation, runtime refactor
  it "preservation P01: check_schema refuses with the same first message, in the same order" do
    b = bases
    m1 = Class.new(b[:object]) { graphql_name "Money"; lifecycle removed: "2025-01-01"; field :cents, Integer, null: true }
    m2 = Class.new(b[:object]) { graphql_name "Money"; lifecycle added: "2025-01-01"; field :amount, String, null: true }
    sub = Class.new(b[:object]) do
      graphql_name "Subscription"
      field :updated, String, null: true do
        argument :x, Integer, required: false, removed: "2025-01-01"
        argument :x, String, required: false, added: "2025-01-01"
      end
    end
    extra = Class.new(b[:object]) { graphql_name "Extra"; lifecycle added: "2025-01-01"; field :y, String, null: true }
    late = Class.new(b[:object]) do
      graphql_name "Query"
      field :a, m1, null: true
      field :b, m2, null: true
      field :c, GraphQL::Schema::LateBoundType.new("Money"), null: true
    end
    plain = Class.new(b[:object]) { graphql_name "Query"; lifecycle added: "2024-06-01"; field :x, String, null: true }
    seen = []
    [[late, sub, [extra]], [plain, sub, [extra]], [plain, nil, [extra]]].each do |query, subscription, extras|
      schema = schema_over(query, :visibility, sub: subscription, extra: extras)
      2.times do
        run(schema, "{ __typename }", VA_OLDV)
        seen << "none"
      rescue StandardError => error
        seen << "#{error.class}: #{error.message}"
      end
    end
    warn "P01:\n#{seen.join("\n")}"
    expect(seen[0]).to match(/Query.c: names Money by name/)
    expect(seen[2]).to match(/Subscription.updated: Subscription.updated.x has two definitions/)
    expect(seen[4]).to match(/Query: a root type cannot have a lifecycle/)
    expect(seen.each_slice(2).all? { |first, second| first == second }).to be(true)
  end

  it "preservation P02: Location and Authorization's audit text are unchanged" do
    expect(GraphQL::Armory::Authorization::Location.of(VerifyAuditLocations::NoRule)).to match(%r{versioning_audit_probes_spec.rb:\d+\z})
    if defined?(GraphQL::Armory::Location)
      expect(GraphQL::Armory::Authorization::Location).to equal(GraphQL::Armory::Location)
    end
    schema = Class.new(ArmoryEngine.base_schema) do
      query(VerifyAuditLocations::Query)
      use GraphQL::Armory::Authorization, adapter: GraphQL::Armory::Authorization::Adapters::Substitute.new(allow: true)
    end
    text = GraphQL::Armory::Authorization::Audit.(schema).to_s
    expect(text).to include("NoRule")
  end

  it "preservation P03: the rake tasks load, once each, and the versions task runs the command" do
    app = Rake::Application.new
    original = Rake.application
    Rake.application = app
    load File.expand_path("../../lib/tasks/graphql_armory.rake", __dir__)
    load File.expand_path("../../lib/tasks/graphql_armory.rake", __dir__)
    expect(Rake::Task.task_defined?("graphql_armory:audit")).to be(true)
    expect(Rake::Task.task_defined?("graphql_armory:audit_baseline")).to be(true)
    expect(Rake::Task["graphql_armory:audit"].actions.size).to eq(1)
    if defined?(GraphQL::Armory::Versioning::Audit)
      expect(Rake::Task["graphql_armory:versions:audit"].actions.size).to eq(1)
      Object.const_set(:VerifyAuditOkSchema, vv::Controls::Schema.example)
      b = bases
      kind = Class.new(b[:enum]) { graphql_name "Kind"; value "A", removed: "2025-01-01" }
      Object.const_set(:VerifyAuditBadSchema, schema_over(Class.new(b[:object]) { graphql_name "Query"; field :kind, kind, null: true }, :visibility))
      out = StringIO.new
      original_stdout = $stdout
      $stdout = out
      begin
        Rake::Task["graphql_armory:versions:audit"].invoke("VerifyAuditOkSchema")
        Rake::Task["graphql_armory:versions:audit"].reenable
        expect { Rake::Task["graphql_armory:versions:audit"].invoke("VerifyAuditBadSchema") }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      ensure
        $stdout = original_stdout
      end
      expect(out.string).to include("No problems.").and include("Kind (empty)")
      nested = begin
        vv::Audit::Command.new(out: StringIO.new).("Nope::Deeper")
      rescue NameError => error
        "raised #{error.class}: #{error.message}"
      end
      warn "P03: Command on a missing nested name: #{nested.inspect}"
    end
  ensure
    Object.send(:remove_const, :VerifyAuditOkSchema) if Object.const_defined?(:VerifyAuditOkSchema)
    Object.send(:remove_const, :VerifyAuditBadSchema) if Object.const_defined?(:VerifyAuditBadSchema)
    Rake.application = original if original
  end
end
