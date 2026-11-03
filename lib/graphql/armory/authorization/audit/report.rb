# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # What an audit found: what is not covered, and every bypass someone declared.
        class Report
          # `location` is "path:line" where the app wrote what the problem is about (see Location), or nil. It is not part of
          # what a problem is: `to_s` and the baseline leave it out, so moving code changes neither.
          Problem = Struct.new(:kind, :path, :message, :location) do
            def to_s
              "#{path} (#{kind}): #{message}"
            end
          end

          Bypass = Struct.new(:path, :reason, :location)

          # The line the report prints for a problem or a bypass: its text, then where it is.
          def self.line(text, location)
            location ? "#{text} (at #{location})" : text
          end

          attr_reader :problems, :bypasses

          def initialize(problems:, bypasses:, reach: nil)
            @problems = problems.freeze
            @bypasses = bypasses.freeze
            @reach = reach
            freeze
          end

          # What a problem reaches beyond its own name: see Reach. Worked out only for a baseline, so a plain audit never reads it.
          def reach_of(problem)
            @reach ? @reach.(problem.path) : []
          end

          def ok?
            problems.empty?
          end

          def to_s
            [problems_text, bypasses_text].compact.join("\n\n") << "\n"
          end

          private

          def problems_text
            return "No problems." if ok?

            ["#{problems.size} #{problems.size == 1 ? 'problem' : 'problems'}:", *problems.map { |problem| "  #{Report.line(problem.to_s, problem.location)}" }].join("\n")
          end

          def bypasses_text
            return if bypasses.empty?

            ["#{bypasses.size} declared #{bypasses.size == 1 ? 'bypass' : 'bypasses'}:",
             *bypasses.map { |bypass| "  #{Report.line("#{bypass.path}: #{bypass.reason}", bypass.location)}" }].join("\n")
          end
        end
      end
    end
  end
end
