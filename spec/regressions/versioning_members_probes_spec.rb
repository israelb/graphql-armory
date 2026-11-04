# frozen_string_literal: true

# Kept from the independent verification of PR #67: versioning increment 2a (arguments, input fields, enum values).
# Each `it` is labelled "security:" (a member outside V must not be sent, introspected, suggested or printed) or
# "preservation:" (behaviour that must keep working). VERSIONING_2A_V1 = 2024-06-01, VERSIONING_2A_V2 = 2025-01-01 (latest); 2024-01-15 retired.
VERSIONING_2A_PLAIN = lambda do |value|
  case value
  when GraphQL::Schema::InputObject then VERSIONING_2A_PLAIN.(value.to_h)
  when Hash then value.to_h { |k, v| [k, VERSIONING_2A_PLAIN.(v)] }
  when Array then value.map { |v| VERSIONING_2A_PLAIN.(v) }
  else value
  end
end

RSpec.describe "Regression probes: versioning increment 2a (members)" do
  VERSIONING_2A_V1 = "2024-06-01"
  VERSIONING_2A_V2 = "2025-01-01"
  VERSIONING_2A_LABELS = %w[2024-01-15 2024-06-01 2025-01-01].freeze
  VERSIONING_2A_RETIRED = %w[2024-01-15].freeze

  let(:calls) { [] }
  let(:config_error) { GraphQL::Armory::Versioning::ConfigurationError }


  def versioned_argument_class
    Class.new(GraphQL::Schema::Argument) { include GraphQL::Armory::Versioning::Base }
  end

  def versioned_value_class
    Class.new(GraphQL::Schema::EnumValue) { include GraphQL::Armory::Versioning::Base }
  end

  def field_class_for(argument_class)
    Class.new(GraphQL::Schema::Field) do
      include GraphQL::Armory::Versioning::Base
      argument_class(argument_class)
    end
  end

  # Records every call with its arguments and answers them as a String.
  def recorder(*names)
    log = calls
    Class.new do
      names.each do |name|
        define_method(name) do |**kw|
          log << [name, VERSIONING_2A_PLAIN.(kw)]
          VERSIONING_2A_PLAIN.(kw).inspect
        end
      end
    end.new
  end

  def schema_for(query_type, visibility, versions: VERSIONING_2A_LABELS, retired: VERSIONING_2A_RETIRED, mutation: nil, directives: [], orphans: [], &block)
    plugin = { visibility: GraphQL::Schema::Visibility, warden: GraphQL::Schema::Warden }.fetch(visibility)
    Class.new(ArmoryEngine.base_schema) do
      query(query_type)
      mutation(mutation) if mutation
      orphan_types(*orphans) unless orphans.empty?
      directives.each { |d| directive(d) }
      use plugin
      use GraphQL::Armory::Versioning, versions: versions, retired: retired, default: :latest
      class_exec(&block) if block
    end
  end

  def run(schema, query, version, variables: {}, root: nil)
    execute_query(schema, query, root_value: root, variables: variables, context: { armory_version: version }).to_h
  end

  # [:result, hash] | [:config_error, message] | [:quirks] (graphql 2.4 cannot print a String with json 3.1)
  def attempt
    [:result, yield]
  rescue GraphQL::Armory::Versioning::ConfigurationError => e
    [:config_error, e.message]
  rescue ArgumentError => e
    raise unless e.message.include?("quirks_mode")

    [:quirks]
  end

  def messages(result) = Array(result["errors"]).map { |e| e["message"] }.join(" | ")

  # Refused: nothing resolved and errors (or graphql 2.4's printing failure).
  def refused?(outcome)
    return true if outcome.first == :quirks
    return false unless outcome.first == :result

    r = outcome.last
    raise "probe defect: #{messages(r)}" if messages(r).include?("Nullability mismatch")

    r.key?("errors") && (r["data"].nil? || r["data"].values.all?(&:nil?))
  end

  def status_enum(value_class = versioned_value_class)
    Class.new(GraphQL::Schema::Enum) do
      graphql_name "Status"
      enum_value_class(value_class)
      value "PAID"
      value "NEWV", value: :newv, added: VERSIONING_2A_V2
      value "OLDV", value: :oldv, removed: VERSIONING_2A_V2
    end
  end

  def item_input(argument_class)
    Class.new(GraphQL::Schema::InputObject) do
      graphql_name "Item"
      argument_class(argument_class)
      argument :name, Integer, required: false
      argument :secret, Integer, required: false, added: VERSIONING_2A_V2
      argument :legacy, Integer, required: false, removed: VERSIONING_2A_V2
    end
  end

  def filter_input(argument_class, status, item)
    Class.new(GraphQL::Schema::InputObject) do
      graphql_name "Filter"
      argument_class(argument_class)
      argument :status, status, required: false
      argument :statuses, [status], required: false
      argument :since, Integer, required: false, added: VERSIONING_2A_V2
      argument :code, Integer, required: false, removed: VERSIONING_2A_V2
      argument :since_day, Integer, required: false, added: VERSIONING_2A_V2
      argument :old_day, Integer, required: false, as: :od, removed: VERSIONING_2A_V2
      argument :new_day, Integer, required: false, as: :nd, added: VERSIONING_2A_V2
      argument :item, item, required: false
      argument :items, [item], required: false
    end
  end

  # echo(filter:, statuses:, items:, page: removed VERSIONING_2A_V2, first: added VERSIONING_2A_V2)
  def world(visibility, &extra)
    ac = versioned_argument_class
    status = status_enum
    item = item_input(ac)
    filter = filter_input(ac, status, item)
    fc = field_class_for(ac)
    query_type = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field_class(fc)
      field :echo, String, null: true do
        argument :filter, filter, required: false
        argument :statuses, [status], required: false
        argument :items, [item], required: false
        argument :page, Integer, required: false, removed: VERSIONING_2A_V2
        argument :first, Integer, required: false, added: VERSIONING_2A_V2
      end
      class_exec(ac, status, item, filter, &extra) if extra
    end
    { schema: schema_for(query_type, visibility), status: status, filter: filter, item: item, ac: ac }
  end

  %i[warden visibility].each do |visibility|
    context "with #{visibility}" do
      let(:w) { world(visibility) }
      let(:root) { recorder(:echo) }

      # ---------------------------------------------------------------- variables
      it "security VERSIONING_2A_V1: a variable naming an enum value added later is refused in the older version" do
        q = "query($s: Status) { echo(filter: { status: $s }) }"
        out = attempt { run(w[:schema], q, VERSIONING_2A_V1, variables: { "s" => "NEWV" }, root: root) }
        expect(refused?(out)).to eq(true)
        expect(calls).to eq([])
      end

      it "security V3: a hidden input field inside a list of input objects (variable) is refused" do
        q = "query($f: Filter) { echo(filter: $f) }"
        a = attempt { run(w[:schema], q, VERSIONING_2A_V2, variables: { "f" => { "items" => [{ "name" => 1 }, { "legacy" => 2 }] } }, root: root) }
        b = attempt { run(w[:schema], q, VERSIONING_2A_V1, variables: { "f" => { "items" => [{ "secret" => 2 }] } }, root: root) }
        c = attempt { run(w[:schema], "query($i: [Item!]) { echo(items: $i) }", VERSIONING_2A_V1, variables: { "i" => [{ "secret" => 2 }] }, root: root) }
        expect([refused?(a), refused?(b), refused?(c)]).to eq([true, true, true])
        expect(calls).to eq([])
      end

      it "security V4: a hidden input field inside a nested input object (variable) is refused" do
        q = "query($f: Filter) { echo(filter: $f) }"
        a = attempt { run(w[:schema], q, VERSIONING_2A_V1, variables: { "f" => { "item" => { "secret" => 1 } } }, root: root) }
        b = attempt { run(w[:schema], q, VERSIONING_2A_V2, variables: { "f" => { "item" => { "legacy" => 1 } } }, root: root) }
        expect([refused?(a), refused?(b)]).to eq([true, true])
        expect(calls).to eq([])
      end

      it "security V5: a list-of-enum variable holding a hidden value is refused (argument and nested)" do
        a = attempt { run(w[:schema], "query($l: [Status!]) { echo(statuses: $l) }", VERSIONING_2A_V2, variables: { "l" => %w[PAID OLDV] }, root: root) }
        b = attempt { run(w[:schema], "query($l: [Status!]) { echo(filter: { statuses: $l }) }", VERSIONING_2A_V1, variables: { "l" => %w[NEWV] }, root: root) }
        c = attempt { run(w[:schema], "query($l: [Status!]) { echo(statuses: $l) }", VERSIONING_2A_V2, variables: { "l" => "OLDV" }, root: root) }
        expect([refused?(a), refused?(b), refused?(c)]).to eq([true, true, true])
        expect(calls).to eq([])
      end

      it "security V6: an operation variable default naming a hidden enum value is refused" do
        a = attempt { run(w[:schema], "query($s: Status = OLDV) { echo(filter: { status: $s }) }", VERSIONING_2A_V2, root: root) }
        b = attempt { run(w[:schema], "query($s: Status = NEWV) { echo(filter: { status: $s }) }", VERSIONING_2A_V1, root: root) }
        c = attempt { run(w[:schema], "query($l: [Status!] = [PAID, OLDV]) { echo(statuses: $l) }", VERSIONING_2A_V2, root: root) }
        expect([refused?(a), refused?(b), refused?(c)]).to eq([true, true, true])
        expect(calls).to eq([])
      end

      it "security V7: an operation variable default naming a hidden input field is refused" do
        a = attempt { run(w[:schema], "query($f: Filter = { code: 1 }) { echo(filter: $f) }", VERSIONING_2A_V2, root: root) }
        b = attempt { run(w[:schema], "query($f: Filter = { item: { secret: 1 } }) { echo(filter: $f) }", VERSIONING_2A_V1, root: root) }
        c = attempt { run(w[:schema], "query($f: Filter = { items: [{ legacy: 1 }] }) { echo(filter: $f) }", VERSIONING_2A_V2, root: root) }
        expect([refused?(a), refused?(b), refused?(c)]).to eq([true, true, true])
        expect(calls).to eq([])
      end

      it "security V8: a hidden argument sent through a variable is refused" do
        a = attempt { run(w[:schema], "query($p: Int) { echo(page: $p) }", VERSIONING_2A_V2, variables: { "p" => 1 }, root: root) }
        b = attempt { run(w[:schema], "query($p: Int) { echo(first: $p) }", VERSIONING_2A_V1, variables: { "p" => 1 }, root: root) }
        expect([refused?(a), refused?(b)]).to eq([true, true])
        expect(calls).to eq([])
      end

      it "preservation V9: visible members through variables reach the resolver in their versions" do
        q = "query($f: Filter, $l: [Status!]) { echo(filter: $f, statuses: $l) }"
        a = run(w[:schema], q, VERSIONING_2A_V1, variables: { "f" => { "status" => "OLDV", "item" => { "legacy" => 1 }, "code" => 3 }, "l" => ["OLDV"] }, root: root)
        b = run(w[:schema], q, VERSIONING_2A_V2, variables: { "f" => { "status" => "NEWV", "items" => [{ "secret" => 2 }], "since" => 4 }, "l" => ["NEWV"] }, root: root)
        expect([a["errors"], b["errors"]]).to eq([nil, nil])
        expect(calls).to eq([
          [:echo, { filter: { status: :oldv, item: { legacy: 1 }, code: 3 }, statuses: [:oldv] }],
          [:echo, { filter: { status: :newv, items: [{ secret: 2 }], since: 4 }, statuses: [:newv] }]
        ])
      end

      # ---------------------------------------------------------------- default values
      def default_schema(visibility, field_name, type_proc, default)
        world(visibility) do |ac, status, item, filter|
          type = type_proc.call(status, item, filter)
          field field_name, String, null: true do
            argument :arg, type, required: false, default_value: default
          end
        end[:schema]
      end

      def args_query(name) = %({ __type(name: "Query") { fields { name args { name defaultValue } } } })

      def default_outcomes(schema, field_name, hidden_in)
        root = recorder(field_name)
        intro = attempt { run(schema, args_query(field_name), hidden_in, root: root) }
        exec = attempt { run(schema, "{ #{GraphQL::Schema::Member::BuildType.camelize(field_name.to_s)} }", hidden_in, root: root) }
        sdl = begin
          [:sdl, schema.to_definition(context: { armory_version: hidden_in })]
        rescue config_error => e
          [:config_error, e.message]
        rescue StandardError => e
          [:other, e.class.name]
        end
        [intro, exec, sdl]
      end

      def expect_default_refused(outcomes, leaked_names)
        intro, exec, sdl = outcomes
        got = [intro.first, exec.first, sdl.first == :sdl && leaked_names.any? { |n| sdl.last.include?(n) }, calls.dup]
        detail = "introspection: #{intro.inspect[0, 400]}
execution: #{exec.inspect[0, 300]}
sdl: #{sdl.inspect[0, 300]}
calls: #{calls.inspect}"
        expect(got).to eq([:config_error, :config_error, false, []]), detail
      end

      it "security D1: an argument default naming an enum value added later (Ruby value) is refused in the older version" do
        schema = default_schema(visibility, :by_status, ->(s, _, _) { s }, :newv)
        expect_default_refused(default_outcomes(schema, :by_status, VERSIONING_2A_V1), ["NEWV"])
      end

      it "security D2: an argument default naming an enum value by its graphql name is refused" do
        vc = versioned_value_class
        kind = Class.new(GraphQL::Schema::Enum) do
          graphql_name "Kind"
          enum_value_class(vc)
          value "BASIC"
          value "NEWK", added: VERSIONING_2A_V2
        end
        schema = default_schema(visibility, :by_kind, ->(_, _, _) { kind }, "NEWK")
        expect_default_refused(default_outcomes(schema, :by_kind, VERSIONING_2A_V1), ["NEWK"])
      end

      it "security D3: an input-object default naming a hidden field is refused for Symbol, String and camelCase keys" do
        [{ since: 1 }, { "since" => 1 }, { since_day: 1 }, { "sinceDay" => 1 }, { sinceDay: 1 }].each do |default|
          calls.clear
          schema = default_schema(visibility, :by_filter, ->(_, _, f) { f }, default)
          expect_default_refused(default_outcomes(schema, :by_filter, VERSIONING_2A_V1), %w[since: sinceDay:])
        end
      end

      it "security D4: an input-object default keyed by the underscore name of an `as:` input field is refused (added later, asked in VERSIONING_2A_V1)" do
        older = default_schema(visibility, :by_filter, ->(_, _, f) { f }, { new_day: 1 })
        expect_default_refused(default_outcomes(older, :by_filter, VERSIONING_2A_V1), %w[newDay])
      end

      it "security D4c: an input-object default keyed by the underscore name of an `as:` input field is refused (removed, asked in VERSIONING_2A_V2)" do
        newer = default_schema(visibility, :by_filter2, ->(_, _, f) { f }, { old_day: 1 })
        expect_default_refused(default_outcomes(newer, :by_filter2, VERSIONING_2A_V2), %w[oldDay])
      end

      it "security D4b: an input-object default keyed by an `as:` keyword naming a hidden field is refused" do
        schema = default_schema(visibility, :by_filter, ->(_, _, f) { f }, { nd: 1 })
        expect_default_refused(default_outcomes(schema, :by_filter, VERSIONING_2A_V1), %w[newDay])
      end

      it "security D5: nested and list-of-input-object defaults naming a hidden field are refused" do
        [[:by_a, ->(_, _, f) { f }, { item: { secret: 1 } }],
         [:by_b, ->(_, _, f) { f }, { items: [{ name: 1 }, { secret: 2 }] }],
         [:by_c, ->(_, i, _) { [i] }, [{ secret: 1 }]],
         [:by_d, ->(_, i, _) { GraphQL::Schema::NonNull.new(GraphQL::Schema::List.new(GraphQL::Schema::NonNull.new(i))) }, [{ secret: 1 }]]].each do |name, type, default|
          calls.clear
          schema = default_schema(visibility, name, type, default)
          expect_default_refused(default_outcomes(schema, name, VERSIONING_2A_V1), %w[secret])
        end
      end

      it "security D6: list-of-enum defaults (list, single item, non-null wrappers) naming a hidden value are refused" do
        [[:by_a, ->(s, _, _) { [s] }, [:newv]],
         [:by_b, ->(s, _, _) { [s] }, :newv],
         [:by_c, ->(s, _, _) { GraphQL::Schema::NonNull.new(GraphQL::Schema::List.new(GraphQL::Schema::NonNull.new(s))) }, ["PAID", :newv]],
         [:by_d, ->(_, _, f) { f }, { statuses: [:newv] }]].each do |name, type, default|
          calls.clear
          schema = default_schema(visibility, name, type, default)
          expect_default_refused(default_outcomes(schema, name, VERSIONING_2A_V1), %w[NEWV])
        end
      end

      it "security D7: an input field default naming a hidden enum value is refused (filter: {} and inputFields)" do
        ac = versioned_argument_class
        status = status_enum
        filter2 = Class.new(GraphQL::Schema::InputObject) do
          graphql_name "Filter2"
          argument_class(ac)
          argument :status, status, required: false, default_value: :newv
          argument :n, Integer, required: false
        end
        fc = field_class_for(ac)
        qt = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field_class(fc)
          field :echo, String, null: true do
            argument :filter, filter2, required: false
          end
        end
        schema = schema_for(qt, visibility)
        exec = attempt { run(schema, "{ echo(filter: { n: 1 }) }", VERSIONING_2A_V1, root: root) }
        intro = attempt { run(schema, '{ __type(name: "Filter2") { inputFields { name defaultValue } } }', VERSIONING_2A_V1) }
        expect([exec.first, intro.first]).to eq([:config_error, :config_error])
        expect(calls).to eq([])
      end

      it "preservation D10: a default every version has is served and printed in both versions" do
        skip "this graphql with json 3.1 cannot print a String value" unless ArmoryJsonPrinting.prints_strings?

        schema = default_schema(visibility, :by_ok, ->(_, _, f) { f }, { status: "PAID", statuses: ["PAID"], item: { name: 1 } })
        root = recorder(:by_ok)
        outs = [VERSIONING_2A_V1, VERSIONING_2A_V2].map { |v| run(schema, args_query(:by_ok), v) }
        execs = [VERSIONING_2A_V1, VERSIONING_2A_V2].map { |v| run(schema, "{ byOk }", v, root: root) }
        defaults = outs.map { |o| o.dig("data", "__type", "fields").find { |f| f["name"] == "byOk" }["args"].first["defaultValue"] }
        expect(defaults).to eq(["{status: PAID, statuses: [PAID], item: {name: 1}}"] * 2) if ArmoryJsonPrinting.prints_strings?
        expect(execs.map { |e| e.key?("errors") }).to eq([false, false])
        expect(calls).to eq([[:by_ok, { arg: { status: "PAID", statuses: ["PAID"], item: { name: 1 } } }]] * 2)
      end

      it "preservation E2: an enum value renamed across versions (same Ruby value) can be an argument default" do
        vc = versioned_value_class
        renamed = Class.new(GraphQL::Schema::Enum) do
          graphql_name "Renamed"
          enum_value_class(vc)
          value "CANCELED", value: :cancelled, removed: VERSIONING_2A_V2
          value "CANCELLED", value: :cancelled, added: VERSIONING_2A_V2
        end
        schema = default_schema(visibility, :by_renamed, ->(_, _, _) { renamed }, :cancelled)
        outs = [VERSIONING_2A_V1, VERSIONING_2A_V2].map { |v| attempt { run(schema, args_query(:by_renamed), v) } }
        expect(outs.map(&:first)).to eq(%i[result result]), outs.inspect[0, 500]
      end

      it "security D11: an executable directive argument default naming a hidden enum value is refused" do
        skip "this graphql with json 3.1 cannot print a String value" unless ArmoryJsonPrinting.prints_strings?

        ac = versioned_argument_class
        status = status_enum
        trace = Class.new(GraphQL::Schema::Directive) do
          graphql_name "trace"
          locations(GraphQL::Schema::Directive::FIELD)
          argument_class(ac)
          argument :level, status, required: false, default_value: :newv
        end
        schema = schema_for(Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :echo, String, null: true }, visibility, directives: [trace])
        intro = attempt { run(schema, "{ __schema { directives { name args { name defaultValue } } } }", VERSIONING_2A_V1) }
        use = attempt { run(schema, "{ echo @trace }", VERSIONING_2A_V1, root: recorder(:echo)) }
        expect(intro.first).to eq(:config_error), intro.inspect[0, 300]
        expect(use.first == :result && use.last.to_s.include?("NEWV")).to eq(false)
      end

      # ---------------------------------------------------------------- shadowing
      def resolver_pair(ac)
        r1 = Class.new(GraphQL::Schema::Resolver) do
          graphql_name "R1"
          argument_class(ac)
          type String, null: true
          argument :q, Integer, required: false
          def resolve(**kw) = kw.inspect
        end
        r2 = Class.new(r1) do
          graphql_name "R2"
          argument :q, Integer, required: false, removed: VERSIONING_2A_V2
        end
        [r1, r2]
      end

      it "security S1: a resolver subclass versioning an inherited argument is refused on every ask" do
        ac = versioned_argument_class
        _, r2 = resolver_pair(ac)
        fc = field_class_for(ac)
        qt = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field_class(fc); field :r, resolver: r2 }
        schema = schema_for(qt, visibility)
        outs = 3.times.map { attempt { run(schema, "{ r(q: 1) }", VERSIONING_2A_V2) } }
        expect(outs.map(&:first)).to eq(%i[config_error] * 3), outs.inspect[0, 400]
      end

      it "security S2: a field with resolver: plus its own versioned argument of the resolver's name is refused" do
        ac = versioned_argument_class
        r1, = resolver_pair(ac)
        fc = field_class_for(ac)
        qt = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field_class(fc)
          field :r, resolver: r1 do
            argument :q, Integer, required: false, removed: VERSIONING_2A_V2
          end
        end
        schema = schema_for(qt, visibility)
        outs = 2.times.map { attempt { run(schema, "{ r(q: 1) }", VERSIONING_2A_V2) } }
        expect(outs.map(&:first)).to eq(%i[config_error] * 2), outs.inspect[0, 400]
      end

      def mutation_classes(ac, log)
        m1 = Class.new(GraphQL::Schema::RelayClassicMutation) do
          graphql_name "M1"
          argument_class(ac)
          argument :note, Integer, required: false
          argument :legacy, Integer, required: false, removed: VERSIONING_2A_V2
          field :ok, String, null: true
          define_method(:resolve) { |**kw| log << [:m1, kw]; Struct.new(:ok, :client_mutation_id, keyword_init: true).new(ok: kw.inspect) }
        end
        m2 = Class.new(m1) do
          graphql_name "M2"
          argument :note, Integer, required: false, removed: VERSIONING_2A_V2
        end
        [m1, m2]
      end

      it "security S3: a mutation's versioned argument is hidden in its generated input object and cannot be sent" do
        ac = versioned_argument_class
        m1, = mutation_classes(ac, calls)
        mt = Class.new(GraphQL::Schema::Object) { graphql_name "Mutation"; field :m1, mutation: m1 }
        schema = schema_for(Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :x, String, null: true }, visibility, mutation: mt)
        sent = attempt { run(schema, "mutation { m1(input: { legacy: 1 }) { ok } }", VERSIONING_2A_V2) }
        fields = run(schema, '{ __type(name: "M1Input") { inputFields { name } } }', VERSIONING_2A_V2).dig("data", "__type", "inputFields").map { |f| f["name"] }
        older = run(schema, "mutation { m1(input: { legacy: 1 }) { ok } }", VERSIONING_2A_V1)
        expect(refused?(sent)).to eq(true)
        expect(fields.include?("legacy")).to eq(false)
        expect(older.key?("errors")).to eq(false)
        expect(calls).to eq([[:m1, { legacy: 1 }]])
        sdl = schema.to_definition(context: { armory_version: VERSIONING_2A_V2 })
        expect(sdl.include?("legacy")).to eq(false)
      end

      it "security S3b: a mutation subclass versioning an inherited argument is refused" do
        ac = versioned_argument_class
        _, m2 = mutation_classes(ac, calls)
        mt = Class.new(GraphQL::Schema::Object) { graphql_name "Mutation"; field :m2, mutation: m2 }
        schema = schema_for(Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :x, String, null: true }, visibility, mutation: mt)
        outs = 2.times.map { attempt { run(schema, '{ __type(name: "M2Input") { inputFields { name } } }', VERSIONING_2A_V2) } }
        expect(outs.map(&:first)).to eq(%i[config_error] * 2), outs.inspect[0, 400]
      end

      it "preservation S4: an interface's versioned argument vs the implementing object's unversioned one (records behaviour)" do
        ac = versioned_argument_class
        fc = field_class_for(ac)
        iface = Module.new do
          include GraphQL::Schema::Interface
          graphql_name "Node2"
          field_class(fc)
          field :f, String, null: true do
            argument :x, Integer, required: false, removed: VERSIONING_2A_V2
          end
        end
        thing = Class.new(GraphQL::Schema::Object) do
          graphql_name "Thing"
          implements iface
          field_class(fc)
          field :f, String, null: true do
            argument :x, Integer, required: false
          end
        end
        obj = Class.new { def f(x: nil) = "x=#{x.inspect}" }.new
        qt = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :thing, thing, null: true
          field :node, iface, null: true
        end
        schema = schema_for(qt, visibility, orphans: [thing]) do
          define_singleton_method(:resolve_type) { |*_| thing }
        end
        root = Class.new { define_method(:thing) { obj }; define_method(:node) { obj } }.new
        on_object = run(schema, "{ thing { f(x: 1) } }", VERSIONING_2A_V2, root: root)
        on_iface = attempt { run(schema, "{ node { f(x: 1) } }", VERSIONING_2A_V2, root: root) }
        expect(on_object).to eq("data" => { "thing" => { "f" => "x=1" } })
        expect(refused?(on_iface)).to eq(true)
      end

      it "security S5: an input-object subclass versioning a field its versioned parent defines is refused" do
        ac = versioned_argument_class
        parent = Class.new(GraphQL::Schema::InputObject) do
          graphql_name "PF"
          argument_class(ac)
          argument :code, Integer, required: false, removed: VERSIONING_2A_V2
        end
        child = Class.new(parent) do
          graphql_name "CF"
          argument :code, Integer, required: false, added: VERSIONING_2A_V2
        end
        fc = field_class_for(ac)
        qt = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field_class(fc)
          field :echo, String, null: true do
            argument :filter, child, required: false
          end
        end
        schema = schema_for(qt, visibility)
        outs = [VERSIONING_2A_V1, VERSIONING_2A_V1].map { |v| attempt { run(schema, "{ echo(filter: { code: 1 }) }", v, root: recorder(:echo)) } }
        expect(outs.map(&:first)).to eq(%i[config_error config_error]), outs.inspect[0, 400]
        expect(calls).to eq([])
      end

      it "security S6: an enum subclass versioning a parent's value with a different `value:` is refused" do
        vc = versioned_value_class
        parent = Class.new(GraphQL::Schema::Enum) do
          graphql_name "PE"
          enum_value_class(vc)
          value "A"
          value "X", value: :x_parent
        end
        child = Class.new(parent) do
          graphql_name "CE"
          value "X", value: :x_child, removed: VERSIONING_2A_V2
        end
        log = calls
        qt = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :echo, String, null: true do
            argument :e, child, required: false
          end
        end
        schema = schema_for(qt, visibility)
        root = Class.new { define_method(:echo) { |e: nil| log << e; e.inspect } }.new
        outs = [attempt { run(schema, "{ echo(e: X) }", VERSIONING_2A_V2, root: root) }, attempt { run(schema, '{ __type(name: "CE") { enumValues { name } } }', VERSIONING_2A_V2) }]
        expect(outs.map(&:first)).to eq(%i[config_error config_error]), outs.inspect[0, 400]
        expect(calls).to eq([])
      end

      it "preservation S7: an enum subclass's unversioned value over a parent's versioned value is served in every version" do
        vc = versioned_value_class
        parent = Class.new(GraphQL::Schema::Enum) do
          graphql_name "PE"
          enum_value_class(vc)
          value "A"
          value "Y", value: :y_parent, added: VERSIONING_2A_V2
        end
        child = Class.new(parent) do
          graphql_name "CE"
          value "Y", value: :y_child
        end
        log = calls
        qt = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :echo, String, null: true do
            argument :e, child, required: false
          end
        end
        schema = schema_for(qt, visibility)
        root = Class.new { define_method(:echo) { |e: nil| log << e; e.inspect } }.new
        outs = [VERSIONING_2A_V1, VERSIONING_2A_V2].map { |v| run(schema, "{ echo(e: Y) }", v, root: root) }
        expect(outs.map { |o| o.key?("errors") }).to eq([false, false])
        expect(calls).to eq(%i[y_child y_child])
      end

      # ---------------------------------------------------------------- directives
      it "security DIR1: an executable directive's versioned argument is absent from __schema.directives in other versions" do
        ac = versioned_argument_class
        trace = Class.new(GraphQL::Schema::Directive) do
          graphql_name "trace"
          locations(GraphQL::Schema::Directive::FIELD)
          argument_class(ac)
          argument :level, Integer, required: false, added: VERSIONING_2A_V2
        end
        schema = schema_for(Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :echo, String, null: true }, visibility, directives: [trace])
        names = [VERSIONING_2A_V1, VERSIONING_2A_V2].map do |v|
          run(schema, "{ __schema { directives { name args { name } } } }", v).dig("data", "__schema", "directives").find { |d| d["name"] == "trace" }["args"].map { |a| a["name"] }
        end
        expect(names).to eq([[], ["level"]])
        expect(schema.to_definition(context: { armory_version: VERSIONING_2A_V1 }).include?("level")).to eq(false)
      end

      it "security DIR2: a directive with FIELD and FIELD_DEFINITION locations refuses a versioned argument on every ask" do
        ac = versioned_argument_class
        mixed = Class.new(GraphQL::Schema::Directive) do
          graphql_name "mixed"
          locations(GraphQL::Schema::Directive::FIELD, GraphQL::Schema::Directive::FIELD_DEFINITION)
          argument_class(ac)
          argument :level, Integer, required: false, added: VERSIONING_2A_V2
        end
        schema = schema_for(Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :echo, String, null: true }, visibility, directives: [mixed])
        outs = [attempt { run(schema, "{ echo @mixed(level: 1) }", VERSIONING_2A_V2, root: recorder(:echo)) },
                attempt { run(schema, "{ __schema { directives { name args { name } } } }", VERSIONING_2A_V2) },
                attempt { run(schema, "{ __schema { directives { name args { name } } } }", VERSIONING_2A_V1) }]
        expect(outs.map(&:first)).to eq(%i[config_error] * 3), outs.inspect[0, 400]
      end

      it "security DIR3: a type-system directive subclass inheriting a versioned argument from an executable parent does not print it" do
        ac = versioned_argument_class
        base_dir = Class.new(GraphQL::Schema::Directive) do
          graphql_name "basedir"
          locations(GraphQL::Schema::Directive::FIELD)
          argument_class(ac)
          argument :team, Integer, required: false, added: VERSIONING_2A_V2
        end
        audit = Class.new(base_dir) do
          graphql_name "audit"
          locations(GraphQL::Schema::Directive::FIELD_DEFINITION)
        end
        qt = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :tagged, String, null: true, directives: { audit => { team: 7 } }
        end
        schema = schema_for(qt, visibility, directives: [audit])
        sdl = begin
          schema.to_definition(context: { armory_version: VERSIONING_2A_V1 })
        rescue config_error => e
          "refused: #{e.message}"
        end
        expect(sdl).to match(/\Arefused: @basedir\.team: is on a directive used in the SDL \(FIELD_DEFINITION\).*cannot have a lifecycle/), sdl[0, 600]
      end

      it "security DIR4: a type-system directive applied with an enum value added later does not print it in the older SDL" do
        ac = versioned_argument_class
        status = status_enum
        meta = Class.new(GraphQL::Schema::Directive) do
          graphql_name "meta"
          locations(GraphQL::Schema::Directive::FIELD_DEFINITION)
          argument_class(ac)
          argument :status, status, required: false
        end
        qt = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :tagged, String, null: true, directives: { meta => { status: :newv } }
        end
        schema = schema_for(qt, visibility, directives: [meta])
        sdl = begin
          schema.to_definition(context: { armory_version: VERSIONING_2A_V1 })
        rescue config_error => e
          "refused: #{e.message}"
        end
        expect(sdl).to match(/\Arefused: @meta\.status: is on a directive used in the SDL \(FIELD_DEFINITION\).*cannot reach versioned members/), sdl[0, 800]
      end

      it "preservation DIR5: @include, @skip and @deprecated are untouched" do
        ac = versioned_argument_class
        fc = field_class_for(ac)
        qt = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field_class(fc)
          field :echo, String, null: true
          field :old, String, null: true, deprecation_reason: "gone"
        end
        schema = schema_for(qt, visibility)
        root = Class.new { def echo = "e"; def old = "o" }.new
        r = [VERSIONING_2A_V1, VERSIONING_2A_V2].map { |v| run(schema, "{ echo @include(if: true) old @skip(if: true) }", v, root: root) }
        d = run(schema, "{ __schema { directives { name args { name } } } }", VERSIONING_2A_V1).dig("data", "__schema", "directives").to_h { |x| [x["name"], x["args"].map { |a| a["name"] }] }
        expect(r).to eq([{ "data" => { "echo" => "e" } }] * 2)
        expect(d.slice("include", "skip", "deprecated")).to eq("include" => ["if"], "skip" => ["if"], "deprecated" => ["reason"])
      end

      it "preservation DIR6: a versioned argument on a directive not added to the schema changes nothing" do
        ac = versioned_argument_class
        Class.new(GraphQL::Schema::Directive) do
          graphql_name "unused"
          locations(GraphQL::Schema::Directive::FIELD_DEFINITION)
          argument_class(ac)
          argument :team, Integer, required: false, removed: VERSIONING_2A_V2
        end
        out = [VERSIONING_2A_V1, VERSIONING_2A_V2].map { |v| run(w[:schema], "{ echo }", v, root: root) }
        expect(out.map { |o| o.key?("errors") }).to eq([false, false])
      end

      # ---------------------------------------------------------------- suggestions
      it "security SUG2: a misspelled input field never names the hidden field" do
        outs = [attempt { run(w[:schema], "{ echo(filter: { cod: 1 }) }", VERSIONING_2A_V2, root: root) },
                attempt { run(w[:schema], "{ echo(filter: { sinc: 1 }) }", VERSIONING_2A_V1, root: root) },
                attempt { run(w[:schema], "{ echo(filter: { item: { secre: 1 } }) }", VERSIONING_2A_V1, root: root) },
                attempt { run(w[:schema], "query($f: Filter) { echo(filter: $f) }", VERSIONING_2A_V2, variables: { "f" => { "cod" => 1 } }, root: root) }]
        texts = outs.map { |o| o.first == :result ? messages(o.last) : o.inspect }
        expect(texts.zip([/\bcode\b/, /\bsince\b/, /\bsecret\b/, /\bcode\b/]).map { |t, re| t.match?(re) }).to eq([false] * 4), texts.inspect
        expect(calls).to eq([])
      end

      it "security SUG3: a misspelled enum literal or variable never lists the hidden value" do
        outs = [attempt { run(w[:schema], "{ echo(filter: { status: OLD }) }", VERSIONING_2A_V2, root: root) },
                attempt { run(w[:schema], "{ echo(statuses: [NEW]) }", VERSIONING_2A_V1, root: root) },
                attempt { run(w[:schema], "query($s: Status) { echo(filter: { status: $s }) }", VERSIONING_2A_V2, variables: { "s" => "OLD" }, root: root) },
                attempt { run(w[:schema], "query($s: [Status!]) { echo(statuses: $s) }", VERSIONING_2A_V1, variables: { "s" => ["NEW"] }, root: root) }]
        texts = outs.map { |o| o.first == :result ? messages(o.last) : o.inspect }
        expect(texts.zip(%w[OLDV NEWV OLDV NEWV]).map { |t, n| t.include?(n) }).to eq([false] * 4), texts.inspect
        expect(calls).to eq([])
      end

      # ---------------------------------------------------------------- caching
      it "security C1: one argument shared by two schemas with different version lists answers each schema's list" do
        ac = versioned_argument_class
        fc = field_class_for(ac)
        qt = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field_class(fc)
          field :echo, String, null: true do
            argument :first, Integer, required: false, added: VERSIONING_2A_V2
          end
        end
        a = schema_for(qt, visibility)
        b = schema_for(qt, visibility, versions: %w[x y], retired: [])
        seq = [
          attempt { run(b, "{ echo }", "y", root: root) },
          attempt { run(a, "{ echo(first: 1) }", VERSIONING_2A_V1, root: root) },
          attempt { run(a, "{ echo(first: 1) }", VERSIONING_2A_V2, root: root) },
          attempt { run(b, "{ echo }", "y", root: root) }
        ]
        expect(seq.map(&:first)).to eq(%i[config_error result result config_error]), seq.inspect[0, 500]
        expect(refused?(seq[1])).to eq(true)
        expect(calls).to eq([[:echo, { first: 1 }]])
      end

      it "security C2: a refusal is raised on every ask, across two schemas sharing the type" do
        ac = versioned_argument_class
        _, r2 = resolver_pair(ac)
        fc = field_class_for(ac)
        qt = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field_class(fc); field :r, resolver: r2 }
        s1 = schema_for(qt, visibility)
        s2 = schema_for(qt, visibility == :warden ? :visibility : :warden)
        outs = [s1, s2, s1, s2].map { |s| attempt { run(s, '{ __type(name: "Query") { fields { args { name } } } }', VERSIONING_2A_V1) } }
        expect(outs.map(&:first)).to eq(%i[config_error] * 4), outs.inspect[0, 400]
      end

      it "security C3: a default refused in VERSIONING_2A_V1 stays refused after a successful ask in VERSIONING_2A_V2, and VERSIONING_2A_V2 keeps working" do
        schema = default_schema(visibility, :by_status, ->(s, _, _) { s }, :newv)
        seq = [VERSIONING_2A_V2, VERSIONING_2A_V1, VERSIONING_2A_V2, VERSIONING_2A_V1].map { |v| attempt { run(schema, args_query(:by_status), v) } }
        expect(seq.map(&:first)).to eq(%i[result config_error result config_error]), seq.inspect[0, 500]
      end

      # ---------------------------------------------------------------- loads / prepare / validates
      it "security L1: a loads: argument hidden in V is refused and never loads" do
        ac = versioned_argument_class
        fc = field_class_for(ac)
        item_obj = Class.new(GraphQL::Schema::Object) { graphql_name "ItemObj"; field :id, GraphQL::Types::ID, null: false }
        qt = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field_class(fc)
          field :load, String, null: true do
            argument :item_id, GraphQL::Types::ID, required: false, loads: item_obj, added: VERSIONING_2A_V2
          end
        end
        log = calls
        schema = schema_for(qt, visibility, orphans: [item_obj]) do
          define_singleton_method(:object_from_id) { |id, _ctx| log << [:object_from_id, id]; Struct.new(:id).new(id) }
          define_singleton_method(:resolve_type) { |*_| item_obj }
        end
        root = Class.new { define_method(:load) { |item: nil| log << [:load, item&.id]; "ok" } }.new
        older = attempt { run(schema, '{ load(itemId: "1") }', VERSIONING_2A_V1, root: root) }
        newer = run(schema, '{ load(itemId: "1") }', VERSIONING_2A_V2, root: root)
        expect(refused?(older)).to eq(true)
        expect(newer).to eq("data" => { "load" => "ok" })
        expect(calls).to eq([[:object_from_id, "1"], [:load, "1"]])
      end

      it "security L2/L3: prepare: and validates: never run for an argument hidden in V, and say nothing about it" do
        ac = versioned_argument_class
        fc = field_class_for(ac)
        log = calls
        qt = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field_class(fc)
          field :prep, String, null: true do
            argument :p, Integer, required: false, prepare: ->(v, _ctx) { log << [:prepared, v]; v }, removed: VERSIONING_2A_V2
            argument :v, Integer, required: false, validates: { numericality: { less_than: 5 } }, removed: VERSIONING_2A_V2
          end
        end
        schema = schema_for(qt, visibility)
        root = recorder(:prep)
        a = run(schema, "{ prep(p: 1) }", VERSIONING_2A_V2, root: root)
        b = run(schema, "{ prep(v: 10) }", VERSIONING_2A_V2, root: root)
        c = run(schema, "{ prep(v: 10) }", VERSIONING_2A_V1, root: root)
        expect([messages(a), messages(b)]).to eq(["Field 'prep' doesn't accept argument 'p'", "Field 'prep' doesn't accept argument 'v'"])
        expect(messages(c)).to include("less than 5")
        expect(calls).to eq([])
      end

      # ---------------------------------------------------------------- ownership / exemptions
      it "preservation O1: visible? owners and ancestors, with Authorization::Base included before and after" do
        auth = GraphQL::Armory::Authorization::Base
        ver = GraphQL::Armory::Versioning::Base
        integ = GraphQL::Armory::Versioning::Integration
        first_auth = Class.new(GraphQL::Schema::Argument) { include auth; include ver }
        first_ver = Class.new(GraphQL::Schema::Argument) { include ver; include auth }
        value = versioned_value_class
        expect(first_auth.instance_method(:visible?).owner).to eq(integ::Argument)
        expect(first_ver.instance_method(:visible?).owner).to eq(GraphQL::Armory::Authorization::Integration::Argument)
        expect(value.instance_method(:visible?).owner).to eq(integ::EnumValue)
        expect(first_auth.ancestors.index(integ::Argument) < first_auth.ancestors.index(integ::Member)).to eq(true)
        expect { Class.new(GraphQL::Schema::EnumValue) { include GraphQL::Armory::Authorization::Base } }.to raise_error(ArgumentError)
        [first_auth, first_ver].each do |ac|
          calls.clear
          fc = field_class_for(ac)
          qt = Class.new(GraphQL::Schema::Object) do
            graphql_name "Query"
            field_class(fc)
            field :echo, String, null: true do
              argument :first, Integer, required: false, added: VERSIONING_2A_V2
            end
          end
          schema = schema_for(qt, visibility)
          r = recorder(:echo)
          expect([refused?([:result, run(schema, "{ echo(first: 1) }", VERSIONING_2A_V1, root: r)]), run(schema, "{ echo(first: 1) }", VERSIONING_2A_V2, root: r).key?("errors")]).to eq([true, false])
        end
      end

      it "preservation E4: Base classes without any lifecycle work on a schema that never installed Versioning" do
        ac = versioned_argument_class
        fc = Class.new(GraphQL::Schema::Field) { argument_class(ac) } # fields with Base always read the version (documented)
        status = Class.new(GraphQL::Schema::Enum) { graphql_name "S"; enum_value_class(Class.new(GraphQL::Schema::EnumValue) { include GraphQL::Armory::Versioning::Base }); value "A" }
        qt = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field_class(fc)
          field :echo, String, null: true do
            argument :s, status, required: false, default_value: "A"
          end
        end
        plugin = { visibility: GraphQL::Schema::Visibility, warden: GraphQL::Schema::Warden }.fetch(visibility)
        schema = Class.new(ArmoryEngine.base_schema) { query(qt); use plugin }
        out = execute_query(schema, "{ echo(s: A) }", root_value: recorder(:echo)).to_h
        expect(out).to eq("data" => { "echo" => "{s: \"A\"}" }).or eq("data" => { "echo" => "{:s=>\"A\"}" })
      end
    end
  end
end
