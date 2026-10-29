# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      module Adapters
        # The adapter of an object nobody configured: it denies everything.
        class Null
          def actor(_context)
            nil
          end

          def authorized?(_actor, _subject, _rule)
            false
          end

          def scope(_actor, items, _rule)
            items.respond_to?(:none) ? items.none : []
          end

          def check(_type, _rule)
            ["no adapter is configured: everything is denied"]
          end
        end
      end
    end
  end
end
