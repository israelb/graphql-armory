# frozen_string_literal: true

require "stringio"

# A method a schema defines on itself wins over the plugin's, so its own `unauthorized_field` decides what a denial
# looks like, whatever `on_unauthorized:` says. The audit must report it, or a denial can reveal what it should hide.
RSpec.describe "the audit and the schema's denial hooks" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:base) { IntegrationSchema.build(flawed: false) }

  def hook_problems(schema)
    armory::Audit.(schema).problems.select { |problem| problem.kind == :hook }
  end

  def schema_with(**options, &body)
    plugin = armory
    Class.new(base) do
      use plugin, adapter: :pundit, **options
      class_eval(&body) if body
    end
  end

  it "reports nothing when the plugin's hooks are the ones that run" do
    expect(base.method(:unauthorized_field).owner).to eq(armory::Integration::Schema)
    expect(hook_problems(base)).to eq([])
    expect(hook_problems(schema_with)).to eq([])
  end

  %i[unauthorized_field unauthorized_object].each do |hook|
    it "reports #{hook} defined on the schema after use" do
      schema = schema_with { define_singleton_method(hook) { |error| nil } }

      expect(hook_problems(schema).map(&:path)).to eq(["Schema.#{hook}"])
      expect(hook_problems(schema).first.message).to match(/on_unauthorized/)
      expect(armory::Audit.(schema).ok?).to be(false)
    end
  end

  it "reports a hook defined before use" do
    plugin = armory
    schema = Class.new(base) do
      def self.unauthorized_field(_error) = nil
      use plugin, adapter: :pundit
    end

    expect(hook_problems(schema).map(&:path)).to eq(["Schema.unauthorized_field"])
  end

  it "reports a hook defined on a subclass of the schema that installed the plugin" do
    schema = Class.new(base) { def self.unauthorized_object(_error) = nil }

    expect(hook_problems(schema).map(&:path)).to eq(["Schema.unauthorized_object"])
  end

  it "reports a hook from a module extended after use" do
    own = Module.new { def unauthorized_field(_error) = nil }
    schema = schema_with { extend own }

    expect(hook_problems(schema).map(&:path)).to eq(["Schema.unauthorized_field"])
  end

  it "does not report a parent's hook when the plugin was first installed below it, because the plugin's runs" do
    plugin = armory
    parent = Class.new(GraphQL::Schema) { def self.unauthorized_field(_error) = :parent }
    schema = Class.new(parent) { use plugin, adapter: :pundit }

    expect(schema.method(:unauthorized_field).owner).to eq(armory::Integration::Schema)
    expect(hook_problems(schema)).to eq([])
  end

  it "reports a parent's hook when a child calls use again: Ruby does not extend with a module twice" do
    parent = Class.new(base) { def self.unauthorized_field(_error) = :parent }
    plugin = armory
    schema = Class.new(parent) { use plugin, adapter: :pundit }

    expect(schema.method(:unauthorized_field).owner).not_to eq(armory::Integration::Schema)
    expect(hook_problems(schema).map(&:path)).to eq(["Schema.unauthorized_field"])
  end

  it "does not report resolve_type, which an app with abstract types must define" do
    schema = schema_with { def self.resolve_type(_type, _object, _context) = nil }

    expect(hook_problems(schema)).to eq([])
  end

  it "does not add a hook problem to a schema without the plugin" do
    schema = Class.new(GraphQL::Schema) { query(Class.new(GraphQL::Schema::Object) { graphql_name "Q"; field :a, String }) }
    kinds = armory::Audit.(schema).problems.map(&:kind)

    expect(kinds).to include(:plugin)
    expect(kinds).not_to include(:hook)
  end

  # Verifier probes: what the audit says must match the hook that really answers the client.
  describe "the audit against what runs" do
    let(:world) { Dummy::World.build }

    def denial(schema)
      result = execute_query(schema, "{ myInvoice { internalNotes } }", context: { current_user: world.alice },
                                                                        root_value: IntegrationSchema::Root.new(my_invoice: world.a1)).to_h
      result.dig("errors", 0, "message")
    end

    def strict(&body)
      Class.new(IntegrationSchema.build(flawed: false, on_unauthorized: :error), &body)
    end

    it "uses the plugin's hook when nothing overrides it" do
      schema = strict

      expect(denial(schema)).to eq("Not found")
      expect(hook_problems(schema)).to eq([])
    end

    it "reports a hook prepended to the singleton class, which answers instead" do
      own = Module.new { def unauthorized_field(_error) = nil }
      schema = strict { singleton_class.prepend(own) }

      expect(denial(schema)).to be_nil
      expect(hook_problems(schema).map(&:path)).to eq(["Schema.unauthorized_field"])
    end

    it "reports a hook made with alias_method, which answers instead" do
      schema = strict do
        class << self
          def quiet(_error) = nil
          alias_method :unauthorized_field, :quiet
        end
      end

      expect(denial(schema)).to be_nil
      expect(hook_problems(schema).map(&:path)).to eq(["Schema.unauthorized_field"])
    end

    it "does not report a module extended before use, which loses to the plugin" do
      own = Module.new { def unauthorized_field(_error) = nil }
      plugin = armory
      schema = Class.new(IntegrationSchema.build(flawed: false, plugin: false)) do
        extend own
        use plugin, adapter: :pundit, on_unauthorized: :error
      end

      expect(denial(schema)).to eq("Not found")
      expect(hook_problems(schema)).to eq([])
    end

    it "runs the plugin's answer through super in a declared hook" do
      plugin = armory
      schema = Class.new(IntegrationSchema.build(flawed: false, plugin: false)) do
        use plugin, adapter: :pundit, on_unauthorized: :error, own_denial_hooks: { unauthorized_field: "logs, then calls super" }
        def self.unauthorized_field(error) = super
      end

      expect(denial(schema)).to eq("Not found")
      expect(hook_problems(schema)).to eq([])
    end
  end

  describe "the audit command" do
    around do |example|
      Object.const_set(:AuditHookSchema, schema)
      example.run
    ensure
      Object.send(:remove_const, :AuditHookSchema)
    end

    def exit_status
      armory::Audit::Command.new(out: StringIO.new).("AuditHookSchema")
    end

    context "with an undeclared hook" do
      let(:schema) { Class.new(IntegrationSchema.build(flawed: false)) { def self.unauthorized_field(_error) = nil } }

      it("exits 1") { expect(exit_status).to eq(1) }
    end

    context "with a declared hook" do
      let(:schema) do
        plugin = GraphQL::Armory::Authorization
        Class.new(IntegrationSchema.build(flawed: false, plugin: false)) do
          use plugin, adapter: :pundit, own_denial_hooks: { unauthorized_field: "answers like a missing field" }
          def self.unauthorized_field(_error) = nil
        end
      end

      it("exits 0") { expect(exit_status).to eq(0) }
    end
  end

  describe "own_denial_hooks:" do
    it "reports the hook again when a second use drops the declaration" do
      plugin = armory
      schema = schema_with(own_denial_hooks: { unauthorized_field: "answers like a missing field" }) do
        def self.unauthorized_field(_error) = nil
        use plugin, adapter: :pundit
      end

      expect(hook_problems(schema).map(&:path)).to eq(["Schema.unauthorized_field"])
    end

    it "does not take a Hash's default value as a declaration" do
      schema = schema_with(own_denial_hooks: Hash.new("anything")) { def self.unauthorized_field(_error) = nil }

      expect(hook_problems(schema).map(&:path)).to eq(["Schema.unauthorized_field"])
    end

    it "keeps its own copy, so changing the Hash after boot changes nothing" do
      hooks = { unauthorized_field: +"answers like a missing field" }
      schema = schema_with(own_denial_hooks: hooks) { def self.unauthorized_field(_error) = nil }
      hooks[:unauthorized_field].clear
      hooks.clear
      report = armory::Audit.(schema)

      expect(hook_problems(schema)).to eq([])
      expect(report.bypasses.map(&:to_a)).to include(["Schema.unauthorized_field", "answers like a missing field"])
    end

    it "refuses indifferent access, whose keys are Strings" do
      expect { schema_with(own_denial_hooks: { unauthorized_field: "a reason" }.with_indifferent_access) }
        .to raise_error(ArgumentError, /own_denial_hooks/)
    end

    it "lists a declared hook as a bypass with its reason, not as a problem" do
      schema = schema_with(own_denial_hooks: { unauthorized_field: "answers like a missing field" }) do
        def self.unauthorized_field(_error) = nil
      end
      report = armory::Audit.(schema)

      expect(hook_problems(schema)).to eq([])
      expect(report.bypasses.map(&:to_a)).to include(["Schema.unauthorized_field", "answers like a missing field"])
    end

    it "still reports the hook it does not name" do
      schema = schema_with(own_denial_hooks: { unauthorized_field: "answers like a missing field" }) do
        def self.unauthorized_field(_error) = nil
        def self.unauthorized_object(_error) = nil
      end

      expect(hook_problems(schema).map(&:path)).to eq(["Schema.unauthorized_object"])
    end

    it "reports a declared hook the schema does not define, instead of ignoring the option" do
      schema = schema_with(own_denial_hooks: { unauthorized_field: "answers like a missing field" })
      report = armory::Audit.(schema)

      expect(hook_problems(schema).map(&:path)).to eq(["Schema.unauthorized_field"])
      expect(hook_problems(schema).first.message).to match(/own_denial_hooks/)
      expect(report.bypasses.map(&:path)).not_to include("Schema.unauthorized_field")
    end

    [
      { resolve_type: "not a denial hook" },
      { unauthorized_field: "" },
      { unauthorized_field: "   " },
      { unauthorized_field: nil },
      { "unauthorized_field" => "a String key" },
      [:unauthorized_field],
      "unauthorized_field"
    ].each do |value|
      it "refuses #{value.inspect} at boot" do
        expect { schema_with(own_denial_hooks: value) }.to raise_error(ArgumentError, /own_denial_hooks/)
      end
    end
  end
end
