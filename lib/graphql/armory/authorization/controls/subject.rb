# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      module Controls
        Subject = Struct.new(:id) do
          def self.example(id: 1)
            new(id)
          end
        end
      end
    end
  end
end
