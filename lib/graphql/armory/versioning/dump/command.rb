# frozen_string_literal: true

module GraphQL
  module Armory
    module Versioning
      class Dump
        # What `rake "graphql_armory:versions:dump[YourSchema,schema]"` runs: writes the files, says which, and answers an
        # exit status. The directory defaults to `schema`.
        class Command
          USAGE = "Name the schema and a directory: rake \"graphql_armory:versions:dump[YourSchema,schema]\""

          # The rake task's action, looked for among the task's actions like the other tasks'.
          RAKE_ACTION = proc do |_task, args|
            Rake::Task[:environment].invoke if Rake::Task.task_defined?(:environment)
            status = new.(args[:schema], args[:dir] || "schema")
            exit(status) unless status.zero?
          end

          def initialize(out: $stdout)
            @out = out
          end

          def call(schema_name, dir)
            return fail_with(USAGE) if schema_name.to_s.empty? || dir.to_s.empty?

            Dump.(Object.const_get(schema_name), dir).each { |file| @out.puts("Wrote #{file}") }
            0
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
