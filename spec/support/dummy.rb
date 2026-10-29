# frozen_string_literal: true

require "active_record"
require "pundit"

# The dummy app: ActiveRecord on in-memory SQLite plus plain Pundit policies. No Rails.
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

dummy = File.expand_path("../dummy", __dir__)
%w[schema models policies world].each { |file| require File.join(dummy, file) }

RSpec.configure do |config|
  # Every example starts from an empty database.
  config.around do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end
end
