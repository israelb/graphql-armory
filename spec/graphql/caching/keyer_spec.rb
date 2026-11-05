# frozen_string_literal: true

require "spec_helper"
require "graphql/armory/caching/canonical"
require "graphql/armory/caching/schema_identity"
require "graphql/armory/caching/viewer"
require "graphql/armory/caching/keyer"

RSpec.describe GraphQL::Armory::Caching::Keyer do
  let(:caching) { GraphQL::Armory::Caching }
  let(:versioning) { GraphQL::Armory::Versioning }
  # The real Digester on a fixed HMAC key, recording every byte string it digests: the keyer's telemetry.
  let(:digested) { [] }
  let(:digester) { caching::Digester.new(mac: ->(bytes) { digested << bytes; OpenSSL::HMAC.digest("SHA256", "spec", bytes) }) }
  let(:schema) { caching::Controls::Schema.example }
  let(:public_policy) { caching::Policy.cacheable(ttl: 60, scope: :public) }
  let(:viewer_policy) { caching::Policy.cacheable(ttl: 30, scope: :viewer) }

  def keyer(**options)
    described_class.build(release: "r1", digester: digester, viewer: :current_user, **options)
  end

  def query(operation = "catalog", schema: self.schema, variables: nil, context: caching::Controls::Context.example(operation: operation), **options)
    schema.query_class.new(schema, nil, variables: variables, context: context, **options)
  end

  # A query on Versioning's example schema (no PersistedQueries): raw documents, versions and profiles.
  def raw_query(text, schema:, version: "2025-01-01", **options)
    schema.query_class.new(schema, text, context: { armory_version: version }, **options)
  end

  # The components the last key was digested from, decoded.
  def components
    JSON.parse(digested.reverse.find { |input| input.start_with?('["armory-cache/2"') })
  end

  def key_for(query, policy = public_policy, keyer: self.keyer, engine: :interpreter)
    keyer.(query, policy, engine: engine)
  end

  describe ".build" do
    it "refuses a missing, empty or non-String release" do
      [nil, "", "  ", :r1].each do |release|
        expect { described_class.build(release: release, digester: digester) }.to raise_error(caching::ConfigurationError, /release:/)
      end
    end

    it "refuses a digester that cannot digest" do
      expect { described_class.build(release: "r1", digester: Object.new) }.to raise_error(caching::ConfigurationError, /digester:/)
    end

    it "refuses a viewer: that is not a context key, a viewer_id: that takes no principal and an unknown anonymous:" do
      expect { keyer(viewer: -> { 1 }) }.to raise_error(caching::ConfigurationError, /viewer:/)
      expect { keyer(viewer: "") }.to raise_error(caching::ConfigurationError, /viewer:/)
      expect { keyer(viewer_id: :id) }.to raise_error(caching::ConfigurationError, /viewer_id:/)
      expect { keyer(viewer_id: -> { 1 }) }.to raise_error(caching::ConfigurationError, /viewer_id:/)
      expect { keyer(anonymous: :public) }.to raise_error(caching::ConfigurationError, /anonymous:/)
    end

    it "requires anonymous_reason: with anonymous: :shared, and refuses it otherwise" do
      expect { keyer(anonymous: :shared) }.to raise_error(caching::ConfigurationError, /anonymous_reason:/)
      expect { keyer(anonymous: :shared, anonymous_reason: " ") }.to raise_error(caching::ConfigurationError, /anonymous_reason:/)
      expect { keyer(anonymous_reason: "guests") }.to raise_error(caching::ConfigurationError, /anonymous_reason:/)
      expect(keyer(anonymous: :shared, anonymous_reason: "the storefront is the same for every guest")).to be_a(described_class)
    end

    it "refuses a vary: that is not a Hash of names to context keys or zero-argument callables" do
      expect { keyer(vary: [:locale]) }.to raise_error(caching::ConfigurationError, /vary:/)
      expect { keyer(vary: { "" => :locale }) }.to raise_error(caching::ConfigurationError, /vary:/)
      expect { keyer(vary: { locale: 1 }) }.to raise_error(caching::ConfigurationError, /vary:/)
      expect { keyer(vary: { locale: ->(context) { context[:locale] } }) }.to raise_error(caching::ConfigurationError, /vary:/)
      expect { keyer(vary: { locale: :locale, "locale" => :language }) }.to raise_error(caching::ConfigurationError, /twice/)
    end

    it "computes no schema digest: the schema is not finished when use runs" do
      built = keyer

      expect(built.schema_identity.computed).to be_empty
    end
  end

  describe ".new" do
    it "is inert: it refuses every key, covers nothing and has no viewer tag" do
      inert = described_class.new

      expect(inert.(query, public_policy, engine: :interpreter)).to eq(caching::Policy.refused(:unconfigured))
      expect(inert.covered_keys(viewer_policy)).to eq([])
      expect { inert.viewer_tag_for(caching::Controls::Viewer.example) }.to raise_error(caching::ConfigurationError)
    end
  end

  describe "#call" do
    it "answers a Key of the policy's scope, digested from the canonical components of design 4.3" do
      q = query("product", variables: { "name" => "Lamp" })

      key = key_for(q)

      expect(key).to be_a(caching::Key)
      expect(key.scope).to eq(:public)
      expect(key.viewer_tag).to be_nil
      expect(components).to eq(
        ["armory-cache/2", "r1", nil, Digest::SHA256.hexdigest(schema.to_definition(context: { armory_full_schema: true })),
         "interpreter", Digest::SHA256.hexdigest(q.document.to_query_string), "Product", [["name", true, "Lamp"]],
         nil, nil, q.max_depth, q.max_complexity, "public", nil, []]
      )
    end

    it "answers the same key for the same request" do
      expect(key_for(query).digest).to eq(key_for(query).digest)
    end

    it "answers a refused policy as it is, reading nothing" do
      refused = caching::Policy.refused(:directive)

      expect(key_for(query, refused)).to equal(refused)
      expect(digested).to be_empty
    end

    it "takes the engine from its caller and refuses an unknown one" do
      on_next = key_for(query, engine: :next).digest
      expect(components[4]).to eq("next")
      expect(key_for(query, engine: :interpreter).digest).not_to eq(on_next)
      expect { key_for(query, engine: :fast) }.to raise_error(ArgumentError, /engine:/)
      expect { keyer.(query, public_policy) }.to raise_error(ArgumentError)
    end

    it "refuses a query whose operation name selects no operation" do
      expect(key_for(query("catalog", operation_name: "Nope"))).to eq(caching::Policy.refused(:operation))
    end

    it "changes with the release" do
      expect(key_for(query).digest).not_to eq(key_for(query, keyer: keyer(release: "r2")).digest)
    end

    it "changes with the schema's name" do
      named = Class.new(schema) { def self.name = "AppSchema" }

      anonymous = key_for(query).digest
      expect(key_for(query(schema: named)).digest).not_to eq(anonymous)
      expect(components[2]).to eq("AppSchema")
    end

    it "changes with the schema's definition, under the same name and document" do
      one = versioning::Controls::Schema.example
      other = versioning::Controls::Schema.example(query: versioning::Controls::MembersQuery.example)
      text = "query Q { __typename }"

      first = key_for(raw_query(text, schema: one))
      first_digest = components[3]
      second = key_for(raw_query(text, schema: other))

      expect(second.digest).not_to eq(first.digest)
      expect(components[3]).not_to eq(first_digest)
    end

    it "changes with the document, the selected operation and the limits" do
      vschema = versioning::Controls::Schema.example
      two = "query A { invoice { number } } query B { invoice { number } }"
      base = key_for(raw_query(two, schema: vschema, operation_name: "A")).digest

      expect(key_for(raw_query(two, schema: vschema, operation_name: "B")).digest).not_to eq(base)
      expect(key_for(raw_query("query A { invoice { number total } }", schema: vschema)).digest).not_to eq(base)
      expect(key_for(raw_query(two, schema: vschema, operation_name: "A", max_depth: 3)).digest).not_to eq(base)
      expect(key_for(raw_query(two, schema: vschema, operation_name: "A", max_complexity: 7)).digest).not_to eq(base)
    end

    it "changes with a declared variable's value" do
      lamp = key_for(query("product", variables: { "name" => "Lamp" })).digest

      expect(key_for(query("product", variables: { "name" => "Desk" })).digest).not_to eq(lamp)
      expect(key_for(query("product", variables: { name: "Lamp" })).digest).to eq(lamp)
    end

    it "changes with the scope, and puts the viewer only in :viewer keys" do
      public_key = key_for(query, public_policy)
      viewer_key = key_for(query, viewer_policy)

      expect(viewer_key.digest).not_to eq(public_key.digest)
      expect(components[12..13]).to eq(["viewer", [caching::Controls::Viewer::User.name, 7]])
    end

    it "changes with each vary: value" do
      varied = keyer(vary: { locale: :locale })

      expect(key_for(query, keyer: varied).digest)
        .not_to eq(key_for(query("catalog", context: caching::Controls::Context.example(locale: "fr")), keyer: varied).digest)
      expect(components.last).to eq([["locale", %w[str fr]]])
    end
  end

  describe "the schema digest" do
    let(:vschema) { versioning::Controls::Schema.example }
    let(:text) { "query Q { invoice { number } }" }

    # graphql 2.4 with json 3.x calls JSON.generate(quirks_mode:) when printing a deprecation reason, so its own
    # to_definition raises on Versioning's example schema: the environment, not the keyer.
    before do
      vschema.to_definition(context: { armory_full_schema: true, armory_version: "2024-06-01" })
    rescue ArgumentError => e
      raise unless e.message.include?("quirks_mode") && Gem::Version.new(GraphQL::VERSION) < Gem::Version.new("2.5")

      skip "graphql #{GraphQL::VERSION} cannot print this schema with json #{JSON::VERSION} (quirks_mode)"
    end

    it "is computed on the first request that needs it, once per version, and differs per version" do
      built = keyer
      key_for(raw_query(text, schema: vschema, version: "2024-06-01"), keyer: built)
      older = components
      key_for(raw_query(text, schema: vschema, version: "2024-06-01"), keyer: built)
      key_for(raw_query(text, schema: vschema, version: "2025-01-01"), keyer: built)
      newer = components

      expect(built.schema_identity.computed.count { |entry| entry.first == :schema }).to eq(2)
      expect(older[8]).to eq("2024-06-01")
      expect(newer[8]).to eq("2025-01-01")
      expect(newer[3]).not_to eq(older[3])
      expect(older[3]).to eq(Digest::SHA256.hexdigest(vschema.to_definition(context: { armory_full_schema: true, armory_version: "2024-06-01" })))
    end

    it "holds the resolved version label, not the client's raw value" do
      key_for(raw_query(text, schema: versioning::Controls::Schema.example(default: :latest), version: nil))

      expect(components[8]).to eq("2025-01-01")
    end

    it "is the same value when two threads compute it first at once" do
      built = keyer
      digests = Array.new(4) { Thread.new { built.schema_identity.schema_digest(vschema, "2025-01-01", nil) } }.map(&:value)

      expect(digests.uniq.size).to eq(1)
    end

    it "is computed per visibility profile under Versioning's profiles: true" do
      skip "profiles: true needs graphql #{versioning::Profiles::MINIMUM_GRAPHQL}" if Gem::Version.new(GraphQL::VERSION) < versioning::Profiles::MINIMUM_GRAPHQL

      controls = versioning::Controls
      profiled = Class.new(GraphQL::Schema) do
        query(controls::Query.example)
        use GraphQL::Armory::Versioning, versions: controls::Versions::LABELS, retired: controls::Versions::RETIRED, default: :latest, profiles: true
        use GraphQL::Schema::Visibility, profiles: GraphQL::Armory::Versioning.profiles(self)
      end
      built = keyer

      key_for(raw_query(text, schema: profiled, version: "2024-06-01"), keyer: built)
      older = components
      key_for(raw_query(text, schema: profiled, version: "2025-01-01"), keyer: built)
      newer = components

      expect(older[9]).to eq(%w[sym armory_v_2024-06-01])
      expect(newer[9]).to eq(%w[sym armory_v_2025-01-01])
      expect(newer[3]).not_to eq(older[3])
      expect(built.schema_identity.computed).to include([:schema, "2024-06-01", :"armory_v_2024-06-01"], [:schema, "2025-01-01", :"armory_v_2025-01-01"])
    end
  end

  describe "the document digest" do
    it "is printed once per document object: a persisted operation's document is shared" do
      built = keyer
      3.times { key_for(query("catalog"), keyer: built) }

      expect(built.schema_identity.computed.count([:document])).to eq(1)
    end
  end

  describe "#covered_keys" do
    it "covers the viewer: key for :viewer policies only, and each vary: context key, never a callable" do
      built = keyer(vary: { locale: :locale, tenant: -> { "acme" } })

      expect(built.covered_keys(viewer_policy)).to eq(%i[current_user locale])
      expect(built.covered_keys(public_policy)).to eq([:locale])
      expect(keyer(viewer: nil).covered_keys(viewer_policy)).to eq([])
    end

    it "exposes the viewer: key and the vary: context keys for the gate's settings" do
      built = keyer(vary: { tenant: -> { "acme" }, locale: :locale, region: "region" })

      expect(built.viewer_key).to eq(:current_user)
      expect(built.vary_context_keys).to eq([:locale, "region"])
      expect(keyer(viewer: nil).viewer_key).to be_nil
      expect(described_class.new.viewer_key).to be_nil
      expect(described_class.new.vary_context_keys).to eq([])
    end
  end

  describe "#viewer_tag_for" do
    it "answers the viewer_tag of that principal's keys, and of anonymous keys for :anonymous" do
      user = caching::Controls::Viewer.example
      shared = keyer(anonymous: :shared, anonymous_reason: "guests see one storefront")

      expect(shared.viewer_tag_for(user)).to eq(key_for(query, viewer_policy, keyer: shared).viewer_tag)
      expect(shared.viewer_tag_for(user)).to eq(digester.(caching::Tags.viewer(caching::Controls::Viewer::User.name, 7)))
      anonymous = key_for(query("catalog", context: caching::Controls::Context.anonymous), viewer_policy, keyer: shared)
      expect(shared.viewer_tag_for(:anonymous)).to eq(anonymous.viewer_tag)
      expect(anonymous.viewer_tag).to eq(digester.(caching::Tags::ANONYMOUS))
    end
  end

  describe "vary:" do
    it "keys a callable's value, which takes no arguments" do
      tenant = "acme"
      built = keyer(vary: { tenant: -> { tenant } })
      acme = key_for(query, keyer: built).digest
      tenant = "globex"

      expect(key_for(query, keyer: built).digest).not_to eq(acme)
      expect(components.last).to eq([["tenant", %w[str globex]]])
    end

    it "sorts entries by name, so the order they were given in does not matter" do
      one = key_for(query, keyer: keyer(vary: { locale: :locale, tenant: -> { 1 } })).digest
      other = key_for(query, keyer: keyer(vary: { tenant: -> { 1 }, locale: :locale })).digest

      expect(one).to eq(other)
    end

    it "types values recursively and keeps an absent context key apart from a nil one" do
      built = keyer(vary: { flags: :flags })
      values = [[:on], ["on"], { "a" => 1 }, { a: 1 }, [1], [1.0], nil, true]
      digests = values.map { |value| key_for(query("catalog", context: caching::Controls::Context.example.merge(flags: value)), keyer: built).digest }
      absent = key_for(query, keyer: built).digest

      expect(digests.uniq.size).to eq(values.size)
      expect(digests).not_to include(absent)
      expect(components.last).to eq([["flags", ["absent"]]])
    end
  end
end
