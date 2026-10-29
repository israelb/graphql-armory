# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      module Controls
        # Stands in for GraphQL::Query::Context: values plus a namespace per library.
        class Context
          def self.example(**values)
            new(values)
          end

          def initialize(values)
            @values = values
            @namespaces = Hash.new { |namespaces, name| namespaces[name] = {} }
          end

          def [](key)
            @values[key]
          end

          def namespace(name)
            @namespaces[name]
          end
        end
      end
    end
  end
end
