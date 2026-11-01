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
            # By position: an app that declares the task again renames its arguments.
            status = new.(args[:schema], args.to_a[1])
            exit(status) unless status.zero?
          end

          # The baseline task's action: writes the file, or removes from it what is gone.
          BASELINE_ACTION = proc do |_task, args|
            Rake::Task[:environment].invoke if Rake::Task.task_defined?(:environment)
            status = new.write_baseline(args[:schema], args.to_a[1])
            exit(status) unless status.zero?
          end

          def initialize(out: $stdout)
            @out = out
          end

          def call(schema_name, baseline = nil)
            with_schema(schema_name, "audit") do |schema|
              report = Audit.(schema)
              next judged(report, baseline) unless baseline.to_s.empty?

              @out.print(report)
              report.ok? ? 0 : 1
            end
          end

          def write_baseline(schema_name, path)
            return fail_with("Name the file: rake graphql_armory:audit_baseline[YourSchema,path]") if path.to_s.empty?

            with_schema(schema_name, "audit_baseline") do |schema|
              wrote(Audit.(schema), path)
            end
          end

          private

          def judged(report, baseline)
            result = Baseline.load(baseline).(report)
            @out.print(result)
            result.passes? ? 0 : 1
          rescue ConfigurationError => error
            fail_with(error.message)
          end

          def wrote(report, path)
            written = Baseline.write(report, path)
            not_accepted = Baseline.new(written.entries).(report).new_problems.size
            @out.puts("#{path}: #{written.entries.size} accepted. Fix them: this list only ever shrinks.")
            @out.puts("#{not_accepted} not accepted: they still fail the audit.") if not_accepted.positive?
            0
          rescue ConfigurationError => error
            fail_with(error.message)
          end

          def with_schema(schema_name, task)
            return fail_with("Name the schema: rake graphql_armory:#{task}[YourSchema]") if schema_name.to_s.empty?

            yield Object.const_get(schema_name)
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
