# frozen_string_literal: true

require "spec_helper"
require "graphql/armory/caching/canonical"
require "graphql/armory/caching/schema_identity"
require "graphql/armory/caching/viewer"
require "graphql/armory/caching/keyer"

# Design 9, attack 6: collide two keys. Every input an answer may depend on that graphql-ruby can see is a key
# component of one type, so two requests share a key only when the answer cannot differ; a value the key cannot hold
# without ambiguity refuses the key instead. A `:viewer` answer belongs to one principal, by class and id (G4).
RSpec.describe "Response caching keys" do
  let(:caching) { GraphQL::Armory::Caching }
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:digested) { [] }
  let(:digester) { caching::Digester.new(mac: ->(bytes) { digested << bytes; OpenSSL::HMAC.digest("SHA256", "spec", bytes) }) }
  let(:schema) { caching::Controls::Schema.example }
  let(:public_policy) { caching::Policy.cacheable(ttl: 60, scope: :public) }
  let(:viewer_policy) { caching::Policy.cacheable(ttl: 30, scope: :viewer) }
  let(:user) { caching::Controls::Viewer.example(id: 7) }
  let(:admin) { caching::Controls::Viewer.example(id: 7, admin: true) }

  def keyer(**options)
    caching::Keyer.build(release: "r1", digester: digester, viewer: :current_user, **options)
  end

  def query(operation = "catalog", variables: nil, context: caching::Controls::Context.example(operation: operation), **options)
    schema.query_class.new(schema, nil, variables: variables, context: context, **options)
  end

  def viewer_query(principal, **extra)
    query("invoices", context: { operation_id: "invoices", current_user: principal, **extra })
  end

  def key_for(query, policy = public_policy, keyer: self.keyer)
    keyer.(query, policy, engine: :interpreter)
  end

  describe "variables" do
    # Versioning's example schema takes raw documents; `tags(first: Int)` takes a nullable variable.
    let(:vschema) { versioning::Controls::Schema.example }
    let(:text) { "query Tags($first: Int) { invoice { tags(first: $first) } }" }

    def tags_key(variables)
      key_for(vschema.query_class.new(vschema, text, variables: variables, context: { armory_version: "2025-01-01" }))
    end

    it "ignores a variable the operation does not declare: it can neither split the key space nor flood the store" do
      expect(tags_key({ "first" => 1, "undeclared" => "x" * 100 }).digest).to eq(tags_key({ "first" => 1 }).digest)
      expect(tags_key({ "undeclared" => 1 }).digest).to eq(tags_key({}).digest)
    end

    it "keeps a variable sent as null apart from one not sent" do
      null = tags_key({ "first" => nil })

      expect(null.digest).not_to eq(tags_key({}).digest)
    end

    it "keeps 1 apart from 1.0, and 1 apart from \"1\"" do
      digests = [1, 1.0, "1"].map { |value| tags_key({ "first" => value }).digest }

      expect(digests.uniq.size).to eq(3)
    end

    it "refuses a Symbol, a Date, a non-finite Float or another Ruby object as a value" do
      [:one, Date.new(2025, 1, 1), Float::NAN, Float::INFINITY, -Float::INFINITY, Object.new].each do |value|
        expect(tags_key({ "first" => value })).to eq(caching::Policy.refused(:variables))
        expect(tags_key({ "first" => [value] })).to eq(caching::Policy.refused(:variables))
      end
    end

    it "refuses a nested Hash with a key that is not a String, and a name given both as a String and a Symbol" do
      expect(tags_key({ "first" => { first: 1 } })).to eq(caching::Policy.refused(:variables))
      expect(tags_key({ "first" => 1, first: 2 })).to eq(caching::Policy.refused(:variables))
    end

    it "refuses variables that are not a Hash, such as ActionController::Parameters" do
      params = Class.new { def to_h = { "first" => 1 } }.new

      expect(tags_key(params)).to eq(caching::Policy.refused(:variables))
    end

    it "refuses bytes that are not UTF-8 text, and keys the same text in another encoding as itself" do
      expect(tags_key({ "first" => "\xFF".b })).to eq(caching::Policy.refused(:variables))
      expect(tags_key({ "first" => "abc".b }).digest).to eq(tags_key({ "first" => "abc" }).digest)
    end

    it "keeps two Hash key orders and two Unicode normalizations apart: never one answer for two inputs" do
      expect(tags_key({ "first" => { "a" => 1, "b" => 2 } }).digest).not_to eq(tags_key({ "first" => { "b" => 2, "a" => 1 } }).digest)
      expect(tags_key({ "first" => "café" }).digest).not_to eq(tags_key({ "first" => "café" }).digest)
    end

    it "cannot forge a separator: a value holding the canonical encoding of others stays one value" do
      forged = tags_key({ "first" => '1],["second",true,2' })
      input = digested.last

      expect(input).to include('[["first",true,"1],[\\"second\\",true,2"]]')
      expect(forged.digest).not_to eq(tags_key({ "first" => 1 }).digest)
    end
  end

  describe "the viewer" do
    it "never shares a key between User 7 and AdminUser 7, nor their purge tags" do
      user_key = key_for(viewer_query(user), viewer_policy)
      admin_key = key_for(viewer_query(admin), viewer_policy)

      expect(user_key.digest).not_to eq(admin_key.digest)
      expect(user_key.viewer_tag).not_to eq(admin_key.viewer_tag)
    end

    it "never shares a key between ids 7 and 8, nor between 7 and \"7\"" do
      seven = key_for(viewer_query(user), viewer_policy).digest
      built = keyer(viewer_id: ->(principal) { principal.id.to_s })

      expect(key_for(viewer_query(caching::Controls::Viewer.example(id: 8)), viewer_policy).digest).not_to eq(seven)
      expect(key_for(viewer_query(user), viewer_policy, keyer: built).digest).not_to eq(seven)
    end

    it "raises when viewer_id: answers nil, an empty String or another type, never quoting the id" do
      [nil, "", 7.0, :secret_id].each do |id|
        built = keyer(viewer_id: ->(_principal) { id })

        expect { key_for(viewer_query(user), viewer_policy, keyer: built) }.to raise_error(caching::ConfigurationError) { |error|
          expect(error.message).to include("viewer_id:")
          expect(error.message).not_to include("secret_id")
        }
      end
    end

    it "raises for a principal of an anonymous class, and for one without an id" do
      nameless = Struct.new(:id).new(7)

      expect { key_for(viewer_query(nameless), viewer_policy) }.to raise_error(caching::ConfigurationError, /anonymous class/)
      expect { key_for(viewer_query("user-7"), viewer_policy) }.to raise_error(caching::ConfigurationError, /no id/)
    end

    it "refuses every :viewer key when no viewer: key is configured" do
      expect(key_for(viewer_query(user), viewer_policy, keyer: keyer(viewer: nil))).to eq(caching::Policy.refused(:viewer_unconfigured))
    end

    it "is not read for a :public key: every viewer shares it" do
      expect(key_for(viewer_query(user)).digest).to eq(key_for(viewer_query(admin)).digest)
      expect(key_for(viewer_query(nil)).digest).to eq(key_for(viewer_query(user)).digest)
    end

    it "under anonymous: :uncacheable, refuses an absent, nil or false viewer" do
      [query("invoices", context: { operation_id: "invoices" }), viewer_query(nil), viewer_query(false)].each do |anonymous|
        expect(key_for(anonymous, viewer_policy)).to eq(caching::Policy.refused(:anonymous))
      end
    end

    it "under anonymous: :shared, shares one key per form of anonymity, apart from every principal, with the anonymous tag" do
      built = keyer(anonymous: :shared, anonymous_reason: "guests see one storefront")
      absent = key_for(query("invoices", context: { operation_id: "invoices" }), viewer_policy, keyer: built)
      keys = [absent, key_for(viewer_query(nil), viewer_policy, keyer: built), key_for(viewer_query(false), viewer_policy, keyer: built)]

      expect(key_for(query("invoices", context: { operation_id: "invoices" }), viewer_policy, keyer: built).digest).to eq(absent.digest)
      expect(keys.map(&:digest).uniq.size).to eq(3)
      expect(keys.map(&:viewer_tag).uniq).to eq([digester.(caching::Tags::ANONYMOUS)])
      expect(keys.map(&:digest)).not_to include(key_for(viewer_query(user), viewer_policy, keyer: built).digest)
    end
  end

  describe "vary:" do
    let(:built) { keyer(vary: { locale: :locale }) }

    def locale_key(locale)
      key_for(query("catalog", context: caching::Controls::Context.example.merge(locale: locale)), keyer: built)
    end

    it "keeps a Symbol value apart from a String one" do
      expect(locale_key(:en).digest).not_to eq(locale_key("en").digest)
    end

    it "keeps 1 apart from \"1\" and from 1.0" do
      expect([1, "1", 1.0].map { |locale| locale_key(locale).digest }.uniq.size).to eq(3)
    end

    it "refuses a value of a type the key cannot hold" do
      [Date.new(2025, 1, 1), Object.new, Float::NAN, [Object.new], { "a" => Time.now }].each do |value|
        expect(locale_key(value)).to eq(caching::Policy.refused(:vary_value))
      end
    end

    it "refuses a callable's value of a type the key cannot hold" do
      callable = keyer(vary: { now: -> { Time.now } })

      expect(key_for(query, keyer: callable)).to eq(caching::Policy.refused(:vary_value))
    end
  end

  describe "what leaves the keyer" do
    it "puts no viewer id, variable, tag or operation name in clear in a Key" do
      secret = caching::Controls::Viewer.example(id: 424_242)
      key = key_for(query("product", variables: { "name" => "SecretLamp" }), public_policy)
      viewer_key = key_for(viewer_query(secret), viewer_policy)

      [key, viewer_key].each do |each_key|
        values = [each_key.digest, each_key.viewer_tag, each_key.inspect].compact.join(" ")
        expect(values).not_to include("SecretLamp", "424242", "Product", "Invoices", "viewer:")
      end
      expect([key.digest, viewer_key.digest, viewer_key.viewer_tag]).to all(match(/\A\h{64}\z/))
    end

    it "digests the components only through the digester: the same request under another HMAC key is another key" do
      other = caching::Digester.new(mac: ->(bytes) { OpenSSL::HMAC.digest("SHA256", "other", bytes) })

      expect(key_for(query).digest).not_to eq(key_for(query, keyer: keyer(digester: other)).digest)
    end
  end
end
