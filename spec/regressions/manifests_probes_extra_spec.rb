# frozen_string_literal: true

require "digest"
require "json"
require "tmpdir"

# Second batch: the unreadable-file case as a non-root process, and how deep the document's freezing goes.
RSpec.describe "PersistedQueries::Manifests extra probes" do
  pq = GraphQL::Armory::PersistedQueries
  inv = pq::Controls::Operations.invoices

  it "[S42b] an unreadable file raises ConfigurationError for a process that cannot read it (non-root fork)" do
    Dir.mktmpdir do |d|
      File.chmod(0o755, d)
      path = File.join(d, "a.json")
      File.write(path, JSON.generate(Digest::SHA256.hexdigest(inv) => inv))
      File.chmod(0, path)
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        Process::UID.change_privilege(65_534)
        begin
          pq::Manifests.build(path)
          writer.write("no raise")
        rescue StandardError => e
          writer.write("#{e.class}: #{e.message}")
        end
        exit!(0)
      end
      writer.close
      Process.wait(pid)
      expect(reader.read).to match(/ConfigurationError: .*cannot be read \(Errno::EACCES\)/)
    end
  end

  it "[C14d] a fetched document cannot be changed through its public arrays, on any level" do
    op = pq::Manifest.new({ Digest::SHA256.hexdigest(inv) => inv }).fetch(Digest::SHA256.hexdigest(inv))
    definition = op.document.definitions.first
    frozen = { definitions: op.document.definitions.frozen?, selections: definition.selections.frozen?,
      variables: definition.variables.frozen?, directives: definition.directives.frozen?, definition: definition.frozen? }
    expect(frozen.values_at(:definitions, :selections)).to eq([true, true]), "frozen map: #{frozen}"
  end
end
