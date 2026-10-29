# frozen_string_literal: true

require "base64"

# A versioned chain encodes with its newest encoder and still reads what older ones handed out, so a key can be
# rotated, or encryption introduced, without breaking IDs and cursors clients already hold.
RSpec.describe "Versioned encoders" do
  let(:armory) { GraphQL::Armory }
  let(:newest) { Class.new(armory::Encoder) { key("n" * 32) } }
  let(:older) { Class.new(armory::Encoder) { key("o" * 32) } }
  let(:chain) { armory::Encoder.versioned(newest, older) }

  def invalid(&block)
    expect(&block).to raise_error(armory::Encoder::InvalidError, "Invalid ID or cursor")
  end

  it "encodes IDs and cursors with the newest encoder" do
    expect([newest.decode(chain.encode("Invoice/42")), newest.decode(chain.encode("10", nonce: true), nonce: true)])
      .to eq(["Invoice/42", "10"])
  end

  it "decodes what any encoder of the chain handed out" do
    expect([chain.decode(older.encode("Invoice/42")), chain.decode(older.encode("10", nonce: true), nonce: true)])
      .to eq(["Invoice/42", "10"])
  end

  it "tells which encoder decoded a value, and nothing when none did" do
    expect([chain.decode_versioned(older.encode("Invoice/42")), chain.decode_versioned("garbage")])
      .to eq([["Invoice/42", older], [nil, nil]])
  end

  it "stops accepting an encoder's values once it leaves the chain" do
    invalid { armory::Encoder.versioned(newest).decode(older.encode("Invoice/42")) }
  end

  it "refuses a value no encoder accepts, with the same error as one encoder" do
    invalid { chain.decode(newest.encode("Invoice/42").reverse) }
  end

  it "does not accept a cursor as an ID through the chain" do
    invalid { chain.decode(older.encode("42", nonce: true)) }
  end

  it "refuses an empty chain and members that cannot encode and decode" do
    expect { armory::Encoder.versioned }.to raise_error(armory::Encoder::ConfigurationError, /at least one/)
    expect { armory::Encoder.versioned(newest, Object.new) }.to raise_error(armory::Encoder::ConfigurationError, /encode and decode/)
  end

  it "fails at boot for a member without a key or whose decode does not take nonce:" do
    plain = Module.new do
      def self.encode(text) = text
      def self.decode(text) = text
    end

    expect { armory::Encoder.versioned(newest, Class.new(armory::Encoder)) }.to raise_error(armory::Encoder::ConfigurationError, /no key/)
    expect { armory::Encoder.versioned(newest, plain) }.to raise_error(armory::Encoder::ConfigurationError, /nonce:/)
  end

  it "does not count a member that answers nil as having decoded the value" do
    silent = Module.new do
      def self.encode(text, nonce: false) = text
      def self.decode(_text, nonce: false) = nil
    end

    expect(armory::Encoder.versioned(silent).decode_versioned("x")).to eq([nil, nil])
  end

  describe "Legacy, graphql-ruby's base64" do
    let(:legacy) { armory::Encoder::Legacy }
    let(:migrating) { armory::Encoder.versioned(newest, legacy) }

    it "reads graphql-ruby's default cursors and base64 IDs, padded or not, url-safe or standard" do
      ids = [Base64.urlsafe_encode64("10", padding: false), Base64.strict_encode64("Invoice-42"), Base64.urlsafe_encode64("Invoice/4?2~")]

      expect([migrating.decode(ids[0], nonce: true), migrating.decode(ids[1]), migrating.decode(ids[2]), migrating.decode_versioned(ids[1]).last])
        .to eq(["10", "Invoice-42", "Invoice/4?2~", legacy])
    end

    it "writes like graphql-ruby's default when it is the newest" do
      expect(legacy.encode("10", nonce: true)).to eq(GraphQL::Schema::Base64Encoder.encode("10"))
    end

    it "does not turn a tampered encrypted ID into garbage text" do
      invalid { migrating.decode(newest.encode("Invoice/42").reverse) }
    end

    it "refuses base64 that does not hold printable text" do
      invalid { legacy.decode(Base64.strict_encode64("\x00\xFF binary".b)) }
      invalid { legacy.decode("%%%") }
      ["=", "==", "===", ""].each { |text| invalid { legacy.decode(text) } }
    end
  end

  describe "as the schema's cursor_encoder" do
    def schema_with(cursor_encoder)
      item = Class.new(GraphQL::Schema::Object) do
        graphql_name "Item"
        field :name, String, null: false, hash_key: :name
      end
      query = Class.new(GraphQL::Schema::Object) do
        graphql_name "Query"
        field :items, item.connection_type, null: false, hash_key: :items
      end
      Class.new(ArmoryEngine.base_schema) do
        query query
        cursor_encoder cursor_encoder
      end
    end

    def names_after(schema, cursor)
      execute_query(schema, "query($after: String) { items(first: 2, after: $after) { nodes { name } } }",
                    variables: { "after" => cursor }, root_value: { items: %w[a b c d].map { |name| { name: name } } })
        .to_h.dig("data", "items", "nodes")&.map { |node| node["name"] }
    end

    it "keeps old cursors working after rotating the key, and after adding encryption" do
      rotated = schema_with(chain)
      encrypted = schema_with(armory::Encoder.versioned(newest, armory::Encoder::Legacy))

      expect([names_after(rotated, older.encode("2", nonce: true)), names_after(encrypted, GraphQL::Schema::Base64Encoder.encode("2"))])
        .to eq([%w[c d], %w[c d]])
    end
  end
end
