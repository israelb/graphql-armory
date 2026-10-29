# frozen_string_literal: true

RSpec.describe GraphQL::Armory do
  it "has a semantic version" do
    expect(GraphQL::Armory::VERSION).to match(/\A\d+\.\d+\.\d+(\.\w+)?\z/)
  end

  it "defines its error base class under GraphQL::Error" do
    expect(GraphQL::Armory::Error.ancestors).to include(GraphQL::Error)
  end

  it "does not require Rails" do
    expect(defined?(::Rails)).to be_nil
  end
end
