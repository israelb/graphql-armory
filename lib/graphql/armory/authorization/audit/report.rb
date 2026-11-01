# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # What an audit found: what is not covered, and every bypass someone declared.
        class Report
          Problem = Struct.new(:kind, :path, :message) do
            def to_s
              "#{path} (#{kind}): #{message}"
            end
          end

          Bypass = Struct.new(:path, :reason)

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

            ["#{problems.size} #{problems.size == 1 ? 'problem' : 'problems'}:", *problems.map { |problem| "  #{problem}" }].join("\n")
          end

          def bypasses_text
            return if bypasses.empty?

            ["#{bypasses.size} declared #{bypasses.size == 1 ? 'bypass' : 'bypasses'}:",
             *bypasses.map { |bypass| "  #{bypass.path}: #{bypass.reason}" }].join("\n")
          end
        end
      end
    end
  end
end
