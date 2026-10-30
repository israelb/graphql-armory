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
          @slots = {}
          @mutex = Mutex.new
        end

        # Token bucket: holds up to `limit` points and refills `limit` points every `window` seconds, continuously.
        # Takes `cost` points when they are there; with `force: true` takes them anyway, down to zero. Answers
        # whether they were there and the whole points left.
        def take(key, cost:, limit:, window:, force: false)
          @mutex.synchronize do
            now = @clock.call
            level, at = @buckets.fetch(key) { [limit, now] }
            level = [level + ([now - at, 0].max * limit / window.to_f), limit].min

            taken = cost <= level
            level = [level - cost, 0].max if taken || force
            @buckets[key] = [level, [now, at].max]

            [taken, level.floor]
          end
        end

        # Slots for operations running at the same time: at most `limit` per key, each held by a token until
        # released or until `ttl` seconds pass (a process that crashed never releases). Takes a slot when one is
        # free; with `force: true` takes it anyway. Answers whether one was free and the slots now held.
        def acquire(key, token:, limit:, ttl:, force: false)
          @mutex.synchronize do
            now = @clock.call
            slots = (@slots[key] ||= {})
            slots.delete_if { |_token, expires_at| expires_at <= now }

            acquired = slots.size < limit
            slots[token] = now + ttl if acquired || force

            [acquired, slots.size]
          end
        end

        def release(key, token:)
          @mutex.synchronize do
            slots = @slots[key] or return
            slots.delete(token)
            @slots.delete(key) if slots.empty?
          end
        end
      end
    end
  end
end
