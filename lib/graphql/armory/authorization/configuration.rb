# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      # What `use GraphQL::Armory::Authorization, ...` stores on the schema.
      class Configuration
        MODES = %i[null error raise].freeze

        DENIAL_HOOKS = %i[unauthorized_field unauthorized_object].freeze

        OWN_CHECKS = %i[authorized? authorizes? authorized_new unauthorized_object visible?].freeze

        attr_reader :adapter, :on_unauthorized, :sinks, :own_denial_hooks, :own_checks

        def initialize(adapter:, on_unauthorized: :null, sinks: [], own_denial_hooks: {}, own_checks: {})
          unless MODES.include?(on_unauthorized)
            raise ArgumentError, "on_unauthorized must be one of #{MODES.inspect}, got #{on_unauthorized.inspect}"
          end
          check_own_denial_hooks(own_denial_hooks)
          check_own_checks(own_checks)

          @own_checks = own_checks.to_h { |holder, methods| [holder, methods.to_h { |name, reason| [name, reason.dup.freeze] }.freeze] }.freeze
          @adapter = resolve(adapter)
          @on_unauthorized = on_unauthorized
          @own_denial_hooks = own_denial_hooks.to_h { |hook, reason| [hook, reason.dup.freeze] }.freeze
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

        def check_own_checks(checks)
          valid = checks.is_a?(Hash) && checks.all? do |holder, methods|
            holder.is_a?(Module) && methods.is_a?(Hash) && methods.all? do |name, reason|
              OWN_CHECKS.include?(name) && reason.is_a?(String) && !reason.strip.empty?
            end
          end
          return if valid

          raise ArgumentError, "own_checks must map a class to #{OWN_CHECKS.inspect} and the reason you keep each, got #{checks.inspect}"
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
