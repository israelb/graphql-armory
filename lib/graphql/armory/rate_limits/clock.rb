# frozen_string_literal: true

module GraphQL
  module Armory
    module RateLimits
      # What a limiter reads the time from: a callable answering seconds, like `Clock.monotonic`.
      module Clock
        def self.monotonic
          MemoryStore.monotonic_clock
        end

        # A clock the test moves (`advance`, `now`) and that counts how often it was read: for tests, instead of
        # hand-written fakes.
        class Substitute
          attr_accessor :now
          attr_reader :reads

          def initialize(now: 0.0)
            @now = now
            @reads = 0
          end

          def call
            @reads += 1
            @now
          end

          def advance(seconds)
            @now += seconds
          end
        end
      end
    end
  end
end
