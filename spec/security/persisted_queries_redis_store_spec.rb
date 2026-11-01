# frozen_string_literal: true

require "digest"
require "json"
require "redis"
require "securerandom"
require "stringio"
require "tmpdir"

# Operations published by a client's CI and read by the server while it runs, with no deploy.
RSpec.describe GraphQL::Armory::PersistedQueries::RedisStore do
  let(:persisted) { GraphQL::Armory::PersistedQueries }
  let(:client) { persisted::RedisStore::Client::Substitute.new }
  let(:invoices) { persisted::Controls::Operations.invoices }
  let(:invoices_id) { Digest::SHA256.hexdigest(invoices) }
  let(:errors) { [] }
  let(:store) { persisted::RedisStore.build(redis: client, on_error: ->(error) { errors << error }) }
  let(:publisher) { persisted::Publisher.build(redis: client) }

  def manifest_of(*queries)
    persisted::Manifest.new(queries.to_h { |query| [Digest::SHA256.hexdigest(query), query] })
  end

  it "holds nothing when nothing was wired" do
    expect(described_class.new.fetch(invoices_id)).to be_nil
  end

  it "refuses at build what it cannot use" do
    expect { described_class.build(redis: Object.new) }.to raise_error(persisted::ConfigurationError, /redis:/)
    expect { described_class.build(redis: client, prefix: "") }.to raise_error(persisted::ConfigurationError, /prefix:/)
    expect { described_class.build(redis: client, digest: :crc) }.to raise_error(persisted::ConfigurationError, /digest/)
    expect { described_class.build(redis: client, on_error: 1) }.to raise_error(persisted::ConfigurationError, /on_error:/)
  end

  it "answers an operation published after it was built, with no restart" do
    expect(store.fetch(invoices_id)).to be_nil

    publisher.(manifest_of(invoices))

    expect(store.fetch(invoices_id).body).to eq(invoices)
    expect(store.fetch(invoices_id).document.to_query_string).to eq(GraphQL.parse(invoices).to_query_string)
  end

  it "reads an operation once, and asks again for an id it does not hold" do
    publisher.(manifest_of(invoices))
    client.calls.clear

    2.times { store.fetch(invoices_id) }
    2.times { store.fetch(Digest::SHA256.hexdigest("{ other }")) }

    expect(client.calls.map(&:first)).to eq(%i[get get get])
  end

  it "does not ask Redis for what cannot be an id" do
    ["a b", "x" * 129, "", "a\nb", "a*"].each { |id| expect(store.fetch(id)).to be_nil }

    expect(client.calls).to eq([])
  end

  it "answers unknown for an id with invalid bytes or another encoding, as a Manifest does" do
    [[255, 97, 98, 99].pack("C*").force_encoding("UTF-8"), "abc".encode("UTF-16")].each { |id| expect(store.fetch(id)).to be_nil }

    expect(client.calls).to eq([])
    expect(errors).to eq([])
  end

  it "does not read a missing digest as no check" do
    expect { described_class.new(redis: client, digest: nil) }.to raise_error(KeyError)
  end

  it "keeps answering what it already read when Redis fails, refuses the rest and says so" do
    publisher.(manifest_of(invoices))
    store.fetch(invoices_id)
    client.fail_with(IOError.new("redis://user:password@host"))

    expect(store.fetch(invoices_id).body).to eq(invoices)
    expect(store.fetch(Digest::SHA256.hexdigest("{ other }"))).to be_nil
    expect(errors.map(&:class)).to eq([IOError])
  end

  it "warns with the error's class alone by default: its message may hold the password" do
    client.fail_with(IOError.new("redis://user:password@host"))
    default = described_class.build(redis: client)

    expect { expect(default.fetch(invoices_id)).to be_nil }.to output(/IOError/).to_stderr
    expect { default.fetch(invoices_id) }.not_to output(/password/).to_stderr
  end

  it "refuses a stored query that is not the digest of its id, and quotes neither" do
    client.set("#{described_class::DEFAULT_PREFIX}#{invoices_id}", "query Secret { secret }")

    expect(store.fetch(invoices_id)).to be_nil
    expect(errors.map(&:class)).to eq([described_class::CorruptOperation])
    expect(errors.first.message).not_to include("Secret")
  end

  it "refuses a stored value that does not parse" do
    body = "query {"
    client.set("#{described_class::DEFAULT_PREFIX}#{Digest::SHA256.hexdigest(body)}", body)

    expect(store.fetch(Digest::SHA256.hexdigest(body))).to be_nil
    expect(errors.map(&:class)).to eq([described_class::CorruptOperation])
  end

  describe "through the plugin" do
    let(:resolved) { [] }
    let(:root) { persisted::Controls::Root.example(resolved) }
    let(:schema) do
      query_type = persisted::Controls::Query.example
      wired = store
      Class.new(ArmoryEngine.base_schema) do
        query query_type
        use GraphQL::Armory::PersistedQueries, store: wired, strict: true
      end
    end

    def run(id) = execute_query(schema, nil, context: { operation_id: id }, root_value: root).to_h

    it "runs a published operation and refuses the rest" do
      expect(run(invoices_id)["errors"].first["message"]).to eq(persisted::UNKNOWN_OPERATION)

      publisher.(manifest_of(invoices))

      expect(run(invoices_id)["data"]).to eq("invoices" => ["A-1"])
      expect(run(Digest::SHA256.hexdigest("{ secret }"))["errors"].first["message"]).to eq(persisted::UNKNOWN_OPERATION)
      expect(resolved).to eq([:invoices])
    end

    it "refuses an id with invalid bytes, and records it" do
      seen = []
      query_type = persisted::Controls::Query.example
      wired = store
      recording = Class.new(ArmoryEngine.base_schema) do
        query query_type
        use GraphQL::Armory::PersistedQueries, store: wired, strict: true, sinks: [->(signal, data) { seen << [signal, data] }]
      end
      result = execute_query(recording, nil, context: { operation_id: [255, 97, 98, 99].pack("C*").force_encoding("UTF-8") }, root_value: root).to_h

      expect(result["errors"].first["message"]).to eq(persisted::UNKNOWN_OPERATION)
      expect(seen).to eq([[:operation_refused, { reason: :unknown_operation }]])
    end

    it "refuses an unknown id while Redis is down, and runs nothing" do
      client.fail_with(IOError.new("down"))

      expect(run(invoices_id)["errors"].first["message"]).to eq(persisted::UNKNOWN_OPERATION)
      expect(resolved).to eq([])
    end

    it "refuses raw queries allowed with a store nobody wired" do
      query_type = persisted::Controls::Query.example
      inert = described_class.new

      expect do
        Class.new(ArmoryEngine.base_schema) do
          query query_type
          use GraphQL::Armory::PersistedQueries, store: inert, strict: false
        end
      end.to raise_error(persisted::ConfigurationError, /strict: false needs a store/)
    end
  end

  describe GraphQL::Armory::PersistedQueries::Publisher do
    it "refuses to publish when nothing was wired" do
      expect { described_class.new.(manifest_of(invoices)) }.to raise_error(described_class::PublishError, /not stored/)
    end

    it "refuses what is not a Manifest" do
      expect { publisher.({ invoices_id => invoices }) }.to raise_error(persisted::ConfigurationError, /Manifest/)
    end

    it "publishes again with no change, and counts what was new" do
      greeting = persisted::Controls::Operations.greeting

      expect(publisher.(manifest_of(invoices)).to_h).to eq(published: 1, unchanged: 0)
      expect(publisher.(manifest_of(invoices, greeting)).to_h).to eq(published: 1, unchanged: 1)
    end

    it "never changes a published operation, and quotes neither query" do
      publisher.(persisted::Manifest.new({ "invoices-v1" => invoices }, digest: false))
      other = persisted::Manifest.new({ "invoices-v1" => "query Secret { secret }" }, digest: false)

      expect { publisher.(other) }.to raise_error(described_class::PublishError) { |error|
        expect(error.message).to include("invoices-v1")
        expect(error.message).not_to match(/Secret|Invoices/)
      }
      expect(client.get("#{GraphQL::Armory::PersistedQueries::RedisStore::DEFAULT_PREFIX}invoices-v1")).to eq(invoices)
    end

    it "publishes nothing when one id could not be read" do
      manifest = persisted::Manifest.new({ "good" => invoices, "not an id" => invoices }, digest: false)

      expect { publisher.(manifest) }.to raise_error(persisted::ConfigurationError, /at entry 1/)
      expect(client.calls).to eq([])
    end

    describe GraphQL::Armory::PersistedQueries::Publisher::Command do
      let(:out) { StringIO.new }
      let(:err) { StringIO.new }

      def run(*argv, env: { "REDIS_URL" => "redis://user:password@host" })
        described_class.call(argv, env: env, out: out, err: err, client: client)
      end

      def write_manifest(dir, query)
        File.join(dir, "manifest.json").tap { |path| File.write(path, JSON.generate(Digest::SHA256.hexdigest(query) => query)) }
      end

      it "publishes every file, says how many and exits 0" do
        Dir.mktmpdir do |dir|
          expect(run(write_manifest(dir, invoices))).to eq(0)
          expect(out.string).to include("1 published, 0 unchanged")
          expect(client.get("#{GraphQL::Armory::PersistedQueries::RedisStore::DEFAULT_PREFIX}#{invoices_id}")).to eq(invoices)
        end
      end

      it "takes --prefix and --digest" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "named.json")
          File.write(path, JSON.generate("invoices-v1" => invoices))

          expect(run("--digest", "false", "--prefix", "web:", path)).to eq(0)
          expect(client.get("web:invoices-v1")).to eq(invoices)
        end
      end

      it "exits 1 on a bad manifest, with no path given, or with no REDIS_URL" do
        Dir.mktmpdir do |dir|
          bad = File.join(dir, "bad.json")
          File.write(bad, "{ not json")

          expect(run(bad)).to eq(1)
          expect(run).to eq(1)
          expect(run(write_manifest(dir, invoices), env: {})).to eq(1)
          expect(err.string).to include("REDIS_URL")
          expect(client.calls).to eq([])
        end
      end

      it "exits 1 when Redis fails, and does not print its message: it may hold the password" do
        client.fail_with(IOError.new("redis://user:password@host"))

        Dir.mktmpdir do |dir|
          expect(run(write_manifest(dir, invoices))).to eq(1)
          expect(err.string).to include("IOError")
          expect(err.string + out.string).not_to include("password")
        end
      end
    end
  end

  context "with a real Redis" do
    before { skip "REDIS_URL is not set (docker compose and CI set it)" if ENV["REDIS_URL"].to_s.empty? }

    let(:redis) { Redis.new(url: ENV.fetch("REDIS_URL")) }
    let(:prefix) { "graphql-armory-spec:#{SecureRandom.hex(8)}:" }

    after { redis.del(redis.keys("#{prefix}*")) unless ENV["REDIS_URL"].to_s.empty? || redis.keys("#{prefix}*").empty? }

    it "publishes in one process and reads non-ASCII text in another" do
      query = 'query Greeting { greeting(name: "José") }'

      expect(persisted::Publisher.build(redis: redis, prefix: prefix).(manifest_of(query)).to_h).to eq(published: 1, unchanged: 0)
      expect(described_class.build(redis: Redis.new(url: ENV.fetch("REDIS_URL")), prefix: prefix).fetch(Digest::SHA256.hexdigest(query)).body).to eq(query)
    end

    it "refuses an unknown id when Redis cannot be reached" do
      down = described_class.build(redis: Redis.new(url: "redis://127.0.0.1:1/0", reconnect_attempts: 0), on_error: ->(error) { errors << error })

      expect(down.fetch(invoices_id)).to be_nil
      expect(errors.size).to eq(1)
    end
  end
end
