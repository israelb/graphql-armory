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
        #
        # An entry accepts one problem as it was: how many times it appeared, and what it reached (see Reach). A problem that
        # grew, because a field or a subclass was added to what it covers, is not the problem someone accepted.
        class Baseline
          VERSION = 1
          Entry = Struct.new(:kind, :path, :message, :count, :covers) do
            def key = [kind, path, message]
            def to_h = { "kind" => kind, "path" => path, "message" => message, "count" => count, "covers" => covers }
          end

          # What a report comes to against a baseline. It has no `ok?`, so nobody reads a pass as a clean schema.
          class Result
            attr_reader :report, :new_problems, :accepted, :gone, :grown

            def initialize(report:, new_problems:, accepted:, gone:, grown: {})
              @report = report
              @new_problems = new_problems.freeze
              @accepted = accepted.freeze
              @gone = gone.freeze
              @grown = grown.freeze
              freeze
            end

            # An accepted problem that is gone fails too: left in the file, it could come back unseen.
            def passes?
              new_problems.empty? && gone.empty?
            end

            def to_s
              sections = [
                section("#{new_problems.size} new #{plural('problem', new_problems.size)}:", new_problems.map { |problem| new_line(problem) }),
                section("#{gone.size} accepted #{plural('problem', gone.size)} no longer found (remove them from the baseline):", gone.map { |entry| "#{entry.path} (#{entry.kind}): #{entry.message}" }),
                section("#{accepted.size} accepted in the baseline, still open:", accepted),
                bypasses_text
              ].compact
              sections.unshift("Passes only because of its baseline.") if passes? && !accepted.empty?
              sections.unshift("No problems.") if passes? && accepted.empty?
              "#{sections.join("\n\n")}\n"
            end

            private

            def new_line(problem)
              extra = grown[problem]
              extra ? "#{problem} (it now also reaches #{extra.join(', ')})" : problem.to_s
            end

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

          # Every problem of a report, accepted as it is now.
          def self.from(report)
            new(report.problems.group_by { |problem| [problem.kind.to_s, problem.path, problem.message] }.map do |(kind, path, message), problems|
              Entry.new(kind, path, message, problems.size, report.reach_of(problems.first))
            end)
          end

          def self.load(path)
            data = begin
              JSON.parse(File.read(path, mode: "r:bom|utf-8"))
            rescue JSON::ParserError, ArgumentError, EncodingError
              # Not the parser's message: it quotes the file's content.
              raise ConfigurationError, "the baseline #{path} is not valid JSON"
            rescue SystemCallError => error
              raise ConfigurationError, "the baseline #{path} cannot be read (#{error.class})"
            end
            unless data.is_a?(Hash) && data["version"].eql?(VERSION) && data["problems"].is_a?(Array)
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
          rescue SystemCallError => error
            raise ConfigurationError, "the baseline #{path} cannot be written (#{error.class})"
          end

          # With no count or covers an entry accepts the narrowest thing: one problem that reaches nothing.
          def self.entry_from(entry, path)
            unless entry.is_a?(Hash) && %w[kind path message].all? { |key| entry[key].is_a?(String) }
              raise ConfigurationError, "the baseline #{path} needs a kind, a path and a message in each problem"
            end

            count = entry.fetch("count", 1)
            covers = entry.fetch("covers", [])
            unless count.is_a?(Integer) && count.positive? && covers.is_a?(Array) && covers.all?(String)
              raise ConfigurationError, "the baseline #{path} needs a positive count and a list of Strings in covers"
            end

            Entry.new(*entry.values_at("kind", "path", "message"), count, covers)
          end
          private_class_method :entry_from

          attr_reader :entries

          # What a baseline never accepts: with no plugin, no rule runs at all, so there is nothing to adopt gradually; an own
          # check or a denial hook reaches whatever uses it later, which no entry can pin down, and each already has its
          # declaration with a reason (`own_checks:`, `own_denial_hooks:`).
          REFUSED = { "plugin" => "a baseline cannot accept a schema that never installed the plugin: install it first",
                      "own_check" => "a baseline cannot accept an own check: remove it, or declare it in own_checks: with a reason",
                      "hook" => "a baseline cannot accept a denial hook: remove it, or declare it in own_denial_hooks: with a reason",
                      "observed" => "a baseline cannot accept observe: it serves what the rule would refuse, and it already says why" }.freeze

          # `new` is inert: it accepts nothing, so every problem is new.
          def initialize(entries = [])
            refused = entries.find { |entry| REFUSED.key?(entry.kind) }
            raise ConfigurationError, "#{REFUSED.fetch(refused.kind)} (#{refused.path})" if refused

            @entries = entries.map { |entry| Entry.new(entry.kind, entry.path, entry.message, entry.count || 1, entry.covers || []) }.uniq(&:key).sort_by(&:to_a).freeze
          end

          def call(report)
            by_key = entries.to_h { |entry| [entry.key, entry] }
            seen = Hash.new(0)
            grown = {}
            accepted, new_problems = report.problems.partition do |problem|
              entry = by_key[key_of(problem)]
              next false unless entry

              extra = beyond(report.reach_of(problem), entry.covers)
              grown[problem] = extra unless extra.empty?
              extra.empty? && (seen[entry.key] += 1) <= entry.count
            end
            found = report.problems.map { |problem| key_of(problem) }
            Result.new(report: report, new_problems: new_problems, accepted: accepted, grown: grown,
                       gone: entries.reject { |entry| found.include?(entry.key) })
          end

          # This baseline without what `other` no longer holds: nothing grows.
          def kept_from(other)
            current = other.entries.to_h { |entry| [entry.key, entry] }
            self.class.new(entries.filter_map do |entry|
              now = current[entry.key]
              next unless now

              Entry.new(entry.kind, entry.path, entry.message, [entry.count, now.count].min, common(entry.covers, now.covers))
            end)
          end

          private

          def key_of(problem)
            [problem.kind.to_s, problem.path, problem.message]
          end

          # What `now` holds beyond `accepted`, counting repeats: two classes may share a name.
          def beyond(now, accepted)
            left = accepted.tally
            now.reject { |item| left[item].to_i.positive? && (left[item] -= 1) }
          end

          def common(one, other)
            left = other.tally
            one.select { |item| left[item].to_i.positive? && (left[item] -= 1) }
          end
        end
      end
    end
  end
end
