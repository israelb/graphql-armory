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
            status = new.(args[:schema], args[:baseline])
            exit(status) unless status.zero?
          end

          # The baseline task's action: writes the file, or removes from it what is gone.
          BASELINE_ACTION = proc do |_task, args|
            Rake::Task[:environment].invoke if Rake::Task.task_defined?(:environment)
            status = new.write_baseline(args[:schema], args[:baseline])
            exit(status) unless status.zero?
          end

          def initialize(out: $stdout)
            @out = out
          end

          def call(schema_name, baseline = nil)
            with_schema(schema_name) do |schema|
              report = Audit.(schema)
              result = baseline.to_s.empty? ? report : Baseline.load(baseline).(report)
              @out.print(result)
              (baseline.to_s.empty? ? report.ok? : result.passes?) ? 0 : 1
            end
          end

          def write_baseline(schema_name, path)
            return fail_with("Name the file: rake graphql_armory:audit_baseline[YourSchema,path]") if path.to_s.empty?

            with_schema(schema_name) do |schema|
              written = Baseline.write(Audit.(schema), path)
              @out.puts("#{path}: #{written.entries.size} accepted. Fix them: this list only ever shrinks.")
              0
            end
          end

          private

          def with_schema(schema_name)
            return fail_with("Name the schema: rake graphql_armory:audit[YourSchema]") if schema_name.to_s.empty?

            yield Object.const_get(schema_name)
          rescue ConfigurationError => error
            fail_with(error.message)
          rescue NameError => error
            raise unless error.name.to_s == schema_name.to_s.split("::").last

            fail_with("No schema named #{schema_name}")
          end

          def fail_with(message)
            @out.puts(message)
            1
          end
        end
      end
    end
  end
end
