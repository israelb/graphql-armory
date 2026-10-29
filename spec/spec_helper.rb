# frozen_string_literal: true

require "bundler/setup"
require "graphql/armory"

Dir[File.join(__dir__, "support", "**", "*.rb")].sort.each { |file| require file }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
  config.filter_run_when_matching :focus
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }

  # Useful Objects: tests observe telemetry and use Substitutes, never mocks or spies.
  config.mock_with :nothing

  config.include ArmoryEngine::Helpers
end
