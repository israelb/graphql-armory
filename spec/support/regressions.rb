# frozen_string_literal: true

require "stringio"

# spec/regressions holds the probes of past verifications. Many print what they observed: keep that out of the output.
RSpec.configure do |config|
  config.around(:each, file_path: %r{spec/regressions/}) do |example|
    original = $stdout
    $stdout = StringIO.new
    example.run
  ensure
    $stdout = original
  end
end
