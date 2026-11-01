# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # What `rake graphql_armory:audit[YourSchema]` runs: prints the report and answers an exit status.
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
            return fail_with("Name the schema: rake graphql_armory:audit[YourSchema]") if schema_name.to_s.empty?

            schema = Object.const_get(schema_name)
            report = Audit.(schema)
            @out.print(report)
            report.ok? ? 0 : 1
          rescue NameError => error
            raise unless error.name.to_s == schema_name.to_s.split("::").last

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
