# frozen_string_literal: true

require "graphql/armory"
require "graphql/armory/caching/audit"

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

  namespace :versions do
    versions_action = GraphQL::Armory::Versioning::Audit::Command::RAKE_ACTION
    unless Rake::Task.task_defined?("graphql_armory:versions:audit") && Rake::Task["graphql_armory:versions:audit"].actions.include?(versions_action)
      desc "Lists what a query of each served version would have refused, and members a version serves outside their lifecycle (exit 1 if any)"
      task :audit, [:schema], &versions_action
    end

    dump_action = GraphQL::Armory::Versioning::Dump::Command::RAKE_ACTION
    unless Rake::Task.task_defined?("graphql_armory:versions:dump") && Rake::Task["graphql_armory:versions:dump"].actions.include?(dump_action)
      desc "Writes each served version's SDL to <dir>/<label>.graphql, plus <dir>/latest.graphql (dir defaults to schema)"
      task :dump, [:schema, :dir], &dump_action
    end

    diff_action = GraphQL::Armory::Versioning::Diff::Command::RAKE_ACTION
    unless Rake::Task.task_defined?("graphql_armory:versions:diff") && Rake::Task["graphql_armory:versions:diff"].actions.include?(diff_action)
      desc "Lists what changes between two served versions: breaking, dangerous and safe (exit 1 if anything breaks)"
      task :diff, [:schema, :from, :to], &diff_action
    end
  end

  namespace :cache do
    cache_action = GraphQL::Armory::Caching::Audit::Command::RAKE_ACTION
    unless Rake::Task.task_defined?("graphql_armory:cache:audit") && Rake::Task["graphql_armory:cache:audit"].actions.include?(cache_action)
      desc "Lists every cache declaration that could serve one viewer's answer to another, and every declaration's reason (exit 1 on problems)"
      task :audit, [:schema], &cache_action
    end
  end
end
