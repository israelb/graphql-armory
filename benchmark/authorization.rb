# frozen_string_literal: true

# What does authorization cost on a list of 1000 invoices?
#
#   docker compose run --rm test bundle exec ruby benchmark/authorization.rb
#   GRAPHQL_ARMORY_ENGINE=next docker compose run --rm test bundle exec ruby benchmark/authorization.rb
#
# Three setups answer the same query with the same 1000 invoices:
#   plain      no authorization at all
#   array      armory, the resolver returns an Array: the scope authorizes each item, then each item is authorized
#   relation   armory, the resolver returns a relation of 2000 invoices: SQL narrows it to 1000, then each item is authorized
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "benchmark/ips"
require "memory_profiler"
require "active_record"
require "pundit"
require "graphql/armory"
require_relative "../spec/support/armory_engine"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
%w[schema models policies world].each { |file| require_relative "../spec/dummy/#{file}" }
require_relative "../spec/support/integration_schema"

ITEMS = 1000

world = Dummy::World.build
Invoice.insert_all(Array.new(ITEMS - 2) { |i| { account_id: world.account_a.id, number: "A-#{i + 3}" } })
Invoice.insert_all(Array.new(ITEMS - 1) { |i| { account_id: world.account_b.id, number: "B-#{i + 2}" } })
own = Invoice.where(account_id: world.account_a.id).to_a
abort "expected #{ITEMS} invoices, got #{own.size}" unless own.size == ITEMS

plain_invoice = Class.new(GraphQL::Schema::Object) do
  graphql_name "Invoice"
  field :number, String, null: false
  field :account_id, Integer, null: false
  field :internal_notes, String
end
plain_query = Class.new(GraphQL::Schema::Object) do
  graphql_name "Query"
  field :invoices, [plain_invoice], null: false
end
plain = Class.new(ArmoryEngine.base_schema) { query plain_query }
armory = IntegrationSchema.build(flawed: false)

def run(schema, query, root)
  options = { context: { current_user: Dummy.alice }, root_value: root }
  result = ArmoryEngine.next? ? schema.execute_next(query, **options) : schema.execute(query, **options)
  raise result["errors"].inspect if result["errors"]
  raise "unexpected size" unless result["data"]["invoices"].size == ITEMS

  result
end

module Dummy
  class << self
    attr_accessor :alice
  end
end
Dummy.alice = world.alice

queries = {
  "number only" => "{ invoices { number } }",
  "three fields (accountId re-checks the type, internalNotes asks manage?)" => "{ invoices { number accountId internalNotes } }"
}
setups = {
  "plain" => [plain, IntegrationSchema::Root.new(invoices: own)],
  "armory, array" => [armory, IntegrationSchema::Root.new(invoices: own)],
  "armory, relation" => [armory, IntegrationSchema::Root.new(invoices: Invoice.order(:id))]
}
# The plain schema reads the root value through the same method name.
plain_root = Struct.new(:invoices)
setups["plain"][1] = plain_root.new(own)

puts "graphql #{GraphQL::VERSION}, engine #{ArmoryEngine.current}, Ruby #{RUBY_VERSION}, #{ITEMS} invoices"

queries.each do |label, query|
  puts "\n== #{label}"
  Benchmark.ips do |x|
    x.config(time: 3, warmup: 1)
    setups.each { |name, (schema, root)| x.report(name) { run(schema, query, root) } }
    x.compare!
  end

  setups.each do |name, (schema, root)|
    report = MemoryProfiler.report { run(schema, query, root) }
    puts format("%-18s allocated objects: %d", name, report.total_allocated)
  end
end
