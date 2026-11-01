# frozen_string_literal: true

require "digest"
require "json"
require "tmpdir"

# Second batch: the unreadable-file case as a non-root process, and how deep the document's freezing goes.
RSpec.describe "PersistedQueries::Manifests extra probes" do
  pq = GraphQL::Armory::PersistedQueries
  inv = pq::Controls::Operations.invoices

  it "[C14d] a fetched document cannot be changed through its public arrays, on any level" do
    op = pq::Manifest.new({ Digest::SHA256.hexdigest(inv) => inv }).fetch(Digest::SHA256.hexdigest(inv))
    definition = op.document.definitions.first
    frozen = { definitions: op.document.definitions.frozen?, selections: definition.selections.frozen?,
      variables: definition.variables.frozen?, directives: definition.directives.frozen?, definition: definition.frozen? }
    expect(frozen.values_at(:definitions, :selections)).to eq([true, true]), "frozen map: #{frozen}"
  end
end
