# frozen_string_literal: true

RSpec.describe GraphQL::Armory::Authorization::Memo do
  let(:memo) { described_class.new }
  let(:rule) { GraphQL::Armory::Authorization::Controls::Rule.example }

  it "computes once per subject and rule" do
    subject_object = Object.new
    runs = 0

    2.times { memo.fetch(subject_object, rule) { runs += 1; true } }

    expect(runs).to eq(1)
  end

  it "remembers a false answer too" do
    subject_object = Object.new
    runs = 0

    2.times { memo.fetch(subject_object, rule) { runs += 1; false } }

    expect(runs).to eq(1)
  end

  it "tells subjects apart by identity, not by equality" do
    first = "same"
    second = "same".dup
    answers = [true, false].each

    results = [first, second].map { |s| memo.fetch(s, rule) { answers.next } }

    expect(results).to eq([true, false])
  end

  it "tells rules apart" do
    other = GraphQL::Armory::Authorization::Rule.new(:manage)
    subject_object = Object.new

    results = [rule, other].map { |r| memo.fetch(subject_object, r) { r.action } }

    expect(results).to eq([rule.action, :manage])
  end

  it "is shared by every call of the same request context" do
    context = GraphQL::Armory::Authorization::Controls::Context.example

    built = [described_class.build(context), described_class.build(context)]

    expect(built.first).to equal(built.last)
  end

  it "is not shared across contexts" do
    contexts = Array.new(2) { GraphQL::Armory::Authorization::Controls::Context.example }

    built = contexts.map { |c| described_class.build(c) }

    expect(built.first).not_to equal(built.last)
  end

  describe "Substitute" do
    it "never remembers" do
      memo = described_class::Substitute.new
      runs = 0

      2.times { memo.fetch(Object.new, rule) { runs += 1 } }

      expect(runs).to eq(2)
    end
  end
end
