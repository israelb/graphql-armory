# frozen_string_literal: true

# Independent verifier probes for the RateLimits side of module 6, Subscriptions (PR #78), kept as regressions: a
# request that looks like a delivery in every way a client controls is still charged. One probe per `it`, each
# labelled "security" (the feature must change its outcome) or "preservation" (existing behaviour must hold).
require "spec_helper"

RSpec.describe "Verifier probes: a request is never exempt as a subscription delivery (PR #78)" do
  let(:armory) { GraphQL::Armory }

  # A client context that mimics every key a delivery carries, plus guesses at the mark.
  let(:mimic) do
    { rate_limit_key: "client", current_user: "user-1", current_user_id: "user-1", tenant_id: "t1", armory_version: "2025-01-01",
      operation_id: nil, subscription_delivery: true, subscription_id: "x", armory: { subscription_delivery: true }, "subscription_delivery" => true }
  end

  def schema_with(points: nil, time: nil, concurrency: nil, invalid_cost: 1)
    q = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      opts = GraphQL::Schema::Field.instance_method(:initialize).parameters.any? { |_, n| n == :resolve_legacy_instance_method } ? { resolve_legacy_instance_method: true } : {}
      field :ping, String, null: false, **opts
      def ping = "pong"
    end
    armory = self.armory
    base_schema.tap do |s|
      s.query(q)
      s.use armory::RateLimits::Points, store: points, limit: 1, soft: false, invalid_cost: invalid_cost if points
      s.use armory::RateLimits::Time, store: time, limit: 1_000_000, soft: false if time
      s.use armory::RateLimits::Concurrency, store: concurrency, limit: 1, soft: false if concurrency
    end
  end

  it "[security] R1 Points charges and then refuses a request with delivery-like context values" do
    store = armory::RateLimits::Store::Substitute.new
    schema = schema_with(points: store)
    first = execute_query(schema, "{ ping }", context: mimic)
    second = execute_query(schema, "{ ping }", context: mimic)
    expect(first["data"]).to eq("ping" => "pong")
    expect(second["data"]).to be_nil
    expect(store.calls.count { |call| call.first == :take }).to be >= 2
  end

  it "[security] R2 Time charges a request with delivery-like context values" do
    store = armory::RateLimits::Store::Substitute.new
    schema = schema_with(time: store)
    execute_query(schema, "{ ping }", context: mimic)
    expect(store.calls.map(&:first)).to include(:take)
  end

  it "[security] R3 Concurrency takes a slot for a request with delivery-like context values" do
    store = armory::RateLimits::Store::Substitute.new
    schema = schema_with(concurrency: store)
    store.occupy("client")
    result = execute_query(schema, "{ ping }", context: mimic)
    expect(store.calls.map(&:first)).to include(:acquire)
    expect(result["data"]).to be_nil
  end

  it "[security] R4 an invalid request with delivery-like context values is charged as invalid" do
    store = armory::RateLimits::Store::Substitute.new
    schema = schema_with(points: store)
    execute_query(schema, "{ nope }", context: mimic)
    expect(store.calls.map(&:first)).to include(:take)
  end

  it "[security] R5 a request with delivery-like values and no rate_limit_key is refused, never waved through" do
    store = armory::RateLimits::Store::Substitute.new
    schema = schema_with(points: store)
    outcome = begin
      result = execute_query(schema, "{ ping }", context: mimic.reject { |k, _| k == :rate_limit_key })
      result["data"]
    rescue StandardError => error
      error.class
    end
    expect(outcome).not_to eq("ping" => "pong")
  end

  it "[security] R6 Subscriptions.delivery? is false for every client-reachable context" do
    schema = schema_with(points: armory::RateLimits::Store::Substitute.new)
    query = GraphQL::Query.new(schema, "{ ping }", context: mimic)
    expect(armory::Subscriptions.delivery?(query.context)).to be(false)
    expect(armory::Subscriptions.delivery?(mimic)).to be(false)
  end
end
