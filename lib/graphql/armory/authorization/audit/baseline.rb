# frozen_string_literal: true

require "json"

module GraphQL
  module Armory
    module Authorization
      class Audit
        # The problems a team accepted for now, so adopting the gem on a large schema fails the build only on new ones.
        # A report's `ok?` never changes because of it: a schema with problems is not ok, with or without a baseline.
        #
        #   Baseline.load("config/graphql_armory_baseline.json").(report).passes?
        class Baseline
          VERSION = 1
          Entry = Struct.new(:kind, :path, :message) do
            def to_h = { "kind" => kind, "path" => path, "message" => message }
          end

          # What a report comes to against a baseline. It has no `ok?`, so nobody reads a pass as a clean schema.
          class Result
            attr_reader :report, :new_problems, :accepted, :gone

            def initialize(report:, new_problems:, accepted:, gone:)
              @report = report
              @new_problems = new_problems.freeze
              @accepted = accepted.freeze
              @gone = gone.freeze
              freeze
            end

            # An accepted problem that is gone fails too: left in the file, it could come back unseen.
            def passes?
              new_problems.empty? && gone.empty?
            end

            def to_s
              sections = [
                section("#{new_problems.size} new #{plural('problem', new_problems.size)}:", new_problems),
                section("#{gone.size} accepted #{plural('problem', gone.size)} no longer found (remove them from the baseline):", gone.map { |entry| "#{entry.path} (#{entry.kind}): #{entry.message}" }),
                section("#{accepted.size} accepted in the baseline, still open:", accepted),
                bypasses_text
              ].compact
              sections.unshift("Passes only because of its baseline.") if passes? && !accepted.empty?
              sections.unshift("No new problems.") if sections.empty?
              "#{sections.join("\n\n")}\n"
            end

            private

            def section(title, lines)
              return if lines.empty?

              [title, *lines.map { |line| "  #{line}" }].join("\n")
            end

            def bypasses_text
              section("#{report.bypasses.size} declared #{report.bypasses.size == 1 ? 'bypass' : 'bypasses'}:", report.bypasses.map { |bypass| "#{bypass.path}: #{bypass.reason}" })
            end

            def plural(word, count)
              count == 1 ? word : "#{word}s"
            end
          end

          # Every problem of a report, accepted.
          def self.from(report)
            new(report.problems.map { |problem| Entry.new(problem.kind.to_s, problem.path, problem.message) })
          end

          def self.load(path)
            data = begin
              JSON.parse(File.read(path, mode: "r:bom|utf-8"))
            rescue JSON::ParserError
              raise ConfigurationError, "the baseline #{path} is not valid JSON"
            rescue SystemCallError => error
              raise ConfigurationError, "the baseline #{path} cannot be read (#{error.class})"
            end
            unless data.is_a?(Hash) && data["version"] == VERSION && data["problems"].is_a?(Array)
              raise ConfigurationError, "the baseline #{path} needs version #{VERSION} and a list of problems"
            end

            new(data["problems"].map { |entry| entry_from(entry, path) })
          end

          # Creates the file with every problem. A file that exists only ever loses what is gone: accepting a new problem is
          # a manual edit, so it shows in review. Answers what was written.
          def self.write(report, path)
            baseline = from(report)
            kept = File.exist?(path) ? load(path).kept_from(baseline) : baseline
            File.write(path, "#{JSON.pretty_generate('version' => VERSION, 'problems' => kept.entries.map(&:to_h))}\n")
            kept
          end

          def self.entry_from(entry, path)
            unless entry.is_a?(Hash) && %w[kind path message].all? { |key| entry[key].is_a?(String) }
              raise ConfigurationError, "the baseline #{path} needs a kind, a path and a message in each problem"
            end

            Entry.new(*entry.values_at("kind", "path", "message"))
          end
          private_class_method :entry_from

          attr_reader :entries

          # `new` is inert: it accepts nothing, so every problem is new. A schema with no plugin cannot be accepted: then
          # no rule runs at all, and there is nothing to adopt gradually.
          def initialize(entries = [])
            if entries.any? { |entry| entry.kind == "plugin" }
              raise ConfigurationError, "a baseline cannot accept a schema that never installed the plugin: install it first"
            end

            @entries = entries.uniq.sort_by(&:to_a).freeze
          end

          def call(report)
            accepted, new_problems = report.problems.partition { |problem| entries.include?(entry_of(problem)) }
            found = report.problems.map { |problem| entry_of(problem) }
            Result.new(report: report, new_problems: new_problems, accepted: accepted, gone: entries - found)
          end

          def kept_from(other)
            self.class.new(entries & other.entries)
          end

          private

          def entry_of(problem)
            Entry.new(problem.kind.to_s, problem.path, problem.message)
          end
        end
      end
    end
  end
end
