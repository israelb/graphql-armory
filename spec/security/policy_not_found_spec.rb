# frozen_string_literal: true

# Pundit's own message quotes `record.inspect`, so an app that shows exception text to clients would show the record.
class ArmoryGhostRecord
  def inspect = "#<ArmoryGhostRecord secret=SECRET>"
end

class ArmoryPickedLaxPolicy
  class Scope
    def initialize(_user, scope) = @scope = scope
    def resolve = @scope
  end

  def initialize(_user, _record); end
  def read? = true
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

  # A String a type wraps can be the client's text: it must not name the policy that judges it.
  it "does not let a String object pick its own policy" do
    expect { adapter.authorized?(:someone, "ArmoryPickedLax", read) }.to raise_error(Pundit::NotDefinedError, /no policy found for String/)
  end

  it "still reads a String model the schema author wrote" do
    with_model = GraphQL::Armory::Authorization::Rule.new(:read, model: "ArmoryPickedLax")

    expect(adapter.check("ArmoryPickedLax", read)).to eq([])
    expect(adapter.scope(:someone, :items, with_model)).to eq(:items)
  end

  it "does not read the items to name a relation with no policy" do
    relation = Class.new { def inspect = raise("ran the query") }.new

    expect { adapter.scope(:someone, relation, read) }.to raise_error(Pundit::NotDefinedError)
  end
end
