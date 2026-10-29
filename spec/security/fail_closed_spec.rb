# frozen_string_literal: true

# Anything nobody covered, or anything that goes wrong while deciding, must not hand out data.
RSpec.describe "Deny by default" do
  let(:audit) { GraphQL::Armory::Authorization::Audit }
  let(:authorization) { GraphQL::Armory::Authorization }

  def ask(schema, query, user:, **root)
    execute_query(schema, query, context: { current_user: user }, root_value: IntegrationSchema::Root.new(**root))
  end

  def problem(report, kind, path)
    report.problems.find { |found| found.kind == kind && found.path == path }
  end

  it "fails the query for a type without a policy, and the audit lists it" do
    expect { as(world.alice, "{ ghost { label } }", ghost: Ghost.new) }.to raise_error(Pundit::NotDefinedError)

    expect(problem(audit.(IntegrationSchema.build), :adapter, "Ghost").message).to eq("GhostPolicy not found")
  end

  it "answers null for a type with no rule, even to its owner, and the audit lists it" do
    schema = IntegrationSchema.build(type_action: nil)

    result = ask(schema, "{ myInvoice { number } }", user: world.alice, my_invoice: world.a1)

    expect(result["data"]).to eq("myInvoice" => nil)
    expect(problem(audit.(schema), :no_rule, "Invoice")).not_to be_nil
  end

  it "denies a field that declares no rule on a bypassed type, and the audit lists it" do
    result = as(world.alice, "{ ping noRule }")

    expect(result["data"]).to be_nil
    expect(problem(audit.(IntegrationSchema.build), :field_without_rule, "Query.no_rule")).not_to be_nil
  end

  it "cannot protect a type whose base class never included the integration, so the audit lists it" do
    result = as(world.alice, "{ forgotten { secret } }", forgotten: Struct.new(:secret).new("hunter2"))

    expect(result["data"]).to eq("forgotten" => { "secret" => "hunter2" })
    expect(problem(audit.(IntegrationSchema.build), :unprotected, "Forgotten")).not_to be_nil
  end

  it "refuses a policy answer that is truthy but not true" do
    [:yes, 1, "true", Object.new].each do |answer|
      schema = IntegrationSchema.build(adapter: authorization::Adapters::Substitute.new(allow: answer))

      expect { ask(schema, "{ myInvoice { number } }", user: world.alice, my_invoice: world.a1) }
        .to raise_error(authorization::AdapterError)
    end
  end

  it "never lets data through when the adapter raises" do
    schema = IntegrationSchema.build(adapter: authorization::Adapters::Substitute.new(raises: RuntimeError.new("boom")))

    expect { ask(schema, "{ myInvoice { number } }", user: world.alice, my_invoice: world.a1) }.to raise_error(RuntimeError, /boom/)
  end

  it "refuses to answer when the schema never installed the plugin" do
    schema = IntegrationSchema.build(plugin: false)

    expect { ask(schema, "{ myInvoice { number } }", user: world.alice, my_invoice: world.a1) }.to raise_error(StandardError)
  end

  it "refuses to answer when there is no user at all" do
    expect { as(nil, "{ myInvoice { number } }", my_invoice: world.a1) }.to raise_error(StandardError)
  end
end
