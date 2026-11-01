# frozen_string_literal: true

require "digest"
require "json"
require "tmpdir"

# Several client builds, each with its manifest, behind one `store:`.
RSpec.describe GraphQL::Armory::PersistedQueries::Manifests do
  let(:persisted) { GraphQL::Armory::PersistedQueries }
  let(:operations) { persisted::Controls::Operations }
  let(:invoices) { operations.invoices }
  let(:greeting) { operations.greeting }

  def manifest_of(*queries, **options)
    persisted::Manifest.new(queries.to_h { |query| [Digest::SHA256.hexdigest(query), query] }, **options)
  end

  def write_manifest(dir, name, *queries)
    path = File.join(dir, name)
    File.write(path, JSON.generate(queries.to_h { |query| [Digest::SHA256.hexdigest(query), query] }))
    path
  end

  it "holds nothing when nothing was wired" do
    expect(described_class.new.fetch("anything")).to be_nil
  end

  it "answers an operation of any manifest, and nil for an id none holds" do
    store = described_class.new([manifest_of(invoices), manifest_of(greeting)])

    expect(store.fetch(Digest::SHA256.hexdigest(invoices)).body).to eq(invoices)
    expect(store.fetch(Digest::SHA256.hexdigest(greeting)).body).to eq(greeting)
    expect(store.fetch(Digest::SHA256.hexdigest("{ secret }"))).to be_nil
  end

  it "counts an operation two builds share once" do
    expect(described_class.new([manifest_of(invoices), manifest_of(invoices, greeting)]).size).to eq(2)
  end

  it "refuses at boot two manifests that put different queries behind one id, and quotes neither" do
    first = persisted::Manifest.new({ "invoices-v1" => invoices }, digest: false)
    second = persisted::Manifest.new({ "invoices-v1" => "query Secret { secret }" }, digest: false)

    expect { described_class.new([first, second]) }.to raise_error(persisted::ConfigurationError) { |error|
      expect(error.message).to include("invoices-v1")
      expect(error.message).not_to match(/Secret|Invoices/)
    }
  end

  it "does not quote an id that may be query text" do
    text = "query Secret { secret }"
    first = persisted::Manifest.new({ text => invoices }, digest: false)
    second = persisted::Manifest.new({ text => greeting }, digest: false)

    expect { described_class.new([first, second]) }.to raise_error(persisted::ConfigurationError) { |error|
      expect(error.message).not_to include("Secret")
    }
  end

  it "refuses what is not a Manifest" do
    [nil, "a.json", [Object.new], [{ "id" => "query" }]].each do |manifests|
      expect { described_class.new(manifests) }.to raise_error(persisted::ConfigurationError, /manifests/)
    end
  end

  describe ".build" do
    it "loads every file a pattern or a list names" do
      Dir.mktmpdir do |dir|
        write_manifest(dir, "web.json", invoices)
        path = write_manifest(dir, "mobile.json", greeting)

        expect(described_class.build(File.join(dir, "*.json")).size).to eq(2)
        expect(described_class.build(path).size).to eq(1)
        expect(described_class.build([path, File.join(dir, "web.json")]).size).to eq(2)
      end
    end

    it "refuses at boot a pattern that matches nothing: strict mode would refuse every client" do
      Dir.mktmpdir do |dir|
        expect { described_class.build(File.join(dir, "*.json")) }.to raise_error(persisted::ConfigurationError, /no manifest/)
        expect { described_class.build([]) }.to raise_error(persisted::ConfigurationError, /no manifest/)
      end
    end

    it "refuses at boot a file that does not load, naming it" do
      Dir.mktmpdir do |dir|
        write_manifest(dir, "good.json", invoices)
        File.write(File.join(dir, "bad.json"), "{ not json")

        expect { described_class.build(File.join(dir, "*.json")) }.to raise_error(persisted::ConfigurationError, /bad\.json/)
      end
    end

    it "passes digest: to every file" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "named.json"), JSON.generate("invoices-v1" => invoices))

        expect { described_class.build(File.join(dir, "*.json")) }.to raise_error(persisted::ConfigurationError, /digest/)
        expect(described_class.build(File.join(dir, "*.json"), digest: false).size).to eq(1)
      end
    end
  end

  describe "through the plugin" do
    let(:resolved) { [] }

    def schema_with(store)
      query_type = persisted::Controls::Query.example
      Class.new(ArmoryEngine.base_schema) do
        query query_type
        use GraphQL::Armory::PersistedQueries, store: store, strict: true
      end
    end

    it "runs what any manifest holds and refuses the rest" do
      schema = schema_with(described_class.new([manifest_of(invoices), manifest_of(greeting)]))
      root = persisted::Controls::Root.example(resolved)
      run = ->(context) { execute_query(schema, nil, context: context, root_value: root).to_h }

      expect(run.(operation_id: Digest::SHA256.hexdigest(invoices))["data"]).to eq("invoices" => ["A-1"])
      expect(run.(operation_id: Digest::SHA256.hexdigest("{ secret }"))["errors"].first["message"]).to eq(persisted::UNKNOWN_OPERATION)
      expect(resolved).to eq([:invoices])
    end
  end
end
