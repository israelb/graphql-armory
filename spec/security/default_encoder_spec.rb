# frozen_string_literal: true

require "active_support/key_generator"

# The default encoder never ships a key: it takes one from the app's environment, or from Rails' secret_key_base
# through a purpose of its own, and refuses to start without one instead of serving unencrypted IDs.
RSpec.describe "The default encoder" do
  let(:encoder_class) { GraphQL::Armory::Encoder }
  let(:env_key) { "e" * 32 }
  let(:secret_key_base) { "s" * 64 }

  # What the default encoder needs from a Rails application: its key generator.
  def rails_app(secret)
    Struct.new(:key_generator).new(ActiveSupport::KeyGenerator.new(secret))
  end

  def default(env: {}, rails: nil)
    encoder_class.default(env: env, rails: rails)
  end

  def with_key(key)
    Class.new(encoder_class) { key(key) }
  end

  it "takes the key from GRAPHQL_ARMORY_KEY" do
    expect(default(env: { "GRAPHQL_ARMORY_KEY" => env_key }).encode("Invoice/42")).to eq(with_key(env_key).encode("Invoice/42"))
  end

  it "prefers GRAPHQL_ARMORY_KEY over Rails" do
    encoder = default(env: { "GRAPHQL_ARMORY_KEY" => env_key }, rails: rails_app(secret_key_base))

    expect(encoder.encode("Invoice/42")).to eq(with_key(env_key).encode("Invoice/42"))
  end

  it "derives a key of its own from Rails' secret_key_base, never the secret itself" do
    derived = ActiveSupport::KeyGenerator.new(secret_key_base).generate_key("graphql-armory/ids", 32)
    id = default(rails: rails_app(secret_key_base)).encode("Invoice/42")

    expect([id == with_key(derived).encode("Invoice/42"), id == with_key(secret_key_base).encode("Invoice/42")]).to eq([true, false])
  end

  it "gives different IDs for different secret_key_base values" do
    ids = ["s" * 64, "t" * 64].map { |secret| default(rails: rails_app(secret)).encode("Invoice/42") }

    expect(ids.uniq.size).to eq(2)
  end

  it "treats an empty GRAPHQL_ARMORY_KEY as unset" do
    encoder = default(env: { "GRAPHQL_ARMORY_KEY" => "" }, rails: rails_app(secret_key_base))

    expect(encoder.encode("Invoice/42")).to eq(default(rails: rails_app(secret_key_base)).encode("Invoice/42"))
  end

  it "refuses to start without a key, naming both ways to give one" do
    expect { default }.to raise_error(encoder_class::ConfigurationError, /GRAPHQL_ARMORY_KEY.*secret_key_base/m)
  end

  it "refuses a GRAPHQL_ARMORY_KEY shorter than 32 bytes" do
    expect { default(env: { "GRAPHQL_ARMORY_KEY" => "short" }) }.to raise_error(encoder_class::ConfigurationError, /32 bytes/)
  end

  it "refuses to start when Rails cannot give a secret_key_base" do
    broken = Struct.new(:key_generator).new(Object.new.tap { |generator| def generator.generate_key(*) = raise(ArgumentError, "Missing secret_key_base") })

    expect { default(rails: broken) }.to raise_error(encoder_class::ConfigurationError, /secret_key_base/)
  end
end
