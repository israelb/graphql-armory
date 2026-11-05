# frozen_string_literal: true

require "spec_helper"

# The whole response cache through `use`, on the Controls schema: what a request stores, what the next one is served,
# and what a purge removes. Telemetry is read from the schema's sink, never from mocks.
RSpec.describe "GraphQL::Armory::Caching end to end" do
  let(:caching) { GraphQL::Armory::Caching }
  let(:store) { caching::Controls::Store.example }
  let(:recorded) { [] }
  let(:sink) { ->(signal, data) { recorded << [signal, data] } }
  let(:options) { { store: store, release: "r1", viewer: :current_user, sinks: [sink] } }

  def schema(**extra)
    @schema ||= caching::Controls::Schema.example(caching: options.merge(extra))
  end

  def run(operation, engine: :execute, **context)
    schema.public_send(engine, context: caching::Controls::Context.example(operation: operation, **context)).to_h
  end

  def signals(name) = recorded.select { |signal, _| signal == name }.map(&:last)

  it "stores a public answer on the first request and serves it on the second, unchanged" do
    first = run("names")
    second = run("names", viewer: caching::Controls::Viewer.example(id: 8))

    expect(first["data"]["products"]).not_to be_empty
    expect(second).to eq(first)
    expect(signals(:cache_stored).size).to eq(1)
    expect(signals(:cache_hit).size).to eq(1)
  end

  it "serves a :viewer answer to its viewer only" do
    run("invoices")
    run("invoices")
    run("invoices", viewer: caching::Controls::Viewer.example(id: 8))

    expect(signals(:cache_hit).size).to eq(1)
    expect(signals(:cache_stored).size).to eq(2)
  end

  it "stops serving an answer once its tag is purged" do
    run("catalog")
    caching.purge(schema, tag: "pricing")
    run("catalog")

    expect(signals(:cache_hit)).to be_empty
    expect(signals(:cache_purged).size).to eq(1)
  end

  it "keys the engine: an answer stored by the interpreter is not served on Next", if: ArmoryEngine.supported? do
    run("names")
    run("names", engine: :execute_next)

    expect(signals(:cache_hit)).to be_empty
    expect(signals(:cache_stored).size).to eq(2)
  end
end
