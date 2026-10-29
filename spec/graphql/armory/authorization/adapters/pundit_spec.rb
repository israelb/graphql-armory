# frozen_string_literal: true

RSpec.describe GraphQL::Armory::Authorization::Adapters::Pundit do
  let(:authorization) { GraphQL::Armory::Authorization }
  let(:adapter) { described_class.new }
  let(:world) { Dummy::World.build }
  let(:read) { authorization::Rule.new(:read) }
  let(:manage) { authorization::Rule.new(:manage) }

  it_behaves_like "an armory adapter" do
    let(:context) { authorization::Controls::Context.example(current_user: world.alice) }
    let(:actor) { world.alice }
    let(:subject_object) { world.a1 }
    let(:rule) { read }
  end

  describe "#actor" do
    it "is the current user of the context" do
      context = authorization::Controls::Context.example(current_user: world.alice)

      expect(adapter.actor(context)).to eq(world.alice)
    end
  end

  describe "#authorized?" do
    it "asks the policy of the model for the rule's action" do
      expect(adapter.authorized?(world.alice, world.a1, read)).to be(true)
    end

    it "denies an object of another account" do
      expect(adapter.authorized?(world.alice, world.b1, read)).to be(false)
    end

    it "reads the action from the rule" do
      answers = [world.alice, world.carol].map { |user| adapter.authorized?(user, world.a1, manage) }

      expect(answers).to eq([false, true])
    end

    it "finds the policy through policy_class when the model declares one" do
      credit = Credit.create!(account: world.account_a)

      expect(adapter.authorized?(world.alice, credit, read)).to be(true)
      expect(adapter.authorized?(world.bob, credit, read)).to be(false)
    end

    it "uses the policy of the rule when it names one" do
      rule = authorization::Rule.new(:read, policy: AccountPolicy)

      expect(adapter.authorized?(world.alice, world.account_a, rule)).to be(true)
      expect(adapter.authorized?(world.alice, world.account_b, rule)).to be(false)
    end

    it "does not guess a policy that does not exist" do
      expect { adapter.authorized?(world.alice, Ghost.new, read) }.to raise_error(Pundit::NotDefinedError)
    end

    it "refuses a policy that does not define the action" do
      note = Note.create!(account: world.account_a)

      expect { adapter.authorized?(world.alice, note, manage) }
        .to raise_error(authorization::AdapterError, /NotePolicy does not define manage\?/)
    end

    it "hands back what the policy answered, truthy or not" do
      expect(adapter.authorized?(world.alice, Odd.new, read)).to eq("yes")
    end
  end

  describe "#scope" do
    it "returns the policy scope, still a relation" do
      scoped = adapter.scope(world.alice, Invoice.all, read)

      expect(scoped).to be_a(ActiveRecord::Relation)
      expect(scoped.map(&:number)).to contain_exactly("A-1", "A-2")
    end

    it "never includes objects of another account" do
      world

      expect(adapter.scope(world.bob, Invoice.all, read).map(&:number)).to eq(["B-1"])
    end

    it "uses the scope of the policy the rule names" do
      rule = authorization::Rule.new(:read, policy: AccountPolicy)

      expect(adapter.scope(world.alice, Account.all, rule).map(&:name)).to eq(["A"])
    end

    it "fails with MissingScopeError when the policy has no Scope" do
      expect { adapter.scope(world.alice, Note.all, read) }
        .to raise_error(authorization::MissingScopeError, /NotePolicy has no Scope/)
    end

    it "does not guess a policy that does not exist" do
      expect { adapter.scope(world.alice, [Ghost.new], read) }.to raise_error(Pundit::NotDefinedError)
    end

    it "leaves an empty array empty" do
      expect(adapter.scope(world.alice, [], read)).to eq([])
    end
  end

  describe "#check" do
    it "finds nothing wrong with a complete policy" do
      expect(adapter.check(Invoice, read)).to eq([])
    end

    it "reports a policy that is not there" do
      expect(adapter.check(Ghost, read)).to eq(["GhostPolicy not found"])
    end

    it "reports a missing action and a missing Scope" do
      expect(adapter.check(Note, manage)).to eq(["NotePolicy#manage? is not defined", "NotePolicy::Scope is not defined"])
    end

    it "takes the model from a symbol or a string" do
      expect([adapter.check(:invoice, read), adapter.check("Invoice", read)]).to eq([[], []])
    end

    it "honours policy_class" do
      expect(adapter.check(Credit, read)).to eq([])
    end

    it "has nothing to say about a declared bypass" do
      expect(adapter.check(Ghost, authorization::Rule.none(reason: "public"))).to eq([])
    end
  end

  describe "with the core" do
    let(:context) { authorization::Controls::Context.example(current_user: world.alice) }

    it "lets a user read their own account's invoice" do
      expect(authorization::Authorize.(world.a1, read, context, adapter: adapter)).to be(true)
    end

    it "denies a user reading another account's invoice" do
      expect(authorization::Authorize.(world.b1, read, context, adapter: adapter)).to be(false)
    end

    it "refuses a policy answer that is not a boolean" do
      expect { authorization::Authorize.(Odd.new, read, context, adapter: adapter) }
        .to raise_error(authorization::AdapterError, /true, false or nil/)
    end

    it "scopes a list down to the user's account" do
      scoped = authorization::Scope.(Invoice.all, read, context, adapter: adapter)

      expect(scoped.map(&:number)).to contain_exactly("A-1", "A-2")
    end
  end
end
