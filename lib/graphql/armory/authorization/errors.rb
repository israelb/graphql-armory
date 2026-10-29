# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Error < Armory::Error; end

      # An adapter answered something other than true, false or nil.
      class AdapterError < Error; end

      # An adapter cannot narrow a list to what the actor may see.
      class MissingScopeError < Error; end
    end
  end
end
