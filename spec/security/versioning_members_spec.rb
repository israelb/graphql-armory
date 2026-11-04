# frozen_string_literal: true

# Arguments, input-object fields and enum values declared with `added:` or `removed:` exist only in the versions they live
# in: a client of another version cannot send them (as literals or variables), introspect them, be suggested them or see
# them in that version's SDL.
RSpec.describe "use GraphQL::Armory::Versioning: arguments, input fields and enum values" do
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:controls) { versioning::Controls }
  let(:resolved) { [] }

  def run(schema, query_string, version, root: controls::MembersRoot.example(resolved), variables: {})
    execute_query(schema, query_string, root_value: root, variables: variables, context: { armory_version: version }).to_h
  end

  def messages(result) = Array(result["errors"]).map { |error| error["message"] }

  # Refused before anything runs. Where graphql cannot print the refused value with json 3.1 (2.4, 2.5), building the
  # refusal message raises instead; nothing runs either way.
  def expect_refused(&block)
    if ArmoryJsonPrinting.prints_strings?
      result = block.call
      expect([result.key?("errors"), result.key?("data")]).to eq([true, false])
    else
      expect(&block).to raise_error(ArgumentError, /quirks_mode/)
    end
  end

  def schema_over(query_type, visibility, versions: controls::Versions::LABELS, retired: controls::Versions::RETIRED)
    plugin = controls::Schema::PLUGINS.fetch(visibility)
    Class.new(ArmoryEngine.base_schema) do
      query(query_type)
      use plugin
      use GraphQL::Armory::Versioning, versions: versions, retired: retired, default: :latest
    end
  end

  %i[warden visibility].each do |visibility|
    context "with #{visibility}" do
      let(:schema) { schema_over(controls::MembersQuery.example, visibility) }

      it "accepts a field argument only in the versions it lives in" do
        first_older = run(schema, "{ invoices(first: 1) }", "2024-06-01")
        first_newer = run(schema, "{ invoices(first: 1) }", "2025-01-01")
        page_older = run(schema, "{ invoices(page: 2) }", "2024-06-01")
        page_newer = run(schema, "{ invoices(page: 2) }", "2025-01-01")

        expect([messages(first_older), first_newer, page_older, messages(page_newer)]).to eq(
          [["Field 'invoices' doesn't accept argument 'first'"], { "data" => { "invoices" => ["first=1"] } },
           { "data" => { "invoices" => ["page=2"] } }, ["Field 'invoices' doesn't accept argument 'page'"]]
        )
        expect(resolved).to eq([[:invoices, { first: 1 }], [:invoices, { page: 2 }]])
      end

      it "never suggests an argument outside the version" do
        older = run(schema, "{ invoices(firs: 1) }", "2024-06-01")
        newer = run(schema, "{ invoices(firs: 1) }", "2025-01-01")

        expect([messages(older).join.include?("Did you mean"), messages(newer).join.include?("first")]).to eq([false, true])
        expect(resolved).to eq([])
      end

      it "accepts an input field only in the versions it lives in, as a literal and through a variable" do
        query = "query($f: InvoiceFilter) { invoices(filter: $f) }"
        literal_older = run(schema, '{ invoices(filter: { since: "2024" }) }', "2024-06-01")
        variable_older = run(schema, query, "2024-06-01", variables: { "f" => { "since" => "2024" } })
        variable_newer = run(schema, query, "2025-01-01", variables: { "f" => { "since" => "2024" } })
        code_newer = run(schema, query, "2025-01-01", variables: { "f" => { "code" => "X" } })
        code_literal_newer = run(schema, '{ invoices(filter: { code: "X" }) }', "2025-01-01")
        code_older = run(schema, query, "2024-06-01", variables: { "f" => { "code" => "X" } })

        expect([literal_older, variable_older, code_newer, code_literal_newer].map { |result| result.key?("errors") && !result.key?("data") }).to eq([true, true, true, true])
        expect([variable_newer, code_older]).to eq(
          [{ "data" => { "invoices" => ["filter.since=2024"] } }, { "data" => { "invoices" => ["filter.code=X"] } }]
        )
        expect(resolved.size).to eq(2)
      end

      it "accepts an enum value only in the versions it lives in, as a literal and through a variable" do
        query = "query($s: Status) { invoices(filter: { status: $s }) }"
        cancelled_older = run(schema, query, "2024-06-01", variables: { "s" => "CANCELLED" })
        void_newer = run(schema, "{ invoices(filter: { status: VOID }) }", "2025-01-01")

        expect_refused { run(schema, query, "2025-01-01", variables: { "s" => "CANCELLED" }) }
        expect_refused { run(schema, "{ invoices(filter: { status: CANCELLED }) }", "2025-01-01") }
        expect([cancelled_older, void_newer]).to eq(
          [{ "data" => { "invoices" => ["filter.status=CANCELLED"] } }, { "data" => { "invoices" => ["filter.status=VOID"] } }]
        )
        expect(resolved.size).to eq(2)
      end

      it "introspects each version's arguments, input fields and enum values" do
        query = '{ q: __type(name: "Query") { fields { name args { name } } } f: __type(name: "InvoiceFilter") { inputFields { name } } ' \
                's: __type(name: "Status") { enumValues { name } } }'
        seen = %w[2024-06-01 2025-01-01].to_h do |version|
          data = run(schema, query, version)["data"]
          args = data["q"]["fields"].find { |field| field["name"] == "invoices" }["args"].map { |arg| arg["name"] }
          [version, [args, data["f"]["inputFields"].map { |f| f["name"] }, data["s"]["enumValues"].map { |v| v["name"] }]]
        end

        expect(seen).to eq(
          "2024-06-01" => [%w[filter page], %w[status code], %w[PAID VOID CANCELLED]],
          "2025-01-01" => [%w[filter first], %w[status since], %w[PAID VOID]]
        )
      end

      it "prints each version's arguments, input fields and enum values in its SDL" do
        older = schema.to_definition(context: { armory_version: "2024-06-01" })
        newer = schema.to_definition(context: { armory_version: "2025-01-01" })
        names = %w[page: first: since: code: CANCELLED VOID]

        expect([names.map { |name| older.include?(name) }, names.map { |name| newer.include?(name) }]).to eq(
          [[true, false, false, true, true, true], [false, true, true, false, false, true]]
        )
      end

      it "fails the response when a resolver returns an enum value outside the version (documented limit)" do
        root = controls::MembersRoot.example(resolved, status: "CANCELLED")

        expect(run(schema, "{ status }", "2024-06-01", root: root)).to eq("data" => { "status" => "CANCELLED" })
        expect { run(schema, "{ status }", "2025-01-01", root: root) }.to raise_error(GraphQL::Schema::Enum::UnresolvedValueError)
      end

      it "refuses a default value that names an input field or enum value outside the version it is served in" do
        value_class = controls::EnumValue.example
        argument_class = controls::Argument.example
        status = Class.new(GraphQL::Schema::Enum) do
          graphql_name "Status"
          enum_value_class(value_class)
          value "PAID"
          value "VOID", added: "v2"
        end
        filter = Class.new(GraphQL::Schema::InputObject) do
          graphql_name "Filter"
          argument_class(argument_class)
          argument :page, Integer, required: false, removed: "v3"
        end
        query_type = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field_class(Class.new(GraphQL::Schema::Field) { argument_class(argument_class) })
          field :by_code, String, null: true do
            argument :filter, filter, required: false, default_value: { page: 2 }
          end
          field :by_status, String, null: true do
            argument :status, status, required: false, default_value: "VOID"
          end
        end
        schema = schema_over(query_type, visibility, versions: %w[v1 v2 v3], retired: [])
        query = '{ __type(name: "Query") { fields { args { name defaultValue } } } }'

        expect { run(schema, query, "v1") }.to raise_error(versioning::ConfigurationError, /byStatus\.status: its default_value names .* not in v1/)
        expect { run(schema, query, "v3") }.to raise_error(versioning::ConfigurationError, /byCode\.filter: its default_value names .* not in v3/)
        next unless ArmoryJsonPrinting.prints_strings?

        expect(run(schema, query, "v2").dig("data", "__type", "fields").map { |field| field["args"] }).to eq(
          [[{ "name" => "filter", "defaultValue" => "{page: 2}" }], [{ "name" => "status", "defaultValue" => "VOID" }]]
        )
      end

      it "refuses a versioned argument or enum value that shadows a parent's definition of the same name" do
        argument_class = controls::Argument.example
        value_class = controls::EnumValue.example
        parent_input = Class.new(GraphQL::Schema::InputObject) do
          graphql_name "ParentFilter"
          argument_class(argument_class)
          argument :code, String, required: false
        end
        child_input = Class.new(parent_input) do
          graphql_name "Filter"
          argument :code, String, required: false, removed: "2025-01-01"
        end
        parent_enum = Class.new(GraphQL::Schema::Enum) do
          graphql_name "ParentStatus"
          enum_value_class(value_class)
          value "PAID"
        end
        child_enum = Class.new(parent_enum) do
          graphql_name "Status"
          value "PAID", removed: "2025-01-01"
        end
        with_input = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field_class(Class.new(GraphQL::Schema::Field) { argument_class(argument_class) })
          field :invoices, String, null: true do
            argument :filter, child_input, required: false
          end
        end
        with_enum = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :status, child_enum, null: true
        end

        expect { run(schema_over(with_input, visibility), '{ __type(name: "Filter") { inputFields { name } } }', "2025-01-01") }
          .to raise_error(versioning::ConfigurationError, /Filter\.code: shadows ParentFilter\.code/)
        expect { run(schema_over(with_enum, visibility), '{ __type(name: "Status") { enumValues { name } } }', "2025-01-01") }
          .to raise_error(versioning::ConfigurationError, /Status\.PAID: shadows ParentStatus\.PAID/)
      end

      it "versions the arguments of an executable directive, and refuses a lifecycle on a type-system directive's" do
        argument_class = controls::Argument.example
        executable = Class.new(GraphQL::Schema::Directive) do
          graphql_name "trace"
          locations(GraphQL::Schema::Directive::FIELD)
          argument_class(argument_class)
          argument :level, Integer, required: false, added: "2025-01-01"
        end
        type_system = Class.new(GraphQL::Schema::Directive) do
          graphql_name "owner"
          locations(GraphQL::Schema::Directive::FIELD_DEFINITION)
          argument_class(argument_class)
          argument :team, String, required: false, removed: "2025-01-01"
        end
        query_type = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :invoices, String, null: true
        end
        ok = Class.new { define_method(:invoices) { "ok" } }.new
        plain = schema_over(query_type, visibility)
        plain.directive(executable)
        tagged = schema_over(query_type, visibility)
        tagged.directive(type_system)

        expect(messages(run(plain, "{ invoices @trace(level: 1) }", "2024-06-01", root: ok))).to eq(["Directive 'trace' doesn't accept argument 'level'"])
        expect(run(plain, "{ invoices @trace(level: 1) }", "2025-01-01", root: ok)).to eq("data" => { "invoices" => "ok" })
        expect { tagged.to_definition(context: { armory_version: "2025-01-01" }) }
          .to raise_error(versioning::ConfigurationError, /owner\.team: is on a directive used in the SDL .*cannot have a lifecycle/)
      end

      it "runs a field without a required argument hidden in the client's version (documented limit)" do
        argument_class = controls::Argument.example
        query_type = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field_class(Class.new(GraphQL::Schema::Field) { argument_class(argument_class) })
          field :invoices, String, null: true do
            argument :first, Integer, required: true, added: "2025-01-01"
          end
        end
        schema = schema_over(query_type, visibility)
        root = Class.new { define_method(:invoices) { |first: :absent| "first=#{first}" } }.new

        expect(run(schema, "{ invoices }", "2024-06-01", root: root)).to eq("data" => { "invoices" => "first=absent" })
        expect(messages(run(schema, "{ invoices }", "2025-01-01", root: root)).size).to eq(1)
      end
    end
  end
end
