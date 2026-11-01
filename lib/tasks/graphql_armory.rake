# frozen_string_literal: true

require "graphql/armory"

namespace :graphql_armory do
  # The Railtie loads this before Rails defines :environment, so the action looks it up when it runs. An app may also load this by hand.
  action = GraphQL::Armory::Authorization::Audit::Command::RAKE_ACTION
  unless Rake::Task.task_defined?("graphql_armory:audit") && Rake::Task["graphql_armory:audit"].actions.include?(action)
    desc "Lists every type, field and argument of a schema that no authorization rule covers (exit 1 if any)"
    task :audit, [:schema, :baseline], &action
  end

  baseline_action = GraphQL::Armory::Authorization::Audit::Command::BASELINE_ACTION
  unless Rake::Task.task_defined?("graphql_armory:audit_baseline") && Rake::Task["graphql_armory:audit_baseline"].actions.include?(baseline_action)
    desc "Writes the audit's problems to a baseline file, or removes from it what is gone; it never adds to a file that exists"
    task :audit_baseline, [:schema, :baseline], &baseline_action
  end
end
