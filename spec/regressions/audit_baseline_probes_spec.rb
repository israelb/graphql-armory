# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require "open3"
require "pathname"
require "graphql/armory/authorization/rspec"

# Independent verification of Audit::Baseline. Each `it` is labelled [security] or [preservation].
class ProbeAnything
  VALUES = { ssn: "123-45", secret: "s3cret", all_users: "everyone" }.freeze
  def respond_to_missing?(*) = true
  def method_missing(name, *) = VALUES.fetch(name) { self }
end unless defined?(ProbeAnything)

RSpec.describe "Audit baseline probes" do
  z = GraphQL::Armory::Authorization
  root_dir = File.expand_path("../..", __dir__)
  out_dir = File.join(root_dir, ".probe_out")
  config = "#{ENV.fetch('GRAPHQL_ARMORY_ENGINE', 'interpreter')}-#{GraphQL::VERSION}"

  let(:audit) { z::Audit }
  let(:baseline) { z::Audit::Baseline }

  around do |example|
    Dir.mktmpdir("baseline-probe") do |dir|
      @dir = dir
      example.run
    end
  end

  def self.needs_baseline
    before { skip "no Audit::Baseline in this copy" unless defined?(GraphQL::Armory::Authorization::Audit::Baseline) }
  end

  define_method(:fc) { @fc ||= Class.new(GraphQL::Schema::Field) { include z::Base } }

  # A type whose base class never included Base.
  def open_type(name = "Invoice", &extra)
    Class.new(GraphQL::Schema::Object) do
      graphql_name name
      field :total, String
      def total = "10"
      class_eval(&extra) if extra
    end
  end

  # A protected bypass that needs nothing else, for roots and neighbours.
  define_method(:armored) do |name = "Query", &extra|
    klass = fc
    Class.new(GraphQL::Schema::Object) do
      include z::Base
      field_class klass
      graphql_name name
      authorize :none, reason: "probe", covers_fields: true
      class_eval(&extra) if extra
    end
  end

  define_method(:schema_of) do |root, plugin: true, **options|
    Class.new(ArmoryEngine.base_schema) do
      query root
      use z, adapter: :pundit, **options if plugin
    end
  end

  def query_with(type, name = :invoice)
    armored do
      field name, type, null: true
      define_method(name) { :record }
    end
  end

  def path = File.join(@dir, "baseline.json")

  def accept(schema, at = path)
    baseline.write(audit.(schema), at)
  end

  def judge(schema, at = path)
    baseline.load(at).(audit.(schema))
  end

  def data_of(schema, query)
    execute_query(schema, query, root_value: ProbeAnything.new, context: { current_user: nil }).to_h
  end

  # ---------------------------------------------------------------- 1. identity
  describe "identity of an entry", :baseline do
    needs_baseline

    it "[security] I1 a new field on an accepted unprotected type fails" do
      accept(schema_of(query_with(open_type)))
      changed = schema_of(query_with(open_type { field(:ssn, String); def ssn = "123-45" }))
      expect(data_of(changed, "{ invoice { ssn } }").dig("data", "invoice", "ssn")).to eq("123-45")
      expect(judge(changed).passes?).to be(false)
    end

    it "[security] I2 a new field on an accepted unprotected Query root fails" do
      accept(schema_of(open_type("Query")))
      changed = schema_of(open_type("Query") { field(:all_users, String); def all_users = "everyone" })
      expect(data_of(changed, "{ allUsers }").dig("data", "allUsers")).to eq("everyone")
      expect(judge(changed).passes?).to be(false)
    end

    it "[security] I2b a new field on an accepted unprotected Mutation root fails" do
      m = ->(extra) { open_type("Mutation") { class_eval(&extra) if extra } }
      first = m.(nil)
      old = Class.new(schema_of(armored)) { mutation first }
      accept(old)
      second = m.(proc { field(:delete_all, String) })
      changed = Class.new(schema_of(armored)) { mutation second }
      expect(judge(changed).passes?).to be(false)
    end

    define_method(:connection_type) do |&extra|
      klass = fc
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

    it "[security] I3 a new field on an accepted ignored_rule type (library's authorized? answers) fails" do
      accept(schema_of(query_with(connection_type, :foo)))
      expect(baseline.load(path).entries.map(&:kind)).to include("ignored_rule")
      changed = schema_of(query_with(connection_type { field(:secret, String); def secret = "s3cret" }, :foo))
      expect(judge(changed).passes?).to be(false)
    end

    it "[preservation] I4a a new field on an accepted no_rule type is denied at run time" do
      klass = fc
      type = ->(extra) { Class.new(GraphQL::Schema::Object) { include z::Base; field_class klass; graphql_name "Foo"; field(:a, String); def a = "a"; class_eval(&extra) if extra } }
      accept(schema_of(query_with(type.(nil), :foo)))
      changed = schema_of(query_with(type.(proc { field(:secret, String); def secret = "s3cret" }), :foo))
      expect(judge(changed).passes?).to be(false) # it grew
      expect(data_of(changed, "{ foo { secret } }").to_s).not_to include("s3cret")
    end

    it "[security] I4b a new no-rule field on an accepted :model type: refused or named" do
      klass = fc
      type = ->(extra) { Class.new(GraphQL::Schema::Object) { include z::Base; field_class klass; graphql_name "NoSuchModelAnywhere"; authorize :read; field(:a, String); def a = "a"; class_eval(&extra) if extra } }
      accept(schema_of(query_with(type.(nil), :foo)))
      expect(baseline.load(path).entries.map(&:kind)).to include("model")
      changed = schema_of(query_with(type.(proc { field(:secret, String); def secret = "s3cret" }), :foo))
      seen = begin
        data_of(changed, "{ foo { secret } }").to_s
      rescue StandardError => error
        error.class.to_s
      end
      expect(seen).not_to include("s3cret")
    end

    it "[security] I5 a second non-Base definition of an accepted field (parent and child) fails" do
      child = ->(parent) { Class.new(parent) { graphql_name "Foo"; field(:bar, String) } }
      plain = Class.new(GraphQL::Schema::Object) { include z::Base; field_class GraphQL::Schema::Field; authorize :none, reason: "x" }
      accept(schema_of(query_with(child.(plain), :foo)))
      with_parent = Class.new(plain) { field(:bar, String) }
      changed = schema_of(query_with(child.(with_parent), :foo))
      result = judge(changed)
      expect(result.passes?).to be(false), "problems #{result.report.problems.map(&:to_a)} entries #{baseline.load(path).entries.size}"
    end

    it "[security] I6 a third definition under an accepted 'defined more than once' fails" do
      klass = fc
      top = Class.new(GraphQL::Schema::Object) { include z::Base; field_class klass; authorize :none, reason: "x", covers_fields: true }
      mid = Class.new(top) { field(:bar, String, authorize: :none, reason: "a") }
      foo = ->(parent) { Class.new(parent) { graphql_name "Foo"; field(:bar, String, authorize: :none, reason: "b") } }
      accept(schema_of(query_with(foo.(mid), :foo)))
      expect(baseline.load(path).entries.map(&:kind)).to include("ignored_rule")
      deeper = Class.new(mid) { field(:bar, String, authorize: :none, reason: "c") }
      changed = schema_of(query_with(foo.(deeper), :foo))
      result = judge(changed)
      expect(result.passes?).to be(false), "problems #{result.report.problems.map(&:to_a).map { |a| a.first(2) }} entries #{baseline.load(path).entries.size}"
    end

    it "[security] I7 a second class with an accepted type's graphql_name, behind visible?, fails" do
      a = open_type { def self.visible?(context) = !context[:admin] }
      b = open_type { field(:ssn, String); def self.visible?(context) = !!context[:admin] }
      old = armored { field :a, a, null: true }
      accept(schema_of(old))
      changed = armored { field :a, a, null: true; field :b, b, null: true }
      expect(judge(schema_of(changed)).passes?).to be(false)
    end

    it "[security] I7b the accepted class replaced by another of the same graphql_name with more fields fails" do
      accept(schema_of(query_with(open_type)))
      other = Class.new(GraphQL::Schema::Object) { graphql_name "Invoice"; field(:card_number, String) }
      expect(judge(schema_of(query_with(other))).passes?).to be(false)
    end

    it "[security] I9 a new bypassed implementer under an accepted Interface.field fails" do
      iface = Module.new { include GraphQL::Schema::Interface; graphql_name "Thing"; field(:secret, String) }
      type = lambda do |name|
        klass = fc
        Class.new(GraphQL::Schema::Object) { include z::Base; field_class klass; graphql_name name; implements iface; authorize :none, reason: "x" }
      end
      one = type.("One")
      accept(schema_of(armored { field :one, one, null: true }))
      expect(baseline.load(path).entries.map(&:to_a).flatten).to include("Thing.secret")
      two = type.("Two")
      expect(judge(schema_of(armored { field :one, one, null: true; field :two, two, null: true })).passes?).to be(false)
    end

    it "[security] I10 a new type under an accepted own_check on its base class fails" do
      unless defined?(::ProbeOwnBase)
        Object.const_set(:ProbeOwnBase, Class.new(GraphQL::Schema::Object) { include z::Base; def self.authorized?(_o, _c) = true })
      end
      klass = fc
      kid = ->(name) { Class.new(::ProbeOwnBase) { field_class klass; graphql_name name; authorize :none, reason: "x", covers_fields: true } }
      foo = kid.("FooK")
      accept(schema_of(armored { field :foo, foo, null: true }))
      expect(baseline.load(path).entries.map(&:kind)).to include("own_check")
      bar = kid.("BarK")
      expect(judge(schema_of(armored { field :foo, foo, null: true; field :bar, bar, null: true })).passes?).to be(false)
    end

    it "[preservation] I11 a second own denial hook under an accepted one fails" do
      a = Class.new(schema_of(armored)) { def self.unauthorized_object(_e) = nil }
      accept(a)
      b = Class.new(a) { def self.unauthorized_field(_e) = nil }
      expect(judge(b).passes?).to be(false)
    end

    it "[security] I13 loads: pointed at another type under an accepted unscoped_load fails" do
      target_a = armored("TargetA")
      target_b = armored("TargetB")
      input = lambda do |target|
        Class.new(GraphQL::Schema::InputObject) { graphql_name "In"; argument :thing_id, GraphQL::Types::ID, required: false, loads: target }
      end
      root = lambda do |target|
        i = input.(target)
        armored { field(:x, String) { argument :in, i, required: false } }
      end
      accept(schema_of(root.(target_a)))
      expect(baseline.load(path).entries.map(&:kind)).to include("unscoped_load")
      expect(judge(schema_of(root.(target_b))).passes?).to be(false)
    end

    it "[security] I15a control: a new unprotected type fails and is named" do
      accept(schema_of(query_with(open_type)))
      other = open_type("Payment")
      first = open_type
      result = judge(schema_of(armored { field :invoice, first, null: true; field :payment, other, null: true }))
      expect(result.passes?).to be(false)
      expect(result.new_problems.map(&:path)).to include("Payment")
    end

    it "[security] I15b control: a new non-Base field on a bypassed protected type fails" do
      plain = lambda do |extra|
        Class.new(GraphQL::Schema::Object) { include z::Base; field_class GraphQL::Schema::Field; graphql_name "Foo"; authorize :none, reason: "x"; field(:a, String); class_eval(&extra) if extra }
      end
      accept(schema_of(query_with(plain.(nil), :foo)))
      result = judge(schema_of(query_with(plain.(proc { field(:b, String) }), :foo)))
      expect(result.new_problems.map(&:path)).to eq(["Foo.b"])
    end
  end

  # ---------------------------------------------------------------- 2. whole schema
  describe "whole-schema problems", :baseline do
    needs_baseline

    def entry_file(*entries)
      File.write(path, JSON.generate("version" => 1, "problems" => entries.map { |k, p, m| { "kind" => k, "path" => p, "message" => m } }))
    end

    let(:plugin_msg) { "never installed the plugin: add `use GraphQL::Armory::Authorization, adapter: ...`" }

    it "[security] W1 a plugin entry in a file is refused at load" do
      entry_file(["plugin", "Schema", plugin_msg])
      expect { baseline.load(path) }.to raise_error(z::ConfigurationError)
    end

    ["PLUGIN", " plugin", "plugin ", "Plugin"].each do |kind|
      it "[security] W1b kind #{kind.inspect} cannot accept a schema with no plugin" do
        entry_file([kind, "Schema", plugin_msg])
        expect(judge(schema_of(armored, plugin: false)).passes?).to be(false)
      end
    end

    it "[security] W1c a symbol kind given to new cannot accept a schema with no plugin" do
      built = baseline.new([baseline::Entry.new(:plugin, "Schema", plugin_msg)])
      expect(built.(audit.(schema_of(armored, plugin: false))).passes?).to be(false)
    end

    it "[security] W1d write on a schema with no plugin refuses and leaves no file" do
      expect { accept(schema_of(armored, plugin: false)) }.to raise_error(z::ConfigurationError)
      expect(File.exist?(path)).to be(false)
    end

    it "[security] W2 uninstalling the plugin and keeping the baseline fails" do
      open = query_with(open_type)
      accept(schema_of(open))
      expect(judge(schema_of(open, plugin: false)).passes?).to be(false)
    end

    define_method(:visible_when_type) do |name|
      klass = fc
      Class.new(GraphQL::Schema::Object) do
        include z::Base
        field_class klass
        graphql_name name
        authorize :read, visible_when: :show, model: "NoSuchModel#{name}"
      end
    end

    it "[security] W3 a second visible_when with no model under an accepted one fails" do
      a = visible_when_type("AaV")
      accept(schema_of(armored { field :a, a, null: true }))
      b = visible_when_type("BbV")
      expect(judge(schema_of(armored { field :a, a, null: true; field :b, b, null: true })).passes?).to be(false)
    end

    it "[security] W3b a listing error under an accepted :model elsewhere is still named" do
      klass = fc
      bad = Class.new(GraphQL::Schema::Object) { include z::Base; field_class klass; graphql_name "NoModelZz"; authorize :read }
      accept(schema_of(armored { field :bad, bad, null: true }))
      v = visible_when_type("NewV")
      result = judge(schema_of(armored { field :bad, bad, null: true; field :v, v, null: true }))
      expect(result.passes?).to be(false)
    end
  end

  # ---------------------------------------------------------------- 3. stability
  describe "stability", :baseline do
    needs_baseline

    define_method(:script) do |body|
      file = File.join(@dir, "s#{rand(10**8)}.rb")
      File.write(file, "require 'graphql/armory'\nZ = GraphQL::Armory::Authorization\n#{body}")
      out, status = Open3.capture2e("bundle", "exec", "ruby", "-I", File.join(root_dir, "lib"), file, chdir: root_dir)
      [out, status.exitstatus]
    end

    named = <<~'RB'
      class PF < GraphQL::Schema::Field; include Z::Base; end
      class PA < GraphQL::Schema::Object; graphql_name "A"; field :x, String; end
      class PB < GraphQL::Schema::Object; include Z::Base; graphql_name "B"; field_class GraphQL::Schema::Field; authorize :none, reason: "r"; field :y, String; end
      class PNo < GraphQL::Schema::Object; include Z::Base; graphql_name "NoSuchModel"; field_class PF; authorize :read; field :z, String; end
      class PQ < GraphQL::Schema::Object; include Z::Base; field_class PF; graphql_name "Query"; authorize :none, reason: "r", covers_fields: true
        FIELDS.each { |name, type| field name, Object.const_get(type), null: true }
      end
      class PS < GraphQL::Schema
        query PQ
        use Z, adapter: :pundit
      end
    RB

    it "[security] S2 a named schema: file written in one process passes in another, with reversed field order" do
      file = path
      one, st1 = script("FIELDS = {a: 'PA', b: 'PB', c: 'PNo'}\n#{named}\nZ::Audit::Baseline.write(Z::Audit.(PS), #{file.inspect}); puts 'written'")
      expect(st1).to eq(0), one
      two, st2 = script("FIELDS = {c: 'PNo', b: 'PB', a: 'PA'}\n#{named}\nr = Z::Audit::Baseline.load(#{file.inspect}).(Z::Audit.(PS)); puts r.passes?; puts r")
      expect(st2).to eq(0), two
      expect(two.lines.first.strip).to eq("true"), two
    end

    it "[preservation] S1 an anonymous own_check holder fails closed across processes, it never passes on another's text" do
      file = path
      anon = <<~RB
        base = Class.new(GraphQL::Schema::Object) { include Z::Base; def self.authorized?(_o, _c) = true }
        q = Class.new(base) { graphql_name "Query"; authorize :none, reason: "r", covers_fields: true }
        s = Class.new(GraphQL::Schema) { query q; use Z, adapter: :pundit }
      RB
      one, = script("#{anon}\nb = Z::Audit::Baseline.write(Z::Audit.(s), #{file.inspect}); puts b.entries.map(&:path)")
      expect(one).to include("0x")
      two, = script("#{anon}\nr = Z::Audit::Baseline.load(#{file.inspect}).(Z::Audit.(s)); puts r.passes?")
      expect(two.lines.first.strip).to eq("false"), two
    end

    it "[preservation] S3 writes the rich schema's file for comparison across configurations" do
      FileUtils.mkdir_p(out_dir)
      file = File.join(out_dir, "baseline-#{config}.json")
      FileUtils.rm_f(file)
      klass = fc
      plain = Class.new(GraphQL::Schema::Object) { include z::Base; field_class GraphQL::Schema::Field; graphql_name "Plain"; authorize :none, reason: "r"; field :y, String }
      nomodel = Class.new(GraphQL::Schema::Object) { include z::Base; field_class klass; graphql_name "NoSuchModelR"; authorize :read; field :z, String }
      norule = Class.new(GraphQL::Schema::Object) { include z::Base; field_class klass; graphql_name "NoRule" }
      opened = open_type
      root = armored { field :a, plain, null: true; field :b, nomodel, null: true; field :c, norule, null: true; field :d, opened, null: true }
      s = Class.new(schema_of(root)) { def self.unauthorized_object(_e) = nil }
      baseline.write(audit.(s), file)
      expect(JSON.parse(File.read(file))["problems"]).not_to be_empty
    end
  end

  # ---------------------------------------------------------------- 4. the file
  describe "file handling", :baseline do
    needs_baseline

    let(:dirty) { schema_of(query_with(open_type)) }
    let(:clean) { schema_of(armored) }

    it "[preservation] F1 a BOM still loads" do
      accept(dirty)
      File.binwrite(path, "\xEF\xBB\xBF".b + File.binread(path))
      expect(judge(dirty).passes?).to be(true)
    end

    {
      "empty" => "", "whitespace" => " \n", "null" => "null", "array" => "[]", "number" => "1", "string" => '"x"', "object" => "{}",
      "version only" => '{"version":1}', "wrong version" => '{"version":2,"problems":[]}', "string version" => '{"version":"1","problems":[]}',
      "null version" => '{"version":null,"problems":[]}', "problems null" => '{"version":1,"problems":null}', "problems hash" => '{"version":1,"problems":{}}',
      "problems string" => '{"version":1,"problems":"none"}', "entry not a hash" => '{"version":1,"problems":["x"]}', "entry null" => '{"version":1,"problems":[null]}',
      "entry missing message" => '{"version":1,"problems":[{"kind":"a","path":"b"}]}', "entry number" => '{"version":1,"problems":[{"kind":1,"path":"b","message":"c"}]}',
      "entry null path" => '{"version":1,"problems":[{"kind":"a","path":null,"message":"c"}]}', "truncated" => '{"version":1,"problems":[',
      "binary" => "\xFF\xFE\x00garbage\x80".b, "NaN" => '{"version":NaN,"problems":[]}',
      "deep" => ("[" * 5000) + ("]" * 5000)
    }.each do |name, content|
      it "[security] F3 #{name} fails with a ConfigurationError, on clean and dirty alike" do
        File.binwrite(path, content)
        expect { judge(clean) }.to raise_error(z::ConfigurationError)
        expect { judge(dirty) }.to raise_error(z::ConfigurationError)
      end
    end

    it "[preservation] F4 duplicate entries collapse and nothing else changes" do
      accept(dirty)
      data = JSON.parse(File.read(path))
      size = data["problems"].size
      data["problems"] *= 2
      File.write(path, JSON.generate(data))
      expect(judge(dirty).passes?).to be(true)
      expect(baseline.load(path).entries.size).to eq(size)
    end

    it "[security] F6 a directory as the path fails to load and to write, as a ConfigurationError" do
      FileUtils.mkdir_p(File.join(@dir, "d"))
      expect { judge(dirty, File.join(@dir, "d")) }.to raise_error(z::ConfigurationError)
      expect { accept(dirty, File.join(@dir, "d")) }.to raise_error(z::ConfigurationError)
    end

    it "[preservation] F7 writing where it cannot raises a ConfigurationError" do
      target = File.join(@dir, "no", "such", "dir.json")
      seen = begin
        accept(dirty, target)
        :wrote
      rescue StandardError => error
        error.class
      end
      expect(seen).to eq(z::ConfigurationError)
    end

    it "[security] F8 a dangling symlink fails to load; a symlink to a good file loads" do
      link = File.join(@dir, "link.json")
      File.symlink(File.join(@dir, "absent.json"), link)
      expect { judge(dirty, link) }.to raise_error(z::ConfigurationError)
      accept(dirty)
      good = File.join(@dir, "good.json")
      File.symlink(path, good)
      expect(judge(dirty, good).passes?).to be(true)
    end

    it "[preservation] F8b write through a symlink keeps the link and never adds" do
      accept(dirty)
      good = File.join(@dir, "good.json")
      File.symlink(path, good)
      accept(schema_of(query_with(open_type("Other"))), good)
      expect(File.symlink?(good)).to be(true)
      expect(baseline.load(path).entries).to be_empty
    end

    it "[preservation] F9 a huge file (200k entries) still judges" do
      entries = Array.new(200_000) { |i| { "kind" => "unprotected", "path" => "T#{i}", "message" => "m" } }
      File.write(path, JSON.generate("version" => 1, "problems" => entries))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = judge(clean)
      expect(result.passes?).to be(false)
      expect(result.gone.size).to eq(200_000)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 30
    end

    it "[security] F10 write over an invalid file refuses and leaves its bytes" do
      File.write(path, "not json")
      expect { accept(dirty) }.to raise_error(z::ConfigurationError)
      expect(File.read(path)).to eq("not json")
      File.write(path, '{"version":2,"problems":[]}')
      expect { accept(dirty) }.to raise_error(z::ConfigurationError)
      expect(File.read(path)).to eq('{"version":2,"problems":[]}')
    end

    it "[security] F10b write over an empty file refuses: it never reads as a first run" do
      File.write(path, "")
      expect { accept(dirty) }.to raise_error(z::ConfigurationError)
      expect(File.read(path)).to eq("")
    end

    it "[security] F11 a clean write is an empty list: passes clean, a later problem fails" do
      accept(clean)
      expect(JSON.parse(File.read(path))["problems"]).to eq([])
      expect(judge(clean).passes?).to be(true)
      expect(judge(clean).to_s).to include("No problems.")
      expect(judge(dirty).passes?).to be(false)
    end

    it "[security] F12 write never adds to an existing file, and removes what is gone" do
      accept(clean)
      accept(dirty)
      expect(baseline.load(path).entries).to be_empty
      FileUtils.rm_f(path)
      accept(dirty)
      expect(baseline.load(path).entries).not_to be_empty
      accept(clean)
      expect(baseline.load(path).entries).to be_empty
    end

    it "[security] F14 a NUL in the path never passes" do
      expect { judge(dirty, "a\0b") }.to raise_error(StandardError)
    end

    it "[security] F15 version 1.0 is refused" do
      File.write(path, '{"version":1.0,"problems":[]}')
      expect { judge(clean) }.to raise_error(z::ConfigurationError)
    end

    it "[preservation] F16 duplicate JSON keys never lose an accepted problem into a pass" do
      accept(dirty)
      kept = JSON.parse(File.read(path))["problems"]
      File.write(path, %({"version":1,"problems":#{JSON.generate(kept)},"problems":[]}))
      next if (begin; baseline.load(path); false; rescue z::ConfigurationError; true; end) # this json refuses duplicate keys: fails closed
      expect(judge(dirty).passes?).to be(false)
    end
  end

  # ---------------------------------------------------------------- 7. the result
  describe "Result#to_s", :baseline do
    needs_baseline

    let(:p1) { audit::Report::Problem.new(:no_rule, "A", "m1") }
    let(:p2) { audit::Report::Problem.new(:no_rule, "B", "m2") }
    let(:by) { audit::Report::Bypass.new("C", "why") }

    [true, false].each do |has_new|
      [true, false].each do |has_gone|
        [true, false].each do |has_accepted|
          [true, false].each do |has_bypass|
            it "[security] T1 new=#{has_new} gone=#{has_gone} accepted=#{has_accepted} bypass=#{has_bypass}" do
              entries = []
              entries << baseline::Entry.new("no_rule", "G", "gone") if has_gone
              entries << baseline::Entry.new("no_rule", "A", "m1") if has_accepted
              problems = []
              problems << p1 if has_accepted
              problems << p2 if has_new
              report = audit::Report.new(problems: problems, bypasses: has_bypass ? [by] : [])
              result = baseline.new(entries).(report)
              text = result.to_s
              expect(result.passes?).to eq(!has_new && !has_gone)
              expect(result).not_to respond_to(:ok?)
              expect(text).to include("A (no_rule): m1") if has_accepted
              expect(text).to include("B (no_rule): m2") if has_new
              expect(text).to include("G (no_rule): gone") if has_gone
              expect(text).to include("C: why") if has_bypass
              expect(text.include?("Passes only because")).to eq(result.passes? && has_accepted)
              expect(text.include?("No problems.")).to eq(!has_new && !has_gone && !has_accepted)
            end
          end
        end
      end
    end

    it "[security] T6 two identical problems against one entry are both listed as accepted" do
      entries = [baseline::Entry.new("no_rule", "A", "m1")]
      result = baseline.new(entries).(audit::Report.new(problems: [p1, p1.dup], bypasses: []))
      expect(result.to_s.scan("A (no_rule): m1").size).to eq(2)
    end
  end

  # ---------------------------------------------------------------- invariant
  describe "audit versus run time", :baseline do
    needs_baseline

    it "[security] V1 a real leak, accepted: passes, not ok, the data is served and the output says still open" do
      schema = schema_of(query_with(open_type { field(:ssn, String); def ssn = "123-45" }))
      accept(schema)
      result = judge(schema)
      expect(data_of(schema, "{ invoice { ssn } }").dig("data", "invoice", "ssn")).to eq("123-45")
      expect(audit.(schema).ok?).to be(false)
      expect(result.passes?).to be(true)
      expect(result.to_s).to include("Passes only because of its baseline", "still open", "Invoice (unprotected)")
    end

    it "[security] V2 ok? and the report's text are the same with a file on disk" do
      schema = schema_of(query_with(open_type))
      before_text = audit.(schema).to_s
      accept(schema)
      Dir.chdir(@dir) do
        expect(audit.(schema).ok?).to be(false)
        expect(audit.(schema).to_s).to eq(before_text)
      end
    end

    it "[preservation] V4 owners: load is Baseline's, call is Baseline's, ok? stays on Report" do
      expect(baseline.method(:load).owner).to eq(baseline.singleton_class)
      expect(baseline.new.method(:call).owner).to eq(baseline)
      expect(audit.(schema_of(armored)).method(:ok?).owner).to eq(audit::Report)
    end
  end

  # ---------------------------------------------------------------- 6. the matcher
  describe "the matcher", :baseline do
    needs_baseline

    let(:dirty) { schema_of(query_with(open_type)) }
    let(:clean) { schema_of(armored) }
    let(:failure) { RSpec::Expectations::ExpectationNotMetError }

    it "[preservation] M1 no argument: dirty fails, clean passes" do
      expect { expect(dirty).to be_fully_authorized }.to raise_error(failure, /1 problem:/)
      expect(clean).to be_fully_authorized
    end

    it "[security] M2 baseline: nil audits plainly, even with accepted problems on disk" do
      accept(dirty)
      expect { expect(dirty).to be_fully_authorized(baseline: nil) }.to raise_error(failure)
    end

    it "[security] M3 baseline: '' fails on clean and dirty" do
      expect { expect(clean).to be_fully_authorized(baseline: "") }.to raise_error(z::ConfigurationError)
      expect { expect(dirty).to be_fully_authorized(baseline: "") }.to raise_error(z::ConfigurationError)
    end

    it "[security] M4a a positional path on a dirty schema does not pass" do
      accept(dirty)
      passed = begin
        expect(dirty).to be_fully_authorized(path)
        true
      rescue RSpec::Expectations::ExpectationNotMetError, ArgumentError
        false
      end
      expect(passed).to be(false)
    end

    it "[security] M4b a positional missing path on a clean schema is not silently ignored" do
      passed = begin
        expect(clean).to be_fully_authorized(File.join(@dir, "absent.json"))
        true
      rescue RSpec::Expectations::ExpectationNotMetError, ArgumentError
        false
      end
      expect(passed).to be(false)
    end

    it "[security] M5a negated with a passing baseline: its message does not claim there are no problems" do
      accept(dirty)
      expect { expect(dirty).not_to be_fully_authorized(baseline: path) }.to raise_error(failure) { |error| expect(error.message).not_to include("found no problems") }
    end

    it "[security] M5b negated with a missing file raises, never passes" do
      expect { expect(dirty).not_to be_fully_authorized(baseline: File.join(@dir, "absent.json")) }.to raise_error(z::ConfigurationError)
    end

    it "[preservation] M6 Pathname works" do
      accept(dirty)
      expect(dirty).to be_fully_authorized(baseline: Pathname.new(path))
    end

    it "[security] M7 a missing file raises a clear error naming it" do
      expect { expect(dirty).to be_fully_authorized(baseline: path) }.to raise_error(z::ConfigurationError, /#{Regexp.escape(path)}.*cannot be read/)
    end

    it "[security] M8 a misspelt keyword is not silently ignored on a clean schema" do
      outcome = begin
        expect(clean).to be_fully_authorized(basline: File.join(@dir, "absent.json"))
        :passed
      rescue ArgumentError, RSpec::Expectations::ExpectationNotMetError
        :refused
      end
      expect(outcome).to eq(:refused)
    end

    it "[security] M9 baseline: false audits plainly" do
      accept(dirty)
      expect { expect(dirty).to be_fully_authorized(baseline: false) }.to raise_error(failure)
    end

    it "[security] M10 a new problem fails and the message names it" do
      accept(clean)
      expect { expect(dirty).to be_fully_authorized(baseline: path) }.to raise_error(failure, /1 new problem:.*Invoice \(unprotected\)/m)
    end
  end

  # ---------------------------------------------------------------- 5. rake in a real app
  describe "real Rails app" do
    schemas = <<~'RUBY'
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

    define_method(:write) do |name, text|
      target = File.join(@app, name)
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, text)
    end

    define_method(:app) do |before: "", after: ""|
      write("config/boot.rb", 'require "bundler/setup"')
      write("config/application.rb", <<~RUBY)
        require_relative "boot"
        require "rails"
        require "graphql/armory"
        class ProbeApp < Rails::Application
          config.root = File.expand_path("..", __dir__)
          config.eager_load = false
          config.secret_key_base = "x" * 32
          config.logger = Logger.new(IO::NULL)
        end
      RUBY
      write("config/environment.rb", %(require_relative "application"\nRails.application.initialize!\n))
      write("app/graphql/clean_schema.rb", "#{schemas}\nclass CleanSchema < GraphQL::Schema\n  query CleanQuery\n  use GraphQL::Armory::Authorization, adapter: :pundit\nend\n")
      write("app/graphql/dirty_schema.rb", "#{schemas}\nclass DirtySchema < GraphQL::Schema\n  query DirtyQuery\n  use GraphQL::Armory::Authorization, adapter: :pundit\nend\n")
      write("app/graphql/no_plugin_schema.rb", "#{schemas}\nclass NoPluginSchema < GraphQL::Schema\n  query DirtyQuery\nend\n")
      write("app/graphql/broken_schema.rb", %(raise GraphQL::Armory::Authorization::ConfigurationError, "broken from the schema"\n))
      write("app/graphql/inner_name_schema.rb", "NoSuchThingInside\n")
      write("Rakefile", %(require_relative "config/application"\n#{before}\nRails.application.load_tasks\n#{after}\n))
    end

    define_method(:rake) do |*args|
      out, status = Open3.capture2e("bundle", "exec", "rake", *args, chdir: @app)
      [out, status.exitstatus]
    end

    around do |example|
      Dir.mktmpdir("baseline-app") do |dir|
        @app = dir
        example.run
      end
    end

    define_method(:file) { |name = "b.json"| File.join(@app, name) }

    it "[preservation] D1 writes the plain command's output for the differential with origin/main" do
      app
      lines = []
      [["clean", "graphql_armory:audit[CleanSchema]"], ["dirty", "graphql_armory:audit[DirtySchema]"], ["unknown", "graphql_armory:audit[NoSuch]"],
       ["none", "graphql_armory:audit"], ["nested", "graphql_armory:audit[Foo::Bar]"], ["no plugin", "graphql_armory:audit[NoPluginSchema]"],
       ["config error", "graphql_armory:audit[BrokenSchema]"], ["inner NameError", "graphql_armory:audit[InnerNameSchema]"]].each do |label, task|
        out, status = rake(task)
        cleaned = out.gsub(@app, "APP").lines.reject { |line| line.include?("/gems/") || line.start_with?("/") }.join
        lines << "== #{label}: exit #{status}\n#{cleaned}"
      end
      command = z::Audit::Command
      io = StringIO.new
      lines << "== Command nil: #{command.new(out: io).(nil)} #{io.string}"
      io = StringIO.new
      lines << "== Command unknown: #{command.new(out: io).('NoSuchZ')} #{io.string}"
      FileUtils.mkdir_p(out_dir)
      File.write(File.join(out_dir, "diff-#{config}.txt"), lines.join("\n"))
    end

    it "[preservation] D2 the matcher's plain messages, for the differential" do
      dirty = schema_of(query_with(open_type))
      message = begin
        expect(dirty).to be_fully_authorized
      rescue RSpec::Expectations::ExpectationNotMetError => error
        error.message.gsub(/#<Class:0x\h+>/, "#<Class>")
      end
      negated = begin
        expect(schema_of(armored)).not_to be_fully_authorized
      rescue RSpec::Expectations::ExpectationNotMetError => error
        error.message.gsub(/#<Class:0x\h+>/, "#<Class>")
      end
      FileUtils.mkdir_p(out_dir)
      File.write(File.join(out_dir, "matcher-#{config}.txt"), "#{message}\n---\n#{negated}\n")
    end

    describe "with a baseline", :baseline do
      needs_baseline

      it "[security] R1 audit[Schema,] runs the plain audit: dirty exits 1, clean 0" do
        app
        expect(rake("graphql_armory:audit[DirtySchema,]").last).to eq(1)
        expect(rake("graphql_armory:audit[CleanSchema,]").last).to eq(0)
      end

      it "[security] R2 docs rows: accepted 0; new, message changed, gone, missing, invalid 1; plugin cannot be accepted" do
        app
        out, status = rake("graphql_armory:audit_baseline[DirtySchema,b.json]")
        expect(status).to eq(0), out
        expect(out).to include("accepted")
        good = File.read(file)
        out, status = rake("graphql_armory:audit[DirtySchema,b.json]")
        expect(status).to eq(0), out
        expect(out).to include("Passes only because", "still open", "Query (unprotected)")

        File.write(file, '{"version":1,"problems":[]}')
        out, status = rake("graphql_armory:audit[DirtySchema,b.json]")
        expect(status).to eq(1)
        expect(out).to include("1 new problem:")

        File.write(file, good.sub("so it is open", "so it is OPEN"))
        out, status = rake("graphql_armory:audit[DirtySchema,b.json]")
        expect(status).to eq(1)
        expect(out).to include("1 new problem:", "no longer found")

        File.write(file, good)
        out, status = rake("graphql_armory:audit[CleanSchema,b.json]")
        expect(status).to eq(1)
        expect(out).to include("no longer found")

        out, status = rake("graphql_armory:audit[DirtySchema,absent.json]")
        expect(status).to eq(1)
        expect(out).to include("cannot be read")
        File.write(file, "nope")
        out, status = rake("graphql_armory:audit[DirtySchema,b.json]")
        expect(status).to eq(1)
        expect(out).to include("not valid JSON")

        out, status = rake("graphql_armory:audit_baseline[NoPluginSchema,p.json]")
        expect(status).to eq(1)
        expect(out).to include("never installed the plugin")
        expect(File.exist?(file("p.json"))).to be(false)
      end

      it "[security] R2b audit_baseline with a new problem on an existing file does not report success silently" do
        app
        File.write(file, '{"version":1,"problems":[]}')
        out, status = rake("graphql_armory:audit_baseline[DirtySchema,b.json]")
        expect(JSON.parse(File.read(file))["problems"]).to eq([])
        expect(rake("graphql_armory:audit[DirtySchema,b.json]").last).to eq(1)
        expect([status, out]).to satisfy { |(code, text)| code == 1 || text.match?(/new|not accepted/) }
      end

      it "[security] R3 a path with spaces works" do
        app
        expect(rake("graphql_armory:audit_baseline[DirtySchema,my base.json]").last).to eq(0)
        expect(File.exist?(file("my base.json"))).to be(true)
        expect(rake("graphql_armory:audit[DirtySchema,my base.json]").last).to eq(0)
      end

      it "[security] R4 an app that names the task before the gem loads: baseline honoured" do
        app(before: %(task "graphql_armory:audit" => :environment\ntask "graphql_armory:audit_baseline" => :environment))
        expect(rake("graphql_armory:audit_baseline[DirtySchema,b.json]").last).to eq(0)
        expect(rake("graphql_armory:audit[DirtySchema,b.json]").last).to eq(0)
        expect(rake("graphql_armory:audit[DirtySchema,absent.json]").last).to eq(1)
      end

      it "[security] R4b an app that names the task with [:schema] before load: the path is honoured" do
        app(before: %(task "graphql_armory:audit", [:schema] => :environment))
        File.write(file, '{"version":2}')
        out, status = rake("graphql_armory:audit[CleanSchema,b.json]")
        expect(status).to eq(1), out
      end

      it "[security] R4c [:schema] named AFTER load: a bad path on a clean schema does not pass silently" do
        app(after: %(task "graphql_armory:audit", [:schema] => :environment))
        File.write(file, '{"version":2}')
        out, status = rake("graphql_armory:audit[CleanSchema,b.json]")
        expect(status).to eq(1), out
      end

      it "[preservation] R5 audit_baseline: no schema, no path, unknown schema exit 1 and write nothing" do
        app
        out, status = rake("graphql_armory:audit_baseline")
        expect(status).to eq(1)
        expect(out).to include("Name the file")
        out, status = rake("graphql_armory:audit_baseline[DirtySchema]")
        expect(status).to eq(1)
        expect(out).to include("Name the file")
        out, status = rake("graphql_armory:audit_baseline[,b.json]")
        expect(status).to eq(1)
        expect(out).to include("Name the schema")
        out, status = rake("graphql_armory:audit_baseline[NoSuch,b.json]")
        expect(status).to eq(1)
        expect(out).to include("No schema named NoSuch")
        expect(File.exist?(file)).to be(false)
      end

      it "[preservation] R5b a write that cannot happen exits 1 with a message, no stack" do
        app
        out, status = rake("graphql_armory:audit_baseline[DirtySchema,no/such/dir/b.json]")
        expect(status).to eq(1)
        expect(out).not_to include("rake aborted")
      end

      it "[security] R6 a ConfigurationError from the schema with a baseline exits 1" do
        app
        File.write(file, '{"version":1,"problems":[]}')
        out, status = rake("graphql_armory:audit[BrokenSchema,b.json]")
        expect(status).to eq(1), out
      end

      it "[security] R7 rake -T lists both, once each" do
        app
        out, = rake("-T", "graphql_armory")
        expect(out.scan(/graphql_armory:audit(?!_)/).size).to eq(1)
        expect(out.scan("graphql_armory:audit_baseline").size).to eq(1)
      end
    end
  end
end
