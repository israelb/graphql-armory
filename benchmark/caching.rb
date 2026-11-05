# frozen_string_literal: true

# What does response caching cost on a miss, and what does a hit save, on a list of 1000 items?
#
#   docker compose run --rm test bundle exec ruby benchmark/caching.rb
#   GRAPHQL_ARMORY_ENGINE=next docker compose run --rm test bundle exec ruby benchmark/caching.rb
#
# Profile mode (no ips, no memory runs): where does the time go?
#
#   PROFILE=1 PROFILE_SETUP=hit|miss|uncacheable [PROFILE_RUNS=200] [PROFILE_MODE=cpu|object] \
#     docker compose run --rm test bundle exec ruby benchmark/caching.rb
#
# Every setup runs persisted operations on the same schema shape (Authorization with a bypassed public type,
# PersistedQueries strict), over 1000 items with two fields each:
#   typename      { __typename } without caching: the floor a hit is measured against
#   uncached      the list query, caching not installed
#   miss          the list query, cached, after a purge of everything: lookup, run with the recorder, store
#   hit           the list query, answered from a MemoryStore
#   uncached, stock  the list query plus a `cache: false` field, caching not installed
#   uncacheable   the same query, caching installed: the walk refuses it, then it runs
#
# Compare hit with typename, miss with uncached, and uncacheable with "uncached, stock".
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

profiling = ENV["PROFILE"] == "1"
if profiling
  require "stackprof"
else
  require "benchmark/ips"
  require "memory_profiler"
end
require "graphql/armory"
require_relative "../spec/support/armory_engine"

ITEMS = 1000

module CachingBenchmark
  Item = Struct.new(:name, :price, :stock)
  ITEMS_DATA = Array.new(ITEMS) { |index| Item.new("item-#{index}", index * 100, index % 7) }.freeze
  DOCUMENTS = {
    "typename" => "query Typename { __typename }",
    "items" => "query Items { items { name price } }",
    "stock" => "query Stock { items { name price stock } }"
  }.freeze

  def self.schema(caching: nil)
    controls = GraphQL::Armory::Caching::Controls
    item = Class.new(controls::AppSchema::Bases.example.fetch(:object)) do
      graphql_name "Item"
      authorize :none, reason: "public catalog", covers_fields: true
      cache_fields ttl: 300, scope: :public, reason: "the same for every viewer"
      field :name, String, null: false
      field :price, Integer, null: false
      field :stock, Integer, null: false, cache: false
    end
    controls::AppSchema.example(DOCUMENTS, caching: caching) do |options|
      field :items, [item], null: false, **options
      define_method(:items) { ITEMS_DATA }
    end
  end

  def self.run(schema, operation)
    options = { context: { operation_id: operation } }
    result = ArmoryEngine.next? ? schema.execute_next(nil, **options) : schema.execute(nil, **options)
    raise result["errors"].inspect if result["errors"]
    raise "unexpected size" unless operation == "typename" || result["data"]["items"].size == ITEMS

    result
  end
end

plain = CachingBenchmark.schema
cached = CachingBenchmark.schema(caching: { store: GraphQL::Armory::Caching::MemoryStore.new, release: "benchmark" })
CachingBenchmark.run(cached, "items")
first = CachingBenchmark.run(cached, "items").context[:response_cache]
abort "the warm-up run was not served from the cache: #{first.inspect}" unless first[:status] == :hit

setups = {
  "typename" => -> { CachingBenchmark.run(plain, "typename") },
  "uncached" => -> { CachingBenchmark.run(plain, "items") },
  "miss" => lambda {
    GraphQL::Armory::Caching.purge(cached, all: true)
    CachingBenchmark.run(cached, "items")
  },
  "hit" => -> { CachingBenchmark.run(cached, "items") },
  "uncached, stock" => -> { CachingBenchmark.run(plain, "stock") },
  "uncacheable" => -> { CachingBenchmark.run(cached, "stock") }
}

puts "graphql #{GraphQL::VERSION}, engine #{ArmoryEngine.current}, Ruby #{RUBY_VERSION}, #{ITEMS} items"

if profiling
  name = ENV.fetch("PROFILE_SETUP", "hit")
  setup = setups.fetch(name) { abort "PROFILE_SETUP must be one of #{setups.keys.join(", ")}" }
  runs = Integer(ENV.fetch("PROFILE_RUNS", "200"))
  mode = ENV.fetch("PROFILE_MODE", "cpu").to_sym
  5.times { setup.call }
  result = StackProf.run(mode: mode, raw: true, interval: 200) { runs.times { setup.call } }
  puts "profile: #{name}, mode #{mode}, #{runs} runs x #{ITEMS} items"
  StackProf::Report.new(result).print_text(false, 25)
  exit
end

Benchmark.ips do |x|
  x.config(time: 3, warmup: 1)
  setups.each { |name, setup| x.report(name) { setup.call } }
  x.compare!
end

setups.each do |name, setup|
  report = MemoryProfiler.report { setup.call }
  puts format("%-16s allocated objects: %d", name, report.total_allocated)
end
