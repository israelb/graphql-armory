# frozen_string_literal: true

# A method an app defines on a base class wins over the plugin's module, so its `authorized?` can skip the rule, and
# a resolver's `unauthorized_object` can run a mutation on a refused record. The audit must report them.
RSpec.describe "the audit and the app's own authorization checks" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:world) { Dummy::World.build }
  let(:ran) { [] }

  # Named classes, because the report and `own_checks:` speak in classes.
  def build(on_field: nil, object: nil, invoice: nil, mutation: nil, approve: nil, **options)
    plugin = armory
    calls = ran
    base_argument = Class.new(GraphQL::Schema::Argument) { include plugin::Base }
    base_field = Class.new(GraphQL::Schema::Field) do
      include plugin::Base
      argument_class base_argument
    end
    base_field.class_eval(&on_field) if on_field
    base_object = Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class base_field
      default_action :read
    end
    base_object.class_eval(&object) if object
    payload = Class.new(base_object) { authorize :none, reason: "a payload", covers_fields: true }
    invoice_type = Class.new(base_object) do
      graphql_name "Invoice"
      authorize :read, model: ::Invoice
      field :id, String, null: false, authorize: :none, reason: "ids are public"
    end
    invoice_type.class_eval(&invoice) if invoice
    base_mutation = Class.new(GraphQL::Schema::Mutation) do
      include plugin::Base
      object_class payload
      field_class base_field
      argument_class base_argument
    end
    base_mutation.class_eval(&mutation) if mutation
    approve_mutation = Class.new(base_mutation) do
      graphql_name "ApproveInvoice"
      authorize :approve, model: ::Invoice
      argument :invoice_id, GraphQL::Types::ID, loads: invoice_type
      field :done, String, null: true, hash_key: :done
      field :invoice, invoice_type, null: true, hash_key: :invoice

      define_method(:resolve) do |invoice:|
        calls << invoice.number
        { done: invoice.number }
      end
    end
    approve_mutation.class_eval(&approve) if approve
    query_type = Class.new(base_object) do
      graphql_name "Query"
      authorize :none, reason: "the root holds nothing"
      field :ping, String, null: true, authorize: :none, reason: "public"
    end
    mutation_type = Class.new(base_object) do
      graphql_name "Mutation"
      authorize :none, reason: "the root holds nothing"
      field :approve_invoice, mutation: approve_mutation
    end
    @classes = { base_field: base_field, base_object: base_object, invoice: invoice_type, base_mutation: base_mutation, approve: approve_mutation }
    Class.new(base_schema) do
      use plugin, adapter: :pundit, **options
      query(query_type)
      mutation(mutation_type)
    end
  end

  def problems(schema)
    armory::Audit.(schema).problems.select { |problem| problem.kind == :own_check }
  end

  def approve(schema, invoice, user)
    execute_query(schema, "mutation($id: ID!) { approveInvoice(invoiceId: $id) { done } }",
                  variables: { "id" => invoice.id.to_s }, context: { current_user: user }).to_h
  end

  it "reports nothing when no base class defines its own check" do
    schema = build

    expect(problems(schema)).to eq([])
    expect(armory::Audit.(schema).ok?).to be(true)
  end

  it "reports authorized? on a base mutation" do
    schema = build(mutation: proc { def authorized?(**) = true })

    expect(problems(schema).size).to eq(1)
    expect(problems(schema).first.path).to end_with("#authorized?")
    expect(problems(schema).first.message).to match(/own_checks/)
  end

  it "reports authorized? on a base field" do
    schema = build(on_field: proc { def authorized?(_object, _args, _context) = true })

    expect(problems(schema).map(&:path)).to contain_exactly(end_with("#authorized?"))
  end

  it "reports self.authorized? on a type and on a base object, once each" do
    on_type = build(invoice: proc { def self.authorized?(_object, _context) = true })
    on_base = build(object: proc { def self.authorized?(_object, _context) = true })

    expect(problems(on_type).map(&:path)).to contain_exactly(end_with(".authorized?"))
    expect(problems(on_base).map(&:path)).to contain_exactly(end_with(".authorized?"))
  end

  it "reports unauthorized_object on a resolver" do
    schema = build(approve: proc { def unauthorized_object(error) = error.object })

    expect(problems(schema).map(&:path)).to contain_exactly(end_with("#unauthorized_object"))
  end

  it "reports a check that comes from a module" do
    own = Module.new { def authorized?(**) = true }
    schema = build(mutation: proc { prepend own })

    expect(problems(schema).map(&:path)).to contain_exactly(end_with("#authorized?"))
  end

  # What the report is for: these really do skip the rule.
  it "pins that a base mutation's authorized? skips the rule" do
    world
    approve(build, world.a1, world.alice)
    expect(ran).to eq([])

    approve(build(mutation: proc { def authorized?(**) = true }), world.a1, world.alice)
    expect(ran).to eq(["A-1"])
  end

  describe "own_checks:" do
    it "lists a declared check as a bypass with its reason" do
      schema = build(mutation: proc { def authorized?(**) = super })
      base = @classes[:base_mutation]
      declared = build_declared(base, schema)

      expect(problems(declared)).to eq([])
      expect(armory::Audit.(declared).bypasses.map(&:reason)).to include("adds the OTP check, then calls super")
    end

    # The same schema, with the plugin installed again declaring the class that holds the check.
    def build_declared(owner, schema, reason: "adds the OTP check, then calls super")
      plugin = armory
      Class.new(schema) { use plugin, adapter: :pundit, own_checks: { owner => { authorized?: reason } } }
    end

    it "declares a class-level check by the class that holds it" do
      schema = build(invoice: proc { def self.authorized?(object, context) = super })
      plugin = armory
      type = @classes[:invoice]
      declared = Class.new(schema) { use plugin, adapter: :pundit, own_checks: { type => { authorized?: "narrows the rule" } } }

      expect(problems(declared)).to eq([])
    end

    it "does not cover another method of the same class" do
      schema = build(approve: proc do
        def authorized?(**) = super
        def unauthorized_object(error) = error.object
      end)
      declared = build_declared(@classes[:approve], schema)

      expect(problems(declared).map(&:path)).to contain_exactly(end_with("#unauthorized_object"))
    end

    it "reports a declaration that matches nothing, instead of ignoring it" do
      schema = build
      declared = build_declared(@classes[:base_mutation], schema)

      expect(problems(declared).size).to eq(1)
      expect(problems(declared).first.message).to match(/own_checks/)
    end

    [
      { Object => { resolve: "not a check" } },
      { Object => { authorized?: "" } },
      { Object => { authorized?: " " } },
      { Object => { authorized?: nil } },
      { Object => "a reason" },
      { "Types::BaseField" => { authorized?: "a String key" } },
      [Object],
      "Object"
    ].each do |value|
      it "refuses #{value.inspect} at boot" do
        expect { GraphQL::Armory::Authorization::Configuration.new(adapter: :pundit, own_checks: value) }
          .to raise_error(ArgumentError, /own_checks/)
      end
    end

    it "keeps its own copy" do
      hooks = { Object => { authorized?: +"a reason" } }
      configuration = armory::Configuration.new(adapter: :pundit, own_checks: hooks)
      hooks[Object][:authorized?].clear
      hooks[Object].clear

      expect(configuration.own_checks).to eq({ Object => { authorized?: "a reason" } })
      expect(configuration.own_checks).to be_frozen
    end
  end
end
