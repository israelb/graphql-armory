# frozen_string_literal: true

# The rate limiters as Useful Objects: `new` is inert and refuses, `build` validates and wires the real store,
# `call` is the actuator, and the store has a Null and a Substitute in lib/.
RSpec.describe "rate limits as useful objects" do
  let(:schema) do
    query = GraphQL::Armory::RateLimits::Controls::Query.example
    Class.new(ArmoryEngine.base_schema) { query query }
  end
  let(:query) { GraphQL::Query.new(schema, "{ cheap }", context: GraphQL::Armory::RateLimits::Controls::Context.example) }

  describe GraphQL::Armory::RateLimits::Store::Null do
    it "refuses every charge and slot, and releases nothing" do
      store = GraphQL::Armory::RateLimits::Store::Null.new

      expect([store.take("k", cost: 1, limit: 10, window: 60), store.acquire("k", token: "t", limit: 1, ttl: 60), store.release("k", token: "t")])
        .to eq([[false, 0], [false, 0], nil])
    end
  end

  describe GraphQL::Armory::RateLimits::Points do
    it "is inert with new: no store wired, so every query is refused" do
      expect(GraphQL::Armory::RateLimits::Points.new.(query, 1)).to be_a(GraphQL::AnalysisError)
    end

    it "charges through the store build wires, and records what happened" do
      store = GraphQL::Armory::RateLimits::Store::Substitute.new
      points = GraphQL::Armory::RateLimits::Points.build(store: store, limit: 10, window: 60, soft: false)

      expect(points.(query, 4)).to be_nil
      expect(store.calls).to eq([[:take, "user:1", { cost: 4, limit: 10, window: 60, force: false }]])
      expect(query.context[:rate_limit_points]).to include(cost: 4, remaining: 6, limited: false)
    end

    it "validates its settings in build" do
      expect { GraphQL::Armory::RateLimits::Points.build(store: Object.new, limit: 10) }
        .to raise_error(GraphQL::Armory::RateLimits::ConfigurationError, /store/)
    end
  end

  describe GraphQL::Armory::RateLimits::Concurrency do
    it "is inert with new: no store wired, so every query is refused" do
      schema.trace_with(GraphQL::Armory::RateLimits::Concurrency::Release)

      expect(GraphQL::Armory::RateLimits::Concurrency.new.(query)).to be_a(GraphQL::AnalysisError)
    end
  end

  describe GraphQL::Armory::RateLimits::Store::Substitute do
    let(:store) { GraphQL::Armory::RateLimits::Store::Substitute.new }

    it "behaves like a MemoryStore on a clock the test moves" do
      store.take("k", cost: 10, limit: 10, window: 60)
      store.now += 30

      expect(store.take("k", cost: 0, limit: 10, window: 60)).to eq([true, 5])
    end

    it "fails when told, on one method or all, for a number of calls or until it recovers" do
      store.fail_with(IOError.new("down"), on: :release, times: 1)

      expect { store.release("k", token: "t") }.to raise_error(IOError, "down")
      expect(store.release("k", token: "t")).to be_nil

      store.fail_with(IOError.new("gone"))
      expect { store.take("k", cost: 1, limit: 1, window: 1) }.to raise_error(IOError, "gone")
      store.recover
      expect(store.take("k", cost: 1, limit: 1, window: 1)).to eq([true, 0])
    end

    it "answers what it is told instead of the real answer" do
      store.answer(:take, [0, 0])

      expect(store.take("k", cost: 1, limit: 1, window: 1)).to eq([0, 0])
    end

    it "occupies slots for other operations and counts the slots held, without recording them" do
      token = store.occupy("k")
      store.occupy("k")
      store.release("k", token: token)

      expect([store.held("k"), store.calls.map(&:first)]).to eq([1, [:release]])
    end
  end
end
