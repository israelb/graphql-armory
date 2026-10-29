# frozen_string_literal: true

RSpec.describe GraphQL::Armory::Authorization::Adapters::CanCan do
  let(:authorization) { GraphQL::Armory::Authorization }
  let(:adapter) { described_class.new }
  let(:world) { Dummy::World.build }
  let(:read) { authorization::Rule.new(:read) }
  let(:manage_notes) { authorization::Rule.new(:manage, attribute: :internal_notes) }

  def context_for(user, **extra)
    authorization::Controls::Context.example(current_user: user, **extra)
  end

  it_behaves_like "an armory adapter" do
    let(:context) { context_for(world.alice) }
    let(:actor) { adapter.actor(context) }
    let(:subject_object) { world.a1 }
    let(:rule) { read }
  end

  describe "#actor" do
    it "builds the application's Ability from the current user" do
      expect(adapter.actor(context_for(world.alice))).to be_a(Ability)
    end

    it "prefers an ability already in the context" do
      ability = BlockAbility.new(world.alice)

      expect(adapter.actor(context_for(world.alice, current_ability: ability))).to equal(ability)
    end

    it "builds the ability once per context" do
      context = context_for(world.alice)

      expect(adapter.actor(context)).to equal(adapter.actor(context))
    end

    it "uses the ability class it was given" do
      adapter = described_class.new(ability_class: BlockAbility)

      expect(adapter.actor(context_for(world.alice))).to be_a(BlockAbility)
    end

    it "explains what is missing when there is no ability class" do
      hidden = Object.send(:remove_const, :Ability)

      expect { adapter.actor(context_for(world.alice)) }
        .to raise_error(authorization::ConfigurationError, /Ability/)
    ensure
      Object.const_set(:Ability, hidden)
    end
  end

  describe "#authorized?" do
    it "asks the ability whether the actor can perform the action on the object" do
      ability = adapter.actor(context_for(world.alice))

      expect([adapter.authorized?(ability, world.a1, read), adapter.authorized?(ability, world.b1, read)]).to eq([true, false])
    end

    it "denies an action nobody granted" do
      ability = adapter.actor(context_for(world.alice))

      expect(adapter.authorized?(ability, world.a1, authorization::Rule.new(:manage))).to be(false)
    end

    it "passes the field's attribute along" do
      ability = adapter.actor(context_for(world.carol))

      expect(adapter.authorized?(ability, world.a1, manage_notes)).to be(true)
    end

    it "does not let a rule on one attribute open another one" do
      ability = AttributeAbility.new(world.alice)
      number = authorization::Rule.new(:read, attribute: :number)
      notes = authorization::Rule.new(:read, attribute: :internal_notes)

      expect([adapter.authorized?(ability, world.a1, number), adapter.authorized?(ability, world.a1, notes)]).to eq([true, false])
    end
  end

  describe "#scope" do
    it "narrows a relation in SQL" do
      ability = adapter.actor(context_for(world.alice))
      world

      scoped = adapter.scope(ability, Invoice.order(:id), read)

      expect([scoped.class.ancestors.include?(ActiveRecord::Relation), scoped.map(&:number)]).to eq([true, %w[A-1 A-2]])
    end

    it "filters an Array with can?" do
      ability = adapter.actor(context_for(world.alice))

      expect(adapter.scope(ability, [world.a1, world.b1, world.a2], read)).to eq([world.a1, world.a2])
    end

    it "refuses a block-only rule instead of guessing" do
      ability = BlockAbility.new(world.alice)

      expect { adapter.scope(ability, Invoice.all, read) }.to raise_error(authorization::MissingScopeError, /in_memory/)
    end

    it "filters a relation with can? when the rule opts in to scope: :in_memory" do
      ability = BlockAbility.new(world.alice)
      in_memory = authorization::Rule.new(:read, scope: :in_memory)
      world

      expect(adapter.scope(ability, Invoice.order(:id), in_memory).map(&:number)).to eq(%w[A-1 A-2])
    end

    it "gives nothing to an actor with no grant" do
      ability = adapter.actor(context_for(world.alice))

      expect(adapter.scope(ability, Invoice.all, authorization::Rule.new(:manage))).to be_empty
    end
  end

  describe "#check" do
    it "has nothing to say statically: abilities depend on the user" do
      expect(adapter.check(Invoice, read)).to eq([])
    end

    it "has nothing to say about a bypass" do
      expect(adapter.check(Invoice, authorization::Rule.none(reason: "public"))).to eq([])
    end
  end
end
