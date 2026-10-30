# frozen_string_literal: true

require "digest"
require "json"
require "tmpdir"

# The allowlist is the manifest a client build produced. It is trusted only if every id is the digest of its
# query, so an edited manifest cannot smuggle in a query under another operation's id.
RSpec.describe GraphQL::Armory::PersistedQueries::Manifest do
  let(:manifest_class) { described_class }
  let(:invoices) { "query Invoices { invoices { number } }" }
  let(:account) { "query Account { account { name } }" }

  def relay(digest = :md5, **bodies)
    bodies.values.to_h { |body| [Digest.const_get(digest.to_s.upcase).hexdigest(body), body] }
  end

  def apollo(*bodies)
    { "format" => "apollo-persisted-query-manifest", "version" => 1,
      "operations" => bodies.map { |body| { "id" => Digest::SHA256.hexdigest(body), "name" => body[/query (\w+)/, 1], "type" => "query", "body" => body } } }
  end

  def refused(pattern, &block)
    expect(&block).to raise_error(GraphQL::Armory::PersistedQueries::ConfigurationError, pattern)
  end

  it "reads Apollo's persisted query manifest" do
    manifest = manifest_class.new(apollo(invoices, account))
    operation = manifest.fetch(Digest::SHA256.hexdigest(invoices))

    expect([manifest.size, operation.body, operation.name]).to eq([2, invoices, "Invoices"])
  end

  it "reads Relay's persisted output with the digest Relay was configured with" do
    manifest = manifest_class.new(relay(:md5, a: invoices), digest: :md5)

    expect(manifest.fetch(Digest::MD5.hexdigest(invoices)).body).to eq(invoices)
  end

  it "parses every query once, when it loads" do
    operation = manifest_class.new(apollo(invoices)).fetch(Digest::SHA256.hexdigest(invoices))

    expect([operation.document.class, operation.document.equal?(operation.document)]).to eq([GraphQL::Language::Nodes::Document, true])
  end

  it "answers nil for an id it does not hold" do
    expect(manifest_class.new(apollo(invoices)).fetch("unknown")).to be_nil
  end

  it "loads a manifest file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "persisted-queries.json")
      File.write(path, JSON.generate(apollo(invoices)))

      expect(manifest_class.load(path).size).to eq(1)
    end
  end

  describe "what it refuses at boot" do
    it "refuses an id that is not the digest of its query, naming the id" do
      edited = apollo(invoices)
      edited["operations"][0]["body"] = account
      id = edited["operations"][0]["id"]

      refused(/#{id}.*digest/) { manifest_class.new(edited) }
    end

    it "refuses Relay output checked with the wrong digest" do
      refused(/digest/) { manifest_class.new(relay(:md5, a: invoices), digest: :sha256) }
    end

    it "refuses a query that does not parse, naming the id" do
      broken = "query { invoices {"
      refused(/#{Digest::SHA256.hexdigest(broken)}.*parse/) { manifest_class.new(apollo(broken)) }
    end

    it "refuses an unknown format, version or digest" do
      refused(/format/) { manifest_class.new([invoices]) }
      refused(/version/) { manifest_class.new(apollo(invoices).merge("version" => 2)) }
      refused(/digest/) { manifest_class.new(apollo(invoices), digest: :crc32) }
    end

    it "refuses the same id twice in an Apollo manifest" do
      twice = apollo(invoices)
      twice["operations"] << twice["operations"][0].dup

      refused(/twice/) { manifest_class.new(twice) }
    end

    it "refuses a file that is not JSON, without echoing its content" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "persisted-queries.json")
        File.write(path, "not json at all")

        refused(/#{Regexp.escape(path)}.*JSON/) { manifest_class.load(path) }
      end
    end
  end

  it "skips the digest check only when told to, for ids that are not digests" do
    manifest = manifest_class.new({ "invoices-v1" => invoices }, digest: false)

    expect(manifest.fetch("invoices-v1").body).to eq(invoices)
  end
end
