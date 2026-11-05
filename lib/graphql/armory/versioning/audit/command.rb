# frozen_string_literal: true

module GraphQL
  module Armory
    module Versioning
      class Audit
        # What `rake "graphql_armory:versions:audit[YourSchema]"` runs: prints the report and answers an exit status.
        class Command
          # The rake task's action. The app's Rake file may name the task first, to add a prerequisite, so the task existing does
          # not mean this ran: the file looks for this object among its actions.
          RAKE_ACTION = proc do |_task, args|
            Rake::Task[:environment].invoke if Rake::Task.task_defined?(:environment)
            status = new.(args[:schema])
            exit(status) unless status.zero?
          end

          def initialize(out: $stdout)
            @out = out
          end

          def call(schema_name)
            return fail_with("Name the schema: rake \"graphql_armory:versions:audit[YourSchema]\"") if schema_name.to_s.empty?

            report = Audit.(Object.const_get(schema_name))
            @out.print(report)
            report.ok? ? 0 : 1
          rescue NameError => error
            raise unless schema_name.to_s.split("::").include?(error.name.to_s)

            fail_with("No schema named #{schema_name}")
          end

          private

          def fail_with(message)
            @out.puts(message)
            1
          end
        end
      end
    end
  end
end
