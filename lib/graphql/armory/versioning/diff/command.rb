# frozen_string_literal: true

module GraphQL
  module Armory
    module Versioning
      class Diff
        # What `rake "graphql_armory:versions:diff[YourSchema,FROM,TO]"` runs: prints the diff and answers an exit status,
        # 1 when something breaks.
        class Command
          USAGE = "Name the schema and two versions: rake \"graphql_armory:versions:diff[YourSchema,FROM,TO]\""

          # The rake task's action. The rake file looks for this object among the task's actions, so an app that names the
          # task first (to add a prerequisite) still gets it once.
          RAKE_ACTION = proc do |_task, args|
            Rake::Task[:environment].invoke if Rake::Task.task_defined?(:environment)
            status = new.(args[:schema], args[:from], args[:to])
            exit(status) unless status.zero?
          end

          def initialize(out: $stdout, diff: Diff)
            @out = out
            @diff = diff
          end

          def call(schema_name, from, to)
            return fail_with(USAGE) if [schema_name, from, to].any? { |value| value.to_s.empty? }

            result = @diff.(Object.const_get(schema_name), from: from, to: to)
            @out.print(result)
            result.breaking? ? 1 : 0
          rescue ConfigurationError => error
            fail_with(error.message)
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
