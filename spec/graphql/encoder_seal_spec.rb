# frozen_string_literal: true

require "spec_helper"
require "openssl"

# `Encoder.seal`/`open` encrypt arbitrary bytes for storage (response cache entries) and `Encoder.mac` gives keyed
# digests (cache keys and tags), each under a subkey of its own purpose, so none of them is ever accepted as an ID or
# a cursor, and IDs and cursors stay exactly what they were.
RSpec.describe "Encoder sealing and keyed digests" do
  let(:encoder_class) { GraphQL::Armory::Encoder }
  let(:invalid_error) { GraphQL::Armory::Encoder::InvalidError }
  let(:configuration_error) { GraphQL::Armory::Encoder::ConfigurationError }
  let(:encoder) { encoder_with(key: "k" * 32) }
  let(:bytes) { "{\"data\":{\"invoice\":{\"total\":\"9.99\"}}}" }

  def encoder_with(key:, tag: nil)
    Class.new(encoder_class) do
      key(key)
      tag(tag) if tag
    end
  end

  def invalid(&block)
    expect(&block).to raise_error(invalid_error, "Invalid ID or cursor")
  end

  # Changes one character of the text, at `index`, into another base64url character.
  def tampered(text, index)
    text.dup.tap { |copy| copy[index] = copy[index] == "A" ? "B" : "A" }
  end

  describe "seal and open" do
    it "round-trips bytes under the same additional data and purpose, answering binary bytes" do
      sealed = encoder.seal(bytes, aad: "entry:abc", purpose: "cache")
      opened = encoder.open(sealed, aad: "entry:abc", purpose: "cache")

      expect([opened, opened.encoding]).to eq([bytes.b, Encoding::BINARY])
    end

    it "answers base64url text that hides the plaintext and differs on every seal (random nonce)" do
      first = encoder.seal(bytes, aad: "a", purpose: "cache")
      second = encoder.seal(bytes, aad: "a", purpose: "cache")

      expect(first).to match(/\A[A-Za-z0-9_-]+\z/)
      expect([first == second, first.include?("invoice"), first.include?(Base64.urlsafe_encode64(bytes, padding: false)[0, 12])])
        .to eq([false, false, false])
    end

    it "round-trips empty bytes and bytes that are not UTF-8" do
      binary = "\xFF\x00\xFE".b

      expect([encoder.open(encoder.seal("", aad: "", purpose: "cache"), aad: "", purpose: "cache"),
              encoder.open(encoder.seal(binary, aad: "", purpose: "cache"), aad: "", purpose: "cache")]).to eq(["".b, binary])
    end

    it "does not open under other additional data: a value moved to another key fails" do
      sealed = encoder.seal(bytes, aad: "entry:abc", purpose: "cache")

      invalid { encoder.open(sealed, aad: "entry:abd", purpose: "cache") }
    end

    it "does not open under another purpose" do
      sealed = encoder.seal(bytes, aad: "a", purpose: "cache")

      invalid { encoder.open(sealed, aad: "a", purpose: "cache-other") }
    end

    it "does not open with another key or another tag" do
      sealed = encoder.seal(bytes, aad: "a", purpose: "cache")

      invalid { encoder_with(key: "j" * 32).open(sealed, aad: "a", purpose: "cache") }
      invalid { encoder_with(key: "k" * 32, tag: "other-app").open(sealed, aad: "a", purpose: "cache") }
    end

    it "binds the tag: a value sealed under a tag opens only under that tag" do
      tagged = encoder_with(key: "k" * 32, tag: "v1")
      sealed = tagged.seal(bytes, aad: "a", purpose: "cache")

      expect(tagged.open(sealed, aad: "a", purpose: "cache")).to eq(bytes.b)
      invalid { encoder.open(sealed, aad: "a", purpose: "cache") }
    end

    it "refuses a value with any character changed, truncated, empty, padded, or not a String, with the same error" do
      sealed = encoder.seal(bytes, aad: "a", purpose: "cache")

      [0, 8, 16, sealed.length / 2, sealed.length - 1].each { |index| invalid { encoder.open(tampered(sealed, index), aad: "a", purpose: "cache") } }
      invalid { encoder.open(sealed[0...-1], aad: "a", purpose: "cache") }
      invalid { encoder.open(sealed[0, 20], aad: "a", purpose: "cache") }
      invalid { encoder.open("", aad: "a", purpose: "cache") }
      invalid { encoder.open("#{sealed}=", aad: "a", purpose: "cache") }
      invalid { encoder.open("not base64!", aad: "a", purpose: "cache") }
      invalid { encoder.open(nil, aad: "a", purpose: "cache") }
    end

    it "never opens an ID or a cursor, and a sealed value never decodes as either" do
      id = encoder.encode("Invoice/42")
      cursor = encoder.encode("10", nonce: true)
      sealed = encoder.seal("Invoice/42", aad: "", purpose: "cache")

      invalid { encoder.open(id, aad: "", purpose: "cache") }
      invalid { encoder.open(cursor, aad: "", purpose: "cache") }
      invalid { encoder.decode(sealed) }
      invalid { encoder.decode(sealed, nonce: true) }
    end

    it "refuses a purpose that is not lowercase words joined by dashes, and additional data that is not a String" do
      [nil, "", "Cache", "cache/x", "cache digest", :cache, "-cache"].each do |purpose|
        expect { encoder.seal(bytes, aad: "a", purpose: purpose) }.to raise_error(ArgumentError, /purpose/)
        expect { encoder.open("x", aad: "a", purpose: purpose) }.to raise_error(ArgumentError, /purpose/)
        expect { encoder.mac(bytes, purpose: purpose) }.to raise_error(ArgumentError, /purpose/)
      end
      expect { encoder.seal(bytes, aad: nil, purpose: "cache") }.to raise_error(ArgumentError, /aad/)
      expect { encoder.open("x", aad: 1, purpose: "cache") }.to raise_error(ArgumentError, /aad/)
      expect { encoder.seal(nil, aad: "a", purpose: "cache") }.to raise_error(ArgumentError, /bytes/)
    end

    it "refuses to seal, open or mac without a key, naming the missing key" do
      keyless = Class.new(encoder_class)

      expect { keyless.seal(bytes, aad: "a", purpose: "cache") }.to raise_error(configuration_error, /key/)
      expect { keyless.open("x" * 40, aad: "a", purpose: "cache") }.to raise_error(configuration_error, /key/)
      expect { keyless.mac(bytes, purpose: "cache-digest") }.to raise_error(configuration_error, /key/)
    end

    it "is inherited by the default encoder and by subclasses" do
      default = encoder_class.default(env: { "GRAPHQL_ARMORY_KEY" => "d" * 32 }, rails: nil)
      child = Class.new(encoder)

      expect(default.open(default.seal(bytes, aad: "a", purpose: "cache"), aad: "a", purpose: "cache")).to eq(bytes.b)
      expect(child.open(encoder.seal(bytes, aad: "a", purpose: "cache"), aad: "a", purpose: "cache")).to eq(bytes.b)
    end
  end

  describe "mac" do
    it "answers the raw 32-byte HMAC, the same every time" do
      mac = encoder.mac("viewer:[\"User\",7]", purpose: "cache-digest")

      expect([mac.bytesize, mac.encoding, encoder.mac("viewer:[\"User\",7]", purpose: "cache-digest") == mac]).to eq([32, Encoding::BINARY, true])
    end

    it "differs per bytes, purpose, key and tag, and is not an HMAC under the raw key" do
      mac = encoder.mac("tag:pricing", purpose: "cache-digest")
      others = [
        encoder.mac("tag:pricinh", purpose: "cache-digest"),
        encoder.mac("tag:pricing", purpose: "cache"),
        encoder_with(key: "j" * 32).mac("tag:pricing", purpose: "cache-digest"),
        encoder_with(key: "k" * 32, tag: "v1").mac("tag:pricing", purpose: "cache-digest"),
        OpenSSL::HMAC.digest("SHA256", "k" * 32, "tag:pricing")
      ]

      expect(others).to all(satisfy { |other| other != mac })
    end

    it "feeds the caching Digester, which answers 64 hex characters shared by every Digester built on the encoder" do
      digester = GraphQL::Armory::Caching::Digester.build(encoder: encoder)

      expect(digester.("tag:pricing")).to match(/\A\h{64}\z/)
      expect(digester.("tag:pricing")).to eq(GraphQL::Armory::Caching::Digester.build(encoder: encoder).("tag:pricing"))
      expect(digester.("tag:pricing")).to eq(encoder.mac("tag:pricing", purpose: "cache-digest").unpack1("H*"))
    end
  end

  describe "IDs and cursors are unchanged" do
    # Handed out by the encoder before sealing existed (pinned at 2d489ac): they must keep decoding, and IDs must
    # keep encoding to exactly the same text.
    let(:pinned_id) { "BmDENctMgo1Scn0UJR4miaTpXtzhCwV4k4qAux9Lqxb9WvwiKtI" }
    let(:pinned_tagged_id) { "mZTzSuh4IJ2oU-1WxGmBIpR9WDzDjd6K_HGiCl_LWHa0Kp65BG0" }
    let(:pinned_cursor) { "Muy8VSzON0TeJ76m5YDDYNqwgYPrW7yoXIRY2ZDg" }

    it "encodes an ID byte for byte as before, with and without a tag" do
      expect([encoder.encode("Invoice/42"), encoder_with(key: "k" * 32, tag: "v1").encode("Invoice/42")]).to eq([pinned_id, pinned_tagged_id])
    end

    it "decodes the IDs and cursors handed out before" do
      expect([encoder.decode(pinned_id), encoder.decode(pinned_cursor, nonce: true)]).to eq(["Invoice/42", "10"])
    end

    it "keeps them unchanged after the encoder sealed, opened and digested" do
      encoder.open(encoder.seal(bytes, aad: "a", purpose: "cache"), aad: "a", purpose: "cache")
      encoder.mac(bytes, purpose: "cache-digest")

      expect([encoder.encode("Invoice/42"), encoder.decode(pinned_cursor, nonce: true)]).to eq([pinned_id, "10"])
    end
  end

  describe "a versioned chain" do
    let(:old) { encoder_with(key: "o" * 32) }
    let(:chain) { encoder_class.versioned(encoder, old, encoder_class::Legacy) }

    it "seals with its newest encoder" do
      sealed = chain.seal(bytes, aad: "a", purpose: "cache")

      expect(encoder.open(sealed, aad: "a", purpose: "cache")).to eq(bytes.b)
      invalid { old.open(sealed, aad: "a", purpose: "cache") }
    end

    it "opens what any of its encoders sealed, and refuses what none opens with the same error" do
      sealed_by_old = old.seal(bytes, aad: "a", purpose: "cache")

      expect(chain.open(sealed_by_old, aad: "a", purpose: "cache")).to eq(bytes.b)
      invalid { chain.open(sealed_by_old, aad: "b", purpose: "cache") }
      invalid { chain.open(encoder_with(key: "x" * 32).seal(bytes, aad: "a", purpose: "cache"), aad: "a", purpose: "cache") }
    end

    it "digests with its newest encoder" do
      expect(chain.mac(bytes, purpose: "cache-digest")).to eq(encoder.mac(bytes, purpose: "cache-digest"))
    end

    it "refuses to seal or digest when its newest member does not encrypt, and still refuses bad arguments" do
      legacy_first = encoder_class.versioned(encoder_class::Legacy, encoder)

      expect { legacy_first.seal(bytes, aad: "a", purpose: "cache") }.to raise_error(configuration_error, /Legacy/)
      expect { legacy_first.mac(bytes, purpose: "cache-digest") }.to raise_error(configuration_error, /Legacy/)
      expect(legacy_first.open(encoder.seal(bytes, aad: "a", purpose: "cache"), aad: "a", purpose: "cache")).to eq(bytes.b)
      expect { chain.open("x", aad: "a", purpose: "Cache") }.to raise_error(ArgumentError, /purpose/)
    end

    it "skips members that cannot open, such as a custom ID encoder, and refuses to seal with one" do
      custom = Module.new do
        def self.encode(text, nonce: false) = text
        def self.decode(text, nonce: false) = text
      end

      expect(encoder_class.versioned(custom, encoder).open(encoder.seal(bytes, aad: "a", purpose: "cache"), aad: "a", purpose: "cache")).to eq(bytes.b)
      expect { encoder_class.versioned(custom, encoder).seal(bytes, aad: "a", purpose: "cache") }.to raise_error(configuration_error, /cannot seal/)
    end

    it "keeps encoding and decoding IDs as before" do
      expect([chain.encode("Invoice/42"), chain.decode(old.encode("Invoice/42"))]).to eq([encoder.encode("Invoice/42"), "Invoice/42"])
    end
  end

  describe "encoders that do not encrypt" do
    [GraphQL::Armory::Encoder::Null, GraphQL::Armory::Encoder::Legacy].each do |plain|
      it "#{plain.name.split("::").last} refuses to seal and to digest, and opens nothing" do
        expect { plain.seal(bytes, aad: "a", purpose: "cache") }.to raise_error(configuration_error, /cannot seal/)
        expect { plain.mac(bytes, purpose: "cache-digest") }.to raise_error(configuration_error, /cannot digest/)
        invalid { plain.open(encoder.seal(bytes, aad: "a", purpose: "cache"), aad: "a", purpose: "cache") }
        invalid { plain.open(Base64.urlsafe_encode64(bytes, padding: false), aad: "a", purpose: "cache") }
      end
    end

    it "Legacy still reads and writes graphql-ruby's base64, and Null still hands out nothing" do
      legacy = GraphQL::Armory::Encoder::Legacy

      expect([legacy.encode("Invoice/42"), legacy.decode("SW52b2ljZS80Mg")]).to eq(%w[SW52b2ljZS80Mg Invoice/42])
      expect { GraphQL::Armory::Encoder::Null.encode("Invoice/42") }.to raise_error(configuration_error)
      invalid { GraphQL::Armory::Encoder::Null.decode("SW52b2ljZS80Mg") }
    end
  end

  describe "Encoder::Substitute" do
    let(:substitute) { GraphQL::Armory::Encoder::Substitute.new }

    it "seals reversibly, binding the additional data and purpose, and records each call" do
      sealed = substitute.seal(bytes, aad: "a", purpose: "cache")

      expect(substitute.open(sealed, aad: "a", purpose: "cache")).to eq(bytes.b)
      invalid { substitute.open(sealed, aad: "b", purpose: "cache") }
      invalid { substitute.open(sealed, aad: "a", purpose: "cache-digest") }
      expect(substitute.sealed).to eq([{ bytes: bytes.b, aad: "a", purpose: "cache" }])
      expect(substitute.opened.map { |call| call[:aad] }).to eq(%w[a b a])
    end

    it "answers a 32-byte digest per purpose and records it" do
      mac = substitute.mac("tag:pricing", purpose: "cache-digest")

      expect([mac.bytesize, mac == substitute.mac("tag:pricing", purpose: "cache"), substitute.macs.size]).to eq([32, false, 2])
      expect(GraphQL::Armory::Caching::Digester.build(encoder: substitute).("tag:pricing")).to eq(mac.unpack1("H*"))
    end

    it "keeps sealed values and IDs apart" do
      invalid { substitute.decode(substitute.seal(bytes, aad: "a", purpose: "cache")) }
      invalid { substitute.open(substitute.encode("Invoice/42"), aad: "a", purpose: "cache") }
    end

    it "fails when told, on seal, open and mac" do
      sealed = substitute.seal(bytes, aad: "a", purpose: "cache")
      substitute.fail_with(IOError.new("down"))

      expect { substitute.seal(bytes, aad: "a", purpose: "cache") }.to raise_error(IOError)
      expect { substitute.open(sealed, aad: "a", purpose: "cache") }.to raise_error(IOError)
      expect { substitute.mac(bytes, purpose: "cache-digest") }.to raise_error(IOError)
      substitute.recover
      expect(substitute.open(sealed, aad: "a", purpose: "cache")).to eq(bytes.b)
    end
  end

  it "never uses Marshal in the encoder or the cache codec" do
    root = File.expand_path("../../lib/graphql/armory", __dir__)
    files = [File.join(root, "encoder.rb"), *Dir[File.join(root, "encoder", "*.rb")], File.join(root, "caching", "codec.rb")]

    expect(files.select { |file| File.exist?(file) }.size).to eq(files.size)
    expect(files.select { |file| File.read(file).include?("Marshal") }).to eq([])
  end
end
