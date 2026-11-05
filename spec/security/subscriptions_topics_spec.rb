# frozen_string_literal: true

require "spec_helper"
require "date"
require_relative "../graphql/subscriptions/core/core_helpers"

# Guarantee 2 (unsafe behaviour 2): graphql-ruby's topic joins scope, field and arguments with unescaped ":", so crafted
# arguments, and 1 versus "1" scopes, collide with another subscription's topic. The core's topic is a keyed digest of
# a fixed-arity JSON array, canonicalised through the field's argument definitions, so distinct subscriptions never
# share it, and the trigger's raw values meet the subscription's coerced ones.
RSpec.describe "subscriptions: topics" do
  include SubscriptionsCoreHelpers

  it "keeps apart two subscriptions whose graphql-ruby topics collide on ':'" do
    log = controls::Schema.example(directory: directory, subscriptions: {}, plugin: controls::EventLog)
    joined = "subscription { roomUpdated(roomId: \"5:thread:6\") { id } }"
    split = "subscription { roomUpdated(roomId: \"5\", thread: \"6\") { id } }"
    [joined, split].each { |document| execute_query(log, document, context: context_for("user-1")) }

    expect(log.subscriptions.events.map(&:topic).uniq.size).to eq(1) # graphql-ruby's own topics collide

    joined_channel = subscribed(joined)
    split_channel = subscribed(split)
    backend.trigger(:room_updated, { room_id: "5:thread:6" }, room)

    expect([payloads(joined_channel).size, payloads(split_channel).size]).to eq([1, 0])
  end

  it "keeps apart an Integer scope and a String scope that print alike" do
    log = controls::Schema.example(directory: directory, subscriptions: {}, plugin: controls::EventLog)
    [1, "1"].each { |tenant| execute_query(log, "subscription { messagePosted(roomId: 5) { id } }", context: context_for("user-1", tenant: tenant)) }

    expect(log.subscriptions.events.map(&:topic).uniq.size).to eq(1) # graphql-ruby's own topics collide

    integer = subscribed("subscription { messagePosted(roomId: 5) { id } }", tenant: 1)
    string = subscribed("subscription { messagePosted(roomId: 5) { id } }", tenant: "1")
    backend.trigger(:message_posted, { room_id: 5 }, message, scope: 1)

    expect([payloads(integer).size, payloads(string).size]).to eq([1, 0])
  end

  it "meets the trigger whatever form it gives: Integer or String ID, enum by Ruby value or name, a Date or its String, defaults omitted" do
    channel = subscribed("subscription { messagePosted(roomId: \"5\", priority: HIGH, on: \"2025-03-01\") { id } }")
    forms = [
      { room_id: 5, priority: :high, on: Date.new(2025, 3, 1) },
      { "roomId" => "5", "priority" => "HIGH", "on" => "2025-03-01" },
      { room_id: "5", priority: "HIGH", on: Date.new(2025, 3, 1), filter: { priority: :low } },
      { roomId: 5, priority: :high, on: "2025-03-01", filter: { "priority" => "LOW" } }
    ]
    forms.each { |arguments| backend.trigger(:message_posted, arguments, message, scope: "acme") }

    expect(payloads(channel).size).to eq(forms.size)
    expect(payloads(channel)).to all(eq(result: { "data" => { "messagePosted" => { "id" => "m1" } } }, more: true))
  end

  it "does not meet a trigger with a different value in any argument" do
    channel = subscribed("subscription { messagePosted(roomId: \"5\", priority: HIGH) { id } }")
    [{ room_id: 6, priority: :high }, { room_id: 5, priority: :low }, { room_id: 5 }, { room_id: 5, priority: :high, filter: { priority: :high } }].each do |arguments|
      backend.trigger(:message_posted, arguments, message, scope: "acme")
    end

    expect(payloads(channel)).to be_empty
  end
end
