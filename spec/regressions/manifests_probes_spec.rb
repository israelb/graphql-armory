# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "tmpdir"
require "fileutils"

# Independent verification probes for PersistedQueries::Manifests. [S] security, [P] preservation, [C] single-Manifest
# comparison meant to run on origin/main as well. A probe states the outcome the feature should have.
RSpec.describe "PersistedQueries::Manifests probes" do
  pq = GraphQL::Armory::PersistedQueries
  inv = pq::Controls::Operations.invoices
  greet = pq::Controls::Operations.greeting
  secret = "query Secret { secret }"
  sha = ->(q) { Digest::SHA256.hexdigest(q) }
  md5 = ->(q) { Digest::MD5.hexdigest(q) }

  define_method(:ms) { pq::Manifests }
  define_method(:man) { |*qs, **o| pq::Manifest.new(qs.to_h { |q| [sha.(q), q] }, **o) }
  define_method(:conf) { pq::ConfigurationError }

  define_method(:write) do |dir, name, *qs|
    path = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(qs.to_h { |q| [sha.(q), q] }))
    path
  end

  define_method(:apollo) do |dir, file, name, q|
    path = File.join(dir, file)
    File.write(path, JSON.generate("format" => "apollo-persisted-query-manifest", "version" => 1,
      "operations" => [{ "id" => sha.(q), "name" => name, "type" => "query", "body" => q }]))
    path
  end

  define_method(:schema_with) do |store, **opts|
    query_type = pq::Controls::Query.example
    Class.new(ArmoryEngine.base_schema) do
      query query_type
      use GraphQL::Armory::PersistedQueries, store: store, **opts
    end
  end

  let(:resolved) { [] }
  let(:root) { pq::Controls::Root.example(resolved) }
  define_method(:run_q) { |schema, text, **o| execute_query(schema, text, root_value: root, **o).to_h }
  define_method(:err) { |r| r["errors"]&.first&.fetch("message") }

  describe "joining" do
    it "[S1] digest:false, whitespace-only different body raises" do
      a = pq::Manifest.new({ "x" => "query A { invoices }" }, digest: false)
      b = pq::Manifest.new({ "x" => "query A {  invoices }" }, digest: false)
      expect { ms.new([a, b]) }.to raise_error(conf)
    end

    it "[S2] conflict only in the third of three raises" do
      a = pq::Manifest.new({ "x" => inv }, digest: false)
      b = pq::Manifest.new({ "x" => inv, "y" => greet }, digest: false)
      c = pq::Manifest.new({ "y" => secret }, digest: false)
      expect { ms.new([a, b, c]) }.to raise_error(conf)
    end

    it "[P3] same id with a different name loads, first listed name kept, same document runs" do
      Dir.mktmpdir do |d|
        a = apollo(d, "a.json", "FromA", inv)
        b = apollo(d, "b.json", "FromB", inv)
        store = ms.build([a, b])
        expect(store.size).to eq(1)
        expect(store.fetch(sha.(inv)).name).to eq("FromA")
        expect(ms.build([b, a]).fetch(sha.(inv)).name).to eq("FromB")
      end
    end

    it "[P4] same file twice and through a glob" do
      Dir.mktmpdir do |d|
        a = write(d, "a.json", inv)
        expect(ms.build([a, a, File.join(d, "*.json"), File.join(d, "./a.json")]).size).to eq(1)
      end
    end

    it "[S5] md5 and sha256 manifests via new: each id answers its own query only" do
      store = ms.new([man(inv), pq::Manifest.new({ md5.(greet) => greet }, digest: :md5)])
      expect(store.fetch(sha.(inv)).body).to eq(inv)
      expect(store.fetch(md5.(greet)).body).to eq(greet)
      expect(store.fetch(md5.(inv))).to be_nil
      expect(store.fetch(sha.(greet))).to be_nil
    end

    it "[S6] digest:false id equal to a sha256 id with another query raises, either order" do
      forged = pq::Manifest.new({ sha.(inv) => secret }, digest: false)
      expect { ms.new([man(inv), forged]) }.to raise_error(conf)
      expect { ms.new([forged, man(inv)]) }.to raise_error(conf)
    end

    it "[S7] digest:false 32-hex id equal to an md5 id with another query raises" do
      forged = pq::Manifest.new({ md5.(inv) => secret }, digest: false)
      real = pq::Manifest.new({ md5.(inv) => inv }, digest: :md5)
      expect { ms.new([real, forged]) }.to raise_error(conf)
    end

    it "[S8] NFC vs NFD body under digest:false raises" do
      a = pq::Manifest.new({ "x" => "query A { greeting(name: \"é\") }" }, digest: false)
      b = pq::Manifest.new({ "x" => "query A { greeting(name: \"é\") }" }, digest: false)
      expect { ms.new([a, b]) }.to raise_error(conf)
    end
  end

  describe "fetch and immutability" do
    let(:store) { ms.new([man(inv), man(greet)]) }

    it "[S9] non-String ids answer nil" do
      [nil, 1, :a, Object.new, [sha.(inv)], { sha.(inv) => 1 }].each { |id| expect(store.fetch(id)).to be_nil }
    end

    it "[P10] frozen String and String subclass ids find the op" do
      sub = Class.new(String)
      expect(store.fetch(sha.(inv).dup.freeze).body).to eq(inv)
      expect(store.fetch(sub.new(sha.(inv))).body).to eq(inv)
    end

    it "[S11] no hash default answers an unknown id" do
      expect(store.fetch("default")).to be_nil
      expect(store.fetch("")).to be_nil
      expect(store.instance_variable_get(:@operations).default).to be_nil
      expect(store.instance_variable_get(:@operations).default_proc).to be_nil
    end

    it "[S12] returned op and its strings are frozen" do
      op = store.fetch(sha.(inv))
      expect([op, op.id, op.body].all?(&:frozen?)).to eq(true)
      expect { op.body = secret }.to raise_error(FrozenError)
    end

    it "[S13] Manifest#operations cannot change a later fetch" do
      m = man(inv)
      ops = m.operations
      expect { ops[sha.(secret)] = :x }.to raise_error(FrozenError)
      expect { ops.delete(sha.(inv)) }.to raise_error(FrozenError)
      expect { ops[sha.(inv)].body << "x" }.to raise_error(FrozenError)
      expect(m.fetch(sha.(inv)).body).to eq(inv)
    end

    it "[S14a] Manifests: mutating a fetched op's document does not change a later fetch" do
      op = store.fetch(sha.(inv))
      begin
        op.document.definitions.clear
      rescue FrozenError
        nil
      end
      expect(store.fetch(sha.(inv)).document.definitions).not_to be_empty
    end

    it "[C14b] single Manifest: mutating a fetched op's document does not change a later fetch" do
      m = man(inv)
      begin
        m.fetch(sha.(inv)).document.definitions.clear
      rescue FrozenError
        nil
      end
      expect(m.fetch(sha.(inv)).document.definitions).not_to be_empty
    end

    it "[S15] mutating the list after new does not change the store" do
      list = [man(inv)]
      s = ms.new(list)
      list << man(secret)
      list.clear
      expect(s.size).to eq(1)
      expect(s.fetch(sha.(secret))).to be_nil
    end

    it "[S20] a duck-typed store or Substitute is refused, and the message says what to do" do
      duck = Object.new
      def duck.fetch(_id) = nil
      [duck, pq::Store::Substitute.new(inv), pq::Store::Null.new].each do |item|
        expect { ms.new([item]) }.to raise_error(conf, /Manifest/)
      end
    end

    it "[S21] a single Manifest, Hash or Manifests is refused" do
      [man(inv), { a: 1 }, ms.new, [ms.new], [[man(inv)]]].each do |bad|
        expect { ms.new(bad) }.to raise_error(conf)
      end
    end

    it "[S22] digest: on new is not silently ignored" do
      expect { ms.new(digest: :md5) }.to raise_error(conf)
      expect { ms.new([man(inv)], digest: :md5) }.to raise_error(ArgumentError)
    end

    it "[S23] a bogus digest raises in build" do
      Dir.mktmpdir do |d|
        a = write(d, "a.json", inv)
        [:bogus, nil, "sha256", true].each do |dg|
          expect { ms.build(a, digest: dg) }.to raise_error(conf, /digest/)
        end
      end
    end
  end

  describe "paths" do
    it "[S24] an existing file named with [ loads" do
      Dir.mktmpdir do |d|
        p = write(d, "web[1].json", inv)
        expect(ms.build(p).size).to eq(1)
      end
    end

    it "[S25] a directory with brackets, no sibling: pattern does not match itself: raises" do
      Dir.mktmpdir do |d|
        write(d, "pq[v1]/a.json", inv)
        expect { ms.build(File.join(d, "pq[v1]/*.json")) }.to raise_error(conf, /no manifest/)
      end
    end

    it "[S27] a directory as a path raises ConfigurationError" do
      Dir.mktmpdir { |d| expect { ms.build(d) }.to raise_error(conf, /cannot be read/) }
    end

    it "[S28] `*` matching a subdirectory raises" do
      Dir.mktmpdir do |d|
        write(d, "a.json", inv)
        FileUtils.mkdir_p(File.join(d, "sub"))
        expect { ms.build(File.join(d, "*")) }.to raise_error(conf)
      end
    end

    it "[S29] `*` matching a non-JSON file raises" do
      Dir.mktmpdir do |d|
        write(d, "a.json", inv)
        File.write(File.join(d, "README"), "hello")
        expect { ms.build(File.join(d, "*")) }.to raise_error(conf, /README/)
      end
    end

    it "[S30] a package.json matched by *.json raises, also with digest:false" do
      Dir.mktmpdir do |d|
        write(d, "a.json", inv)
        File.write(File.join(d, "package.json"), JSON.generate("name" => "app", "version" => "1"))
        expect { ms.build(File.join(d, "*.json")) }.to raise_error(conf)
        expect { ms.build(File.join(d, "*.json"), digest: false) }.to raise_error(conf)
      end
    end

    it "[P31] a relative path follows cwd; from another cwd it raises" do
      Dir.mktmpdir do |d|
        write(d, "pq/a.json", inv)
        Dir.chdir(d) do
          expect(ms.build("pq/*.json").size).to eq(1)
          expect(ms.build("pq/a.json").size).to eq(1)
        end
        Dir.mktmpdir do |other|
          Dir.chdir(other) { expect { ms.build("pq/*.json") }.to raise_error(conf) }
        end
      end
    end

    it "[S32] backslashes on Linux raise" do
      Dir.mktmpdir do |d|
        write(d, "pq/a.json", inv)
        Dir.chdir(d) { expect { ms.build("pq\\*.json") }.to raise_error(conf, /no manifest/) }
      end
    end

    it "[P33] a symlink to a manifest loads" do
      Dir.mktmpdir do |d|
        a = write(d, "real/a.json", inv)
        FileUtils.mkdir_p(File.join(d, "pq"))
        File.symlink(a, File.join(d, "pq/a.json"))
        expect(ms.build(File.join(d, "pq/*.json")).size).to eq(1)
      end
    end

    it "[S34] a broken symlink raises ConfigurationError, as a path and through a glob" do
      Dir.mktmpdir do |d|
        link = File.join(d, "a.json")
        File.symlink(File.join(d, "gone.json"), link)
        write(d, "b.json", inv)
        expect { ms.build(link) }.to raise_error(conf)
        expect { ms.build(File.join(d, "*.json")) }.to raise_error(conf)
      end
    end

    it "[S38] a stray file literally named *.json does not hide the real manifests" do
      Dir.mktmpdir do |d|
        write(d, "web.json", inv)
        write(d, "*.json", greet)
        begin
          store = ms.build(File.join(d, "*.json"))
        rescue pq::ConfigurationError
          next
        end
        expect(store.fetch(sha.(inv))).not_to be_nil
      end
    end

    it "[P39] Pathname, list of Pathname and a glob Pathname" do
      Dir.mktmpdir do |d|
        a = write(d, "a.json", inv)
        b = write(d, "b.json", greet)
        expect(ms.build(Pathname(a)).size).to eq(1)
        expect(ms.build([Pathname(a), Pathname(b)]).size).to eq(2)
        expect(ms.build([Pathname(a), a]).size).to eq(1)
        expect(ms.build(Pathname(d).join("*.json")).size).to eq(2)
      end
    end

    it "[S40a] nil and [] raise ConfigurationError" do
      expect { ms.build(nil) }.to raise_error(conf)
      expect { ms.build([]) }.to raise_error(conf)
    end

    [["nil entry", [nil]], ["Integer entry", [1]], ["hash", { "a" => 1 }], ["nested list", [["a.json"]]], ["symbol", :a]].each do |label, value|
      it "[S40b] #{label} raises ConfigurationError, never a store" do
        expect { ms.build(value) }.to raise_error(conf)
      end
    end

    it "[S40c] a good path followed by nil raises and leaves no store" do
      Dir.mktmpdir do |d|
        a = write(d, "a.json", inv)
        expect { ms.build([a, nil]) }.to raise_error(StandardError)
      end
    end

    it "[S42] an unreadable file raises ConfigurationError" do
      skip "running as root: permissions do not apply" if Process.uid.zero?
      Dir.mktmpdir do |d|
        a = write(d, "a.json", inv)
        File.chmod(0, a)
        expect { ms.build(a) }.to raise_error(conf, /cannot be read/)
      end
    end

    it "[S43] an empty file, an empty manifest or an edited file among good ones raises" do
      {
        "empty" => "",
        "nothing" => "{}",
        "array" => "[]",
        "edited" => JSON.generate(sha.(inv) => secret)
      }.each do |name, content|
        Dir.mktmpdir do |d|
          write(d, "a.json", inv)
          File.write(File.join(d, "#{name}.json"), content)
          expect { ms.build(File.join(d, "*.json")) }.to raise_error(conf, /#{name}\.json|holds no|format|digest/)
        end
      end
    end

    it "[S44] invalid UTF-8 among good ones raises ConfigurationError and quotes no text" do
      Dir.mktmpdir do |d|
        write(d, "a.json", inv)
        File.binwrite(File.join(d, "b.json"), "{\"x\": \"query Secret { greeting(name: \\\"\xFF\xFE\\\") }\"}".b)
        expect { ms.build(File.join(d, "*.json"), digest: false) }.to raise_error(conf) { |e|
          expect(e.message).not_to include("Secret")
        }
      end
    end

    it "[P45] a file with a BOM loads" do
      Dir.mktmpdir do |d|
        File.binwrite(File.join(d, "a.json"), "\xEF\xBB\xBF".b + JSON.generate(sha.(inv) => inv).b)
        expect(ms.build(File.join(d, "*.json")).size).to eq(1)
      end
    end
  end

  describe "messages" do
    it "[S46] no boot error in a glob quotes query text" do
      {
        "invalid JSON" => "{ \"x\": query Secret { secret } ",
        "digest fail" => JSON.generate(sha.(inv) => secret),
        "text as id" => JSON.generate(secret => secret),
        "no parse" => JSON.generate(sha.("query Secret {") => "query Secret {")
      }.each do |_label, content|
        Dir.mktmpdir do |d|
          write(d, "a.json", inv)
          File.write(File.join(d, "b.json"), content)
          expect { ms.build(File.join(d, "*.json")) }.to raise_error(conf) { |e| expect(e.message).not_to include("Secret") }
        end
      end
    end

    it "[S47] a multi-line id does not slip through the filter into the conflict message" do
      id = "ok\nquery Secret { secret }"
      a = pq::Manifest.new({ id => inv }, digest: false)
      b = pq::Manifest.new({ id => greet }, digest: false)
      expect { ms.new([a, b]) }.to raise_error(conf) { |e| expect(e.message).not_to include("Secret") }
      long = "q" * 129
      c = pq::Manifest.new({ long => inv }, digest: false)
      d = pq::Manifest.new({ long => greet }, digest: false)
      expect { ms.new([c, d]) }.to raise_error(conf) { |e| expect(e.message).not_to include(long) }
    end

  end

  describe "order" do
    it "[P51] the name kept does not depend on creation order" do
      Dir.mktmpdir do |d|
        apollo(d, "z.json", "FromZ", inv)
        apollo(d, "a.json", "FromA", inv)
        apollo(d, "m.json", "FromM", inv)
        expect(ms.build(File.join(d, "*.json")).fetch(sha.(inv)).name).to eq("FromA")
      end
    end
  end

  describe "through the plugin" do
    let(:joined) { ms.new([man(inv), pq::Manifest.new({ md5.(greet) => greet }, digest: :md5)]) }
    let(:strict) { schema_with(joined, strict: true) }

    it "[S52] each manifest's id runs its own query, with variables" do
      expect(run_q(strict, nil, context: { operation_id: sha.(inv) })["data"]).to eq("invoices" => ["A-1"])
      r = run_q(strict, nil, context: { operation_id: md5.(greet) }, variables: { "name" => "x" })
      expect(r["data"]).to eq("greeting" => "Hello x")
      expect(resolved).to eq(%i[invoices greeting])
    end

    it "[S54a] id plus another query is a mismatch, and neither runs" do
      r = run_q(strict, secret, context: { operation_id: sha.(inv) })
      expect(err(r)).to eq(pq::MISMATCH)
      expect(r["data"]).to be_nil
      expect(resolved).to eq([])
    end

    it "[S54b] id plus a document: option is a mismatch" do
      r = run_q(strict, nil, document: GraphQL.parse(secret), context: { operation_id: sha.(inv) })
      expect(err(r)).to eq(pq::MISMATCH)
      expect(resolved).to eq([])
    end

    it "[P55] id plus the same or the printed text runs" do
      printed = GraphQL.parse(inv).to_query_string
      expect(run_q(strict, inv, context: { operation_id: sha.(inv) })["data"]).not_to be_nil
      expect(run_q(strict, printed, context: { operation_id: sha.(inv) })["data"]).not_to be_nil
    end

    it "[S56] raw in strict is refused and nothing resolves" do
      r = run_q(strict, secret, context: {})
      expect(err(r)).to eq(pq::RAW_QUERY_REFUSED)
      expect(resolved).to eq([])
    end

    it "[P57] raw with armory_allow_raw_query true runs in strict" do
      expect(run_q(strict, secret, context: { armory_allow_raw_query: true })["data"]).to eq("secret" => "s3cr3t")
    end

    it "[S58] strict:true with an empty Manifests refuses everything" do
      s = schema_with(ms.new, strict: true)
      expect(err(run_q(s, secret, context: {}))).to eq(pq::RAW_QUERY_REFUSED)
      expect(err(run_q(s, nil, context: { operation_id: sha.(inv) }))).to eq(pq::UNKNOWN_OPERATION)
      expect(resolved).to eq([])
    end

    it "[S59a] strict:false with Manifests.new is refused at boot, as Store::Null is" do
      expect { schema_with(ms.new, strict: false) }.to raise_error(conf)
    end

    it "[S59b] strict:false with Manifests.new([]) is refused at boot" do
      expect { schema_with(ms.new([]), strict: false) }.to raise_error(conf)
    end

    it "[S60] a typo'd Dir.glob into new, strict:false: a raw query does not run behind an empty store" do
      store = ms.new(Dir.glob("/nonexistent/typo/*.json").map { |f| pq::Manifest.load(f) })
      begin
        s = schema_with(store, strict: false)
      rescue pq::ConfigurationError
        next
      end
      r = run_q(s, secret, context: {})
      expect(r["data"]).to be_nil
      expect(resolved).to eq([])
    end

    it "[S61] strict omitted (default false) with an empty Manifests: same" do
      begin
        s = schema_with(ms.new)
      rescue pq::ConfigurationError
        next
      end
      expect(run_q(s, secret, context: {})["data"]).to be_nil
    end

    it "[S61b] a real non-empty store's size reaches zero? an empty store answers size 0" do
      expect(ms.new.size).to eq(0)
    end

    it "[P62] strict:false with a real Manifests runs raw queries and ids" do
      s = schema_with(joined, strict: false)
      expect(run_q(s, secret, context: {})["data"]).to eq("secret" => "s3cr3t")
      expect(run_q(s, nil, context: { operation_id: sha.(inv) })["data"]).to eq("invoices" => ["A-1"])
    end

    it "[S63] non-String operation ids are unknown" do
      [1, :a, [sha.(inv)], { sha.(inv) => 1 }, true, false].each do |id|
        expect(err(run_q(strict, nil, context: { operation_id: id }))).to eq(pq::UNKNOWN_OPERATION)
      end
      expect(resolved).to eq([])
    end

    it "[S64] ids equal to Hash and Object method names are unknown" do
      %w[default __id__ size to_h keys].each do |id|
        expect(err(run_q(strict, nil, context: { operation_id: id }))).to eq(pq::UNKNOWN_OPERATION)
      end
    end

    it "[S65] signals on refusal hold no id and no query" do
      seen = []
      s = schema_with(joined, strict: true, sinks: [->(signal, data) { seen << [signal, data] }])
      run_q(s, secret, context: { operation_id: "attacker-id" })
      run_q(s, secret, context: { operation_id: sha.(inv) })
      run_q(s, secret, context: {})
      text = seen.inspect
      expect(seen.size).to eq(3)
      expect(text).not_to match(/attacker-id|Secret|#{sha.(inv)}/)
    end

    it "[S66] an id never answers another manifest's query" do
      a = pq::Manifest.new({ "a" => inv }, digest: false)
      b = pq::Manifest.new({ "b" => secret }, digest: false)
      s = schema_with(ms.new([a, b]), strict: true)
      expect(run_q(s, nil, context: { operation_id: "a" })["data"]).to eq("invoices" => ["A-1"])
      expect(resolved).to eq([:invoices])
      expect(err(run_q(s, secret, context: { operation_id: "a" }))).to eq(pq::MISMATCH)
      expect(resolved).to eq([:invoices])
    end

    it "[S66b] introspection in strict with Manifests is refused" do
      r = run_q(strict, "{ __schema { types { name } } }", context: {})
      expect(err(r)).to eq(pq::RAW_QUERY_REFUSED)
    end
  end

  describe "silent options" do
    it "[S67] digest:false reaches every file: the second file's non-digest id loads, default raises on it" do
      Dir.mktmpdir do |d|
        a = write(d, "a.json", inv)
        File.write(File.join(d, "b.json"), JSON.generate("named" => greet))
        b = File.join(d, "b.json")
        expect { ms.build([a, b]) }.to raise_error(conf, /digest/)
        expect(ms.build([a, b], digest: false).fetch("named").body).to eq(greet)
      end
    end

    it "[S68] digest: :md5 reaches every file: a sha256 second file raises" do
      Dir.mktmpdir do |d|
        File.write(File.join(d, "a.json"), JSON.generate(md5.(inv) => inv))
        write(d, "b.json", greet)
        expect { ms.build(File.join(d, "*.json"), digest: :md5) }.to raise_error(conf, /digest/)
      end
    end

    it "[S69] every path and every glob match answers its id" do
      Dir.mktmpdir do |d|
        write(d, "g/1.json", inv)
        write(d, "g/2.json", greet)
        c = write(d, "c.json", secret)
        store = ms.build([File.join(d, "g/*.json"), c])
        [inv, greet, secret].each { |q| expect(store.fetch(sha.(q)).body).to eq(q) }
      end
    end
  end

  describe "single Manifest, comparison and preservation" do
    let(:single) { man(inv) }
    let(:schema) { schema_with(single, strict: true) }

    it "[C70a] unknown id refused" do
      expect(err(run_q(schema, nil, context: { operation_id: sha.(secret) }))).to eq(pq::UNKNOWN_OPERATION)
      expect(resolved).to eq([])
    end

    it "[C70b] mismatch refused" do
      expect(err(run_q(schema, secret, context: { operation_id: sha.(inv) }))).to eq(pq::MISMATCH)
    end

    it "[C70c] raw in strict refused" do
      expect(err(run_q(schema, secret, context: {}))).to eq(pq::RAW_QUERY_REFUSED)
    end

    it "[C70d] stored id runs" do
      expect(run_q(schema, nil, context: { operation_id: sha.(inv) })["data"]).to eq("invoices" => ["A-1"])
    end

    it "[C71] Store::Null plus strict:false still raises" do
      expect { schema_with(pq::Store::Null.new, strict: false) }.to raise_error(conf, /strict: false needs a store/)
    end

    it "[C72] a duck-typed store is still accepted by use" do
      stored = man(inv)
      duck = Object.new
      duck.define_singleton_method(:fetch) { |id| stored.fetch(id) }
      s = schema_with(duck, strict: true)
      expect(run_q(s, nil, context: { operation_id: sha.(inv) })["data"]).to eq("invoices" => ["A-1"])
    end

    it "[C73] Manifest.new({}) still raises" do
      expect { pq::Manifest.new({}) }.to raise_error(conf, /no operations/)
    end
  end
end
