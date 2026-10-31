# frozen_string_literal: true

require "fileutils"

# Recheck probes for 92c3c2b (SH1b, OC1/OC2, PA3). Each probe is its own example.
$zz_dump = {}

RSpec.describe "zz recheck 92c3c2b" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:adapter) { armory::Adapters::Substitute.new(allow: false) }
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
      default_action :read
    end
  end

  after(:all) do
  end

  def query_type(&block)
    Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :ping, String, null: true, authorize: :none, reason: "x"
      class_eval(&block)
    end
  end

  def schema_for(query_class, with: adapter, setup: nil)
    plugin = armory
    armory_adapter = with
    Class.new(base_schema) do
      use plugin, adapter: armory_adapter
      query query_class
      class_eval(&setup) if setup
    end
  end

  def report(schema)
    armory::Audit.(schema)
  end

  def record(name, rep)
    text = rep.problems.map { |p| "P #{p.path.gsub(/0x\h+/, '0x')} #{p.kind}: #{p.message.gsub(/0x\h+/, '0x')}" } +
           rep.bypasses.map { |b| "B #{b.path.gsub(/0x\h+/, '0x')}: #{b.reason}" }
    $zz_dump[name] = text.join("\n")
    puts "ZZ[#{name}] ok=#{rep.ok?}\n  #{text.join("\n  ")}"
  end

  def query_of(type)
    query_type { field :doc, type, null: true, authorize: :none, reason: "x" }
  end

  def root_doc(notes = "SECRET")
    Struct.new(:doc).new(Struct.new(:notes, :term).new(notes, nil))
  end

  def notes_for(schema, query = "{ doc { notes } }")
    result = execute_query(schema, query, root_value: root_doc, context: { current_user: :someone }).to_h
    puts "ZZ   runtime #{query} => #{result.inspect}"
    result.dig("data", "doc", "notes")
  end

  def messages_at(rep, path)
    rep.problems.select { |p| p.path == path }
  end

  def served_message?(rep, path)
    messages_at(rep, path).any? { |p| p.message.include?("served with no check") }
  end

  def denied_message?(rep, path)
    messages_at(rep, path).any? { |p| p.message.include?("so it is denied") }
  end

  def own_check_paths(rep)
    rep.problems.select { |p| p.kind == :own_check }.map(&:path)
  end

  def parent_with(rule: [:read, { model: ::Invoice }], &block)
    fk = base_field
    Class.new(base_object) do
      field_class fk
      authorize(rule[0], **rule[1]) if rule
      class_eval(&block)
    end
  end

  # A field class whose definitions graphql-ruby hides with no Schema::Visibility: a fallback serves the one below.
  def hidden_field
    Class.new(base_field) do
      def visible?(_context)
        false
      end
    end
  end

  # ----------------------------------------------------------------- PA3
  describe "PA3" do
    it "[preservation] PA3-2 parent :none without covers_fields: runtime denies and the audit says denied, not served" do
      parent = parent_with(rule: [:none, { reason: "p" }]) { field :notes, String, null: true }
      child = Class.new(parent) { graphql_name "Doc"; authorize :none, reason: "public" }
      schema = schema_for(query_of(child))
      rep = report(schema)
      record("PA3-2", rep)

      expect(notes_for(schema)).to be_nil
      expect(denied_message?(rep, "Doc.notes")).to be(true)
      expect(served_message?(rep, "Doc.notes")).to be(false)
    end

    it "[security] PA3-3 parent :none with covers_fields: served, and the audit says served" do
      parent = parent_with(rule: [:none, { reason: "p", covers_fields: true }]) { field :notes, String, null: true }
      child = Class.new(parent) { graphql_name "Doc"; authorize :none, reason: "public" }
      schema = schema_for(query_of(child))
      rep = report(schema)
      record("PA3-3", rep)

      expect(notes_for(schema)).to eq("SECRET")
      expect(served_message?(rep, "Doc.notes")).to be(true)
    end

    it "[preservation] PA3-4 interface field on a bypassed implementer: denied, reported once on the interface" do
      fk = base_field
      iface = Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Noted"
        field_class fk
        field :notes, String, null: true
      end
      child = Class.new(base_object) { graphql_name "Doc"; implements iface; authorize :none, reason: "public" }
      schema = schema_for(query_of(child))
      rep = report(schema)
      record("PA3-4", rep)

      expect(notes_for(schema)).to be_nil
      expect(messages_at(rep, "Doc.notes")).to eq([])
      expect(messages_at(rep, "Noted.notes").size).to eq(1)
    end

    it "[security] PA3-5 owner two levels up through a class with no rule of its own: served, audit says served" do
      grand = parent_with { field :notes, String, null: true }
      middle = Class.new(grand)
      child = Class.new(middle) { graphql_name "Doc"; authorize :none, reason: "public" }
      schema = schema_for(query_of(child))
      rep = report(schema)
      record("PA3-5", rep)

      expect(notes_for(schema)).to eq("SECRET")
      expect(served_message?(rep, "Doc.notes")).to be(true)
    end

    it "[security] PA3-5b middle class bypassed without covers, owner above has a rule: served, audit says served" do
      grand = parent_with { field :notes, String, null: true }
      middle = Class.new(grand) { authorize :none, reason: "m" }
      child = Class.new(middle) { graphql_name "Doc" }
      schema = schema_for(query_of(child))
      rep = report(schema)
      record("PA3-5b", rep)

      expect(notes_for(schema)).to eq("SECRET")
      expect(served_message?(rep, "Doc.notes")).to be(true)
    end

    it "[security] PA3-6 bypassed type redeclares with authorize: — live def denied and not called served; shadowed def served on fallback" do
      parent = parent_with { field :notes, String, null: true }
      fk = base_field
      child = Class.new(parent) do
        field_class fk
        graphql_name "Doc"
        authorize :none, reason: "public"
        field :notes, String, null: true, authorize: :manage
      end
      schema = schema_for(query_of(child))
      rep = report(schema)
      record("PA3-6", rep)

      expect(notes_for(schema)).to be_nil
      expect(rep.ok?).to be(false)
      expect(messages_at(rep, "Doc.notes").count { |p| p.message.include?("served with no check") }).to eq(1)
    end

    it "[security] PA3-6b same, but the live def is hidden: the fallback serves the parent's def, and the audit said served" do
      parent = parent_with { field :notes, String, null: true }
      hf = hidden_field
      child = Class.new(parent) do
        field_class hf
        graphql_name "Doc"
        authorize :none, reason: "public"
        field :notes, String, null: true, authorize: :manage
      end
      schema = schema_for(query_of(child))
      rep = report(schema)
      record("PA3-6b", rep)

      served = notes_for(schema) == "SECRET"
      expect(served_message?(rep, "Doc.notes")).to eq(served)
      expect(served).to be(true)
    end

    it "[security] PA3-7 bypassed type redeclares WITHOUT authorize: live def denied (message denied), shadowed served (message served)" do
      parent = parent_with { field :notes, String, null: true }
      fk = base_field
      child = Class.new(parent) do
        field_class fk
        graphql_name "Doc"
        authorize :none, reason: "public"
        field :notes, String, null: true
      end
      schema = schema_for(query_of(child))
      allowed = schema_for(query_of(child), with: armory::Adapters::Substitute.new(allow: true))
      rep = report(schema)
      record("PA3-7", rep)

      expect(notes_for(schema)).to be_nil
      expect(notes_for(allowed)).to be_nil
      expect(denied_message?(rep, "Doc.notes")).to be(true)
      expect(served_message?(rep, "Doc.notes")).to be(true)
    end

    it "[security] PA3-7b same with the live def hidden: the fallback serves the parent's def" do
      parent = parent_with { field :notes, String, null: true }
      hf = hidden_field
      child = Class.new(parent) do
        field_class hf
        graphql_name "Doc"
        authorize :none, reason: "public"
        field :notes, String, null: true
      end
      schema = schema_for(query_of(child))
      rep = report(schema)
      record("PA3-7b", rep)

      expect(notes_for(schema)).to eq("SECRET")
      expect(served_message?(rep, "Doc.notes")).to be(true)
    end

    it "[security] PA3-9 parent field declares authorize: true: what the audit says matches what a refused user gets" do
      parent = parent_with { field :notes, String, null: true, authorize: true }
      child = Class.new(parent) { graphql_name "Doc"; authorize :none, reason: "public" }
      schema = schema_for(query_of(child))
      rep = report(schema)
      record("PA3-9", rep)

      served = notes_for(schema) == "SECRET"
      expect(served_message?(rep, "Doc.notes")).to eq(served)
    end

    it "[security] PA3-9b parent bypassed with covers_fields and field authorize: true: audit matches runtime" do
      parent = parent_with(rule: [:none, { reason: "p", covers_fields: true }]) { field :notes, String, null: true, authorize: true }
      child = Class.new(parent) { graphql_name "Doc"; authorize :none, reason: "public" }
      schema = schema_for(query_of(child))
      allowed = schema_for(query_of(child), with: armory::Adapters::Substitute.new(allow: true))
      rep = report(schema)
      record("PA3-9b", rep)

      served = notes_for(schema) == "SECRET"
      puts "ZZ   PA3-9b allowed user gets #{notes_for(allowed).inspect}"
      expect(served_message?(rep, "Doc.notes")).to eq(served)
    end

    it "[preservation] PA3-11 subclass with its own rule (not bypassed): no field finding, refused user gets nothing" do
      parent = parent_with { field :notes, String, null: true }
      child = Class.new(parent) { graphql_name "Doc"; authorize :manage, model: ::Invoice }
      schema = schema_for(query_of(child))
      rep = report(schema)
      record("PA3-11", rep)

      expect(notes_for(schema)).to be_nil
      expect(messages_at(rep, "Doc.notes")).to eq([])
    end

    it "[preservation] PA3-12 reverse: parent bypassed, subclass with a rule: field denied even to an allowed user; audit observation" do
      parent = parent_with(rule: [:none, { reason: "p" }]) { field :notes, String, null: true }
      child = Class.new(parent) { graphql_name "Doc"; authorize :read, model: ::Invoice }
      allowed = schema_for(query_of(child), with: armory::Adapters::Substitute.new(allow: true))
      rep = report(allowed)
      record("PA3-12", rep)

      expect(notes_for(allowed)).to be_nil
      expect(served_message?(rep, "Doc.notes")).to be(false)
    end

    it "[security] PA3-13 bypassed Query root inheriting a field from a base query with a default action: served, audit says served" do
      fk = base_field
      base_query = Class.new(base_object) do
        field_class fk
        field :secret, String, null: true
      end
      query = Class.new(base_query) do
        graphql_name "Query"
        authorize :none, reason: "root"
        field :ping, String, null: true, authorize: :none, reason: "x"
      end
      schema = schema_for(query)
      rep = report(schema)
      record("PA3-13", rep)
      root = Struct.new(:secret, :ping).new("SECRET", "pong")
      result = execute_query(schema, "{ secret }", root_value: root, context: { current_user: :someone }).to_h
      puts "ZZ   runtime => #{result.inspect}"

      expect(result.dig("data", "secret")).to eq("SECRET")
      expect(served_message?(rep, "Query.secret")).to be(true)
    end
  end

  # ----------------------------------------------------------------- served_by_owner?
  describe "served_by_owner?" do
    it "[security] SO-1 owner is a Class without Base (field class with Base): audit must not say denied if it is served" do
      plugin = armory
      fk = base_field
      parent = Class.new(GraphQL::Schema::Object) do
        field_class fk
        field :notes, String, null: true
      end
      child = Class.new(parent) do
        include plugin::Base
        graphql_name "Doc"
        authorize :none, reason: "public"
      end
      schema = schema_for(query_of(child))
      rep = report(schema)
      record("SO-1", rep)
      puts "ZZ   SO-1 authorized? owner=#{child.fields['notes'].method(:authorized?).owner}"
      puts "ZZ   SO-1 notes owner=#{child.fields['notes'].owner.inspect} respond_to armory_rule=#{child.fields['notes'].owner.respond_to?(:armory_rule)}"

      served = notes_for(schema) == "SECRET"
      expect(served && denied_message?(rep, "Doc.notes")).to be(false)
      expect(served_message?(rep, "Doc.notes")).to eq(served)
    end

    it "[security] SO-2 owner whose armory_rule raises: the audit raises, never returns a report" do
      parent = parent_with { field :notes, String, null: true }
      parent.define_singleton_method(:armory_rule) { raise "owner-boom" }
      child = Class.new(parent) { graphql_name "Doc"; authorize :none, reason: "public" }
      schema = schema_for(query_of(child))

      outcome = begin
        report(schema).ok?
      rescue StandardError => error
        error
      end
      puts "ZZ   SO-2 audit => #{outcome.inspect}"
      expect(outcome).to be_a(RuntimeError)
    end


    it "[security] SO-4 field class without Base on a bypassed type: audit says denied — does a refused user get it?" do
      plugin_field = GraphQL::Schema::Field
      child = Class.new(base_object) do
        graphql_name "Doc"
        authorize :none, reason: "public"
        field_class plugin_field
        field :notes, String, null: true
      end
      schema = schema_for(query_of(child))
      rep = report(schema)
      record("SO-4", rep)

      puts "ZZ   SO-4 authorized? owner=#{child.fields['notes'].method(:authorized?).owner}"
      served = notes_for(schema) == "SECRET"
      expect(served && denied_message?(rep, "Doc.notes")).to be(false)
    end

    it "[security] SO-5 field class without Base inherited by a bypassed type from a parent with a rule" do
      plugin_field = GraphQL::Schema::Field
      parent = Class.new(base_object) do
        authorize :read, model: ::Invoice
        field_class plugin_field
        field :notes, String, null: true
      end
      child = Class.new(parent) { graphql_name "Doc"; authorize :none, reason: "public" }
      schema = schema_for(query_of(child))
      rep = report(schema)
      record("SO-5", rep)

      served = notes_for(schema) == "SECRET"
      expect(served && denied_message?(rep, "Doc.notes")).to be(false)
    end
  end

  # ----------------------------------------------------------------- OC1/OC2
  describe "OC1/OC2" do
    def declared_child(parent, field_class: base_field)
      fk = field_class
      Class.new(parent) do
        field_class fk
        graphql_name "Doc"
        field :notes, String, null: true, authorize: :manage, override_reason: "as strict"
      end
    end

    it "[security] OC-1 own authorized? on a shadowed FIELD class is reported" do
      open = Class.new(base_field) do
        def authorized?(_object, _args, _context)
          true
        end
      end
      parent = parent_with { field_class open; field :notes, String, null: true, authorize: :manage }
      rep = report(schema_for(query_of(declared_child(parent))))
      record("OC-1", rep)

      expect(own_check_paths(rep)).to include("#{open.inspect}#authorized?")
    end

    it "[security] OC-2 own authorized? on a resolver's ancestor (R2 < R1), the field shadowed two class levels down" do
      plugin = armory
      r1 = Class.new(GraphQL::Schema::Resolver) do
        include plugin::Base
        graphql_name "OpenNotes"
        type String, null: true
        authorize :manage, model: ::Invoice
        def authorized?(**)
          true
        end
      end
      r2 = Class.new(r1) { graphql_name "OpenNotes2" }
      grand = parent_with { field :notes, resolver: r2 }
      middle = Class.new(grand)
      rep = report(schema_for(query_of(declared_child(middle))))
      record("OC-2", rep)

      expect(own_check_paths(rep)).to include("#{r1.inspect}#authorized?")
    end

    it "[security] OC-3 own authorized? on a shadowed field's ARGUMENT class is reported" do
      open_arg = Class.new(base_argument) do
        def authorized?(_object, _value, _context)
          true
        end
      end
      parent = parent_with do
        field :notes, String, null: true, authorize: :manage do
          argument_class open_arg
          argument :term, String, required: false, authorize: :manage
        end
      end
      rep = report(schema_for(query_of(declared_child(parent))))
      record("OC-3", rep)

      expect(own_check_paths(rep)).to include("#{open_arg.inspect}#authorized?")
    end

    it "[security] OC-4 own visible? with visible_when on a shadowed field is reported" do
      vis = Class.new(base_field) do
        def visible?(_context)
          true
        end
      end
      parent = parent_with { field_class vis; field :notes, String, null: true, authorize: :manage, visible_when: :export }
      rep = report(schema_for(query_of(declared_child(parent))))
      record("OC-4", rep)

      expect(own_check_paths(rep)).to include("#{vis.inspect}#visible?")
    end

    it "[security] OC-5 own unauthorized_object on a shadowed resolver is reported" do
      plugin = armory
      res = Class.new(GraphQL::Schema::Resolver) do
        include plugin::Base
        graphql_name "Notes"
        type String, null: true
        authorize :manage, model: ::Invoice
        def unauthorized_object(error)
          error.object
        end
      end
      parent = parent_with { field :notes, resolver: res }
      rep = report(schema_for(query_of(declared_child(parent))))
      record("OC-5", rep)

      expect(own_check_paths(rep)).to include("#{res.inspect}#unauthorized_object")
    end

    it "[security] OC-6 resolvers at two ancestor levels, each with an own authorized?: both reported" do
      plugin = armory
      make = lambda do |name|
        Class.new(GraphQL::Schema::Resolver) do
          include plugin::Base
          graphql_name name
          type String, null: true
          authorize :manage, model: ::Invoice
          def authorized?(**)
            true
          end
        end
      end
      ra = make.("NotesA")
      rb = make.("NotesB")
      grand = parent_with { field :notes, resolver: ra }
      middle = Class.new(grand) { field :notes, resolver: rb }
      rep = report(schema_for(query_of(declared_child(middle))))
      record("OC-6", rep)

      expect(own_check_paths(rep)).to include("#{ra.inspect}#authorized?", "#{rb.inspect}#authorized?")
    end

    it "[preservation] OC-7 a live definition's own check is reported once, however many types inherit or shadow it" do
      open = Class.new(base_field) do
        def authorized?(_object, _args, _context)
          true
        end
      end
      parent = parent_with { field_class open; field :notes, String, null: true, authorize: :manage }
      kids = %w[DocA DocB DocC].map { |name| Class.new(parent) { graphql_name name } }
      shadow = declared_child(parent)
      query = query_type do
        kids.each_with_index { |kid, i| field :"doc#{i}", kid, null: true, authorize: :none, reason: "x" }
        field :doc, shadow, null: true, authorize: :none, reason: "x"
      end
      rep = report(schema_for(query))
      record("OC-7", rep)

      expect(own_check_paths(rep).count("#{open.inspect}#authorized?")).to eq(1)
    end

    it "[security] OC-8 runtime: a hidden override falls back to a shadowed def whose field class answers true; the audit reports that own check" do
      open = Class.new(base_field) do
        def authorized?(_object, _args, _context)
          true
        end
      end
      hf = hidden_field
      parent = parent_with(rule: [:none, { reason: "p", covers_fields: true }]) { field_class open; field :notes, String, null: true, authorize: :manage }
      child = Class.new(parent) do
        field_class hf
        graphql_name "Doc"
        field :notes, String, null: true, authorize: :manage, override_reason: "as strict"
      end
      schema = schema_for(query_of(child))
      rep = report(schema)
      record("OC-8", rep)

      expect(notes_for(schema)).to eq("SECRET")
      expect(own_check_paths(rep)).to include("#{open.inspect}#authorized?")
    end
  end

  # ----------------------------------------------------------------- SH1b
  describe "SH1b" do
    def raising_adapter(error)
      plugin = armory
      Class.new(plugin::Adapters::Substitute) do
        define_method(:initialize) { super(allow: false) }
        define_method(:check) { |_model, rule| rule.action == :manage ? raise(error) : [] }
      end.new
    end

    def doc_schema(error, shadowed:)
      parent = parent_with { field :notes, String, null: true, authorize: :manage }
      fk = base_field
      child = Class.new(parent) do
        field_class fk
        graphql_name "Doc"
        authorize :read, model: ::Invoice
        if shadowed
          field :notes, String, null: true, authorize: :none, reason: "x", override_reason: "y"
        end
      end
      schema_for(query_of(child), with: raising_adapter(error))
    end

    [["ConfigurationError", -> { GraphQL::Armory::Authorization::ConfigurationError }],
     ["AdapterError", -> { GraphQL::Armory::Authorization::AdapterError }],
     ["RuntimeError", -> { RuntimeError }]].each do |label, klass|
      it "[security] SH-#{label}-shadowed: an adapter raising #{label} while checking a shadowed field fails the audit" do
        error_class = klass.call
        schema = doc_schema(error_class.new("boom-#{label}"), shadowed: true)
        expect { report(schema) }.to raise_error(error_class, "boom-#{label}")
      end

      it "[preservation] SH-#{label}-live: an adapter raising #{label} while checking a live field fails the audit" do
        error_class = klass.call
        schema = doc_schema(error_class.new("boom-#{label}"), shadowed: false)
        expect { report(schema) }.to raise_error(error_class, "boom-#{label}")
      end
    end

    it "[security] SH-4 a shadowed field whose type is a missing constant: audit runs, its declaration and arguments are still audited" do
      parent = parent_with do
        field :notes, "ZzMissingType", null: true do
          argument :term, String, required: false, authorize: :none, reason: "term-reason"
        end
      end
      fk = base_field
      child = Class.new(parent) do
        field_class fk
        graphql_name "Doc"
        authorize :none, reason: "public"
        field :notes, String, null: true, authorize: :none, reason: "x", override_reason: "y"
      end
      schema = schema_for(query_of(child))
      rep = report(schema)
      record("SH-4", rep)

      expect(served_message?(rep, "Doc.notes")).to be(true)
      expect(rep.bypasses.map(&:path)).to include("Doc.notes(term)")
      expect(notes_for(schema)).to eq("SECRET")
    end

    it "[security] SH-5 a shadowed field whose type is an anonymous class without graphql_name: never a silent ok" do
      plugin = armory
      anon = Class.new(base_object) { authorize :read, model: ::Invoice }
      parent = begin
        parent_with { field :notes, anon, null: true }
      rescue StandardError => error
        puts "ZZ   SH-5 cannot even be defined: #{error.class}"
        next
      end
      fk = base_field
      child = Class.new(parent) do
        field_class fk
        graphql_name "Doc"
        authorize :none, reason: "public"
        field :notes, String, null: true, authorize: :none, reason: "x", override_reason: "y"
      end
      schema = schema_for(query_of(child))
      outcome = begin
        rep = report(schema)
        record("SH-5", rep)
        rep.ok?
      rescue StandardError => error
        error
      end
      puts "ZZ   SH-5 audit => #{outcome.inspect[0, 300]}"
      puts "ZZ   SH-5 runtime notes => #{notes_for(schema).inspect}"
      expect(outcome).not_to eq(true)
    end

    it "[security] SH-6 a shadowed field whose block names a missing constant: never a silent ok" do
      parent = parent_with do
        field :notes, String, null: true do
          argument :term, ZzMissingArgType, required: false
        end
      end
      fk = base_field
      child = Class.new(parent) do
        field_class fk
        graphql_name "Doc"
        authorize :none, reason: "public"
        field :notes, String, null: true, authorize: :none, reason: "x", override_reason: "y"
      end
      schema = schema_for(query_of(child))
      runtime = begin
        notes_for(schema).inspect
      rescue StandardError, NameError => error
        error.class.name
      end
      outcome = begin
        report(schema).ok?
      rescue StandardError, NameError => error
        error
      end
      puts "ZZ   SH-6 runtime => #{runtime}; audit => #{outcome.inspect[0, 200]}"
      expect(outcome).not_to eq(true)
    end
  end

  # ----------------------------------------------------------------- preservation
  describe "preservation" do
    it "[preservation] PR-1 relay connection and edge types: no served finding, report recorded" do
      doc = parent_with { field :notes, String, null: true }
      doc.graphql_name "Doc"
      query = query_type { field :docs, doc.connection_type, null: true, authorize: :none, reason: "x" }
      rep = report(schema_for(query))
      record("PR-1", rep)

      expect(rep.problems.map(&:message).grep(/served with no check/)).to eq([])
    end

    it "[preservation] PR-2 global_id_field :id with override_reason over Node: the bypass is listed, nothing served" do
      fk = base_field
      doc = Class.new(base_object) do
        field_class fk
        graphql_name "Doc"
        authorize :read, model: ::Invoice
        implements GraphQL::Types::Relay::Node
        global_id_field :id, override_reason: "Node's id answers the same"
      end
      query = query_type do
        field :doc, doc, null: true, authorize: :none, reason: "x"
      end
      schema = schema_for(query, setup: proc { def self.id_from_object(o, t, c) = "x"; def self.object_from_id(i, c) = nil; def self.resolve_type(t, o, c) = nil })
      rep = report(schema)
      record("PR-2", rep)

      expect(rep.bypasses.map(&:reason)).to include("Node's id answers the same")
      expect(rep.problems.map(&:message).grep(/served with no check/)).to eq([])
    end

    it "[preservation] PR-3 interface fields on a bypassed implementer through a parent class: once on the interface, never served" do
      fk = base_field
      iface = Module.new do
        include GraphQL::Schema::Interface
        graphql_name "Noted"
        field_class fk
        field :notes, String, null: true
        field :title, String, null: true, authorize: :none, reason: "t"
      end
      parent = parent_with { implements iface }
      child = Class.new(parent) { graphql_name "Doc"; authorize :none, reason: "public" }
      schema = schema_for(query_of(child))
      rep = report(schema)
      record("PR-3", rep)

      expect(notes_for(schema)).to be_nil
      expect(messages_at(rep, "Doc.notes")).to eq([])
      expect(messages_at(rep, "Noted.notes").size).to eq(1)
      expect(rep.problems.map(&:message).grep(/served with no check/)).to eq([])
    end

    it "[preservation] PR-4 mutation and resolver fields on a bypassed Query root: no field_without_rule" do
      plugin = armory
      mutation = Class.new(GraphQL::Schema::Mutation) do
        include plugin::Base
        graphql_name "CreateDoc"
        authorize :manage, model: ::Invoice
        field :ok, GraphQL::Types::Boolean, null: true
      end
      resolver = Class.new(GraphQL::Schema::Resolver) do
        include plugin::Base
        graphql_name "FindDoc"
        type String, null: true
        authorize :none, reason: "find"
      end
      fk = base_field
      query = Class.new(base_object) do
        field_class fk
        graphql_name "Query"
        authorize :none, reason: "root"
        field :find, resolver: resolver
      end
      mutation_root = Class.new(base_object) do
        field_class fk
        graphql_name "Mutation"
        authorize :none, reason: "root"
        field :create_doc, mutation: mutation
      end
      schema = schema_for(query, setup: proc { mutation mutation_root })
      rep = report(schema)
      record("PR-4", rep)

      expect(rep.problems.map(&:kind)).not_to include(:field_without_rule)
    end

    it "[preservation] PR-5 300 types x 80 fields audit in under 60 seconds" do
      fk = base_field
      parent = parent_with { 40.times { |j| field :"p#{j}", String, null: true } }
      types = Array.new(300) do |i|
        Class.new(i.even? ? parent : base_object) do
          field_class fk
          graphql_name "T#{i}"
          if i % 3 == 0
            authorize :none, reason: "b"
          else
            authorize :read, model: ::Invoice
          end
          (i.even? ? 40 : 80).times { |j| field :"f#{j}", String, null: true }
        end
      end
      query = query_type { types.each_with_index { |type, i| field :"t#{i}", type, null: true, authorize: :none, reason: "x" } }
      schema = schema_for(query)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      rep = report(schema)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      puts "ZZ   PR-5 #{elapsed.round(2)}s, #{rep.problems.size} problems, #{rep.bypasses.size} bypasses"
      $zz_dump["PR-5"] = "problems=#{rep.problems.size} bypasses=#{rep.bypasses.size} kinds=#{rep.problems.map(&:kind).tally.sort.inspect}"

      expect(elapsed).to be < 60
    end
  end
end
