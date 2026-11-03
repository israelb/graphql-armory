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

          # `at:` is what the problem is about (a type, a field, an argument or a method), for its file and line.
          def problem(kind, path, message, at: nil)
            @problems << Report::Problem.new(kind, path, message, Location.of(at))
          end

          def problem?(kind, path = nil)
            @problems.any? { |problem| problem.kind == kind && (path.nil? || problem.path == path) }
          end

          def bypass(path, reason, at: nil)
            @bypasses << Report::Bypass.new(path, reason, Location.of(at))
          end

          def report(reach = nil)
            Report.new(problems: @problems.sort_by { |problem| [problem.path, problem.kind.to_s] },
                       bypasses: @bypasses.sort_by(&:path),
                       reach: reach)
          end
        end
      end
    end
  end
end
