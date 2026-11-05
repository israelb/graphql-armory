# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      # What happened to the message at `index` of one `publish`:
      #
      #   :ok       accepted by the provider
      #   :gone     the channel no longer exists for the provider: the core deletes the subscription
      #   :retry    a transient failure (rate limited, a timeout): kept, not retried inline
      #   :refused  the provider refused it for good (too large, a bad request); `reason` says why
      class Outcome
        STATUSES = %i[ok gone retry refused].freeze

        attr_reader :status, :index, :reason

        def initialize(status:, index:, reason: nil)
          raise ArgumentError, "Outcome status: must be one of #{STATUSES.inspect}" unless STATUSES.include?(status)
          raise ArgumentError, "Outcome index: must be a non-negative Integer" unless index.is_a?(Integer) && index >= 0
          raise ArgumentError, "Outcome reason: must be a Symbol or nil" unless reason.nil? || reason.is_a?(Symbol)

          @status = status
          @index = index
          @reason = reason
          freeze
        end

        def ok? = status == :ok
        def gone? = status == :gone
        def retry? = status == :retry
        def refused? = status == :refused

        def ==(other)
          other.is_a?(Outcome) && [other.status, other.index, other.reason] == [status, index, reason]
        end
        alias_method :eql?, :==

        def hash = [status, index, reason].hash
      end
    end
  end
end
