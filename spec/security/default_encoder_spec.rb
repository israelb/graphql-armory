# frozen_string_literal: true

require "openssl"

# The default encoder never ships a key: it takes one from the app's environment, or derives one from Rails'
# secret_key_base for this purpose alone, and refuses to start without one instead of serving unencrypted IDs.
RSpec.describe "The default encoder" do
  let(:encoder_class) { GraphQL::Armory::Encoder }
  let(:env_key) { "e" * 32 }
  let(:secret_key_base) { "s" * 64 }

  # What the default encoder reads from a Rails application: its secret_key_base, and nothing else. A
  # `key_generator` that raises proves it is never asked (its digest depends on when it is first built).
  def rails_app(secret)
    Struct.new(:secret_key_base) do
      def key_generator = raise("the default encoder must not use Rails' key generator")
    end.new(secret)
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

  it "derives a key of its own from secret_key_base with HKDF, never the secret itself, nor Rails' key generator" do
    derived = OpenSSL::KDF.hkdf(secret_key_base, salt: "graphql-armory", info: "graphql-armory/ids", length: 32, hash: "SHA256")
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

  it "refuses a GRAPHQL_ARMORY_KEY with surrounding or only whitespace, which other processes may strip" do
    ["#{env_key}\n", " #{env_key}", " " * 32].each do |value|
      expect { default(env: { "GRAPHQL_ARMORY_KEY" => value }) }.to raise_error(encoder_class::ConfigurationError, /whitespace/)
    end
  end

  it "refuses to start without a key, naming both ways to give one" do
    expect { default }.to raise_error(encoder_class::ConfigurationError, /GRAPHQL_ARMORY_KEY.*secret_key_base/m)
  end

  it "refuses a GRAPHQL_ARMORY_KEY shorter than 32 bytes" do
    expect { default(env: { "GRAPHQL_ARMORY_KEY" => "short" }) }.to raise_error(encoder_class::ConfigurationError, /32 bytes/)
  end

  it "refuses a Rails app with no secret_key_base" do
    expect { default(rails: rails_app(nil)) }.to raise_error(encoder_class::ConfigurationError, /no secret_key_base/)
  end

  it "refuses to start when Rails cannot give a secret_key_base, without echoing its message" do
    broken = Object.new.tap { |app| def app.secret_key_base = raise(ArgumentError, "secret=SUPERSECRET") }

    expect { default(rails: broken) }.to raise_error(encoder_class::ConfigurationError) { |error| expect(error.message).not_to include("SUPERSECRET") }
  end
end
