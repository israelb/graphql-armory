# frozen_string_literal: true

require "graphql/armory"

namespace :graphql_armory do
  # The Railtie loads this before Rails defines :environment, so the action looks it up when it runs. An app may also load this by hand.
  action = GraphQL::Armory::Authorization::Audit::Command::RAKE_ACTION
  unless Rake::Task.task_defined?("graphql_armory:audit") && Rake::Task["graphql_armory:audit"].actions.include?(action)
    desc "Lists every type, field and argument of a schema that no authorization rule covers (exit 1 if any)"
    task :audit, [:schema], &action
  end
end
