# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      module Controls
        module Rule
          def self.example(action: :read, **options)
            Authorization::Rule.new(action, **options)
          end
        end
      end
    end
  end
end
