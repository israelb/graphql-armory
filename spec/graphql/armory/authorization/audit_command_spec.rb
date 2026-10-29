# frozen_string_literal: true

require "rake"

RSpec.describe "the audit command" do
  let(:authorization) { GraphQL::Armory::Authorization }

  before do
    Object.const_set(:CleanSchema, IntegrationSchema.build(flawed: false))
    Object.const_set(:FlawedSchema, IntegrationSchema.build)
  end

  after do
    Object.send(:remove_const, :CleanSchema)
    Object.send(:remove_const, :FlawedSchema)
  end

  describe GraphQL::Armory::Authorization::Audit::Command do
    def run(name)
      out = StringIO.new
      status = described_class.new(out: out).(name)
      [status, out.string]
    end

    it "exits 0 and says so when the schema is covered" do
      status, text = run("CleanSchema")

      expect(status).to eq(0)
      expect(text).to start_with("No problems")
    end

    it "exits 1 and lists the problems when it is not" do
      status, text = run("FlawedSchema")

      expect(status).to eq(1)
      expect(text).to include("Forgotten (unprotected)")
    end

    it "exits 1 when the schema does not exist" do
      status, text = run("NoSuchSchema")

      expect([status, text]).to eq([1, "No schema named NoSuchSchema\n"])
    end

    it "exits 1 when no schema was named" do
      status, text = run(nil)

      expect([status, text]).to eq([1, "Name the schema: rake graphql_armory:audit[YourSchema]\n"])
    end
  end

  describe "the rake task" do
    let(:application) { Rake::Application.new }

    before do
      Rake.application = application
      load File.expand_path("../../../../lib/tasks/graphql_armory.rake", __dir__)
    end

    after { Rake.application = Rake::Application.new }

    it "is named graphql_armory:audit" do
      expect(application.lookup("graphql_armory:audit")).not_to be_nil
    end

    it "passes quietly for a covered schema" do
      expect { application["graphql_armory:audit"].invoke("CleanSchema") }.to output(/\ANo problems/).to_stdout
    end

    it "exits 1 for a schema with gaps, so CI fails" do
      task = application["graphql_armory:audit"]

      expect { expect { task.invoke("FlawedSchema") }.to output(/Forgotten/).to_stdout }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end
  end
end

RSpec.describe "be_fully_authorized" do
  require "graphql/armory/authorization/rspec"

  it "passes for a schema where everything is covered" do
    expect(IntegrationSchema.build(flawed: false)).to be_fully_authorized
  end

  it "fails and names the gaps otherwise" do
    expect { expect(IntegrationSchema.build).to be_fully_authorized }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError, /Forgotten \(unprotected\)/)
  end

  it "reads well when negated" do
    expect(IntegrationSchema.build).not_to be_fully_authorized
  end
end
