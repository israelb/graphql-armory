# frozen_string_literal: true

# The audit's checks of what a version serves without refusing anything, one shape at a time, beyond the matrix's rows.
RSpec.describe "GraphQL::Armory::Versioning::Audit hazards" do
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:old) { "2024-06-01" }
  let(:new) { "2025-01-01" }

  def audit(schema) = versioning::Audit.(schema)

  def found(report, kind) = report.problems.select { |problem| problem.kind == kind }

  def paths(report, kind) = found(report, kind).map(&:path)

  def run(schema, query_string, version, root: nil)
    execute_query(schema, query_string, root_value: root, context: { armory_version: version }).to_h
  end

  def record(**values) = Struct.new(*values.keys, keyword_init: true).new(**values)

  def schema_over(query_type, visibility, **options)
    plugin = versioning::Controls::Schema::PLUGINS.fetch(visibility)
    settings = { versions: versioning::Controls::Versions::LABELS, retired: versioning::Controls::Versions::RETIRED, default: :latest, **options }
    Class.new(ArmoryEngine.base_schema) do
      query(query_type)
      use plugin
      use GraphQL::Armory::Versioning, **settings
    end
  end

  def bases
    mod = versioning::Base
    membership = Class.new(GraphQL::Schema::TypeMembership) { include mod }
    argument = Class.new(GraphQL::Schema::Argument) { include mod }
    field = Class.new(GraphQL::Schema::Field) { include mod; argument_class(argument) }
    object = Class.new(GraphQL::Schema::Object) { include mod; field_class(field) }
    interface = Module.new do
      include GraphQL::Schema::Interface
      include mod
      field_class(field)
      type_membership_class(membership)
    end
    { argument: argument, field: field, object: object, interface: interface, membership: membership }
  end

  %i[warden visibility].each do |visibility|
    context "with #{visibility}" do
      describe ":fallback" do
        it "reports a field hidden on a subclass while its parent's definition lives in the version" do
          b = bases
          parent = Class.new(b[:object]) { graphql_name "Document"; field :title, String, null: true }
          child = Class.new(parent) { graphql_name "Contract"; field :title, String, null: true, removed: "2025-01-01" }
          query = Class.new(b[:object]) { graphql_name "Query"; field :contract, child, null: true; field :document, parent, null: true }
          schema = schema_over(query, visibility)

          served = run(schema, "{ contract { title } }", new, root: record(contract: record(title: "t"), document: nil))
          if visibility == :warden
            expect(served).to eq("data" => { "contract" => { "title" => "t" } })
          else
            expect(served["errors"].map { |error| error["message"] }).to eq(["Field 'title' doesn't exist on type 'Contract'"])
          end
          report = audit(schema)
          expect(paths(report, :fallback)).to eq(["Contract.title"])
          message = visibility == :warden ? /hides Contract's definition, so the Warden serves Document's/ : /Contract no longer has title in 2025-01-01, though Document's definition lives there/
          expect(found(report, :fallback).first.message).to match(message)
        end

        it "does not count an interface whose membership the version hides" do
          b = bases
          totaled = Module.new { include b[:interface]; graphql_name "Totaled"; field :total, Integer, null: true }
          invoice = Class.new(b[:object]) do
            graphql_name "Invoice"
            implements totaled, removed: "2025-01-01"
            field :id, GraphQL::Types::ID, null: true
            field :total, Integer, null: true, removed: "2025-01-01"
          end
          other = Class.new(b[:object]) { graphql_name "Other"; implements totaled; field :id, GraphQL::Types::ID, null: true }
          query = Class.new(b[:object]) { graphql_name "Query"; field :invoice, invoice, null: true; field :other, other, null: true }

          expect(paths(audit(schema_over(query, visibility)), :fallback)).to eq([])
        end

        it "does not report a field versioned with its interface's definition" do
          b = bases
          totaled = Module.new { include b[:interface]; graphql_name "Totaled"; field :id, GraphQL::Types::ID, null: true; field :total, Integer, null: true, removed: "2025-01-01" }
          invoice = Class.new(b[:object]) { graphql_name "Invoice"; implements totaled; field :total, Integer, null: true, removed: "2025-01-01" }
          query = Class.new(b[:object]) { graphql_name "Query"; field :invoice, invoice, null: true }

          expect(audit(schema_over(query, visibility)).problems).to eq([])
        end
      end

      describe ":own_check" do
        it "reports a visible? on a type class, at the type" do
          b = bases
          admin = Class.new(b[:object]) { graphql_name "Admin"; lifecycle added: "2025-01-01"; field :a, String, null: true; def self.visible?(_context) = true }
          query = Class.new(b[:object]) { graphql_name "Query"; field :admin, admin, null: true, added: "2025-01-01" }
          report = audit(schema_over(query, visibility))

          expect(paths(report, :own_check)).to eq(["Admin.visible?"])
          expect(found(report, :own_check).first.location).to match(/versioning_audit_hazards_spec\.rb:\d+/)
        end

        it "reports a visible? in an interface's definition_methods, at the interface" do
          b = bases
          named = Module.new do
            include b[:interface]
            graphql_name "Named"
            field :name, String, null: true
            definition_methods { def visible?(_context) = true }
          end
          person = Class.new(b[:object]) { graphql_name "Person"; implements named }
          query = Class.new(b[:object]) { graphql_name "Query"; field :person, person, null: true }

          expect(paths(audit(schema_over(query, visibility)), :own_check)).to eq(["Named.visible?"])
        end

        it "reports a visible? on argument, enum value and membership classes" do
          b = bases
          argument_with = Class.new(b[:argument]) { def visible?(context) = super }
          value_class = Class.new(GraphQL::Schema::EnumValue) { include GraphQL::Armory::Versioning::Base; def visible?(context) = super }
          membership = Class.new(b[:membership]) { def visible?(context) = super }
          kind = Class.new(GraphQL::Schema::Enum) { include GraphQL::Armory::Versioning::Base; enum_value_class(value_class); graphql_name "Kind"; value "A" }
          named = Module.new { include b[:interface]; graphql_name "Named"; type_membership_class(membership); field :name, String, null: true }
          field_with = Class.new(b[:field]) { argument_class(argument_with) }
          person = Class.new(b[:object]) { graphql_name "Person"; implements named, added: "2025-01-01"; field :age, Integer, null: true }
          query = Class.new(b[:object]) do
            graphql_name "Query"
            field_class(field_with)
            field :kind, kind, null: true do
              argument :q, String, required: false
            end
            field :person, person, null: true
            field :named, named, null: true, added: "2025-01-01"
          end
          report = audit(schema_over(query, visibility))

          expect(found(report, :own_check).map(&:location).uniq.size).to eq(3)
          expect(paths(report, :own_check)).to all(end_with("#visible?"))
        end

        it "reports a resolver's and a mutation's visible?" do
          b = bases
          resolver = Class.new(GraphQL::Schema::Resolver) do
            include GraphQL::Armory::Versioning::Base
            graphql_name "Finder"
            type String, null: true
            def self.visible?(_context) = true
          end
          query = Class.new(b[:object]) { graphql_name "Query"; field :find, resolver: resolver }

          expect(paths(audit(schema_over(query, visibility)), :own_check)).to eq(["Finder.visible?"])
        end

        it "reports a visible? defined on one field at that field, even when its class is declared" do
          b = bases
          query = Class.new(b[:object]) do
            graphql_name "Query"
            field :ping, String, null: true
            field :old, String, null: true, removed: "2025-01-01" do
              def self.visible?(_context) = true
            end
          end
          report = audit(schema_over(query, visibility, own_checks: { b[:field] => { visible?: "not here" } }))

          expect(paths(report, :own_check)).to include("Query.old")
          expect(found(report, :own_check).find { |problem| problem.path == "Query.old" }.message).to match(/own_checks: cannot declare it/)
          expect(report.ok?).to be(false)
        end

        it "reports the schema's own visible?" do
          b = bases
          query = Class.new(b[:object]) { graphql_name "Query"; field :ping, String, null: true }
          schema = schema_over(query, visibility)
          schema.define_singleton_method(:visible?) { |member, context| super(member, context) }

          problem = found(audit(schema), :own_check).first
          expect(problem.path).to eq("Schema.visible?")
          expect(problem.message).to match(/on the schema: graphql-ruby asks it about every member/)
        end

        it "follows the whole chain: a method that calls super does not hide one below it" do
          b = bases
          middle = Class.new(b[:object]) { def self.visible?(_context) = true }
          thing = Class.new(middle) { graphql_name "Thing"; field :a, String, null: true; def self.visible?(context) = super }
          query = Class.new(b[:object]) { graphql_name "Query"; field :thing, thing, null: true }

          expect(found(audit(schema_over(query, visibility)), :own_check).size).to eq(2)
        end

        it "does not report a visible? behind the plugin's" do
          below = Class.new(GraphQL::Schema::Object) { def self.visible?(context) = super }
          mod = GraphQL::Armory::Versioning::Base
          base_field = bases[:field]
          object = Class.new(below) { include mod; field_class(base_field) }
          query = Class.new(object) { graphql_name "Query"; field :ping, String, null: true }

          expect(paths(audit(schema_over(query, visibility)), :own_check)).to eq([])
        end

        it "lists a declared one as information, and reports a declared holder with no visible?" do
          b = bases
          careful = Class.new(b[:object]) { def self.visible?(context) = super }
          thing = Class.new(careful) { graphql_name "Thing"; field :a, String, null: true }
          query = Class.new(b[:object]) { graphql_name "Query"; field :thing, thing, null: true }
          report = audit(schema_over(query, visibility, own_checks: { careful => { visible?: "logs" }, thing => { visible?: "stale" } }))

          declared, stale = found(report, :own_check).partition(&:information?)
          expect(declared.map(&:message)).to eq(["declared in own_checks: logs"])
          expect(stale.map { |problem| [problem.path, problem.message] }).to eq([["Thing visible?", "named in own_checks: but defines no visible? ahead of the plugin's: remove it from the option"]])
          expect(report.ok?).to be(false)
        end
      end

      describe ":default_value" do
        it "reports a default naming an enum value the latest version does not have, whatever the argument class" do
          b = bases
          value_class = Class.new(GraphQL::Schema::EnumValue) { include GraphQL::Armory::Versioning::Base }
          kind = Class.new(GraphQL::Schema::Enum) { include GraphQL::Armory::Versioning::Base; enum_value_class(value_class); graphql_name "Kind"; value "A"; value "OLD", removed: "2025-01-01" }
          query = Class.new(b[:object]) { graphql_name "Query"; field :kind, kind, null: true }
          schema = schema_over(query, visibility)
          # Defined after the schema loaded (as code reloading does): graphql-ruby's own check of defaults has run already.
          query.field(:pick, String, null: true) { argument :kind, kind, required: false, default_value: "OLD" }

          # graphql 2.4 with json 3 fails while building its own message (ArgumentError): a raise all the same.
          expect { schema.to_definition(context: { armory_version: old }) }.to raise_error(StandardError)
          report = audit(schema)
          expect(found(report, :default_value).map(&:path)).to eq(["Query.pick.kind"])
          expect(found(report, :default_value).first.message).to match(/names Kind\.OLD, which the latest version does not have/)
        end

        it "reports an input-object default naming an input field outside the version, on an argument class without Base" do
          b = bases
          input = Class.new(GraphQL::Schema::InputObject) do
            include GraphQL::Armory::Versioning::Base
            argument_class(b[:argument])
            graphql_name "Filter"
            argument :q, String, required: false
            argument :since, String, required: false, added: "2025-01-01"
          end
          plain = Class.new(b[:field]) { argument_class(GraphQL::Schema::Argument) }
          query = Class.new(b[:object]) do
            graphql_name "Query"
            field_class(plain)
            field :find, String, null: true do
              argument :filter, input, required: false, default_value: { since: "today" }
            end
          end
          schema = schema_over(query, visibility)

          expect { schema.to_definition(context: { armory_version: old }) }.to raise_error(ArgumentError, /No argument definition on Filter/)
          report = audit(schema)
          expect(paths(report, :default_value)).to eq(["Query.find.filter"])
          expect(found(report, :default_value).first.message).to match(/names Filter\.since, not in 2024-06-01/)
        end

        it "leaves an argument class with Base to its own refusal" do
          b = bases
          value_class = Class.new(GraphQL::Schema::EnumValue) { include GraphQL::Armory::Versioning::Base }
          kind = Class.new(GraphQL::Schema::Enum) { include GraphQL::Armory::Versioning::Base; enum_value_class(value_class); graphql_name "Kind"; value "A"; value "NEW", added: "2025-01-01" }
          query = Class.new(b[:object]) do
            graphql_name "Query"
            field :pick, String, null: true do
              argument :kind, kind, required: false, default_value: "NEW"
            end
          end
          report = audit(schema_over(query, visibility))

          expect(report.problems.map { |problem| [problem.kind, problem.path] }).to eq([[:refused, "Query.pick.kind"]])
        end
      end

      describe ":subscription_trigger" do
        def subscribed(query, subscription, visibility, **options)
          plugin = versioning::Controls::Schema::PLUGINS.fetch(visibility)
          settings = { versions: versioning::Controls::Versions::LABELS, retired: versioning::Controls::Versions::RETIRED, default: :latest, **options }
          Class.new(ArmoryEngine.base_schema) do
            query(query)
            subscription(subscription)
            use plugin
            use GraphQL::Armory::Versioning, **settings
          end
        end

        let(:query) { Class.new(bases[:object]) { graphql_name "Query"; field :ping, String, null: true } }

        it "reports a nested input field with a default that a served version does not have" do
          b = bases
          input = Class.new(GraphQL::Schema::InputObject) do
            include GraphQL::Armory::Versioning::Base
            argument_class(b[:argument])
            graphql_name "Filter"
            argument :q, String, required: false
            argument :channel, String, required: false, default_value: "all", added: "2025-01-01"
          end
          subscription = Class.new(b[:object]) do
            graphql_name "Subscription"
            field :updated, String, null: true do
              argument :filter, input, required: false
            end
          end
          report = audit(subscribed(query, subscription, visibility))

          expect(paths(report, :subscription_trigger)).to eq(["Filter.channel"])
          expect(report.ok?).to be(false)
        end

        it "reports an argument the latest version does not have" do
          b = bases
          subscription = Class.new(b[:object]) do
            graphql_name "Subscription"
            field :updated, String, null: true do
              argument :id, String, required: false, removed: "2025-01-01"
            end
          end
          problem = found(audit(subscribed(query, subscription, visibility)), :subscription_trigger).first

          expect(problem.path).to eq("Subscription.updated.id")
          expect(problem.message).to match(/is not in the latest version: .*raises unless its context names a version that has it/)
        end

        it "lists a subscription field the default version does not have as information" do
          b = bases
          subscription = Class.new(b[:object]) { graphql_name "Subscription"; field :updated, String, null: true; field :created, String, null: true, added: "2025-01-01" }
          report = audit(subscribed(query, subscription, visibility, default: old))

          expect(found(report, :subscription_trigger).map { |problem| [problem.path, problem.information?] }).to eq([["Subscription.created", true]])
          expect(found(report, :subscription_trigger).first.message).to match(/default version \(2024-06-01\) does not have it/)
          expect(report.ok?).to be(true)
        end

        it "lists default: :refuse as information when subscription fields include Base" do
          b = bases
          subscription = Class.new(b[:object]) { graphql_name "Subscription"; field :updated, String, null: true }
          report = audit(subscribed(query, subscription, visibility, default: :refuse))

          expect(found(report, :subscription_trigger).map { |problem| [problem.path, problem.information?] }).to eq([["Subscription", true]])
          expect(report.ok?).to be(true)
        end
      end
    end
  end

  describe "own_checks:" do
    def schema_with(own_checks)
      Class.new(GraphQL::Schema) { use GraphQL::Armory::Versioning, versions: %w[2025-01-01], default: :latest, own_checks: own_checks }
    end

    it "refuses anything but a class or module mapped to { visible?: reason }" do
      [{ "Thing" => { visible?: "x" } }, { Object => { authorized?: "x" } }, { Object => { visible?: " " } }, { Object => {} }, [], nil].each do |value|
        expect { schema_with(value) }.to raise_error(versioning::ConfigurationError, /own_checks: must map a class or module to \{ visible\?: /)
      end
    end

    it "keeps the declarations on the gate" do
      expect(schema_with(Object => { visible?: "logs" }).armory_versioning.own_checks).to eq(Object => { visible?: "logs" })
      expect(versioning::Gate.new.own_checks).to eq({})
    end
  end
end
