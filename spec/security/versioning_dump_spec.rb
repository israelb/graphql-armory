# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "rake"

# Versioning's dump: one SDL file per served version, plus latest.graphql, each exactly what a client of that version sees.
# It never writes outside the directory it is given, and never a retired version.
RSpec.describe "GraphQL::Armory::Versioning::Dump" do
  let(:versioning) { GraphQL::Armory::Versioning }
  let(:controls) { versioning::Controls }

  around do |example|
    @dir = Dir.mktmpdir("armory-dump")
    example.run
  ensure
    FileUtils.remove_entry(@dir)
  end

  # graphql 2.4 with json 3.1 cannot print a String (the control's deprecation reason) in `to_definition`.
  def needs_printing!
    skip "this graphql with json 3.1 cannot print a String value" unless ArmoryJsonPrinting.prints_strings?
  end

  def schema_with(labels, retired: [])
    query = controls::Query.example
    Class.new(GraphQL::Schema) do
      query(query)
      use GraphQL::Schema::Visibility
      use GraphQL::Armory::Versioning, versions: labels, retired: retired, default: :latest
    end
  end

  %i[visibility warden].each do |visibility|
    it "writes each served version's SDL and latest.graphql, never a retired version (#{visibility})" do
      needs_printing!
      schema = controls::Schema.example(visibility: visibility)
      target = File.join(@dir, "nested", "schema")

      written = versioning::Dump.(schema, target)

      expect(written).to eq(%w[2024-06-01.graphql 2025-01-01.graphql latest.graphql].map { |name| File.join(target, name) })
      expect(Dir.children(target).sort).to eq(%w[2024-06-01.graphql 2025-01-01.graphql latest.graphql])
      %w[2024-06-01 2025-01-01].each do |label|
        expect(File.read(File.join(target, "#{label}.graphql"))).to eq(schema.to_definition(context: { armory_version: label }))
      end
      expect(File.read(File.join(target, "latest.graphql"))).to eq(File.read(File.join(target, "2025-01-01.graphql")))
      expect(File.read(File.join(target, "2024-06-01.graphql"))).to include("amount").and(include("total"))
      expect(File.read(File.join(target, "2024-06-01.graphql"))).not_to include("tags")
      expect(File.read(File.join(target, "2025-01-01.graphql"))).to include("tags")
      expect(File.read(File.join(target, "2025-01-01.graphql"))).not_to include("amount")
    end
  end

  it "writes through its directory, which a Substitute can stand in for" do
    needs_printing!
    directory = versioning::Dump::Directory::Substitute.new

    written = versioning::Dump.new(directory).(controls::Schema.example)

    expect(written).to eq(%w[2024-06-01.graphql 2025-01-01.graphql latest.graphql])
    expect(directory.written.keys).to eq(written)
    expect(directory.written["latest.graphql"]).to include("tags")
  end

  it "writes nothing when built with new" do
    needs_printing!
    expect(versioning::Dump.new.(controls::Schema.example)).to eq([])
  end

  it "writes nothing when one version cannot be dumped" do
    needs_printing!
    directory = versioning::Dump::Directory::Substitute.new
    directory.fail_with(IOError.new("disk full"))

    expect { versioning::Dump.new(directory).(controls::Schema.example) }.to raise_error(IOError, "disk full")
    expect(directory.written).to eq({})
  end

  describe "labels that are not safe file names" do
    ["../outside", "a/b", "a\\b", ".hidden", "latest", "LATEST", "a\0b"].each do |label|
      it "refuses #{label.inspect} before writing anything" do
        schema = schema_with(["2024-06-01", label].uniq)
        directory = versioning::Dump::Directory::Substitute.new

        expect { versioning::Dump.new(directory).(schema) }.to raise_error(versioning::ConfigurationError, /#{Regexp.escape(label.inspect)}/)
        expect(directory.written).to eq({})
      end
    end

    it "refuses two labels that differ only by case, which one file system would merge" do
      schema = schema_with(%w[v1 V1])

      expect { versioning::Dump.(schema, @dir) }.to raise_error(versioning::ConfigurationError, /"v1" and "V1"/)
      expect(Dir.children(@dir)).to eq([])
    end
  end

  it "refuses a directory that is not a non-empty path, and a schema without versioning" do
    plain = Class.new(GraphQL::Schema) { query(Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :x, String, null: true }) }

    expect { versioning::Dump.build("") }.to raise_error(versioning::ConfigurationError, /directory/)
    expect { versioning::Dump.build(nil) }.to raise_error(versioning::ConfigurationError, /directory/)
    expect { versioning::Dump.(plain, @dir) }.to raise_error(versioning::ConfigurationError, /never installed the plugin/)
  end

  describe "the rake command" do
    around do |example|
      Object.const_set(:ArmoryVersioningDumpSchema, controls::Schema.example)
      example.run
    ensure
      Object.send(:remove_const, :ArmoryVersioningDumpSchema)
    end

    it "writes the files and says which, answering 0" do
      needs_printing!
      out = StringIO.new

      expect(versioning::Dump::Command.new(out: out).("ArmoryVersioningDumpSchema", @dir)).to eq(0)
      expect(out.string).to eq(%w[2024-06-01 2025-01-01 latest].map { |name| "Wrote #{File.join(@dir, "#{name}.graphql")}\n" }.join)
    end

    it "answers 1 with a message for a missing or unknown schema" do
      out = StringIO.new
      command = versioning::Dump::Command.new(out: out)

      expect(command.("", @dir)).to eq(1)
      expect(command.("NoSuchSchemaHere", @dir)).to eq(1)
      expect(out.string).to include("rake \"graphql_armory:versions:dump[YourSchema,schema]\"").and include("No schema named NoSuchSchemaHere")
      expect(Dir.children(@dir)).to eq([])
    end

    it "is a rake task, defined once however often the file loads, next to the diff task" do
      original = Rake.application
      stdout = $stdout
      $stdout = StringIO.new
      Rake.application = Rake::Application.new
      2.times { load File.expand_path("../../lib/tasks/graphql_armory.rake", __dir__) }

      expect(Rake::Task["graphql_armory:versions:dump"].actions.size).to eq(1)
      expect(Rake::Task["graphql_armory:versions:diff"].actions.size).to eq(1)
      expect { Rake::Task["graphql_armory:versions:diff"].invoke("ArmoryVersioningDumpSchema", "2024-06-01", "2025-01-01") }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect($stdout.string).to include("Invoice.amount: field removed")
      needs_printing!
      Rake::Task["graphql_armory:versions:dump"].invoke("ArmoryVersioningDumpSchema", @dir)
      expect(Dir.children(@dir).sort).to eq(%w[2024-06-01.graphql 2025-01-01.graphql latest.graphql])
    ensure
      $stdout = stdout if stdout
      Rake.application = original if original
    end
  end
end
