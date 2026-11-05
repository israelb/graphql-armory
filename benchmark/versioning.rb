# frozen_string_literal: true

# What does versioning cost per query, and what does `profiles: true` save?
#
#   docker compose run --rm test bundle exec ruby benchmark/versioning.rb
#   GRAPHQL_ARMORY_ENGINE=next docker compose run --rm test bundle exec ruby benchmark/versioning.rb
#
# Profile mode (no ips, no memory runs): where does the time go?
#
#   PROFILE=1 PROFILE_SETUP=plain|warden|visibility|profiles [PROFILE_RUNS=50] [PROFILE_MODE=cpu|object] \
#     docker compose run --rm test bundle exec ruby benchmark/versioning.rb
#
# One schema of 40 object types with 25 fields each; in the versioned setups half the fields carry a lifecycle and 10
# types have a field defined twice (twins with disjoint lifecycles). The query selects all 25 fields of 8 types (200
# fields), each over a list of 100 items, as a client of the third of four versions. Four setups answer it:
#   plain       no versioning, Schema::Visibility
#   warden      versioning under the legacy Schema::Warden: visible? asked once per member per query
#   visibility  versioning under Schema::Visibility (a dynamic profile per query): the same
#   profiles    versioning with profiles: true and preload: each version's visibility computed once, at boot
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

TYPES = 40
FIELDS = 25
TWINS = 10
SELECTED = 8
ITEMS = 100
VERSIONS = %w[v1 v2 v3 v4].freeze
VERSION = "v3"

# One record class answers every field of every type.
Item = Struct.new(*Array.new(FIELDS) { |i| :"f#{i}" })
ITEM = Item.new(*Array.new(FIELDS) { |i| i })

def build_schema(versioned:, plugin: nil, profiles: false)
  base_field = Class.new(GraphQL::Schema::Field) { include GraphQL::Armory::Versioning::Base if versioned }
  base_object = Class.new(GraphQL::Schema::Object) do
    include GraphQL::Armory::Versioning::Base if versioned
    field_class(base_field)
  end
  types = Array.new(TYPES) do |t|
    Class.new(base_object) do
      graphql_name "T#{t}"
      FIELDS.times do |i|
        name = :"f#{i}"
        if !versioned || i.odd?
          field name, Integer, null: false
        elsif i == 0 && t < TWINS
          field name, Integer, null: false, removed: VERSION
          field name, Integer, null: false, added: VERSION
        else
          # Live in v3 either way: what is measured is the cost of asking, not of hiding.
          field name, Integer, null: false, **(i % 4 == 0 ? { added: "v2" } : { removed: "v4" })
        end
      end
    end
  end
  query_type = Class.new(base_object) do
    graphql_name "Query"
    types.each_with_index { |type, t| field :"t#{t}", [type], null: false }
  end
  items = Array.new(ITEMS, ITEM)
  root = Class.new { TYPES.times { |t| define_method(:"t#{t}") { items } } }.new

  schema = Class.new(ArmoryEngine.base_schema) do
    query(query_type)
    use plugin if plugin && !profiles
    if versioned
      use GraphQL::Armory::Versioning, versions: VERSIONS, default: :latest, profiles: profiles
      use GraphQL::Schema::Visibility, profiles: GraphQL::Armory::Versioning.profiles(self), preload: true if profiles
    end
  end
  [schema, root]
end

QUERY = "{ #{Array.new(SELECTED) { |t| "t#{t} { #{Array.new(FIELDS) { |i| "f#{i}" }.join(' ')} }" }.join(' ')} }"

def run(schema, root)
  options = { context: { armory_version: VERSION }, root_value: root }
  result = ArmoryEngine.next? ? schema.execute_next(QUERY, **options) : schema.execute(QUERY, **options)
  raise result["errors"].inspect if result["errors"]
  raise "unexpected size" unless result["data"]["t#{SELECTED - 1}"].size == ITEMS

  result
end

setups = {
  "plain" => build_schema(versioned: false, plugin: GraphQL::Schema::Visibility),
  "warden" => build_schema(versioned: true, plugin: GraphQL::Schema::Warden),
  "visibility" => build_schema(versioned: true, plugin: GraphQL::Schema::Visibility),
  "profiles" => build_schema(versioned: true, profiles: true)
}

puts "graphql #{GraphQL::VERSION}, engine #{ArmoryEngine.current}, Ruby #{RUBY_VERSION}, " \
     "#{SELECTED * FIELDS} fields x #{ITEMS} items, #{TYPES} types"

if profiling
  name = ENV.fetch("PROFILE_SETUP", "visibility")
  schema, root = setups.fetch(name) { abort "PROFILE_SETUP must be one of #{setups.keys.join(', ')}" }
  runs = Integer(ENV.fetch("PROFILE_RUNS", "50"))
  mode = ENV.fetch("PROFILE_MODE", "cpu").to_sym
  5.times { run(schema, root) }
  result = StackProf.run(mode: mode, raw: true, interval: 200) { runs.times { run(schema, root) } }
  puts "profile: #{name}, mode #{mode}, #{runs} runs"
  StackProf::Report.new(result).print_text(false, 25)
  exit
end

setups.each_value { |(schema, root)| 3.times { run(schema, root) } }

Benchmark.ips do |x|
  x.config(time: 5, warmup: 2)
  setups.each { |name, (schema, root)| x.report(name) { run(schema, root) } }
  x.compare!
end

setups.each do |name, (schema, root)|
  report = MemoryProfiler.report { run(schema, root) }
  puts format("%-12s allocated objects: %d", name, report.total_allocated)
end
