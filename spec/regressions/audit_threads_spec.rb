# frozen_string_literal: true

# One Audit object serves several threads and keeps nothing of a run. A switch at every method call of the
# plugin makes the race certain where waiting for it would be intermittent.
RSpec.describe "one Audit object under threads" do
  let(:armory) { GraphQL::Armory::Authorization }

  def schema_with(index)
    plugin = armory
    field_base = Class.new(GraphQL::Schema::Field) { include plugin::Base }
    base = Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class field_base
    end
    uncovered = Class.new(base) do
      graphql_name "Uncovered#{index}"
      field :secret, String, null: true
    end
    query_class = Class.new(base) do
      graphql_name "Query"
      authorize :none, reason: "root #{index}", covers_fields: true
      field :uncovered, uncovered, null: true, authorize: :none, reason: "edge #{index}"
    end
    Class.new(base_schema) do
      use plugin, adapter: plugin::Adapters::Substitute.new
      query query_class
    end
  end

  def text_of(report)
    report.problems.map(&:to_s) + report.bypasses.map { |bypass| "#{bypass.path} #{bypass.reason}" }
  end

  it "gives each thread the report of its own schema" do
    schemas = Array.new(8) { |index| schema_with(index) }
    audit = armory::Audit.new(adapter: armory::Adapters::Substitute.new)
    expected = schemas.map { |schema| text_of(audit.(schema)) }
    wrong = Queue.new

    switch = TracePoint.new(:call) { |point| Thread.pass if point.path.include?("armory/authorization") }
    switch.enable
    begin
      Array.new(12) do |thread|
        Thread.new do
          8.times do |run|
            index = (thread + run) % schemas.size
            got = begin
              text_of(audit.(schemas[index]))
            rescue StandardError => e
              e.class.name
            end
            wrong << [index, got] unless got == expected[index]
          end
        end
      end.each(&:join)
    ensure
      switch.disable
    end

    expect(wrong.size).to eq(0)
    expect(expected.map { |lines| lines.join.include?("Uncovered") }).to all(be(true))
  end

  it "gives the same report whichever schema came before, and keeps no state of a run" do
    schemas = Array.new(3) { |index| schema_with(index) }
    audit = armory::Audit.new(adapter: armory::Adapters::Substitute.new)
    fresh = schemas.map { |schema| text_of(armory::Audit.new(adapter: armory::Adapters::Substitute.new).(schema)) }

    expect(schemas.map { |schema| text_of(audit.(schema)) }).to eq(fresh)
    expect(schemas.reverse.map { |schema| text_of(audit.(schema)) }).to eq(fresh.reverse)
    expect(audit.instance_variables).to eq([:@adapter])
  end
end
