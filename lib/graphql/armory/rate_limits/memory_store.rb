# frozen_string_literal: true

module GraphQL
  module Armory
    module RateLimits
      # Buckets kept in this process's memory: for tests, development and single-process servers. Several
      # processes each keep their own buckets, so a client gets the limit once per process; share a store between
      # processes in production.
      class MemoryStore
        def self.monotonic_clock
          -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        end

        def initialize(clock: self.class.monotonic_clock)
          @clock = clock
          @buckets = {}
          @mutex = Mutex.new
        end

        # Token bucket: holds up to `limit` points and refills `limit` points every `window` seconds, continuously.
        # Takes `cost` points when they are there; with `force: true` takes them anyway, down to zero. Answers
        # whether they were there and the whole points left.
        def take(key, cost:, limit:, window:, force: false)
          @mutex.synchronize do
            now = @clock.call
            level, at = @buckets.fetch(key) { [limit, now] }
            level = [level + ((now - at) * limit / window.to_f), limit].min

            taken = cost <= level
            level = [level - cost, 0].max if taken || force
            @buckets[key] = [level, now]

            [taken, level.floor]
          end
        end
      end
    end
  end
end
