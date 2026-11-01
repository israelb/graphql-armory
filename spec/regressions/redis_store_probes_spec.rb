# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "redis"
require "securerandom"
require "stringio"
require "tmpdir"
require "fileutils"
require "rbconfig"
require "timeout"

# Verifier's probes for RedisStore / Publisher / Command. Each `it` is labelled security or preservation.
RSpec.describe "runtime store probes" do
  pq = GraphQL::Armory::PersistedQueries
  redis_store = pq::RedisStore
  publisher_class = pq::Publisher
  sub = pq::RedisStore::Client::Substitute

  secret = "s3cretP4ss"
  doc_path = File.expand_path("../../docs/persisted-queries.md", __dir__)
  doc_path = "#{Dir.pwd}/docs/persisted-queries.md" unless File.exist?(doc_path)

  let(:errors) { [] }
  let(:signals) { [] }
  let(:ran) { [] }
  let(:prefix) { "probe:#{SecureRandom.hex(6)}:" }
  let(:admin) { Redis.new(url: ENV.fetch("REDIS_URL")) }
  let(:on_error) { ->(e) { errors << e } }

  def sha(body) = Digest::SHA256.hexdigest(body)

  def probe_root
    log = ran
    Class.new do
      define_method(:secret) { log << :secret; "SECRET" }
      define_method(:other) { log << :other; "OTHER" }
      define_method(:greeting) { |name: nil| log << :greeting; "hi #{name}" }
    end.new
  end

  def manifest_of(*queries, digest: :sha256)
    GraphQL::Armory::PersistedQueries::Manifest.new(queries.to_h { |q| [sha(q), q] }, digest: digest)
  end

  def schema_for(store, strict: true)
    query_type = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      field :secret, String, null: true
      field :other, String, null: true
      field :greeting, String, null: true do
        argument :name, String, required: false
      end
    end
    sink = ->(signal, data) { signals << [signal, data] }
    s = store
    Class.new(ArmoryEngine.base_schema) do
      query query_type
      use GraphQL::Armory::PersistedQueries, store: s, strict: strict, sinks: [sink]
    end
  end

  def run(schema, id = nil, text: nil, **ctx)
    context = ctx
    context[:operation_id] = id unless id.nil?
    execute_query(schema, text, context: context, root_value: probe_root).to_h
  end

  def code(result) = result.dig("errors", 0, "extensions", "code")

  def capture_stderr
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end

  def ops(store) = store.instance_variable_get(:@operations)

  def refused_reasons = signals.select { |s, _| s == :operation_refused }.map { |_, d| d[:reason] }

  # A client answering what it is told, for shapes redis gems do not give.
  def answering(value)
    Class.new do
      define_method(:get) { |_k| value }
      define_method(:set) { |_k, _v, nx: false| true }
    end.new
  end

  def exe(*args, env: {})
    Open3.capture3({ "REDIS_URL" => ENV.fetch("REDIS_URL") }.merge(env), RbConfig.ruby, "-Ilib", "exe/graphql-armory-publish", *args, chdir: Dir.pwd)
  end

  def write_manifest(dir, name, hash)
    path = File.join(dir, name)
    File.write(path, JSON.generate(hash))
    path
  end

  def apollo(*queries)
    { "format" => "apollo-persisted-query-manifest", "version" => 1,
      "operations" => queries.map { |q| { "id" => sha(q), "name" => "x", "body" => q, "type" => "query" } } }
  end

  QUERY = "{ secret }"

  describe "1 key injection and id shapes" do
    bad = {
      "trailing newline" => "abc\n", "inner newline" => "ab\nc", "crlf" => "abc\r\nGET x", "glob" => "a*", "question" => "a?", "bracket" => "a[b]",
      "space" => "a b", "129 chars" => "a" * 129, "empty" => "", "slash" => "a/b", "null byte" => "a\0b", "unicode" => "é", "1MB" => "a" * 1_000_000
    }
    bad.each do |label, id|
      it "P01 security: id with #{label} never reaches Redis, UNKNOWN_OPERATION" do
        client = sub.new
        r = run(schema_for(redis_store.build(redis: client, on_error: on_error)), id)
        expect(code(r)).to eq("UNKNOWN_OPERATION")
        expect(r["data"]).to be_nil
        expect(client.calls).to eq([])
        expect(ran).to eq([])
      end
    end

    it "P02a security: id with invalid UTF-8 bytes through the plugin is UNKNOWN_OPERATION, not an exception" do
      client = sub.new
      r = run(schema_for(redis_store.build(redis: client, on_error: on_error)), "\xFFabc".dup.force_encoding("UTF-8"))
      expect(code(r)).to eq("UNKNOWN_OPERATION")
      expect(client.calls).to eq([])
    end

    it "P02b security: same invalid id on a Manifest store (baseline shape, for comparison)" do
      r = run(schema_for(manifest_of(QUERY)), "\xFFabc".dup.force_encoding("UTF-8"))
      expect(code(r)).to eq("UNKNOWN_OPERATION")
    end

    it "P02c security: invalid-UTF-8 id, fetch directly" do
      expect(redis_store.build(redis: sub.new, on_error: on_error).fetch("\xFF".dup.force_encoding("UTF-8"))).to be_nil
    end

    it "P02d security: invalid id reachable from a JSON body through PersistedQueries.operation_id" do
      params = JSON.parse(%({"operationId":"\xFFabc"}).dup.force_encoding("UTF-8"))
      id = pq.operation_id(params)
      expect(id).not_to be_nil
      r = run(schema_for(redis_store.build(redis: sub.new, on_error: on_error)), id)
      expect(code(r)).to eq("UNKNOWN_OPERATION")
    end

    it "P02e security: invalid id reachable from a Rack-style query string" do
      id = URI.decode_www_form_component("%FFabc") # what Rack::Utils.unescape does, UTF-8 by default
      expect(id.valid_encoding?).to eq(false)
      r = run(schema_for(redis_store.build(redis: sub.new, on_error: on_error)), id)
      expect(code(r)).to eq("UNKNOWN_OPERATION")
    end

    it "P03a security: UTF-16 encoded id is UNKNOWN_OPERATION, not an exception" do
      r = run(schema_for(redis_store.build(redis: sub.new, on_error: on_error)), "abc".encode("UTF-16LE"))
      expect(code(r)).to eq("UNKNOWN_OPERATION")
    end

    it "P03b preservation: binary-encoded digest id runs the same operation and shares the memo" do
      client = sub.new
      publisher_class.build(redis: client).(manifest_of(QUERY))
      store = redis_store.build(redis: client, on_error: on_error)
      r = run(schema_for(store), sha(QUERY).b)
      expect(r["data"]).to eq("secret" => "SECRET")
      expect(ops(store).size).to eq(1)
      store.fetch(sha(QUERY))
      expect(ops(store).size).to eq(1)
    end

    [1, :sym, ["a"], { "a" => 1 }, 1.5, true].each do |id|
      it "P04 security: non-String id #{id.inspect} refused, no Redis call" do
        client = sub.new
        r = run(schema_for(redis_store.build(redis: client, on_error: on_error)), id)
        expect(code(r)).to eq("UNKNOWN_OPERATION")
        expect(client.calls).to eq([])
      end
    end

    it "P04b security: an object with to_str is not treated as a String by the store" do
      obj = Object.new
      def obj.to_str = "abc"
      expect(redis_store.build(redis: sub.new, on_error: on_error).fetch(obj)).to be_nil
    end

    it "P06 security: a rate-limit key in the same real Redis under another prefix is unreachable, nothing memoized" do
      admin.set("rate:1", "{ secret }", ex: 60)
      store = redis_store.build(redis: admin, prefix: prefix, digest: false, on_error: on_error)
      r = run(schema_for(store), "rate:1")
      expect(code(r)).to eq("UNKNOWN_OPERATION")
      expect(ops(store)).to be_empty
      expect(ran).to eq([])
    end

    it "P07a security: short prefix, digest on: a sibling key reached is refused and not memoized" do
      admin.set("appx#{prefix}", "{ secret }", ex: 60)
      store = redis_store.build(redis: admin, prefix: "app", on_error: on_error)
      r = run(schema_for(store), "x#{prefix}")
      expect(code(r)).to eq("UNKNOWN_OPERATION")
      expect(errors.map(&:class)).to eq([redis_store::CorruptOperation])
      expect(ops(store)).to be_empty
    end

    it "P08a security: nested prefix, digest on: allowlist of a nested prefix is not reachable" do
      nested = "#{prefix}mobile:"
      publisher_class.build(redis: admin, prefix: nested).(manifest_of(QUERY))
      store = redis_store.build(redis: admin, prefix: prefix, on_error: on_error)
      r = run(schema_for(store), "mobile:#{sha(QUERY)}")
      expect(code(r)).to eq("UNKNOWN_OPERATION")
      expect(ran).to eq([])
    end

    it "P09 security: a key of another type under the prefix refuses, on_error, not memoized" do
      id = sha(QUERY + prefix)
      admin.hset("#{prefix}#{id}", "a", "b")
      admin.expire("#{prefix}#{id}", 60)
      store = redis_store.build(redis: admin, prefix: prefix, on_error: on_error)
      r = run(schema_for(store), id)
      expect(code(r)).to eq("UNKNOWN_OPERATION")
      expect(errors.size).to eq(1)
      expect(ops(store)).to be_empty
      expect(refused_reasons).to eq([:unknown_operation])
    end
  end

  describe "2 memory" do
    it "P10a security: 5000 unknown ids add nothing" do
      store = redis_store.build(redis: sub.new, on_error: on_error)
      5000.times { |i| store.fetch(sha(i.to_s)) }
      expect(ops(store)).to be_empty
    end

    it "P10b security: failures add nothing" do
      client = sub.new
      client.fail_with(IOError.new("down"))
      store = redis_store.build(redis: client, on_error: on_error)
      2000.times { |i| store.fetch(sha(i.to_s)) }
      expect(ops(store)).to be_empty
      expect(errors.size).to eq(2000)
    end

    it "P10c security: corrupt and unparseable values add nothing" do
      client = sub.new
      client.set("#{redis_store::DEFAULT_PREFIX}#{sha("a")}", "{ secret }")
      client.set("#{redis_store::DEFAULT_PREFIX}#{sha("{ {")}", "{ {")
      store = redis_store.build(redis: client, on_error: on_error)
      3.times { store.fetch(sha("a")); store.fetch(sha("{ {")) }
      expect(ops(store)).to be_empty
      expect(errors.map(&:class).uniq).to eq([redis_store::CorruptOperation])
    end

    it "P10d security: a corrupt value that gets fixed by nobody stays refused; no id runs twice differently" do
      client = sub.new
      key = "#{redis_store::DEFAULT_PREFIX}#{sha("{ other }")}"
      client.set(key, "{ secret }")
      store = redis_store.build(redis: client, on_error: on_error)
      expect(store.fetch(sha("{ other }"))).to be_nil
      expect(store.fetch(sha("{ secret }"))).to be_nil
    end
  end

  describe "3 digest" do
    it "P12a preservation: digest:false reads and runs an arbitrary id" do
      client = sub.new
      client.set("#{redis_store::DEFAULT_PREFIX}opaque", QUERY)
      r = run(schema_for(redis_store.build(redis: client, digest: false, on_error: on_error)), "opaque")
      expect(r["data"]).to eq("secret" => "SECRET")
    end

    it "P12b security: digest on, sha256 id over another real query is refused and the real query does not run" do
      client = sub.new
      client.set("#{redis_store::DEFAULT_PREFIX}#{sha("{ other }")}", "{ secret }")
      r = run(schema_for(redis_store.build(redis: client, on_error: on_error)), sha("{ other }"))
      expect(code(r)).to eq("UNKNOWN_OPERATION")
      expect(ran).to eq([])
    end

    { md5: Digest::MD5, sha1: Digest::SHA1 }.each do |name, klass|
      it "P13 security: #{name} store runs its digest and refuses a sha256 id over the same query" do
        client = sub.new
        client.set("#{redis_store::DEFAULT_PREFIX}#{klass.hexdigest(QUERY)}", QUERY)
        client.set("#{redis_store::DEFAULT_PREFIX}#{sha(QUERY)}", QUERY)
        schema = schema_for(redis_store.build(redis: client, digest: name, on_error: on_error))
        expect(run(schema, klass.hexdigest(QUERY))["data"]).to eq("secret" => "SECRET")
        expect(code(run(schema, sha(QUERY)))).to eq("UNKNOWN_OPERATION")
      end
    end

    it "P14 security: uppercase hex id is not the digest as checked: refused, memo never holds it" do
      client = sub.new
      client.set("#{redis_store::DEFAULT_PREFIX}#{sha(QUERY).upcase}", QUERY)
      store = redis_store.build(redis: client, on_error: on_error)
      expect(store.fetch(sha(QUERY).upcase)).to be_nil
      expect(ops(store)).to be_empty
    end

    it "P15 preservation: two ids, one body, digest:false: each memo entry holds own id" do
      client = sub.new
      client.set("#{redis_store::DEFAULT_PREFIX}one", QUERY)
      client.set("#{redis_store::DEFAULT_PREFIX}two", QUERY)
      store = redis_store.build(redis: client, digest: false, on_error: on_error)
      expect(store.fetch("one").id).to eq("one")
      expect(store.fetch("two").id).to eq("two")
    end

    [nil, "sha256", :bogus, true].each do |d|
      it "P16a security: build refuses digest #{d.inspect}" do
        expect { redis_store.build(redis: sub.new, digest: d) }.to raise_error(pq::ConfigurationError)
      end
    end

    it "P16b security: RedisStore.new(digest: nil) must not silently drop the digest check" do
      client = sub.new
      client.set("#{redis_store::DEFAULT_PREFIX}#{sha("{ other }")}", "{ secret }")
      result = begin
        redis_store.new(redis: client, digest: nil, on_error: on_error).fetch(sha("{ other }"))
      rescue StandardError, KeyError
        nil
      end
      expect(result).to be_nil
    end

    it "P17 security: build refuses non-String prefix and new with empty prefix does not reach bare keys" do
      expect { redis_store.build(redis: sub.new, prefix: :x) }.to raise_error(pq::ConfigurationError)
      expect { publisher_class.build(redis: sub.new, prefix: nil) }.to raise_error(pq::ConfigurationError)
    end
  end

  describe "4 encoding" do
    let(:greek) { 'query Greeting { greeting(name: "José ñ 日本語") }' }

    it "P18a preservation: non-ASCII through real Redis runs, with the client also sending the same text" do
      publisher_class.build(redis: admin, prefix: prefix).(manifest_of(greek))
      schema = schema_for(redis_store.build(redis: Redis.new(url: ENV.fetch("REDIS_URL")), prefix: prefix, on_error: on_error))
      expect(run(schema, sha(greek))["data"]).to eq("greeting" => "hi José ñ 日本語")
      expect(run(schema, sha(greek), text: greek)["data"]).to eq("greeting" => "hi José ñ 日本語")
    end

    it "P19a security: stored invalid UTF-8 outside strings, right digest: refused, no raise" do
      body = "{ secret \xFF }".b
      admin.set("#{prefix}#{sha(body)}", body, ex: 60)
      store = redis_store.build(redis: admin, prefix: prefix, on_error: on_error)
      r = run(schema_for(store), sha(body))
      expect(code(r)).to eq("UNKNOWN_OPERATION")
      expect(ran).to eq([])
      expect(errors.map(&:class)).to eq([redis_store::CorruptOperation])
    end

    it "P19b security: stored invalid UTF-8 in a string literal, right digest: refused or ok but no raise and no corrupt JSON" do
      body = "{ greeting(name: \"\xFF\") }".b
      admin.set("#{prefix}#{sha(body)}", body, ex: 60)
      store = redis_store.build(redis: admin, prefix: prefix, on_error: on_error)
      r = run(schema_for(store), sha(body))
      expect(code(r)).to eq("UNKNOWN_OPERATION")
      expect(errors.map(&:class)).to eq([redis_store::CorruptOperation])
    end

    it "P20 security: stored BOM + query with right digest does not raise; outcome recorded by parse" do
      body = "\xEF\xBB\xBF{ secret }".dup.force_encoding("UTF-8")
      admin.set("#{prefix}#{sha(body)}", body, ex: 60)
      r = run(schema_for(redis_store.build(redis: admin, prefix: prefix, on_error: on_error)), sha(body))
      expect(r["data"]).to eq("secret" => "SECRET").or(be_nil)
      puts "P20 BOM outcome: #{r.inspect} errors=#{errors.map(&:class)}"
    end

    it "P21 preservation: a client answering ASCII-8BIT is read as text" do
      store = redis_store.build(redis: answering(greek.b), on_error: on_error)
      op = store.fetch(sha(greek))
      expect(op.body.encoding).to eq(Encoding::UTF_8)
      expect(op.body).to eq(greek)
      expect(run(schema_for(store), sha(greek), text: greek)["data"]).to eq("greeting" => "hi José ñ 日本語")
    end

    it "P21b security: a frozen answer does not raise" do
      expect(redis_store.build(redis: answering(QUERY.dup.freeze), on_error: on_error).fetch(sha(QUERY))).not_to be_nil
    end

    it "P22 preservation: publisher reruns report unchanged, not conflict, on non-ASCII with a binary-answering Redis" do
      m = manifest_of(greek)
      publisher_class.build(redis: admin, prefix: prefix).(m)
      binary = Redis.new(url: ENV.fetch("REDIS_URL"))
      expect(publisher_class.build(redis: binary, prefix: prefix).(m).to_h).to eq(published: 0, unchanged: 1)
      binary_answer = Class.new do
        def initialize(v) = @v = v
        def get(_k) = @v
        def set(_k, _v, nx: false) = false
      end.new(greek.b)
      expect(publisher_class.build(redis: binary_answer).(m).to_h).to eq(published: 0, unchanged: 1)
    end

    ["", "   ", "# only a comment\n", "\n\n"].each do |body|
      it "P23 security: stored value #{body.inspect} with the right digest refuses" do
        admin.set("#{prefix}#{sha(body)}", body, ex: 60)
        r = run(schema_for(redis_store.build(redis: admin, prefix: prefix, on_error: on_error)), sha(body))
        expect(code(r)).to eq("UNKNOWN_OPERATION")
        expect(errors.map(&:class)).to eq([redis_store::CorruptOperation])
      end
    end

    it "P23b security: a stored fragment-only or schema-definition document with right digest does not run data" do
      body = "fragment F on Query { secret }"
      admin.set("#{prefix}#{sha(body)}", body, ex: 60)
      r = run(schema_for(redis_store.build(redis: admin, prefix: prefix, on_error: on_error)), sha(body))
      expect(r["data"]).to be_nil
      expect(ran).to eq([])
    end
  end

  describe "5 outages" do
    let(:down_url) { "redis://:#{secret}@127.0.0.1:1/0" }
    let(:down) { Redis.new(url: down_url, timeout: 0.2, reconnect_attempts: 0) }

    it "P24 security: real unreachable Redis: UNKNOWN_OPERATION, on_error, :operation_refused, nothing runs, no secret in the response" do
      schema = schema_for(redis_store.build(redis: down, on_error: on_error))
      r = run(schema, sha(QUERY))
      expect(code(r)).to eq("UNKNOWN_OPERATION")
      expect(JSON.generate(r)).not_to include(secret)
      expect(JSON.generate(r)).not_to include("127.0.0.1")
      expect(ran).to eq([])
      expect(errors.size).to eq(1)
      expect(refused_reasons).to eq([:unknown_operation])
    end

    it "P25 security: id already read keeps its result in an outage with nothing reported" do
      client = sub.new
      publisher_class.build(redis: client).(manifest_of(QUERY))
      schema = schema_for(redis_store.build(redis: client, on_error: on_error))
      run(schema, sha(QUERY))
      client.fail_with(IOError.new("down"))
      expect(run(schema, sha(QUERY))["data"]).to eq("secret" => "SECRET")
      expect(errors).to eq([])
      expect(refused_reasons).to eq([])
    end

    it "P26 preservation: a blackholed Redis honours the documented timeout" do
      slow = Redis.new(url: "redis://:#{secret}@10.255.255.1:6379/0", timeout: 0.5, reconnect_attempts: 0)
      store = redis_store.build(redis: slow, on_error: on_error)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(store.fetch(sha(QUERY))).to be_nil
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
    end

    it "P27 security: client raising non-StandardError: propagates and nothing runs" do
      boom = Class.new do
        def get(_k) = raise(NotImplementedError, "boom")
        def set(*, **) = nil
      end.new
      schema = schema_for(redis_store.build(redis: boom, on_error: on_error))
      expect { run(schema, sha(QUERY)) }.to raise_error(NotImplementedError)
      expect(ran).to eq([])
    end

    it "P28a security: raising on_error fails the request on this engine and nothing runs" do
      client = sub.new
      client.fail_with(IOError.new("down"))
      schema = schema_for(redis_store.build(redis: client, on_error: ->(_e) { raise ArgumentError, "reporter down" }))
      expect { run(schema, sha(QUERY)) }.to raise_error(ArgumentError, "reporter down")
      expect(ran).to eq([])
    end

    it "P28b security: raising on_error inside a multiplex aborts the whole batch, nothing runs" do
      client = sub.new
      publisher_class.build(redis: client).(manifest_of("{ other }"))
      store = redis_store.build(redis: client, on_error: ->(_e) { raise ArgumentError, "reporter down" })
      schema = schema_for(store)
      store.fetch(sha("{ other }"))
      client.fail_with(IOError.new("down"))
      expect do
        schema.multiplex([{ context: { operation_id: sha("{ other }") }, root_value: probe_root },
                          { context: { operation_id: sha(QUERY) }, root_value: probe_root }])
      end.to raise_error(ArgumentError)
      expect(ran).to eq([])
    end

    it "P29 security: real connection error message handed to on_error: does it hold the password? (doc example reports it raw)" do
      redis_store.build(redis: down, on_error: on_error).fetch(sha(QUERY))
      e = errors.first
      puts "P29 class=#{e.class} message=#{e.message.gsub(secret, "<SECRET>")} cause=#{e.cause&.class}: #{e.cause&.message&.gsub(secret, "<SECRET>")}"
      expect(e.message).not_to include(secret)
      expect(e.cause&.message.to_s).not_to include(secret)
    end

    it "P29b security: wrong-password real error message does not hold the password" do
      host = URI(ENV.fetch("REDIS_URL")).host
      bad = Redis.new(url: "redis://nouser:#{secret}@#{host}:6379/0", reconnect_attempts: 0)
      redis_store.build(redis: bad, on_error: on_error).fetch(sha(QUERY))
      e = errors.first
      puts "P29b class=#{e.class} message=#{e.message.gsub(secret, "<SECRET>")}"
      expect(e.message).not_to include(secret)
    end

    it "P30 security: default warning on a real failure prints class only, no URL or password" do
      out = capture_stderr { redis_store.build(redis: down).fetch(sha(QUERY)) }
      expect(out).not_to include(secret)
      expect(out).not_to include("127.0.0.1")
      expect(out).to match(/\Agraphql-armory: persisted query store failed \([\w:]+\)\n\z/)
    end

    it "P31 security: strict:false, failing store, id and text: refused, raw text does not run" do
      client = sub.new
      client.fail_with(IOError.new("down"))
      schema = schema_for(redis_store.build(redis: client, on_error: on_error), strict: false)
      r = run(schema, sha(QUERY), text: QUERY)
      expect(code(r)).to eq("UNKNOWN_OPERATION")
      expect(ran).to eq([])
    end

    it "P32 security: strict:false, unknown id and raw text: refused" do
      schema = schema_for(redis_store.build(redis: sub.new, on_error: on_error), strict: false)
      r = run(schema, "unknown", text: QUERY)
      expect(code(r)).to eq("UNKNOWN_OPERATION")
      expect(ran).to eq([])
    end

    it "P33 security: strict:false, corrupt value, id and raw text: refused" do
      client = sub.new
      client.set("#{redis_store::DEFAULT_PREFIX}#{sha(QUERY)}", "{ other }")
      schema = schema_for(redis_store.build(redis: client, on_error: on_error), strict: false)
      r = run(schema, sha(QUERY), text: QUERY)
      expect(code(r)).to eq("UNKNOWN_OPERATION")
      expect(ran).to eq([])
    end

    [1, false, true, ["{ secret }"], { "a" => 1 }, :sym].each do |value|
      it "P34 security: Redis answering #{value.inspect} refuses" do
        store = redis_store.build(redis: answering(value), on_error: on_error)
        expect(store.fetch(sha(QUERY))).to be_nil
        expect(ops(store)).to be_empty
        expect(errors.map(&:class)).to eq([redis_store::CorruptOperation])
      end
    end

    it "P34b security: a real outage during strict mode with raw text and no id is still RAW_QUERY_REFUSED" do
      schema = schema_for(redis_store.build(redis: down, on_error: on_error))
      expect(code(run(schema, text: QUERY))).to eq("RAW_QUERY_REFUSED")
      expect(errors).to eq([])
    end

    it "P34c security: a Redis that recovers answers the id, no negative memo" do
      client = sub.new
      client.fail_with(IOError.new("down"))
      publisher_store = redis_store.build(redis: client, on_error: on_error)
      expect(publisher_store.fetch(sha(QUERY))).to be_nil
      client.recover
      publisher_class.build(redis: client).(manifest_of(QUERY))
      expect(publisher_store.fetch(sha(QUERY))).not_to be_nil
    end
  end

  describe "6 publisher" do
    it "P35 security: 8 concurrent runs of one manifest: every run ok, each id published once" do
      queries = (1..50).map { |i| "query Q#{i} { secret }" }
      m = manifest_of(*queries)
      results = 8.times.map do
        Thread.new { publisher_class.build(redis: Redis.new(url: ENV.fetch("REDIS_URL")), prefix: prefix).(m) }
      end.map(&:value)
      expect(results.sum(&:published)).to eq(50)
      expect(results.map { |r| r.published + r.unchanged }.uniq).to eq([50])
    end

    it "P36 security: concurrent runs with different bodies under one id: one wins, the rest raise, value is the winner's" do
      bodies = (1..8).map { |i| "query Q#{i} { secret }" }
      outcomes = bodies.map do |body|
        Thread.new do
          m = pq::Manifest.new({ "same-id" => body }, digest: false)
          begin
            publisher_class.build(redis: Redis.new(url: ENV.fetch("REDIS_URL")), prefix: prefix).(m)
            [:ok, body]
          rescue publisher_class::PublishError
            [:refused, body]
          end
        end
      end.map(&:value)
      expect(outcomes.count { |o, _| o == :ok }).to eq(1)
      expect(admin.get("#{prefix}same-id")).to eq(outcomes.find { |o, _| o == :ok }.last)
    end

    it "P37 preservation: a run that dies midway and reruns finishes with nothing changed" do
      queries = (1..5).map { |i| "query R#{i} { secret }" }
      dying = Class.new do
        def initialize(r, n) = (@r = r; @n = n; @i = 0)
        def get(k) = @r.get(k)
        def set(k, v, nx: false)
          @i += 1
          raise IOError, "died" if @i > @n
          @r.set(k, v, nx: nx)
        end
      end
      m = manifest_of(*queries)
      expect { publisher_class.build(redis: dying.new(admin, 2), prefix: prefix).(m) }.to raise_error(IOError)
      expect(publisher_class.build(redis: admin, prefix: prefix).(m).to_h).to eq(published: 3, unchanged: 2)
    end

    it "P38 security: id conflict midway: stored value intact, PublishError, message quotes neither query" do
      admin.set("#{prefix}b", "{ other }", ex: 60)
      m = pq::Manifest.new({ "a" => "query A { secret }", "b" => "query B { secret }", "c" => "query C { secret }" }, digest: false)
      expect { publisher_class.build(redis: admin, prefix: prefix).(m) }.to raise_error(publisher_class::PublishError) { |e|
        expect(e.message).not_to include("secret")
        expect(e.message).not_to include("{ other }")
      }
      expect(admin.get("#{prefix}b")).to eq("{ other }")
      puts "P38 partial: a=#{admin.get("#{prefix}a").inspect} c=#{admin.get("#{prefix}c").inspect}"
    end

    it "P39a preservation: redis-rb real set(nx:) answers true then false" do
      expect(admin.set("#{prefix}nx", "v", nx: true, ex: 60)).to eq(true)
      expect(admin.set("#{prefix}nx", "v", nx: true, ex: 60)).to eq(false)
    end

    it "P39b security: a client answering 'OK' and nil like a raw client still detects a conflict" do
      raw = Class.new do
        attr_reader :data
        def initialize = @data = {}
        def get(k) = @data[k]
        def set(k, v, nx: false)
          return nil if nx && @data.key?(k)
          @data[k] = v
          "OK"
        end
      end.new
      m = pq::Manifest.new({ "a" => "query A { secret }" }, digest: false)
      expect(publisher_class.build(redis: raw).(m).to_h).to eq(published: 1, unchanged: 0)
      expect(publisher_class.build(redis: raw).(m).to_h).to eq(published: 0, unchanged: 1)
      other = pq::Manifest.new({ "a" => "query B { secret }" }, digest: false)
      expect { publisher_class.build(redis: raw).(other) }.to raise_error(publisher_class::PublishError)
    end

    it "P39c preservation: bare ConnectionPool is refused at build, not silently" do
      require "connection_pool"
      pool = ConnectionPool.new(size: 1) { admin }
      expect { publisher_class.build(redis: pool) }.to raise_error(pq::ConfigurationError, /redis:/)
      expect { redis_store.build(redis: pool) }.to raise_error(pq::ConfigurationError, /redis:/)
    end

    it "P39d preservation: ConnectionPool::Wrapper works for both" do
      require "connection_pool"
      wrapper = ConnectionPool::Wrapper.new(size: 2) { Redis.new(url: ENV.fetch("REDIS_URL")) }
      expect(publisher_class.build(redis: wrapper, prefix: prefix).(manifest_of(QUERY)).to_h).to eq(published: 1, unchanged: 0)
      expect(publisher_class.build(redis: wrapper, prefix: prefix).(manifest_of(QUERY)).to_h).to eq(published: 0, unchanged: 1)
      expect(redis_store.build(redis: wrapper, prefix: prefix, on_error: on_error).fetch(sha(QUERY))).not_to be_nil
    end

    it "P41 security: subclass of Manifest and Manifests are refused, by class" do
      sub_manifest = Class.new(pq::Manifest).new({ sha(QUERY) => QUERY })
      expect { publisher_class.build(redis: sub.new).(sub_manifest) }.to raise_error(pq::ConfigurationError)
      expect { publisher_class.build(redis: sub.new).(pq::Manifests.new([manifest_of(QUERY)])) }.to raise_error(pq::ConfigurationError)
    end

    it "P47 security: a key of another type at publish: exit 1, not overwritten" do
      Dir.mktmpdir do |dir|
        path = write_manifest(dir, "m.json", apollo(QUERY))
        admin.rpush("#{prefix}#{sha(QUERY)}", "x")
        admin.expire("#{prefix}#{sha(QUERY)}", 60)
        o, e, st = exe("--prefix", prefix, path)
        expect(st.exitstatus).to eq(1)
        expect(e).to match(/publishing failed \(Redis::/)
        expect(o).to eq("")
        expect(admin.type("#{prefix}#{sha(QUERY)}")).to eq("list")
      end
    end
  end

  describe "6b documented ACLs, verbatim" do
    let(:acl_lines) { File.read(doc_path).scan(/^\s*(ACL SETUSER .+)$/).flatten }
    let(:host) { URI(ENV.fetch("REDIS_URL")).host }
    let(:unique_q) { "query Acl#{SecureRandom.hex(6)} { secret }" }

    before { acl_lines.each { |line| admin.call(*line.split(" ")) } }
    after do
      admin.call("ACL", "DELUSER", "armory-server")
      admin.call("ACL", "DELUSER", "armory-ci")
      admin.del("#{redis_store::DEFAULT_PREFIX}#{sha(unique_q)}")
    end

    def server(db = 0) = Redis.new(url: "redis://armory-server:SERVER_PASSWORD@#{host}:6379/#{db}", reconnect_attempts: 0)
    def ci(db = 0) = Redis.new(url: "redis://armory-ci:CI_PASSWORD@#{host}:6379/#{db}", reconnect_attempts: 0)

    it "P43 security: publisher with the read-only server user: exit 1, nothing stored, no password in output" do
      Dir.mktmpdir do |dir|
        path = write_manifest(dir, "m.json", apollo(unique_q))
        o, e, st = exe(path, env: { "REDIS_URL" => "redis://armory-server:SERVER_PASSWORD@#{host}:6379/0" })
        expect(st.exitstatus).to eq(1)
        expect(o + e).not_to include("SERVER_PASSWORD")
        expect(admin.get("#{redis_store::DEFAULT_PREFIX}#{sha(unique_q)}")).to be_nil
      end
    end

    it "P46 security (documented limit): the CI's user can overwrite without NX; digest on keeps the query from running" do
      c = ci
      c.set("#{redis_store::DEFAULT_PREFIX}#{sha(unique_q)}", "{ secret }")
      store = redis_store.build(redis: server, on_error: on_error)
      expect(store.fetch(sha(unique_q))).to be_nil
    end
  end

  describe "6c other redis gems" do
    def with_other_gems
      $probe_other_gems_dir ||= begin
        dir = Dir.mktmpdir("othergems")
        Bundler.with_unbundled_env do
          out, st = Open3.capture2e("gem", "install", "--no-document", "--install-dir", dir, "redis:4.8.1", "redis-namespace:1.11.0", "connection_pool")
          raise out unless st.success?
        end
        dir
      end
      yield $probe_other_gems_dir
    end

    def script(body, gemdir)
      Bundler.with_unbundled_env do
        env = { "GEM_PATH" => "#{gemdir}:#{Bundler.bundle_path rescue "/bundle/ruby/3.3.0"}:/bundle/ruby/3.3.0", "REDIS_URL" => ENV.fetch("REDIS_URL") }
        Open3.capture3(env, RbConfig.ruby, "-I#{Dir.pwd}/lib", "-e", body)
      end
    end

    it "P39h security: redis 4.8 error message holds no password" do
      with_other_gems do |dir|
        o, e, st = script(<<~RUBY, dir)
          gem "redis", "4.8.1"
          require "redis"
          require "graphql"
          require "graphql/armory"
          pq = GraphQL::Armory::PersistedQueries
          r = Redis.new(url: "redis://:#{secret}@127.0.0.1:1/0", reconnect_attempts: 0)
          pq::RedisStore.build(redis: r, on_error: ->(err) { puts "\#{err.class}: \#{err.message}" }).fetch("abc")
          pq::RedisStore.build(redis: r).fetch("abc")
        RUBY
        puts "P39h: #{o.gsub(secret, "<SECRET>")} #{e[0, 400].gsub(secret, "<SECRET>")}"
        expect(st.exitstatus).to eq(0)
        expect(o + e).not_to include("s3cretP4ss")
      end
    end
  end

  describe "7 executable" do
    around { |ex| Dir.mktmpdir { |dir| @dir = dir; ex.run } }

    def assert_fail(o, e, st, message = nil)
      expect(st.exitstatus).to eq(1)
      expect(o + e).not_to include("s3cretP4ss")
      expect(e).to match(message) if message
      expect(e).not_to include("#{Dir.pwd}/lib"), "backtrace leaked: #{e[0, 300]}"
    end

    it "P48 preservation: real publish exits 0, rerun unchanged, value is the text" do
      path = write_manifest(@dir, "m.json", apollo(QUERY))
      o, e, st = exe("--prefix", prefix, path)
      expect([o, e, st.exitstatus]).to eq(["#{path}: 1 published, 0 unchanged\n", "", 0])
      o, = exe("--prefix", prefix, path)
      expect(o).to eq("#{path}: 0 published, 1 unchanged\n")
      expect(admin.get("#{prefix}#{sha(QUERY)}")).to eq(QUERY)
    end

    it "P49a security: bad digest name" do
      path = write_manifest(@dir, "m.json", apollo(QUERY))
      o, e, st = exe("--digest", "crc", "--prefix", prefix, path)
      assert_fail(o, e, st, /unknown digest/)
      expect(admin.get("#{prefix}#{sha(QUERY)}")).to be_nil
    end

    it "P49b preservation: --digest false and sha1 and md5" do
      path = write_manifest(@dir, "f.json", { "opaque" => QUERY })
      o, _, st = exe("--digest", "false", "--prefix", prefix, path)
      expect(st.exitstatus).to eq(0)
      expect(o).to include("1 published")
      sha1 = write_manifest(@dir, "s.json", { Digest::SHA1.hexdigest(QUERY) => QUERY })
      expect(exe("--digest", "sha1", "--prefix", prefix, sha1).last.exitstatus).to eq(0)
      md5 = write_manifest(@dir, "m5.json", { Digest::MD5.hexdigest(QUERY) => QUERY })
      expect(exe("--digest", "md5", "--prefix", prefix, md5).last.exitstatus).to eq(0)
      expect(exe("--digest", "sha1", "--prefix", prefix, md5).last.exitstatus).to eq(1)
    end

    it "P49c security: empty --prefix" do
      path = write_manifest(@dir, "m.json", apollo(QUERY))
      o, e, st = exe("--prefix", "", path)
      assert_fail(o, e, st, /prefix/)
    end

    it "P49d security: unknown option" do
      o, e, st = exe("--nope", "x.json")
      assert_fail(o, e, st, /invalid option/)
    end

    it "P49e security: option missing its argument" do
      o, e, st = exe("--digest")
      assert_fail(o, e, st, /missing argument/)
    end

    it "P49f security: missing file" do
      o, e, st = exe(File.join(@dir, "nope.json"))
      assert_fail(o, e, st, /cannot be read/)
    end

    it "P49g security: a directory" do
      o, e, st = exe(@dir)
      assert_fail(o, e, st, /cannot be read/)
    end

    it "P49h security: invalid JSON" do
      File.write(File.join(@dir, "b.json"), "{nope")
      o, e, st = exe(File.join(@dir, "b.json"))
      assert_fail(o, e, st, /not valid JSON/)
    end

    it "P49i security: file with invalid UTF-8" do
      File.binwrite(File.join(@dir, "b.json"), "{\"a\xFF\":\"{ b }\"}".b)
      o, e, st = exe("--digest", "false", "--prefix", prefix, File.join(@dir, "b.json"))
      puts "P49i: #{st.exitstatus} #{o.inspect} #{e.inspect}"
      assert_fail(o, e, st)
    end

    it "P49j security: empty argv prints usage, exit 1" do
      o, e, st = exe
      assert_fail(o, e, st, /Usage/)
    end

    it "P49k security: no REDIS_URL, exit 1" do
      path = write_manifest(@dir, "m.json", apollo(QUERY))
      o, e, st = exe(path, env: { "REDIS_URL" => nil })
      assert_fail(o, e, st, /REDIS_URL is not set/)
    end

    it "P49l security: edited manifest (digest wrong): exit 1, nothing stored, quotes no query" do
      path = write_manifest(@dir, "m.json", { sha("{ other }") => QUERY })
      o, e, st = exe("--prefix", prefix, path)
      assert_fail(o, e, st, /not the digest/)
      expect(e).not_to include("secret")
      expect(admin.keys("#{prefix}*")).to eq([])
    end

    it "P49m security: empty manifest" do
      path = write_manifest(@dir, "m.json", {})
      o, e, st = exe("--prefix", prefix, path)
      assert_fail(o, e, st, /no operations/)
    end

    {
      "unreachable" => "redis://user:%s@127.0.0.1:1/0",
      "unresolvable" => "redis://user:%s@no-such-host.invalid:6379/0",
      "malformed" => "redis://user:%s@bad host:6379",
      "http scheme" => "http://user:%s@127.0.0.1:1/0",
      "garbage" => "%s",
      "bad port" => "redis://user:%s@127.0.0.1:notaport/0",
      "bad db" => "redis://user:%s@127.0.0.1:1/x",
      "rediss" => "rediss://user:%s@127.0.0.1:1/0",
    }.each do |label, template|
      it "P50 security: #{label} REDIS_URL with a password: exit 1, no password in output, no backtrace" do
        path = write_manifest(@dir, "m.json", apollo(QUERY))
        o, e, st = exe(path, env: { "REDIS_URL" => format(template, secret) })
        puts "P50 #{label}: #{st.exitstatus} #{e.gsub(secret, "<SECRET>").strip[0, 200]}"
        assert_fail(o, e, st, /publishing failed/)
      end
    end

    it "P50i security: wrong password against the real Redis: exit 1, no password in output" do
      path = write_manifest(@dir, "m.json", apollo(QUERY))
      host = URI(ENV.fetch("REDIS_URL")).host
      o, e, st = exe(path, env: { "REDIS_URL" => "redis://nouser:#{secret}@#{host}:6379/0" })
      assert_fail(o, e, st, /publishing failed/)
    end

    it "P53 preservation: --help and --version exit codes" do
      o, e, st = exe("--help")
      puts "P53 help: #{st.exitstatus} #{o.inspect} #{e.inspect}"
      expect(st.exitstatus).to eq(0)
      expect(o).to include("--digest").and include("--prefix")
      o, e, st = exe("--version")
      puts "P53 version: #{st.exitstatus} #{o.inspect} #{e.inspect}"
    end

    it "P54a security: several files, conflict in the second: first stays, exit 1" do
      first = write_manifest(@dir, "a.json", { "x" => "{ a }" })
      second = write_manifest(@dir, "b.json", { "x" => "{ b }" })
      o, e, st = exe("--digest", "false", "--prefix", prefix, first, second)
      expect(st.exitstatus).to eq(1)
      expect(e).to include("already holds another query")
      expect(o).to include("a.json: 1 published")
      expect(admin.get("#{prefix}x")).to eq("{ a }")
    end

    it "P54b security: a bad second file: nothing stored from the first" do
      first = write_manifest(@dir, "a.json", apollo(QUERY))
      File.write(File.join(@dir, "b.json"), "{nope")
      o, e, st = exe("--prefix", prefix, first, File.join(@dir, "b.json"))
      assert_fail(o, e, st, /not valid JSON/)
      expect(admin.keys("#{prefix}*")).to eq([])
    end

    it "P54c security: a manifest with an id RedisStore cannot read: exit 1, nothing stored" do
      path = write_manifest(@dir, "m.json", { "good" => "{ a }", "bad\nid" => "{ b }" })
      o, e, st = exe("--digest", "false", "--prefix", prefix, path)
      assert_fail(o, e, st, /cannot read/)
      expect(admin.keys("#{prefix}*")).to eq([])
    end

    # Installed from the gemspec.
    def built_gem
      $probe_built_gem ||= begin
        out = Dir.mktmpdir("gemout")
        Bundler.with_unbundled_env do
          o, st = Open3.capture2e("gem", "build", "graphql-armory.gemspec", "--output", File.join(out, "armory.gem"), chdir: Dir.pwd)
          raise o unless st.success?
        end
        File.join(out, "armory.gem")
      end
    end

    def installed(with_redis:)
      $probe_installed ||= {}
      $probe_installed[with_redis] ||= begin
        dir = Dir.mktmpdir("gemhome")
        list = [built_gem]
        list << "redis" if with_redis
        Bundler.with_unbundled_env do
          o, st = Open3.capture2e({ "GEM_HOME" => dir, "GEM_PATH" => dir }, "gem", "install", "--no-document", "--install-dir", dir, "--bindir", "#{dir}/bin", *list)
          raise o unless st.success?
        end
        dir
      end
    end

    def run_installed(dir, *args, env: {})
      Bundler.with_unbundled_env do
        Open3.capture3({ "GEM_HOME" => dir, "GEM_PATH" => dir, "REDIS_URL" => ENV.fetch("REDIS_URL") }.merge(env), "#{dir}/bin/graphql-armory-publish", *args)
      end
    end

  end

  describe "8 gate" do
    it "P55a security: strict:false refuses RedisStore.new" do
      expect { schema_for(redis_store.new, strict: false) }.to raise_error(pq::ConfigurationError, /strict: false needs a store/)
    end

    it "P55b security: strict:false refuses build(redis: Client::Null.new)" do
      expect { schema_for(redis_store.build(redis: redis_store::Client::Null.new), strict: false) }.to raise_error(pq::ConfigurationError)
    end

    it "P55c preservation: strict:false accepts a wired one, a subclass of Null counts as unwired" do
      expect { schema_for(redis_store.build(redis: sub.new), strict: false) }.not_to raise_error
      expect(redis_store.new(redis: Class.new(redis_store::Client::Null).new).empty?).to eq(true)
    end

    it "P56a preservation: child schema inherits the store and the refusal" do
      client = sub.new
      publisher_class.build(redis: client).(manifest_of(QUERY))
      parent = schema_for(redis_store.build(redis: client, on_error: on_error))
      child = Class.new(parent)
      expect(run(child, sha(QUERY))["data"]).to eq("secret" => "SECRET")
      expect(code(run(child, text: "{ secret }"))).to eq("RAW_QUERY_REFUSED")
      expect(code(run(child, "nope"))).to eq("UNKNOWN_OPERATION")
    end

    it "P56b preservation: one store on two schemas: both run, one Redis read, no cross-talk in refusals" do
      client = sub.new
      publisher_class.build(redis: client).(manifest_of(QUERY))
      store = redis_store.build(redis: client, on_error: on_error)
      a = schema_for(store)
      b = schema_for(store)
      client.calls.clear
      expect(run(a, sha(QUERY))["data"]).to eq("secret" => "SECRET")
      expect(run(b, sha(QUERY))["data"]).to eq("secret" => "SECRET")
      expect(client.calls.size).to eq(1)
    end

    it "P57 preservation: 40 threads on one id with a real Redis: same answer, one memo entry" do
      publisher_class.build(redis: admin, prefix: prefix).(manifest_of(QUERY))
      wrapper = Redis.new(url: ENV.fetch("REDIS_URL"))
      store = redis_store.build(redis: wrapper, prefix: prefix, on_error: on_error)
      answers = 40.times.map { Thread.new { store.fetch(sha(QUERY)) } }.map(&:value)
      expect(answers.compact.size).to eq(40)
      expect(answers.map(&:object_id).uniq.size).to be <= 40
      expect(store.fetch(sha(QUERY))).to equal(store.fetch(sha(QUERY)))
      expect(ops(store).size).to eq(1)
      expect(errors).to eq([])
    end

    it "P58 preservation: who answers: fetch is the store's own, query class holds Lookup" do
      expect(redis_store.instance_method(:fetch).owner).to eq(redis_store)
      expect(schema_for(redis_store.build(redis: sub.new)).query_class.include?(pq::Lookup)).to eq(true)
    end

    it "P58b security: operation returned is frozen, mutating it raises" do
      client = sub.new
      publisher_class.build(redis: client).(manifest_of(QUERY))
      op = redis_store.build(redis: client, on_error: on_error).fetch(sha(QUERY))
      expect(op).to be_frozen
      expect(op.body).to be_frozen
      expect(op.id).to be_frozen
    end

    it "P58c security: the stored query runs, never the text with a known id and a document supplied" do
      client = sub.new
      publisher_class.build(redis: client).(manifest_of(QUERY))
      schema = schema_for(redis_store.build(redis: client, on_error: on_error))
      r = execute_query(schema, nil, document: GraphQL.parse("{ other }"), context: { operation_id: sha(QUERY) }, root_value: probe_root).to_h
      expect(code(r)).to eq("OPERATION_MISMATCH")
      expect(ran).to eq([])
    end
  end

  describe "9 docs" do
    let(:docs) { File.read(doc_path) }

    it "D1 security: row 1: Redis down, already read: normal result, nothing seen" do
      client = sub.new
      publisher_class.build(redis: client).(manifest_of(QUERY))
      schema = schema_for(redis_store.build(redis: client, on_error: on_error))
      run(schema, sha(QUERY))
      signals.clear
      client.fail_with(IOError.new("x"))
      expect(run(schema, sha(QUERY))["data"]).to eq("secret" => "SECRET")
      expect(errors).to eq([])
      expect(refused_reasons).to eq([])
    end

    it "D2 security: row 2: down, not read: UNKNOWN_OPERATION, on_error with the error, :operation_refused" do
      client = sub.new
      failure = IOError.new("x")
      client.fail_with(failure)
      r = run(schema_for(redis_store.build(redis: client, on_error: on_error)), sha(QUERY))
      expect(code(r)).to eq("UNKNOWN_OPERATION")
      expect(errors).to eq([failure])
      expect(refused_reasons).to eq([:unknown_operation])
    end

    it "D3 security: row 3: never published: UNKNOWN_OPERATION, :operation_refused, no on_error" do
      r = run(schema_for(redis_store.build(redis: admin, prefix: prefix, on_error: on_error)), sha(QUERY))
      expect(code(r)).to eq("UNKNOWN_OPERATION")
      expect(errors).to eq([])
      expect(refused_reasons).to eq([:unknown_operation])
    end

    it "D4a security: row 4: not the digest: CorruptOperation, :operation_refused" do
      admin.set("#{prefix}#{sha("{ other }")}", QUERY, ex: 60)
      r = run(schema_for(redis_store.build(redis: admin, prefix: prefix, on_error: on_error)), sha("{ other }"))
      expect(code(r)).to eq("UNKNOWN_OPERATION")
      expect(errors.map(&:class)).to eq([redis_store::CorruptOperation])
      expect(errors.first.message).not_to include("secret")
      expect(refused_reasons).to eq([:unknown_operation])
    end

    it "D4b security: row 4: does not parse: CorruptOperation, :operation_refused" do
      body = "{ secret"
      admin.set("#{prefix}#{sha(body)}", body, ex: 60)
      r = run(schema_for(redis_store.build(redis: admin, prefix: prefix, on_error: on_error)), sha(body))
      expect(code(r)).to eq("UNKNOWN_OPERATION")
      expect(errors.map(&:class)).to eq([redis_store::CorruptOperation])
      expect(refused_reasons).to eq([:unknown_operation])
    end

    it "D5 security: row 5: CI publishes another query: nothing changes for clients, PublishError, exit 1" do
      Dir.mktmpdir do |dir|
        admin.set("#{prefix}x", "{ secret }", ex: 60)
        schema = schema_for(redis_store.build(redis: Redis.new(url: ENV.fetch("REDIS_URL")), prefix: prefix, digest: false, on_error: on_error))
        expect(run(schema, "x")["data"]).to eq("secret" => "SECRET")
        path = write_manifest(dir, "m.json", { "x" => "{ other }" })
        _, e, st = exe("--digest", "false", "--prefix", prefix, path)
        expect(st.exitstatus).to eq(1)
        expect(e).to include("already holds another query")
        expect(run(schema, "x")["data"]).to eq("secret" => "SECRET")
        expect(admin.get("#{prefix}x")).to eq("{ secret }")
      end
    end

    it "D6 preservation: raw SET NX contract, default prefix, value is the query text, refused SET returns nil" do
      id = sha("query Raw#{prefix.tr(":", "_")} { secret }")
      body = "query Raw#{prefix.tr(":", "_")} { secret }"
      begin
        expect(admin.call("SET", "graphql-armory:persisted-queries:#{id}", body, "NX")).to eq("OK")
        expect(admin.call("SET", "graphql-armory:persisted-queries:#{id}", "{ other }", "NX")).to be_nil
        expect(run(schema_for(redis_store.build(redis: admin, on_error: on_error)), id)["data"]).to eq("secret" => "SECRET")
        m = pq::Manifest.new({ id => body })
        expect(publisher_class.call(m, redis: admin).to_h).to eq(published: 0, unchanged: 1)
      ensure
        admin.del("graphql-armory:persisted-queries:#{id}")
      end
    end

    it "D7 preservation: the server example runs as written, with a stand-in on_error" do
      store = redis_store.build(
        redis: Redis.new(url: ENV.fetch("REDIS_URL"), timeout: 0.5, reconnect_attempts: 0),
        on_error: ->(error) { errors << error }
      )
      expect(store).to be_a(redis_store)
      expect(store.fetch(sha("never #{prefix}"))).to be_nil
      expect(errors).to eq([])
    end

    it "D8 preservation: API paragraph: Publisher.call answers published and unchanged, Substitute stands in" do
      client = sub.new
      r = publisher_class.call(manifest_of(QUERY), redis: client, prefix: "x:")
      expect(r.published).to eq(1)
      expect(r.unchanged).to eq(0)
      expect(client.calls).to eq([[:set, "x:#{sha(QUERY)}"]])
    end

    it "D9 preservation: removal: removing a key does not revoke until restart; a new store does not see it" do
      publisher_class.build(redis: admin, prefix: prefix).(manifest_of(QUERY))
      store = redis_store.build(redis: admin, prefix: prefix, on_error: on_error)
      expect(store.fetch(sha(QUERY))).not_to be_nil
      admin.del("#{prefix}#{sha(QUERY)}")
      expect(store.fetch(sha(QUERY))).not_to be_nil
      expect(redis_store.build(redis: admin, prefix: prefix, on_error: on_error).fetch(sha(QUERY))).to be_nil
    end

    it "D10 security: one store per prefix keeps allowlists apart" do
      publisher_class.build(redis: admin, prefix: prefix).(manifest_of(QUERY))
      other = redis_store.build(redis: admin, prefix: "#{prefix}other-", on_error: on_error)
      expect(other.fetch(sha(QUERY))).to be_nil
    end

    it "D11 preservation: the doc's on_error default claim: an on_error that raises makes the request fail" do
      client = sub.new
      client.set("#{redis_store::DEFAULT_PREFIX}#{sha(QUERY)}", "{ other }")
      schema = schema_for(redis_store.build(redis: client, on_error: ->(_) { raise "report down" }))
      expect { run(schema, sha(QUERY)) }.to raise_error(RuntimeError, "report down")
      expect(ran).to eq([])
    end

    it "D12 preservation: mermaid block exists, is the sequence diagram" do
      block = docs[/```mermaid\n(.*?)```/m, 1]
      expect(block).to start_with("sequenceDiagram")
      expect(block.scan(/^\s*alt\b/).size).to eq(block.scan(/^\s*end\b/).size)
    end
  end

  describe "fork and recursion" do
    it "P65 preservation: a forked child reads with an inherited client" do
      skip "no fork" unless Process.respond_to?(:fork)
      publisher_class.build(redis: admin, prefix: prefix).(manifest_of(QUERY))
      shared = Redis.new(url: ENV.fetch("REDIS_URL"))
      store = redis_store.build(redis: shared, prefix: prefix, on_error: on_error)
      store.fetch(sha("touch")) # connects before the fork
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        op = store.fetch(sha(QUERY))
        writer.write(op ? "found" : "missing #{errors.map(&:class)}")
        writer.close
        exit!(0)
      end
      writer.close
      Process.wait(pid)
      expect(reader.read).to eq("found")
    end

    it "P67 security: a stored very deep query with the right digest does not run; outcome recorded" do
      body = "#{"{ a " * 200_000}#{"}" * 200_000}"
      admin.set("#{prefix}#{sha(body)}", body, ex: 60)
      store = redis_store.build(redis: admin, prefix: prefix, on_error: on_error)
      outcome = begin
        run(schema_for(store), sha(body))
      rescue Exception => e # rubocop:disable Lint/RescueException
        e.class
      end
      puts "P67 outcome: #{outcome.is_a?(Hash) ? outcome.dig("errors", 0, "message") : outcome} errors=#{errors.map(&:class)} memo=#{ops(store).size}"
      expect(ran).to eq([])
    end
  end

  describe "added after the first run" do
    it "P02h security: one invalid id in a multiplex must not fail its neighbours" do
      client = sub.new
      publisher_class.build(redis: client).(manifest_of(QUERY))
      schema = schema_for(redis_store.build(redis: client, on_error: on_error))
      results = schema.multiplex([{ context: { operation_id: sha(QUERY) }, root_value: probe_root },
                                  { context: { operation_id: "\xFF".dup.force_encoding("UTF-8") }, root_value: probe_root }])
      expect(results.first.to_h["data"]).to eq("secret" => "SECRET")
      expect(code(results.last.to_h)).to eq("UNKNOWN_OPERATION")
    end

    it "P26b security: after a read timeout the next read gets its own reply, not the late one (digest false, real Redis paused)" do
      admin.set("#{prefix}first", "{ secret }", ex: 60)
      admin.set("#{prefix}second", "{ other }", ex: 60)
      client = Redis.new(url: ENV.fetch("REDIS_URL"), timeout: 0.1, reconnect_attempts: 0)
      client.ping
      store = redis_store.build(redis: client, prefix: prefix, digest: false, on_error: on_error)
      admin.call("CLIENT", "PAUSE", "400", "ALL")
      expect(store.fetch("first")).to be_nil
      sleep 0.6
      expect(errors.size).to eq(1)
      second = store.fetch("second")
      expect(second.body).to eq("{ other }")
      expect(store.fetch("first").body).to eq("{ secret }")
    end

    it "P57b security: 60 threads, 20 ids, one client, digest false: every id gets its own query" do
      ids = (1..20).map { |i| "id#{i}" }
      ids.each { |id| admin.set("#{prefix}#{id}", "query #{id} { secret }", ex: 60) }
      store = redis_store.build(redis: Redis.new(url: ENV.fetch("REDIS_URL")), prefix: prefix, digest: false, on_error: on_error)
      wrong = 60.times.map { |t| Thread.new { ids.rotate(t).reject { |id| store.fetch(id).body == "query #{id} { secret }" } } }.flat_map(&:value)
      expect(wrong).to eq([])
      expect(errors).to eq([])
      expect(ops(store).size).to eq(20)
    end

    it "P60a security: wrong digest flag at the CI: --digest false over a sha256-looking id publishes with exit 0; the server refuses, the right query cannot then be published" do
      Dir.mktmpdir do |dir|
        good_id = sha("{ other }")
        wrong = write_manifest(dir, "wrong.json", { good_id => "{ secret }" })
        o, e, st = exe("--digest", "false", "--prefix", prefix, wrong)
        puts "P60a first: #{st.exitstatus} #{o.strip} #{e.strip}"
        store = redis_store.build(redis: Redis.new(url: ENV.fetch("REDIS_URL")), prefix: prefix, on_error: on_error)
        expect(code(run(schema_for(store), good_id))).to eq("UNKNOWN_OPERATION")
        expect(ran).to eq([])
        right = write_manifest(dir, "right.json", { good_id => "{ other }" })
        o, e, st = exe("--prefix", prefix, right)
        puts "P60a second: #{st.exitstatus} #{o.strip} #{e.strip}"
        expect(st.exitstatus).to eq(1)
      end
    end

    it "P60b preservation: md5 manifest published to a sha256 server: exit 0 at the CI, every id refused at run time" do
      Dir.mktmpdir do |dir|
        id = Digest::MD5.hexdigest(QUERY)
        path = write_manifest(dir, "m.json", { id => QUERY })
        _, _, st = exe("--digest", "md5", "--prefix", prefix, path)
        expect(st.exitstatus).to eq(0)
        store = redis_store.build(redis: admin, prefix: prefix, on_error: on_error)
        expect(code(run(schema_for(store), id))).to eq("UNKNOWN_OPERATION")
        expect(errors.map(&:class)).to eq([redis_store::CorruptOperation])
      end
    end

    it "P61 security: on_error default under a silenced interpreter ($VERBOSE=nil) still refuses" do
      client = sub.new
      client.fail_with(IOError.new("down"))
      old = $VERBOSE
      begin
        $VERBOSE = nil
        out = capture_stderr { expect(redis_store.build(redis: client).fetch(sha(QUERY))).to be_nil }
        puts "P61 warned under VERBOSE=nil: #{out.inspect}"
      ensure
        $VERBOSE = old
      end
    end

    it "P02f security: a lone surrogate escape does not make an invalid id on this json version (route recorded)" do
      outcome = begin
        pq.operation_id(JSON.parse('{"operationId":"\ud800"}'))
      rescue JSON::ParserError
        :json_refuses
      end
      puts "P02f #{JSON::VERSION}: #{outcome.inspect} valid=#{outcome.respond_to?(:valid_encoding?) ? outcome.valid_encoding? : "-"}"
      if outcome.is_a?(String)
        expect(code(run(schema_for(redis_store.build(redis: sub.new, on_error: on_error)), outcome))).to eq("UNKNOWN_OPERATION")
      end
    end

    it "P02g security: plain Rack GET with %FF in operationId: UNKNOWN_OPERATION" do
      require "rack"
      env = Rack::MockRequest.env_for("/graphql?operationId=%FFabc")
      id = pq.operation_id(Rack::Request.new(env).params)
      expect(id.valid_encoding?).to eq(false)
      expect(code(run(schema_for(redis_store.build(redis: sub.new, on_error: on_error)), id))).to eq("UNKNOWN_OPERATION")
    end

    it "P02i security: plain Rack GET with %FF inside Apollo's extensions JSON: UNKNOWN_OPERATION" do
      require "rack"
      env = Rack::MockRequest.env_for("/graphql?extensions=%7B%22persistedQuery%22%3A%7B%22sha256Hash%22%3A%22%FF%22%7D%7D")
      id = pq.operation_id(Rack::Request.new(env).params)
      expect(id).not_to be_nil
      expect(code(run(schema_for(redis_store.build(redis: sub.new, on_error: on_error)), id))).to eq("UNKNOWN_OPERATION")
    end

    it "P02j preservation: what Rails does with the same bytes before the plugin sees them (recorded)" do
      require "action_controller"
      [["GET", Rack::MockRequest.env_for("/graphql?operationId=%FFabc")],
       ["POST json", Rack::MockRequest.env_for("/graphql", method: "POST", "CONTENT_TYPE" => "application/json", input: %({"operationId":"\xFFabc"}).b)]].each do |label, env|
        outcome = begin
          request = ActionDispatch::Request.new(env)
          id = request.params["operationId"]
          "reaches the app: valid=#{id&.valid_encoding?}"
        rescue StandardError => e
          "refused by Rails: #{e.class}"
        end
        puts "P02j #{label}: #{outcome}"
      end
    end

  end
end
