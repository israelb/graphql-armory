# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      # What `use GraphQL::Armory::Authorization, ...` stores on the schema.
      class Configuration
        MODES = %i[null error raise].freeze

        attr_reader :adapter, :on_unauthorized, :sinks

        def initialize(adapter:, on_unauthorized: :null, sinks: [])
          unless MODES.include?(on_unauthorized)
            raise ArgumentError, "on_unauthorized must be one of #{MODES.inspect}, got #{on_unauthorized.inspect}"
          end

          @adapter = resolve(adapter)
          @on_unauthorized = on_unauthorized
          Telemetry.build(sinks: sinks) # raises at boot when the sinks are not callables
          @sinks = sinks
        end

        private

        def resolve(adapter)
          case adapter
          when :pundit then Adapters::Pundit.new
          when :cancan then Adapters::CanCan.new
          when Symbol, String then raise ArgumentError, "unknown adapter #{adapter.inspect}; use :pundit, :cancan or an adapter object"
          else adapter
          end
        end
      end
    end
  end
end
