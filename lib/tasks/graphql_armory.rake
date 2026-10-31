# frozen_string_literal: true

require "graphql/armory"

namespace :graphql_armory do
  # The Railtie loads this before Rails defines :environment, so it is looked up when the task runs. An app may also load this by hand.
  unless Rake::Task.task_defined?("graphql_armory:audit")
    desc "Lists every type, field and argument of a schema that no authorization rule covers (exit 1 if any)"
    task :audit, [:schema] do |_task, args|
      Rake::Task[:environment].invoke if Rake::Task.task_defined?(:environment)
      status = GraphQL::Armory::Authorization::Audit::Command.new.(args[:schema])
      exit(status) unless status.zero?
    end
  end
end
