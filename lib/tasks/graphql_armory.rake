# frozen_string_literal: true

require "graphql/armory"

namespace :graphql_armory do
  desc "Lists every type, field and argument of a schema that no authorization rule covers (exit 1 if any)"
  task :audit, [:schema] => (Rake::Task.task_defined?(:environment) ? [:environment] : []) do |_task, args|
    status = GraphQL::Armory::Authorization::Audit::Command.new.(args[:schema])
    exit(status) unless status.zero?
  end
end
