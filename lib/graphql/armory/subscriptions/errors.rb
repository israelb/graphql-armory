# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      class Error < Armory::Error; end

      # An option of `use`, the schema or a dependency is not set up the way subscriptions need. Raised at boot.
      class ConfigurationError < Error; end

      # A subscription refused when it is created (a client-chosen id, a viewer that does not dump, a cap reached, an
      # argument or scope that cannot be digested). `reason` is a Symbol for telemetry; the message never quotes a
      # value the client sent.
      class RefusedError < Error
        attr_reader :reason

        def initialize(message = "subscription refused", reason: :refused)
          raise ArgumentError, "RefusedError reason: must be a Symbol, got #{reason.class}" unless reason.is_a?(Symbol)

          @reason = reason
          super(message)
        end
      end

      # The transport or its HTTP client failed (a timeout, a refused connection, an answer it cannot read). The
      # message names the error class, never a URL's query string, a credential or a payload.
      class TransportError < Error; end
    end
  end
end
