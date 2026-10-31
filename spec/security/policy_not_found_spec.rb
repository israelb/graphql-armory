# frozen_string_literal: true

# Pundit's own message quotes `record.inspect`, so an app that shows exception text to clients would show the record.
class ArmoryGhostRecord
  def inspect = "#<ArmoryGhostRecord secret=SECRET>"
end

RSpec.describe "a record with no policy" do
  let(:adapter) { GraphQL::Armory::Authorization::Adapters::Pundit.new }
  let(:read) { GraphQL::Armory::Authorization::Rule.new(:read) }

  it "raises Pundit's error, naming the class and not the record" do
    expect { adapter.authorized?(:someone, ArmoryGhostRecord.new, read) }.to raise_error(Pundit::NotDefinedError) do |error|
      expect(error.message).to include("ArmoryGhostRecord")
      expect(error.message).not_to include("SECRET")
    end
  end

  it "does the same for a list and for nil" do
    expect { adapter.scope(:someone, [ArmoryGhostRecord.new], read) }.to raise_error(Pundit::NotDefinedError) { |error| expect(error.message).not_to include("SECRET") }
    expect { adapter.authorized?(:someone, nil, read) }.to raise_error(Pundit::NotDefinedError, /NilClass/)
  end

  # A Struct or OpenStruct with a `class` member answers `class` with the record's data.
  it "does not ask the record what its class is" do
    with_member = Struct.new(:class).new("SECRET")
    lying = Class.new do
      def is_a?(klass) = klass == Module || super
      def to_s = "SECRET"
    end.new

    [with_member, lying].each do |record|
      expect { adapter.authorized?(:someone, record, read) }.to raise_error(Pundit::NotDefinedError) { |error| expect(error.message).not_to include("SECRET") }
    end
  end

  it "does not read the items to name a relation with no policy" do
    relation = Class.new { def inspect = raise("ran the query") }.new

    expect { adapter.scope(:someone, relation, read) }.to raise_error(Pundit::NotDefinedError)
  end
end
