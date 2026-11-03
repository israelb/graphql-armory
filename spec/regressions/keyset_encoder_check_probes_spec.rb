# frozen_string_literal: true

# Probes kept from the verification of C5 (Keyset encoder check at schema load), PR #52. Each `it` is labelled security or preservation.
require "base64"
require "json"
require "zlib"
require "uri"
require "openssl"
require "securerandom"
require "active_support"
require "active_support/message_verifier"
require "active_support/message_encryptor"

RSpec.describe "C5 probes" do
  keyset = GraphQL::Armory::Keyset
  armory = GraphQL::Armory::IDs::Controls::Encoder.example

  shape = lambda do |transform, back|
    Module.new do
      define_singleton_method(:encode) { |text, nonce: false| transform.(text) }
      define_singleton_method(:decode) { |text, nonce: false| back.(text) }
    end
  end
  b64u = ->(bytes) { Base64.urlsafe_encode64(bytes, padding: false) }
  unb64u = ->(text) { Base64.urlsafe_decode64(text) }
  identity = shape.(->(t) { t }, ->(t) { t })

  cipher = lambda do |name, iv|
    key = SecureRandom.random_bytes(32)
    enc = lambda do |text|
      c = OpenSSL::Cipher.new(name).encrypt
      c.key = key
      c.iv = iv if iv
      c.auth_data = "" if name.end_with?("gcm")
      out = c.update(text.b) + c.final
      out += c.auth_tag if name.end_with?("gcm")
      b64u.(out)
    end
    dec = lambda do |text|
      bytes = unb64u.(text)
      c = OpenSSL::Cipher.new(name).decrypt
      c.key = key
      c.iv = iv if iv
      if name.end_with?("gcm")
        c.auth_tag = bytes[-16..]
        c.auth_data = ""
        bytes = bytes[0...-16]
      end
      (c.update(bytes) + c.final).force_encoding("UTF-8")
    end
    shape.(enc, dec)
  end

  base32 = lambda do |text|
    alphabet = ("A".."Z").to_a + ("2".."7").to_a
    text.b.unpack1("B*").scan(/.{1,5}/).map { |bits| alphabet[bits.ljust(5, "0").to_i(2)] }.join
  end
  unbase32 = lambda do |text|
    alphabet = ("A".."Z").to_a + ("2".."7").to_a
    bits = text.chars.map { |ch| alphabet.index(ch).to_s(2).rjust(5, "0") }.join
    [bits[0, bits.size - (bits.size % 8)]].pack("B*").force_encoding("UTF-8")
  end
  std = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  rotated = std.chars.rotate(7).join

  legacy_like = lambda do |decoder|
    Module.new do
      define_singleton_method(:encode) { |text, nonce: false| text }
      define_singleton_method(:decode) { |text, nonce: false| decoder.(text) }
    end
  end

  not_private = {
    "Base64 with another alphabet" => shape.(->(t) { Base64.strict_encode64(t).tr(std, rotated) }, ->(t) { Base64.strict_decode64(t.tr(rotated, std)) }),
    "Base32" => shape.(base32, unbase32),
    "URL-escaped text" => shape.(->(t) { URI.encode_www_form_component(t) }, ->(t) { URI.decode_www_form_component(t) }),
    "deflate of plain text, raw" => shape.(->(t) { Zlib::Deflate.deflate(t) }, ->(t) { Zlib::Inflate.inflate(t) }),
    "gzip-like deflate in Base64" => shape.(->(t) { b64u.(Zlib::Deflate.deflate(t)) }, ->(t) { Zlib::Inflate.inflate(unb64u.(t)) }),
    "JSON with a key renamed" => shape.(->(t) { h = JSON.parse(t); JSON.generate(h.transform_keys { |k| "x#{k}" }) },
                                        ->(t) { JSON.generate(JSON.parse(t).transform_keys { |k| k.delete_prefix("x") }) }),
    "Marshal (MessagePack stand-in)" => shape.(->(t) { Marshal.dump(t) }, ->(t) { Marshal.load(t) }),
    "Base64 split by newlines" => shape.(->(t) { [t].pack("m") }, ->(t) { t.unpack1("m") }),
    "Base64 split by dots" => shape.(->(t) { b64u.(t).scan(/.{1,6}/).join(".") }, ->(t) { unb64u.(t.delete(".")) }),
    "double Base64" => shape.(->(t) { b64u.(b64u.(t)) }, ->(t) { unb64u.(unb64u.(t)) }),
    "values split by a byte" => shape.(->(t) { t.chars.join("\x01") }, ->(t) { t.delete("\x01") }),
    "AES-256-GCM with a fixed nonce" => cipher.("aes-256-gcm", "\0" * 12),
    "AES-256-ECB" => cipher.("aes-256-ecb", nil),
    "AES-256-CBC with a fixed IV" => cipher.("aes-256-cbc", "\0" * 16),
    "Base64 with a long random suffix" => shape.(->(t) { "#{b64u.(t)}.#{SecureRandom.hex(300)}" }, ->(t) { unb64u.(t.split(".").first) }),
    "Base64 behind a long random alphanumeric prefix" => shape.(->(t) { SecureRandom.alphanumeric(301) + b64u.(t) }, ->(t) { unb64u.(t[301..]) }),
    "MessageVerifier (signed, not encrypted)" => (lambda do
      verifier = ActiveSupport::MessageVerifier.new(SecureRandom.hex(32), digest: "SHA256", serializer: JSON)
      shape.(->(t) { verifier.generate(t) }, ->(t) { verifier.verify(t) })
    end).call,
    "a chain with graphql-ruby's Base64Encoder last" => GraphQL::Armory::Encoder.versioned(armory, GraphQL::Schema::Base64Encoder),
    "a chain with a hex legacy last" => GraphQL::Armory::Encoder.versioned(armory, legacy_like.(->(t) { raise ArgumentError unless t.match?(/\A\h+\z/); [t].pack("H*").force_encoding("UTF-8") })),
    "a chain with a prefixed Base64 legacy last" => GraphQL::Armory::Encoder.versioned(armory, legacy_like.(->(t) { raise ArgumentError unless t.start_with?("c:"); unb64u.(t.delete_prefix("c:")).force_encoding("UTF-8") }))
  }

  define_method(:schema_with) do |encoder, **options|
    Class.new(GraphQL::Schema) do
      cursor_encoder encoder
      use keyset, **options
    end
  end

  it "environment: graphql version and engine" do
    puts "\n[env] GraphQL::VERSION=#{GraphQL::VERSION} engine=#{ArmoryEngine.current} ruby=#{RUBY_VERSION}"
  end

  # S1: non-private encoders refused at load
  not_private.each do |name, encoder|
    it "security: refuses #{name}" do
      expect { schema_with(encoder) }.to raise_error(keyset::ConfigurationError, /cursor_encoder/)
    end
  end

  # S2: sound encoders accepted
  sound = {
    "MessageEncryptor AES-256-GCM" => (lambda do
      encryptor = ActiveSupport::MessageEncryptor.new(SecureRandom.random_bytes(32), cipher: "aes-256-gcm", serializer: JSON)
      shape.(->(t) { encryptor.encrypt_and_sign(t) }, ->(t) { encryptor.decrypt_and_verify(t) })
    end).call,
    "a short random server-side token" => (lambda do
      store = {}
      shape.(->(t) { SecureRandom.alphanumeric(8).tap { |token| store[token] = t } }, ->(t) { store.fetch(t) })
    end).call,
    "the Armory encoder with a long output" => shape.(->(t) { "#{armory.encode(t, nonce: true)}.#{SecureRandom.hex(500)}" }, ->(t) { armory.decode(t.split(".").first, nonce: true) }),
    "the Armory encoder answering frozen Strings" => shape.(->(t) { armory.encode(t, nonce: true).freeze }, ->(t) { armory.decode(t, nonce: true).freeze }),
    "the Armory encoder decoding to US-ASCII" => shape.(->(t) { armory.encode(t, nonce: true) }, ->(t) { armory.decode(t, nonce: true).dup.force_encoding("US-ASCII") }),
    "the Armory encoder ignoring nonce: (deterministic, SIV-like)" => shape.(->(t) { armory.encode(t, nonce: false) }, ->(t) { armory.decode(t, nonce: false) }),
    "an Encoder subclass with its own key" => Class.new(GraphQL::Armory::Encoder) { key SecureRandom.hex(32) },
    "a subclass of an Encoder subclass" => Class.new(Class.new(GraphQL::Armory::Encoder) { key SecureRandom.hex(32) }) { tag "v2" }
  }
  sound.each do |name, encoder|
    it "preservation: accepts #{name}" do
      expect { schema_with(encoder) }.not_to raise_error
    end
  end

  it "preservation: refuses (correctly) an encoder that raises only on nonce: true, naming the class" do
    only_ids = Module.new do
      define_singleton_method(:encode) { |t, nonce: false| raise ArgumentError, "ids only s3cret" if nonce; t }
      define_singleton_method(:decode) { |t, nonce: false| t }
    end
    expect { schema_with(only_ids) }.to raise_error(keyset::ConfigurationError) { |e|
      expect(e.message).to include("ArgumentError")
      expect(e.message).not_to include("s3cret")
    }
  end

  it "preservation: an Encoder with no key yet is refused, naming only the class" do
    keyless = Class.new(GraphQL::Armory::Encoder)
    expect { schema_with(keyless) }.to raise_error(keyset::ConfigurationError, /Encoder::ConfigurationError/)
  end

  # S4: messages
  it "security: an encoder raising Keyset::ConfigurationError does not leak its message" do
    leaky = shape.(->(_t) { raise keyset::ConfigurationError, "key=s3cret" }, ->(t) { t })
    expect { schema_with(leaky) }.to raise_error(keyset::ConfigurationError) { |e| expect(e.message).not_to include("s3cret") }
  end

  it "security: an encoder raising NotImplementedError (not a StandardError) gives a ConfigurationError without its message" do
    stub = shape.(->(_t) { raise NotImplementedError, "key=s3cret" }, ->(t) { t })
    expect { schema_with(stub) }.to raise_error(keyset::ConfigurationError) { |e| expect(e.message).not_to include("s3cret") }
  end

  it "security: the error for a forged-text decoder holds neither the probe output nor the encoder" do
    chain = GraphQL::Armory::Encoder.versioned(armory, GraphQL::Armory::Encoder::Legacy)
    expect { schema_with(chain) }.to raise_error(keyset::ConfigurationError) { |e|
      expect(e.message).not_to include("graphql-armory-probe")
      expect(e.message).not_to include("Versioned")
    }
  end

  # S3: later encoders
  describe "later encoders" do
    it "security: a named `class Child < Parent` setting identity is refused" do
      holder = Module.new
      holder.const_set(:Parent, schema_with(armory))
      holder.const_set(:Bad, identity)
      expect { holder.module_eval("class Child < Parent; cursor_encoder Bad; end", __FILE__, __LINE__) }.to raise_error(keyset::ConfigurationError)
    end

    it "security: a grandchild through an intermediate subclass is checked" do
      mid = Class.new(schema_with(armory))
      expect { Class.new(mid) { cursor_encoder identity } }.to raise_error(keyset::ConfigurationError)
    end

    it "security: a schema built on the engine base (with Execution::Next when present) is checked later" do
      parent = Class.new(ArmoryEngine.base_schema) { cursor_encoder GraphQL::Armory::IDs::Controls::Encoder.example; use GraphQL::Armory::Keyset }
      expect { parent.cursor_encoder(identity) }.to raise_error(keyset::ConfigurationError)
      expect { Class.new(parent) { cursor_encoder GraphQL::Schema::Base64Encoder } }.to raise_error(keyset::ConfigurationError)
    end

    it "security: there is no cursor_encoder= writer to bypass the check" do
      expect(schema_with(armory).respond_to?(:cursor_encoder=)).to be(false)
    end

    it "security: method(:cursor_encoder).owner is SchemaChecks on the schema and its subclasses" do
      parent = schema_with(armory)
      child = Class.new(parent)
      grandchild = Class.new(child)
      owners = [parent, child, grandchild].map { |s| s.method(:cursor_encoder).owner }
      puts "\n[owner] #{owners.inspect}"
      expect(owners).to all(eq(keyset::SchemaChecks))
    end

    it "security: a cooperative module extended after use still goes through the check" do
      schema = schema_with(armory)
      schema.extend(Module.new { def cursor_encoder(new_encoder = nil) = super })
      expect { schema.cursor_encoder(identity) }.to raise_error(keyset::ConfigurationError)
    end

    it "security: use twice, plain true then false, re-checks the encoder" do
      schema = Class.new(GraphQL::Schema) { cursor_encoder identity; use keyset, plain_cursors: true }
      expect { schema.use(keyset) }.to raise_error(keyset::ConfigurationError)
    end

    it "preservation: use twice, false then plain true, allows a readable encoder after" do
      schema = schema_with(armory)
      schema.use(keyset, plain_cursors: true)
      expect { schema.cursor_encoder(identity) }.not_to raise_error
    end

    it "security: a subclass's use with plain_cursors: false explicitly, then identity, is refused" do
      parent = schema_with(identity, plain_cursors: true)
      encoder = armory
      child = Class.new(parent) { cursor_encoder encoder; use keyset, plain_cursors: false }
      expect { child.cursor_encoder(identity) }.to raise_error(keyset::ConfigurationError)
    end

    it "security: a plain sibling does not turn off the check of its strict parent or siblings" do
      parent = schema_with(armory)
      Class.new(parent) { use keyset, plain_cursors: true }
      expect { Class.new(parent) { cursor_encoder identity } }.to raise_error(keyset::ConfigurationError)
      expect(parent.armory_keyset_plain_cursors).to be(false)
    end

    it "security: an intermediate schema not extended does not hide a bad inherited encoder" do
      x = Class.new(GraphQL::Schema) { cursor_encoder identity }
      expect { Class.new(x) { use keyset } }.to raise_error(keyset::ConfigurationError)
    end

    it "security: grandchild of a plain-true intermediate that turns it back off is checked" do
      strict = schema_with(armory)
      plain = Class.new(strict) { use keyset, plain_cursors: true }
      expect { Class.new(plain) { use keyset; cursor_encoder identity } }.to raise_error(keyset::ConfigurationError)
    end

  end

  # Pages: S5 and runtime
  describe "pages" do
    let(:controls) { keyset::Controls }
    let(:document) { "{ items(first: 1) { edges { cursor } nodes { id } } }" }

    before { 2.times { |i| KeysetItem.create!(rank: i, name: "secret-#{i}") } }

    define_method(:run) do |schema, connection|
      execute_query(schema, document, root_value: controls::Root.example(connection))
    end
    define_method(:schema_for) do |encoder: nil, **use_options|
      controls::Schema.example(base: base_schema, cursor_encoder: encoder).tap { |s| s.use(keyset, **use_options) unless use_options.empty? }
    end

    it "preservation: with use and the Armory encoder, a cursor is opaque and pages forward" do
      schema = schema_for(encoder: armory, plain_cursors: false)
      first = run(schema, keyset.build(KeysetItem.order(:rank)))
      cursor = first.dig("data", "items", "edges", 0, "cursor")
      expect(cursor).not_to include("rank")
      expect(Base64.urlsafe_decode64(cursor)).not_to include("\"k\"") rescue nil
      doc = "{ items(first: 1, after: #{cursor.to_json}) { nodes { id } } }"
      second = execute_query(schema, doc, root_value: controls::Root.example(keyset.build(KeysetItem.order(:rank))))
      expect(second.dig("data", "items", "nodes").size).to eq(1)
      expect(second.dig("data", "items", "nodes", 0, "id")).not_to eq(first.dig("data", "items", "nodes", 0, "id"))
    end

    it "security: a connection built with nil for a plain schema is refused on another schema without use" do
      connection = keyset.build(KeysetItem.order(:id))
      expect(run(schema_for(plain_cursors: true), connection).dig("data", "items", "nodes").size).to eq(1)
      other = keyset.build(KeysetItem.order(:id))
      expect { run(schema_for, other) }.to raise_error(keyset::ConfigurationError, /plain_cursors/)
    end

    it "security: explicit nil on build with no use still refuses Base64" do
      expect { run(schema_for, keyset.build(KeysetItem.order(:id), plain_cursors: nil)) }.to raise_error(keyset::ConfigurationError)
    end

    it "security: a strict parent's plain child does not let the parent page Base64" do
      parent = schema_for(encoder: armory, plain_cursors: false)
      child = Class.new(parent) { use GraphQL::Armory::Keyset, plain_cursors: true; cursor_encoder GraphQL::Schema::Base64Encoder }
      expect(run(child, keyset.build(KeysetItem.order(:id))).dig("data", "items", "nodes").size).to eq(1)
      expect(parent.cursor_encoder).to eq(armory)
    end

    it "security: a rescoped connection with explicit false is refused on a plain schema" do
      connection = keyset.build(KeysetItem.order(:id), plain_cursors: false).rescoped { |r| r.where.not(id: nil) }
      expect { run(schema_for(plain_cursors: true), connection) }.to raise_error(keyset::ConfigurationError)
    end

    it "preservation: a subclass of a plain schema inherits plain cursors on a page" do
      child = Class.new(schema_for(plain_cursors: true))
      expect(run(child, keyset.build(KeysetItem.order(:id))).dig("data", "items", "nodes").size).to eq(1)
    end

    it "preservation: Keyset.new directly (connections.add style) ignores the schema's plain_cursors and refuses Base64" do
      relation = KeysetItem.order(:id)
      connection = keyset.new(relation, columns: keyset::Ordering.(relation))
      expect { run(schema_for(plain_cursors: true), connection) }.to raise_error(keyset::ConfigurationError)
    end

    it "preservation: without use, a readable custom encoder still pages (differential A vs B)" do
      result = run(controls::Schema.example(base: base_schema, cursor_encoder: identity), keyset.build(KeysetItem.order(:id)))
      puts "\n[diff-identity] #{result.to_h.to_json}"
      expect(result.dig("data", "items", "edges", 0, "cursor")).to include("\"k\"")
    end

    it "preservation: without use, Base64 is refused on the first page with the same message (differential A vs B)" do
      expect { run(controls::Schema.example(base: base_schema), keyset.build(KeysetItem.order(:id))) }.to raise_error(keyset::ConfigurationError) { |e|
        puts "\n[diff-base64] #{e.message}"
      }
    end

    it "preservation: build(plain_cursors: true) with no use pages with Base64 (differential A vs B)" do
      result = run(controls::Schema.example(base: base_schema), keyset.build(KeysetItem.order(:id), plain_cursors: true))
      puts "\n[diff-plain] #{result.to_h.to_json}"
      expect(result.dig("data", "items", "nodes").size).to eq(1)
    end

    it "preservation: build(plain_cursors: 'yes') raises naming the option" do
      expect { keyset.build(KeysetItem.order(:id), plain_cursors: "yes") }.to raise_error(keyset::ConfigurationError, /plain_cursors/)
    end


    it "preservation: use is recorded in schema.plugins" do
      schema = schema_for(encoder: armory, plain_cursors: false)
      expect(schema.plugins.map(&:first)).to include(keyset)
    end
  end
end
