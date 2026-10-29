# frozen_string_literal: true

# Every adapter answers the same four questions. Define `adapter`, `context`, `actor`,
# `subject_object` and `rule` (plus `items`) and include this in the adapter's spec.
RSpec.shared_examples "an armory adapter" do
  %i[actor authorized? scope check].each do |question|
    it "answers #{question}" do
      expect(adapter).to respond_to(question)
    end
  end

  it "answers authorized? with true, false or nil, never anything else" do
    expect([true, false, nil]).to include(adapter.authorized?(actor, subject_object, rule))
  end

  it "lists the problems of a check as an array" do
    expect(adapter.check(subject_object.class, rule)).to be_an(Array)
  end
end
