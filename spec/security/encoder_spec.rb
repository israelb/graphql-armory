# frozen_string_literal: true

require "base64"

# IDs and cursors leave the server encrypted and authenticated: a client cannot read them, guess the next one,
# forge one, or turn a cursor into an ID. Whatever fails to decode fails the same way, without saying why.
RSpec.describe GraphQL::Armory::Encoder do
  let(:key) { "k" * 32 }
  let(:encoder) { encoder_with(key: key) }

  def encoder_with(key:, tag: nil, codec: nil)
    Class.new(described_class) do
      key(key)
      tag(tag) if tag
      codec(codec) if codec
    end
  end

  def invalid(&block)
    expect(&block).to raise_error(GraphQL::Armory::Encoder::InvalidError, "Invalid ID or cursor")
  end

  # Changes one character of the encoded text, at `index`, into another valid base64url character.
  def tampered(text, index)
    text.dup.tap { |copy| copy[index] = copy[index] == "A" ? "B" : "A" }
  end

  describe "IDs" do
    it "round-trips, and the same input always gives the same ID" do
      id = encoder.encode("Invoice/42")

      expect([encoder.decode(id), encoder.encode("Invoice/42")]).to eq(["Invoice/42", id])
    end

    it "does not show the plaintext, even as base64" do
      id = encoder.encode("Invoice/42")

      expect([id.include?("Invoice"), id.include?(Base64.urlsafe_encode64("Invoice/42", padding: false))]).to eq([false, false])
    end

    it "gives two IDs different nonces, so encrypting many never repeats one" do
      nonces = %w[Invoice/42 Invoice/43].map { |text| Base64.urlsafe_decode64(encoder.encode(text))[0, 12] }

      expect(nonces.uniq.size).to eq(2)
    end

    it "round-trips text that is not ASCII" do
      expect(encoder.decode(encoder.encode("Factura/ñ-✓"))).to eq("Factura/ñ-✓")
    end
  end

  describe "cursors" do
    it "round-trips, and the same input gives a different cursor every time" do
      first = encoder.encode("10", nonce: true)
      second = encoder.encode("10", nonce: true)

      expect([first == second, encoder.decode(first, nonce: true), encoder.decode(second, nonce: true)]).to eq([false, "10", "10"])
    end
  end

  describe "what fails to decode" do
    it "refuses an ID with any character changed" do
      id = encoder.encode("Invoice/42")

      [0, id.size / 2, id.size - 1].each { |index| invalid { encoder.decode(tampered(id, index)) } }
    end

    it "refuses an ID made with another key" do
      invalid { encoder.decode(encoder_with(key: "x" * 32).encode("Invoice/42")) }
    end

    it "refuses an ID made with another tag" do
      invalid { encoder_with(key: key, tag: "v2").decode(encoder_with(key: key, tag: "v1").encode("Invoice/42")) }
    end

    it "does not accept a cursor as an ID, nor an ID as a cursor" do
      invalid { encoder.decode(encoder.encode("42", nonce: true)) }
      invalid { encoder.decode(encoder.encode("42"), nonce: true) }
    end

    it "refuses malformed, empty and truncated input with the same message" do
      id = encoder.encode("Invoice/42")

      ["%%%", "", "abc", id[0, 20], Base64.urlsafe_encode64("Invoice/42")].each { |text| invalid { encoder.decode(text) } }
    end
  end

  describe "configuration" do
    it "refuses a key shorter than 32 bytes" do
      expect { encoder_with(key: "short") }.to raise_error(GraphQL::Armory::Encoder::ConfigurationError, /32 bytes/)
    end

    it "refuses to encode without a key" do
      expect { Class.new(described_class).encode("x") }.to raise_error(GraphQL::Armory::Encoder::ConfigurationError, /key/)
    end

    it "lets a subclass inherit the key and override the tag" do
      parent = encoder_with(key: key, tag: "v1")
      child = Class.new(parent) { tag("v2") }

      invalid { parent.decode(child.encode("Invoice/42")) }
      expect(child.decode(child.encode("Invoice/42"))).to eq("Invoice/42")
    end

    it "writes the bytes with a custom codec" do
      hex = Module.new do
        def self.encode(bytes) = bytes.unpack1("H*")
        def self.decode(text) = [text].pack("H*")
      end
      hex_encoder = encoder_with(key: key, codec: hex)
      id = hex_encoder.encode("Invoice/42")

      expect([id.match?(/\A\h+\z/), hex_encoder.decode(id)]).to eq([true, "Invoice/42"])
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

    let(:schema) { schema_with(encoder) }
    let(:root) { { items: %w[a b c d].map { |name| { name: name } } } }

    def page(after: nil)
      execute_query(schema, "query($after: String) { items(first: 2, after: $after) { nodes { name } pageInfo { endCursor } } }",
                    variables: { "after" => after }, root_value: root).to_h
    end

    it "paginates with encrypted cursors" do
      first = page
      cursor = first.dig("data", "items", "pageInfo", "endCursor")

      expect([first.dig("data", "items", "nodes"), page(after: cursor).dig("data", "items", "nodes")])
        .to eq([[{ "name" => "a" }, { "name" => "b" }], [{ "name" => "c" }, { "name" => "d" }]])
    end

    it "answers a tampered cursor with an error, not with another page" do
      cursor = page.dig("data", "items", "pageInfo", "endCursor")
      result = page(after: tampered(cursor, cursor.size / 2))

      # graphql-ruby decodes the cursor once per selection (nodes, pageInfo), so the error may repeat.
      expect([result.dig("data", "items", "nodes"), result["errors"].map { |error| error["message"] }.uniq]).to eq([nil, ["Invalid ID or cursor"]])
    end
  end
end
