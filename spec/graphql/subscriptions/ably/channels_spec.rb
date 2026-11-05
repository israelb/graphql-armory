# frozen_string_literal: true

require_relative "ably_helper"

RSpec.describe "GraphQL::Armory::Subscriptions::Ably channels" do
  include AblyHelper

  it "names a channel <prefix>:<viewer digest>:<id>, and reads the id back" do
    expect(channel).to eq("graphql:#{digest}:#{id}")
    expect(ably.id_from(channel)).to eq(id)
    expect(ably(prefix: "app-1").channel_for(id, digest)).to eq("app-1:#{digest}:#{id}")
  end

  it "names the channel of an anonymous subscription" do
    anonymous = subscriptions::Record::ANONYMOUS

    expect(ably.id_from(ably.channel_for(id, anonymous))).to eq(id)
  end

  it "refuses to name a channel for a digest or id that is not what the core stores" do
    expect { ably.channel_for(id, "Z" * 64) }.to raise_error(ArgumentError)
    expect { ably.channel_for(id, "ab:cd") }.to raise_error(ArgumentError)
    expect { ably.channel_for("short", digest) }.to raise_error(ArgumentError)
    expect { ably.channel_for("a:#{id}", digest) }.to raise_error(ArgumentError)
  end

  it "reads an id only from a channel it would have named" do
    bad = [
      nil, 5, "", id, "graphql:#{id}", "other:#{digest}:#{id}", "graphql:#{digest}:#{id}:more", "graphql:#{digest}:",
      "graphql:#{digest.upcase}:#{id}", "graphql:#{digest[0, 63]}:#{id}", "graphql:#{digest}:short",
      "graphql:#{digest}:#{id}\n", "graphql:#{digest}:#{id}!", "graphql::#{id}"
    ]

    expect(bad.map { |name| ably.id_from(name) }).to all(be_nil)
  end
end
