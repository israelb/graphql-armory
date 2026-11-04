# frozen_string_literal: true

module GraphQL
  module Armory
    module Versioning
      # What the gate decided for one request: the version it is served, or why it is refused.
      class Decision
        # What a client reads in `extensions.code`, by reason.
        CODES = { unknown: "UNKNOWN_API_VERSION", retired: "RETIRED_API_VERSION", missing: "MISSING_API_VERSION" }.freeze

        # Fixed messages: they never quote what the client sent, nor list the versions.
        MESSAGES = { unknown: "Unknown API version", retired: "This API version is retired", missing: "Send an API version" }.freeze

        def self.served(version) = new(:served, version, nil)
        def self.defaulted(version) = new(:defaulted, version, nil)

        def self.refused(reason, version: nil)
          raise ArgumentError, "reason must be one of #{CODES.keys.inspect}, got #{reason.inspect}" unless CODES.key?(reason)

          new(:refused, version, reason)
        end

        attr_reader :outcome, :version, :reason

        def initialize(outcome, version, reason)
          @outcome = outcome
          @version = version
          @reason = reason
          freeze
        end

        def refused?
          @outcome == :refused
        end

        def code
          CODES[@reason]
        end

        def message
          MESSAGES[@reason]
        end

        # The telemetry signal and its data: the schema's own label, or the reason. Never the client's value.
        def signal
          :"version_#{@outcome}"
        end

        def data
          refused? ? { reason: @reason } : { version: @version.label }
        end

        # What `visible?` raises for a query whose version is refused, when a caller that skips validation reaches it.
        def error
          return MissingVersionError.new("#{message}: pass context: { armory_version: \"<label>\" }, or set default: on use", code) if @reason == :missing

          RefusedVersionError.new(message, code)
        end

        def ==(other)
          other.is_a?(Decision) && [outcome, version, reason] == [other.outcome, other.version, other.reason]
        end
      end

      # What a request with no version gets, chosen by `use`'s `default:`.
      module Default
        # `default: :latest`, for a new API: clients that send nothing follow the schema forward.
        class Latest
          def call(versions) = Decision.defaulted(versions.latest)
        end

        # `default: "2024-06-01"`, for an API with clients in production: they keep the schema they were built against.
        class Label
          def initialize(label)
            @label = label.dup.freeze
            freeze
          end

          def call(versions) = Decision.defaulted(versions.fetch(@label))
        end

        # `default: :refuse`: every request must name its version.
        class Refuse
          def call(_versions) = Decision.refused(:missing)
        end
      end
    end
  end
end
