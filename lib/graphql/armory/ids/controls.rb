# frozen_string_literal: true

module GraphQL
  module Armory
    module IDs
      # Test data for encrypted IDs, reusable by apps and other gems.
      module Controls
        # An Encoder subclass with a fixed test key. Never use its key in production.
        module Encoder
          def self.example(key: "k" * 32)
            Class.new(Armory::Encoder) { key(key) }
          end
        end

        # A record with an id, as `id_from_object` receives it.
        module Record
          def self.example(id: 1)
            Struct.new(:id).new(id)
          end
        end
      end
    end
  end
end
