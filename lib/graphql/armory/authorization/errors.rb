# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Error < Armory::Error; end

      # An adapter answered something other than true, false or nil.
      class AdapterError < Error; end

      # An adapter cannot narrow a list to what the actor may see.
      class MissingScopeError < Error; end

      # The schema or a class was not set up the way the integration needs.
      class ConfigurationError < Error; end

      # Raised on a denial when the schema asks for `on_unauthorized: :raise`.
      # It names the type but never the record.
      class NotAuthorizedError < Error
        attr_reader :type_name

        def initialize(type_name = nil)
          @type_name = type_name
          super("Not authorized to access #{type_name || 'this object'}")
        end
      end
    end
  end
end
