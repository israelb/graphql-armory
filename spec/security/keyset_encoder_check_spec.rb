# frozen_string_literal: true

require "base64"

# Without `use`, a schema that cannot keep cursors private is refused on the first keyset page, in production, and only if
# it has the default encoder. `use Keyset` checks the encoder when the schema class loads.
RSpec.describe "checking the cursor encoder when the schema loads" do
  keyset = GraphQL::Armory::Keyset
  armory_encoder = GraphQL::Armory::IDs::Controls::Encoder.example

  shape = lambda do |transform, back|
    Module.new do
      define_singleton_method(:encode) { |text, nonce: false| transform.(text) }
      define_singleton_method(:decode) { |text, nonce: false| back.(text) }
    end
  end
  rot13 = ->(text) { text.tr("A-Za-z", "N-ZA-Mn-za-m") }
  # A key that never changes, so every position depends only on its own byte.
  xor = ->(text) { text.bytes.map { |byte| (byte ^ 0x5A).chr }.join.unpack1("H*") }
  unxor = ->(text) { [text].pack("H*").bytes.map { |byte| (byte ^ 0x5A).chr }.join }

  not_private = {
    "identity" => shape.(->(text) { text }, ->(text) { text }),
    "Base64" => GraphQL::Schema::Base64Encoder,
    "a wrapper of the default" => shape.(->(text) { GraphQL::Schema::Base64Encoder.encode(text) }, ->(text) { GraphQL::Schema::Base64Encoder.decode(text) }),
    "Base64 behind a prefix" => shape.(->(text) { "v1:#{Base64.strict_encode64(text)}" }, ->(text) { Base64.strict_decode64(text.delete_prefix("v1:")) }),
    "hex" => shape.(->(text) { text.unpack1("H*") }, ->(text) { [text].pack("H*") }),
    "ROT13" => shape.(rot13, rot13),
    "reversed" => shape.(lambda(&:reverse), lambda(&:reverse)),
    "a fixed XOR" => shape.(xor, unxor),
    "the test substitute" => GraphQL::Armory::Encoder::Substitute.new
  }

  define_method(:schema_with) do |encoder, **options|
    Class.new(GraphQL::Schema) do
      cursor_encoder encoder
      use keyset, **options
    end
  end

  it "accepts the gem's encoder" do
    expect(schema_with(armory_encoder).cursor_encoder).to eq(armory_encoder)
  end

  not_private.each do |name, encoder|
    it "refuses #{name}" do
      expect { schema_with(encoder) }.to raise_error(keyset::ConfigurationError, /cursor_encoder/)
    end

    it "accepts #{name} with plain_cursors: true" do
      expect { schema_with(encoder, plain_cursors: true) }.not_to raise_error
    end
  end

  it "refuses a schema with no encoder, and says to put it above" do
    expect { Class.new(GraphQL::Schema) { use keyset } }.to raise_error(keyset::ConfigurationError, /above/)
  end

  it "refuses an encoder that does not take nonce:" do
    no_nonce = Module.new do
      def self.encode(text, nonce: false) = armored(text)
      def self.armored(text) = GraphQL::Armory::IDs::Controls::Encoder.example.encode(text, nonce: true)
      def self.decode(text) = text
    end

    expect { schema_with(no_nonce) }.to raise_error(keyset::ConfigurationError, /cursor_encoder/)
  end

  it "refuses an encoder that does not answer what it was given" do
    broken = shape.(->(text) { armory_encoder.encode(text, nonce: true) }, ->(_text) { "something else" })

    expect { schema_with(broken) }.to raise_error(keyset::ConfigurationError, /round trip|give back/)
  end

  it "refuses an encoder that answers no String" do
    expect { schema_with(shape.(->(_text) { 1 }, ->(text) { text })) }.to raise_error(keyset::ConfigurationError, /cursor_encoder/)
  end

  it "names the class of an error, never its words" do
    raising = shape.(->(_text) { raise ArgumentError, "the key is s3cret" }, ->(text) { text })

    expect { schema_with(raising) }.to raise_error(keyset::ConfigurationError) { |error|
      expect(error.message).to include("ArgumentError")
      expect(error.message).not_to include("s3cret")
    }
  end

  it "refuses a chain that decodes forged Base64" do
    chain = GraphQL::Armory::Encoder.versioned(armory_encoder, GraphQL::Armory::Encoder::Legacy)

    expect { schema_with(chain) }.to raise_error(keyset::ConfigurationError, /forged/)
    expect { schema_with(chain, plain_cursors: true) }.not_to raise_error
  end

  it "accepts an encoder that delegates through method_missing" do
    delegator = Class.new(BasicObject) do
      define_method(:method_missing) { |name, *args, **options, &block| armory_encoder.public_send(name, *args, **options, &block) }
      define_method(:respond_to_missing?) { |*_args| true }
    end.new

    expect { schema_with(delegator) }.not_to raise_error
  end

  describe "an encoder set later" do
    let(:identity) { not_private.fetch("identity") }

    it "is checked on the same schema" do
      schema = schema_with(armory_encoder)
      encoder = identity

      expect { schema.cursor_encoder(encoder) }.to raise_error(keyset::ConfigurationError, /cursor_encoder/)
      expect(schema.cursor_encoder).to eq(armory_encoder)
    end

    it "is checked on a subclass" do
      parent = schema_with(armory_encoder)
      encoder = identity

      expect { Class.new(parent) { cursor_encoder encoder } }.to raise_error(keyset::ConfigurationError, /cursor_encoder/)
    end

    it "is accepted on a subclass of a schema with plain cursors" do
      parent = schema_with(identity, plain_cursors: true)
      encoder = not_private.fetch("hex")

      expect(Class.new(parent) { cursor_encoder encoder }.cursor_encoder).to eq(encoder)
    end

    it "takes a subclass's own use, which is visible in its body" do
      parent = schema_with(armory_encoder)
      encoder = identity

      child = Class.new(parent) do
        use keyset, plain_cursors: true
        cursor_encoder encoder
      end

      expect(child.cursor_encoder).to eq(encoder)
      expect { parent.cursor_encoder(encoder) }.to raise_error(keyset::ConfigurationError)
    end

    it "checks again what a subclass inherits when it turns plain cursors off" do
      parent = schema_with(identity, plain_cursors: true)

      expect { Class.new(parent) { use keyset } }.to raise_error(keyset::ConfigurationError, /cursor_encoder/)
    end
  end

  it "refuses a plain_cursors: that is not a boolean" do
    expect { schema_with(armory_encoder, plain_cursors: "yes") }.to raise_error(keyset::ConfigurationError, /plain_cursors/)
  end

  it "leaves a schema with no use alone" do
    schema = Class.new(GraphQL::Schema) { cursor_encoder not_private.fetch("identity") }

    expect(schema.cursor_encoder).to eq(not_private.fetch("identity"))
  end

  describe "a page" do
    let(:controls) { keyset::Controls }
    let(:document) { "{ items(first: 1) { nodes { id } } }" }

    define_method(:page) do |schema, **options|
      execute_query(schema, document, root_value: controls::Root.example(keyset.build(KeysetItem.order(:id), **options)))
    end

    before { KeysetItem.create!(rank: 1) }

    define_method(:plain_schema) { |**options| controls::Schema.example(base: base_schema).tap { |schema| schema.use(keyset, **options) } }

    it "follows the schema's plain_cursors: true" do
      expect(page(plain_schema(plain_cursors: true)).dig("data", "items", "nodes").size).to eq(1)
    end

    it "lets an explicit plain_cursors: false win over the schema's" do
      expect { page(plain_schema(plain_cursors: true), plain_cursors: false) }.to raise_error(keyset::ConfigurationError, /plain_cursors/)
    end

    it "lets an explicit plain_cursors: true pass, with no use" do
      expect(page(controls::Schema.example(base: base_schema), plain_cursors: true).dig("data", "items", "nodes").size).to eq(1)
    end

    it "still refuses Base64 on the first page with no use" do
      expect { page(controls::Schema.example(base: base_schema)) }.to raise_error(keyset::ConfigurationError, /plain_cursors/)
    end

    it "keeps following the schema after a scope changes the relation" do
      connection = keyset.build(KeysetItem.order(:id))
      rescoped = connection.rescoped { |relation| relation.where.not(id: nil) }
      schema = plain_schema(plain_cursors: true)

      result = execute_query(schema, document, root_value: controls::Root.example(rescoped))

      expect(result.dig("data", "items", "nodes").size).to eq(1)
    end
  end
end
