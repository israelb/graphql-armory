# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      # Reads a schema's subscriptions setup, without running anything, and reports what could let a delivery reach
      # someone it was not computed for, or run without the schema's plugins. Notices list what a reviewer should read
      # (each stored context key with its reason, anonymous mode, fields marked broadcastable) and never fail it.
      #
      #   report = GraphQL::Armory::Subscriptions::Audit.(AppSchema)
      #   report.ok?   # false on an :error finding
      #   puts report
      class Audit
        # One finding: `kind` (a Symbol), `severity` (:error or :notice), `message`.
        Finding = Struct.new(:kind, :severity, :message, keyword_init: true) do
          def initialize(...)
            super
            freeze
          end

          def to_s = "[#{severity}] #{kind}: #{message}"
        end

        # What the audit found, in order.
        class Report
          attr_reader :findings

          def initialize(findings = [])
            @findings = findings.dup.freeze
            freeze
          end

          def ok?
            findings.none? { |finding| finding.severity == :error }
          end

          def to_s
            return "subscriptions audit: nothing to report" if findings.empty?

            (["subscriptions audit: #{ok? ? "ok" : "failed"}"] + findings.map(&:to_s)).join("\n")
          end
        end

        def self.build
          new
        end

        def self.call(schema)
          build.(schema)
        end

        def call(schema)
          findings = []
          backend = schema.respond_to?(:subscriptions) ? schema.subscriptions : nil
          unless backend.is_a?(Core)
            findings << error(:plugin, "#{schema} does not use GraphQL::Armory::Subscriptions (#{backend.nil? ? "no subscriptions" : backend.class})")
            return Report.new(findings)
          end

          unless backend.schema.equal?(schema)
            findings << error(:child_schema, "#{schema} shares the subscriptions of #{backend.schema}: its deliveries run on #{backend.schema} and its plugins, " \
                                             "not on #{schema}'s; install GraphQL::Armory::Subscriptions on the schema that executes")
          end
          settings = backend.settings
          if !settings.viewer.anonymous? && !backend.transport.capabilities.viewer_bound?
            findings << error(:transport, "#{backend.transport.class} is not viewer_bound, with a viewer configured: one viewer could read another's channel")
          end
          findings.concat(broadcastable(schema))
          findings << notice(:anonymous, "every subscription is viewer-independent: #{settings.viewer.reason}") if settings.viewer.anonymous?
          settings.context_keys.each do |key, reason|
            findings << notice(:context_key, "context[#{key.inspect}] is stored with every subscription and restored on each delivery: #{reason}")
          end
          Report.new(findings)
        end

        private

        def broadcastable(schema)
          root = schema.subscription
          return [] unless root

          root.all_field_definitions.select { |field| field.respond_to?(:broadcastable?) && field.broadcastable? == true }.map do |field|
            notice(:broadcastable, "#{field.path} is marked broadcastable: true, which is ignored: every subscriber runs with its own context")
          end
        end

        def error(kind, message) = Finding.new(kind: kind, severity: :error, message: message)
        def notice(kind, message) = Finding.new(kind: kind, severity: :notice, message: message)
      end
    end
  end
end
