# frozen_string_literal: true

require "spec_helper"
require_relative "core_helpers"

RSpec.describe GraphQL::Armory::Subscriptions::Audit do
  include SubscriptionsCoreHelpers

  def kinds(report, severity = nil)
    report.findings.select { |finding| severity.nil? || finding.severity == severity }.map(&:kind)
  end

  it "passes the control schema, listing each stored context key with its reason for review" do
    report = described_class.call(schema)

    expect(report).to be_ok
    expect(kinds(report)).to eq([:context_key])
    expect(report.findings.first.message).to include("tenant_id", "scopes every message")
    expect(report.to_s).to include("tenant_id")
  end

  it "fails a schema without this backend" do
    report = described_class.call(controls::Schema.example)

    expect(report).not_to be_ok
    expect(kinds(report, :error)).to eq([:plugin])
  end

  it "reports a field marked broadcastable: true, which the backend ignores" do
    types = controls::Schema::Types.example
    schema = controls::Schema.example(directory: directory, types: types, subscriptions: nil)
    schema.subscription.field :scores, String, null: true, broadcastable: true
    schema.use(GraphQL::Armory::Subscriptions, **controls::Options.example(directory: directory, store: store, transport: transport))

    report = described_class.call(schema)

    expect(kinds(report, :notice)).to include(:broadcastable)
    expect(report.findings.find { |finding| finding.kind == :broadcastable }.message).to include("Subscription.scores")
    expect(report).to be_ok
  end

  it "fails a child schema, whose deliveries run on the parent that installed the backend" do
    child = Class.new(schema)

    expect(kinds(described_class.call(child), :error)).to eq([:child_schema])
  end

  it "fails a viewer over a transport that is not viewer bound, when one was forced in" do
    loose = controls::Transport.example(capabilities: controls::Capabilities.example(viewer_bound: false))
    forced = GraphQL::Armory::Subscriptions::Core.new(schema: schema, settings: backend.settings, store: store, transport: loose,
                                                      encoder: backend.encoder)
    schema.subscriptions = forced

    expect(kinds(described_class.call(schema), :error)).to eq([:transport])
  end

  it "lists anonymous mode with its reason" do
    anonymous = build_schema(viewer: nil, anonymous: "public scores", cap_key: ->(context) { context[:ip] }, context_keys: { tenant_id: "x", current_user_id: "y" })

    expect(kinds(described_class.call(anonymous), :notice)).to include(:anonymous)
  end
end
