# frozen_string_literal: true

RSpec.describe "GraphQL::Armory::Authorization integration" do
  let(:authorization) { GraphQL::Armory::Authorization }
  let(:world) { Dummy::World.build }
  let(:seen) { [] }
  let(:sink) { ->(signal, data) { seen << [signal, data] } }

  def run(query, user:, schema: nil, **root)
    schema ||= IntegrationSchema.build(sinks: [sink])
    execute_query(schema, query, context: { current_user: user }, root_value: IntegrationSchema::Root.new(**root))
  end

  describe "an object type with a rule" do
    it "returns what the policy allows" do
      result = run("{ myInvoice { number } }", user: world.alice, my_invoice: world.a1)

      expect(result["data"]).to eq("myInvoice" => { "number" => "A-1" })
      expect(result["errors"]).to be_nil
    end

    it "answers null for an object the policy denies" do
      result = run("{ myInvoice { number } }", user: world.alice, my_invoice: world.b1)

      expect(result["data"]).to eq("myInvoice" => nil)
      expect(result["errors"]).to be_nil
    end

    it "scopes a list before it authorizes each item" do
      result = run("{ invoices { number } }", user: world.alice, invoices: [world.a1, world.b1, world.a2])

      expect(result["data"]["invoices"]).to eq([{ "number" => "A-1" }, { "number" => "A-2" }])
      expect(result["errors"]).to be_nil
    end

    it "uses the action the type declares over the default" do
      alice = run("{ myAdminInvoice { number } }", user: world.alice, my_admin_invoice: world.a1)
      carol = run("{ myAdminInvoice { number } }", user: world.carol, my_admin_invoice: world.a1)

      expect([alice["data"], carol["data"]]).to eq([{ "myAdminInvoice" => nil }, { "myAdminInvoice" => { "number" => "A-1" } }])
    end
  end

  describe "a field with a rule" do
    let(:query) { "{ myInvoice { number internalNotes } }" }

    it "answers null when the policy denies the field's action" do
      result = run(query, user: world.alice, my_invoice: world.a1)

      expect(result["data"]).to eq("myInvoice" => { "number" => "A-1", "internalNotes" => nil })
    end

    it "returns the field when the policy allows it" do
      result = run(query, user: world.carol, my_invoice: world.a1)

      expect(result["data"]["myInvoice"]["internalNotes"]).to eq("secret A-1")
    end

    it "re-checks the type's action on the parent with `authorize: true`" do
      result = run("{ myInvoice { accountId } }", user: world.alice, my_invoice: world.a1)

      expect(result["data"]).to eq("myInvoice" => { "accountId" => world.account_a.id })
    end

    it "lets a declared bypass through" do
      result = run("{ myInvoice { id } }", user: world.alice, my_invoice: world.a1)

      expect(result["data"]["myInvoice"]["id"]).to eq(world.a1.id.to_s)
    end
  end

  describe "deny by default" do
    it "answers null for a field on a bypassed type that declares no rule" do
      result = run("{ ping noRule }", user: world.alice)

      expect(result["data"]).to be_nil
      expect(result["errors"]).not_to be_nil
    end

    it "answers null for a type with no rule and no default action" do
      schema = IntegrationSchema.build(type_action: nil)

      result = run("{ myInvoice { number } }", user: world.alice, schema: schema, my_invoice: world.a1)

      expect(result["data"]).to eq("myInvoice" => nil)
    end

    it "fails loudly, not open, when the default action has no policy" do
      expect { run("{ ghost { label } }", user: world.alice, ghost: Ghost.new) }
        .to raise_error(Pundit::NotDefinedError)
    end

    # The interpreter masks the error's class when it is raised while authorizing the root type
    # (graphql-ruby evaluates `context[:current_object]` before any result exists), so only
    # the refusal is pinned here; the message is pinned where graphql-ruby does not interfere.
    it "refuses to run a schema that never installed the plugin" do
      schema = IntegrationSchema.build(plugin: false)

      expect { run("{ myInvoice { number } }", user: world.alice, schema: schema, my_invoice: world.a1) }
        .to raise_error(StandardError)
    end

    it "says what is missing when the plugin was never installed" do
      context = authorization::Controls::Context.example
      context.define_singleton_method(:schema) { Class.new(GraphQL::Schema) }

      expect { authorization::Integration.configuration(context) }
        .to raise_error(authorization::ConfigurationError, /use GraphQL::Armory::Authorization/)
    end
  end

  describe "what the client sees on a denial" do
    let(:denied) { { user: nil, my_invoice: nil } }

    def denied_run(mode)
      schema = IntegrationSchema.build(on_unauthorized: mode, sinks: [sink])
      run("{ myInvoice { number } }", user: world.alice, schema: schema, my_invoice: world.b1)
    end

    it "is null and no error with :null" do
      result = denied_run(:null)

      expect([result["data"], result["errors"]]).to eq([{ "myInvoice" => nil }, nil])
    end

    it "is null and a generic NOT_FOUND error with :error" do
      result = denied_run(:error)

      expect(result["data"]).to eq("myInvoice" => nil)
      expect(result["errors"].map { |e| [e["message"], e["extensions"]] }).to eq([["Not found", { "code" => "NOT_FOUND" }]])
    end

    it "does not name the type, the policy or the record in the error" do
      text = denied_run(:error)["errors"].map { |e| [e["message"], e["extensions"]] }.to_s

      expect(text).not_to match(/Invoice|Policy|B-1|#{world.b1.id}/)
    end

    it "is an exception with :raise" do
      expect { denied_run(:raise) }.to raise_error(authorization::NotAuthorizedError, /Invoice/)
    end
  end

  describe "telemetry" do
    it "records a denial without record attributes" do
      run("{ myInvoice { number } }", user: world.alice, my_invoice: world.b1)

      expect(seen).to include([:denied, { type: "Invoice", action: :read }])
    end

    it "asks once per object and action even when the type and a field both check it" do
      run("{ myInvoice { number accountId } }", user: world.alice, my_invoice: world.a1)

      expect(seen.count { |signal, _| signal == :allowed }).to eq(1)
    end
  end

  describe "the plugin" do
    it "takes an adapter object" do
      adapter = authorization::Adapters::Substitute.new(allow: true, actor: :anyone)
      schema = IntegrationSchema.build(adapter: adapter)

      run("{ myInvoice { number } }", user: world.alice, schema: schema, my_invoice: world.b1)

      expect(adapter.asked.map(&:first)).to eq([:anyone])
    end

    it "refuses an adapter it does not know" do
      expect { IntegrationSchema.build(adapter: :nope) }.to raise_error(ArgumentError, /unknown adapter/)
    end

    it "refuses an unknown denial mode" do
      expect { IntegrationSchema.build(on_unauthorized: :shrug) }.to raise_error(ArgumentError, /on_unauthorized/)
    end
  end

  describe "the engine check" do
    let(:next_context) { authorization::Controls::Context.example(__graphql_execute_next: true) }

    it "refuses Execution::Next on a graphql version that crashes on a denied field" do
      expect { authorization::Integration.check_engine!(next_context, supported: false) }
        .to raise_error(authorization::ConfigurationError, /Execution::Next needs graphql >= 2\.6\.2/)
    end

    it "lets Execution::Next through on a supported version" do
      expect(authorization::Integration.check_engine!(next_context, supported: true)).to be_nil
    end

    it "does not mind the version when the interpreter runs" do
      context = authorization::Controls::Context.example

      expect(authorization::Integration.check_engine!(context, supported: false)).to be_nil
    end
  end

  describe "declaring rules" do
    let(:base) { Class.new(GraphQL::Schema::Object) { include GraphQL::Armory::Authorization::Base } }

    it "refuses a bypass without a reason on a type" do
      expect { Class.new(base) { authorize :none } }.to raise_error(ArgumentError, /reason/)
    end

    it "refuses a bypass without a reason on a field" do
      field_class = Class.new(GraphQL::Schema::Field) { include GraphQL::Armory::Authorization::Base }

      expect { field_class.new(name: :x, type: String, owner: base, authorize: :none) }.to raise_error(ArgumentError, /reason/)
    end

    it "refuses to be included where it has no meaning" do
      expect { Class.new { include GraphQL::Armory::Authorization::Base } }.to raise_error(ArgumentError, /Base/)
    end

    it "inherits the default action" do
      parent = Class.new(base) { default_action :view }

      expect(Class.new(parent).default_action).to eq(:view)
    end
  end
end
