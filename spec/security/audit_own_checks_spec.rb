# frozen_string_literal: true

# A method an app defines on a base class wins over the plugin's module, so its `authorized?` can skip the rule, and
# a resolver's `unauthorized_object` can run a mutation on a refused record. The audit must report them.
RSpec.describe "the audit and the app's own authorization checks" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:world) { Dummy::World.build }
  let(:ran) { [] }

  # Named classes, because the report and `own_checks:` speak in classes.
  def build(on_field: nil, object: nil, invoice: nil, mutation: nil, approve: nil, on_argument: nil, input: nil, plain_mutation: nil, plain_class: GraphQL::Schema::Mutation, relay_template: false, **options)
    plugin = armory
    calls = ran
    base_argument = Class.new(GraphQL::Schema::Argument) { include plugin::Base }
    base_argument.class_eval(&on_argument) if on_argument
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
    if relay_template
      connection_class = Class.new(base_object) do
        include GraphQL::Types::Relay::ConnectionBehaviors
        authorize :none, reason: "a connection", covers_fields: true
      end
      edge_class = Class.new(base_object) do
        include GraphQL::Types::Relay::EdgeBehaviors
        authorize :none, reason: "an edge", covers_fields: true
      end
      base_object.connection_type_class(connection_class)
      base_object.edge_type_class(edge_class)
    end
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
      field :first_invoice, invoice_type, null: true, authorize: :none, reason: "the type's rule decides"
      field :invoice_list, [invoice_type], null: true, authorize: :none, reason: "the type's rule and scope decide"
      field :invoices, invoice_type.connection_type, null: true, authorize: :none, reason: "scoped by the node type" if relay_template
      if input
        input_type = Class.new(GraphQL::Schema::InputObject) do
          include plugin::Base
          graphql_name "SomeInput"
          argument_class base_argument
          argument :note, String, required: false
        end
        input_type.singleton_class.class_eval(&input)
        field :with_input, String, null: true, authorize: :none, reason: "public" do
          argument :input, input_type, required: false
        end
      end
    end
    mutation_type = Class.new(base_object) do
      graphql_name "Mutation"
      authorize :none, reason: "the root holds nothing"
      field :approve_invoice, mutation: approve_mutation
      if plain_mutation
        plain = Class.new(plain_class) do
          graphql_name "Plain"
          object_class payload
          field_class base_field
          field :done, String, null: true, hash_key: :done
        end
        plain.class_eval(&plain_mutation)
        field :plain, mutation: plain
      end
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

  # Verifier probes: these run the refused path too, and the audit said nothing.
  it "reports unauthorized_object on a base field, which graphql-ruby also calls" do
    schema = build(on_field: proc { def unauthorized_object(error) = error.object })

    expect(problems(schema).map(&:path)).to contain_exactly(end_with("#unauthorized_object"))
    expect(problems(schema).first.message).to match(/refused record/)
  end

  it "reports authorized? on a base argument, which skips an argument's rule" do
    schema = build(on_argument: proc { def authorized?(*) = true })

    expect(problems(schema).map(&:path)).to contain_exactly(end_with("#authorized?"))
  end

  it "reports self.authorized? and self.unauthorized_object on an input object" do
    schema = build(input: proc do
      def authorized?(*) = true
      def unauthorized_object(error) = error.object
    end)

    expect(problems(schema).map(&:path)).to contain_exactly(end_with(".authorized?"), end_with(".unauthorized_object"))
  end

  it "reports unauthorized_object on a mutation that does not include Base" do
    schema = build(plain_mutation: proc { def unauthorized_object(error) = error.object })

    expect(problems(schema).map(&:path)).to contain_exactly(end_with("#unauthorized_object"))
  end

  it "reports authorizes? on a base field, which on Execution::Next skips authorized?" do
    schema = build(on_field: proc { def authorizes?(_context) = false })

    expect(problems(schema).map(&:path)).to contain_exactly(end_with("#authorizes?"))
  end

  it "reports self.authorizes? on a type and on a base object, which on Execution::Next skips the type's rule" do
    own = Module.new { def authorizes?(_context) = false }
    on_type = build(invoice: proc { def self.authorizes?(_context) = false })
    on_base = build(object: proc { def self.authorizes?(_context) = false })
    by_extend = build(invoice: proc { extend own })

    [on_type, on_base, by_extend].each do |schema|
      expect(problems(schema).map(&:path)).to contain_exactly(end_with(".authorizes?"))
      expect(problems(schema).first.message).to match(/Execution::Next/)
    end
  end

  it "lists a declared self.authorizes? as a bypass" do
    schema = build(invoice: proc { def self.authorizes?(_context) = true })
    plugin = armory
    type = @classes[:invoice]
    declared = Class.new(schema) { use plugin, adapter: :pundit, own_checks: { type => { authorizes?: "always runs the rule" } } }

    expect(problems(declared)).to eq([])
    expect(armory::Audit.(declared).bypasses.map(&:reason)).to include("always runs the rule")
  end

  # An app's method can sit under another one that only calls super.
  describe "checks at several levels" do
    let(:skipping) { Module.new { def authorized?(_object, _context) = true } }
    let(:passing) { Module.new { def authorized?(object, context) = super } }

    it "reports a parent's check that answers true under a child's that calls super" do
      own = skipping
      schema = build(object: proc { extend own }, invoice: proc { def self.authorized?(object, context) = super })

      expect(problems(schema).size).to eq(2)
      expect(problems(schema).map(&:path)).to all(end_with(".authorized?"))
    end

    it "does not let a declaration of the outer level hide the inner one" do
      own = skipping
      plugin = armory
      schema = build(object: proc { extend own }, invoice: proc { def self.authorized?(object, context) = super })
      type = @classes[:invoice]
      declared = Class.new(schema) { use plugin, adapter: :pundit, own_checks: { type => { authorized?: "calls super" } } }

      expect(problems(declared).size).to eq(1)
      expect(armory::Audit.(declared).ok?).to be(false)
    end

    it "accepts a declaration of every level when each one calls super" do
      own = passing
      plugin = armory
      schema = build(object: proc { extend own }, invoice: proc { def self.authorized?(object, context) = super })
      type = @classes[:invoice]
      declared = Class.new(schema) do
        use plugin, adapter: :pundit, own_checks: { type => { authorized?: "calls super" }, own => { authorized?: "calls super" } }
      end

      expect(problems(declared)).to eq([])
    end

    it "reports a field's check that answers true under one that calls super" do
      own = Module.new { def authorized?(*) = true }
      schema = build(on_field: proc do
        include own
        def authorized?(*) = super
      end)

      expect(problems(schema).size).to eq(2)
    end

    it "reports a resolver's check that answers true under one that calls super" do
      own = Module.new { def authorized?(**) = true }
      schema = build(approve: proc do
        include own
        def authorized?(**) = super
      end)

      expect(problems(schema).size).to eq(2)
    end
  end

  describe "visible? over visible_when:" do
    it "reports a type's own visible? when its rule has visible_when:" do
      schema = build(invoice: proc do
        authorize :read, model: ::Invoice, visible_when: :manage
        def self.visible?(_context) = true
      end)

      expect(problems(schema).map(&:path)).to contain_exactly(end_with(".visible?"))
      expect(problems(schema).first.message).to match(/visible_when/)
    end

    it "reports a base field's own visible? over a field with visible_when:" do
      schema = build(on_field: proc { def visible?(_context) = true }, invoice: proc do
        field :secret, String, null: true, authorize: :none, reason: "x", visible_when: :manage
      end)

      expect(problems(schema).map(&:path)).to contain_exactly(end_with("#visible?"))
    end

    it "does not report an own visible? where no visible_when: depends on it" do
      schema = build(invoice: proc { def self.visible?(context) = super })

      expect(problems(schema)).to eq([])
    end
  end

  def foreign_invoice(schema)
    execute_query(schema, "{ firstInvoice { id } }", context: { current_user: world.bob },
                                                     root_value: Struct.new(:first_invoice).new(world.a1)).to_h.dig("data", "firstInvoice")
  end

  describe "records that come through the scope" do
    def numbers(schema)
      world
      execute_query(schema, "{ invoiceList { id } }", context: { current_user: world.alice },
                                                      root_value: Struct.new(:invoice_list).new(::Invoice.all)).to_h.dig("data", "invoiceList")&.size
    end

    let(:skip_rule) do
      proc do
        authorize :manage, model: ::Invoice
        reauthorize_scoped_objects(false)
      end
    end

    it "reports reauthorize_scoped_objects(false), and pins that it serves what the rule refuses" do
      schema = build(invoice: skip_rule)

      expect(problems(schema).map(&:path)).to contain_exactly(end_with(".reauthorize_scoped_objects"))
      expect(problems(schema).first.message).to match(/skip the rule/)
      expect(numbers(build(invoice: proc { authorize :manage, model: ::Invoice }))).to be_nil
      expect(numbers(schema)).to eq(2)
    end

    it "reports it once, on the base object that sets it" do
      schema = build(object: proc { reauthorize_scoped_objects(false) })

      expect(problems(schema).map(&:path).uniq.size).to eq(1)
      expect(problems(schema).size).to eq(1)
    end

    it "lists it as a bypass when declared" do
      plugin = armory
      schema = build(invoice: skip_rule)
      type = @classes[:invoice]
      declared = Class.new(schema) do
        use plugin, adapter: :pundit, own_checks: { type => { reauthorize_scoped_objects: "the scope is as strict as the rule" } }
      end

      expect(problems(declared)).to eq([])
      expect(armory::Audit.(declared).bypasses.map(&:reason)).to include("the scope is as strict as the rule")
    end

    it "does not report reauthorize_scoped_objects(true) or a type that bypasses the rule" do
      on = build(invoice: proc { reauthorize_scoped_objects(true) })
      bypassed = build(invoice: proc do
        authorize :none, reason: "public", covers_fields: true
        reauthorize_scoped_objects(false)
      end)

      expect(problems(on)).to eq([])
      expect(problems(bypassed)).to eq([])
    end

    it "reports an own scope_items, and pins that with reauthorization off it serves another account's records" do
      schema = build(invoice: proc do
        reauthorize_scoped_objects(false)
        def self.scope_items(items, _context) = items.where("1=1")
      end)

      expect(problems(schema).map(&:path)).to include(end_with(".scope_items"))
      expect(numbers(schema)).to eq(::Invoice.count)
      expect(numbers(build)).to eq(2)
    end
  end

  it "reports self.wrap on a type, and pins that on the interpreter it skips the rule" do
    schema = build(invoice: proc { def self.wrap(object, context) = new(object, context) })

    expect(problems(schema).map(&:path)).to contain_exactly(end_with(".wrap"))
    expect(problems(schema).first.message).to match(/authorized\?/)
    expect(foreign_invoice(build)).to be_nil
    expect(foreign_invoice(schema)).not_to be_nil unless ArmoryEngine.next?
  end

  it "pins that a parent's check under a child's super serves a record the rule refuses" do
    own = Module.new { def authorized?(_object, _context) = true }

    expect(foreign_invoice(build(object: proc { extend own }, invoice: proc { def self.authorized?(object, context) = super }))).not_to be_nil
  end

  it "reports self.authorized_new on a type, which on the interpreter skips the check" do
    schema = build(invoice: proc { def self.authorized_new(object, context) = new(object, context) })

    expect(problems(schema).map(&:path)).to contain_exactly(end_with(".authorized_new"))
    expect(problems(schema).first.message).to match(/authorized\?/)
  end

  # Recheck probes: the same checks, reached another way.
  it "reports a check a mutation inherits from a module on its parent" do
    own = Module.new { def unauthorized_object(error) = error.object }
    schema = build(mutation: proc { include own })

    expect(problems(schema).map(&:path)).to contain_exactly(end_with("#unauthorized_object"))
  end

  it "reports class-level checks an input object gets through extend" do
    own = Module.new do
      def authorized?(*) = true
      def unauthorized_object(error) = error.object
    end
    schema = build(input: proc { include own })

    expect(problems(schema).map(&:path)).to contain_exactly(end_with(".authorized?"), end_with(".unauthorized_object"))
  end

  it "reports self.authorized? a type gets through extend" do
    own = Module.new { def authorized?(_object, _context) = true }
    schema = build(invoice: proc { extend own })

    expect(problems(schema).map(&:path)).to contain_exactly(end_with(".authorized?"))
  end

  it "reports unauthorized_object on a RelayClassicMutation that does not include Base" do
    schema = build(plain_class: GraphQL::Schema::RelayClassicMutation, plain_mutation: proc { def unauthorized_object(error) = error.object })

    expect(problems(schema).map(&:path)).to contain_exactly(end_with("#unauthorized_object"))
  end

  it "reports nothing for the connection and edge classes of graphql-ruby's install template" do
    schema = build(relay_template: true)

    expect(problems(schema)).to eq([])
    expect(armory::Audit.(schema).ok?).to be(true)
  end

  # What the report is for.
  it "pins that a base argument's authorized? skips the argument's rule" do
    run_query = lambda do |schema|
      execute_query(schema, %({ guarded(secret: "s") }), context: { current_user: world.alice }, root_value: Struct.new(:ignored).new).to_h
    end
    guarded = lambda do |on_argument|
      plugin = armory
      base_argument = Class.new(GraphQL::Schema::Argument) { include plugin::Base }
      base_argument.class_eval(&on_argument) if on_argument
      base_field = Class.new(GraphQL::Schema::Field) do
        include plugin::Base
        argument_class base_argument
      end
      root = Class.new(GraphQL::Schema::Object) do
        include plugin::Base
        field_class base_field
        graphql_name "Query"
        authorize :none, reason: "the root holds nothing"
        field :guarded, String, null: true, authorize: :none, reason: "public", resolver_method: :guarded do
          argument :secret, String, required: false, authorize: :manage, model: ::Invoice
        end
        define_method(:guarded) { |secret: nil| "got #{secret}" }
      end
      Class.new(base_schema) do
        use plugin, adapter: :pundit
        query(root)
      end
    end
    skip "Execution::Next resolves root objects differently here" if ArmoryEngine.next?

    expect(run_query.(guarded.(nil)).dig("data", "guarded")).to be_nil
    expect(run_query.(guarded.(proc { def authorized?(*) = true })).dig("data", "guarded")).to eq("got s")
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
