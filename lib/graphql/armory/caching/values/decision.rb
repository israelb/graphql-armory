# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # What the gate decided for one query: answer it from `entry` (hit), run it and maybe store it under `key`
      # (miss, with the `policy` and the `lookup` it was decided on), or run it uncached (pass, with a `reason`).
      Decision = Struct.new(:kind, :entry, :key, :policy, :lookup, :reason, keyword_init: true) do
        def self.hit(entry)
          new(kind: :hit, entry: entry, key: nil, policy: nil, lookup: nil, reason: nil)
        end

        def self.miss(key, policy, lookup)
          new(kind: :miss, entry: nil, key: key, policy: policy, lookup: lookup, reason: nil)
        end

        def self.pass(reason)
          new(kind: :pass, entry: nil, key: nil, policy: nil, lookup: nil, reason: reason)
        end

        def initialize(kind:, entry:, key:, policy:, lookup:, reason:)
          case kind
          when :hit
            raise ArgumentError, "a hit needs an Entry" unless entry.is_a?(Entry)
          when :miss
            raise ArgumentError, "a miss needs a Key" unless key.is_a?(Key)
            raise ArgumentError, "a miss needs a cacheable Policy" unless policy.is_a?(Policy) && policy.cacheable?
            raise ArgumentError, "a miss needs a Lookup" unless lookup.is_a?(Lookup)
          when :pass
            raise ArgumentError, "a pass needs a reason Symbol, got #{reason.inspect}" unless reason.is_a?(Symbol)
          else
            raise ArgumentError, "Decision kind must be :hit, :miss or :pass, got #{kind.inspect}"
          end

          super
          freeze
        end

        def hit? = kind == :hit
        def miss? = kind == :miss
        def pass? = kind == :pass
      end
    end
  end
end
