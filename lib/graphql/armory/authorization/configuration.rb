# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      # What `use GraphQL::Armory::Authorization, ...` stores on the schema.
      class Configuration
        MODES = %i[null error raise].freeze

        DENIAL_HOOKS = %i[unauthorized_field unauthorized_object].freeze

        attr_reader :adapter, :on_unauthorized, :sinks, :own_denial_hooks

        def initialize(adapter:, on_unauthorized: :null, sinks: [], own_denial_hooks: {})
          unless MODES.include?(on_unauthorized)
            raise ArgumentError, "on_unauthorized must be one of #{MODES.inspect}, got #{on_unauthorized.inspect}"
          end
          check_own_denial_hooks(own_denial_hooks)

          @adapter = resolve(adapter)
          @on_unauthorized = on_unauthorized
          @own_denial_hooks = own_denial_hooks
          Telemetry.build(sinks: sinks) # raises at boot when the sinks are not callables
          @sinks = sinks
        end

        private

        def check_own_denial_hooks(hooks)
          valid = hooks.is_a?(Hash) && hooks.all? do |hook, reason|
            DENIAL_HOOKS.include?(hook) && reason.is_a?(String) && !reason.strip.empty?
          end
          return if valid

          raise ArgumentError, "own_denial_hooks must map #{DENIAL_HOOKS.inspect} to the reason you keep your own, got #{hooks.inspect}"
        end

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
