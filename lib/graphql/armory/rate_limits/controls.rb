# frozen_string_literal: true

module GraphQL
  module Armory
    module RateLimits
      # Test data for the rate limiters, reusable by apps and other gems.
      module Controls
        # A Query type: `cheap` costs 1 point, `report` costs 40, `broken` raises when resolved.
        module Query
          def self.example
            Class.new(GraphQL::Schema::Object) do
              graphql_name "Query"
              field :cheap, String, null: false
              field :report, String, null: false, complexity: 40
              field :broken, String, null: false
            end
          end
        end

        # The root object for Query.example; it adds the name of each field it resolves to `resolved`.
        module Root
          def self.example(resolved = [])
            Class.new do
              define_method(:cheap) { resolved << :cheap; "ok" }
              define_method(:report) { resolved << :report; "big" }
              define_method(:broken) { raise IOError, "disk on fire" }
            end.new
          end
        end

        # A root for Query.example whose every field takes `seconds` on `clock` (a Clock::Substitute) before it
        # answers, so a spec decides how long an operation took.
        module Time
          def self.example(clock, resolved = [], seconds: 0.25)
            root = Root.example(resolved)
            Class.new do
              %i[cheap report broken].each do |field|
                define_method(field) do
                  clock.advance(seconds)
                  root.public_send(field)
                end
              end
            end.new
          end
        end

        # A query context naming its client.
        module Context
          def self.example(key: "user:1", **context)
            { RateLimits::KEY => key, **context }
          end
        end
      end
    end
  end
end
