# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # Collects what one audit finds.
        class Findings
          def initialize
            @problems = []
            @bypasses = []
          end

          def problem(kind, path, message)
            @problems << Report::Problem.new(kind, path, message)
          end

          def problem?(kind, path = nil)
            @problems.any? { |problem| problem.kind == kind && (path.nil? || problem.path == path) }
          end

          def bypass(path, reason)
            @bypasses << Report::Bypass.new(path, reason)
          end

          def report
            Report.new(problems: @problems.sort_by { |problem| [problem.path, problem.kind.to_s] },
                       bypasses: @bypasses.sort_by(&:path))
          end
        end
      end
    end
  end
end
