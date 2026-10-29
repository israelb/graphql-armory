# frozen_string_literal: true

RSpec.describe GraphQL::Armory::Authorization do
  it "groups its errors under the base error class of the gem" do
    [described_class::AdapterError, described_class::MissingScopeError].each do |error|
      expect(error.ancestors).to include(GraphQL::Armory::Error)
    end
  end
end
