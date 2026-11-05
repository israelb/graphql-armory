# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      class Audit
        # What a cache audit found: the problems, and every declaration someone made with its reason, listed apart.
        class Report
          # `location` is "path:line" where the app wrote what the problem is about (see Location), or nil. `severity` is
          # nil for a problem, or :information for something that never serves a wrong answer (an operation that is never
          # cached): `ok?` ignores it unless the audit was strict.
          Problem = Struct.new(:kind, :path, :message, :location, :severity) do
            def information? = severity == :information

            def to_s
              "#{path} (#{kind}): #{message}"
            end
          end

          # A declaration the team made, and why: `kind` is :public, :anonymous, :neutral_key, :context_method, :own_check
          # or :cache_safe.
          Declared = Struct.new(:kind, :path, :reason, :location)

          def self.line(text, location)
            location ? "#{text} (at #{location})" : text
          end

          attr_reader :problems, :declarations

          def initialize(problems: [], declarations: [], strict: false)
            @problems = problems.freeze
            @declarations = declarations.freeze
            @strict = strict
            freeze
          end

          def strict?
            @strict
          end

          # The problems `ok?` counts: every one under `strict: true`, else all but information.
          def failing
            @strict ? problems : problems.reject(&:information?)
          end

          def information
            @strict ? [] : problems.select(&:information?)
          end

          def ok?
            failing.empty?
          end

          def to_s
            [failing_text, information_text, declarations_text].compact.join("\n\n") << "\n"
          end

          private

          def failing_text
            return "No problems." if ok?

            ["#{failing.size} #{failing.size == 1 ? 'problem' : 'problems'}:", *failing.map { |problem| "  #{Report.line(problem.to_s, problem.location)}" }].join("\n")
          end

          def information_text
            return if information.empty?

            ["Information:", *information.map { |problem| "  #{Report.line(problem.to_s, problem.location)}" }].join("\n")
          end

          def declarations_text
            return if declarations.empty?

            ["#{declarations.size} #{declarations.size == 1 ? 'declaration' : 'declarations'}:",
             *declarations.map { |declared| "  #{Report.line("#{declared.path} (#{declared.kind}): #{declared.reason}", declared.location)}" }].join("\n")
          end
        end

        # Collects what one audit finds. A problem found twice (a field inherited by several types, a versioned twin of the
        # same name) is listed once.
        class Findings
          def initialize
            @problems = {}
            @declarations = {}
          end

          def problem(kind, path, message, at: nil, severity: nil)
            @problems[[kind, path, message]] ||= Report::Problem.new(kind, path, message, Location.of(at), severity)
          end

          def information(kind, path, message, at: nil)
            problem(kind, path, message, at: at, severity: :information)
          end

          def problem?(kind, path = nil)
            @problems.each_value.any? { |problem| problem.kind == kind && (path.nil? || problem.path == path) }
          end

          def declared(kind, path, reason, at: nil)
            @declarations[[kind, path]] ||= Report::Declared.new(kind, path, reason, Location.of(at))
          end

          def report(strict: false)
            Report.new(problems: @problems.values.sort_by { |problem| [problem.path, problem.kind.to_s, problem.message] },
                       declarations: @declarations.values.sort_by { |declared| [declared.kind.to_s, declared.path] },
                       strict: strict)
          end
        end
      end
    end
  end
end
