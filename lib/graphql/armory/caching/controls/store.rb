# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      module Controls
        module Store
          # A `Store::Substitute` on a fixed clock.
          def self.example(now: 1_000_000)
            Caching::Store::Substitute.new(now: now)
          end
        end
      end
    end
  end
end
