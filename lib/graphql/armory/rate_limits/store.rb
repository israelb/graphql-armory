# frozen_string_literal: true

require "securerandom"

module GraphQL
  module Armory
    module RateLimits
      # What a limiter keeps its state in: `MemoryStore`, `RedisStore`, or any object answering the same methods.
      # `Null` and `Substitute` are the inert and the test stand-ins.
      module Store
        # The store of a limiter nobody wired: it refuses every charge and slot, so `Points.new` and
        # `Concurrency.new` never let a query through.
        class Null
          def take(_key, cost:, limit:, window:, force: false)
            [false, 0]
          end

          def acquire(_key, token:, limit:, ttl:, force: false)
            [false, 0]
          end

          def release(_key, token:)
            nil
          end
        end

        # A MemoryStore on a clock the test moves (`now`), that records its calls, fails when told and answers what
        # it is told: for tests, instead of hand-written fakes.
        class Substitute
          attr_accessor :now
          attr_reader :calls

          def initialize(now: 0.0)
            @now = now
            @memory = MemoryStore.new(clock: -> { @now })
            @calls = []
            @failures = {}
            @answers = {}
          end

          # Raises `error` from `on` (:take, :acquire, :release, or :all) for the next `times` calls, or every call.
          def fail_with(error, on: :all, times: nil)
            @failures[on] = [error, times]
          end

          def recover
            @failures.clear
          end

          # Answers `value` from `method` instead of the real answer, for answers no real store gives.
          def answer(method, value)
            @answers[method] = value
          end

          # Holds a slot for an operation running elsewhere. Not recorded in `calls`.
          def occupy(key, token: SecureRandom.hex(8), ttl: 60)
            @memory.acquire(key, token: token, limit: 1, ttl: ttl, force: true)
            token
          end

          # The slots held for `key` now. Not recorded in `calls`.
          def held(key)
            probe = SecureRandom.hex(8)
            held = @memory.acquire(key, token: probe, limit: 1, ttl: 1, force: true).last - 1
            @memory.release(key, token: probe)
            held
          end

          def take(key, cost:, limit:, window:, force: false)
            perform(:take, key, cost: cost, limit: limit, window: window, force: force) do
              @memory.take(key, cost: cost, limit: limit, window: window, force: force)
            end
          end

          def acquire(key, token:, limit:, ttl:, force: false)
            perform(:acquire, key, token: token, limit: limit, ttl: ttl, force: force) do
              @memory.acquire(key, token: token, limit: limit, ttl: ttl, force: force)
            end
          end

          def release(key, token:)
            perform(:release, key, token: token) { @memory.release(key, token: token) }
            nil
          end

          private

          def perform(method, key, **arguments)
            @calls << [method, key, arguments]
            fail!(method)
            return @answers[method] if @answers.key?(method)

            yield
          end

          def fail!(method)
            on = @failures.key?(method) ? method : :all
            error, times = @failures[on]
            return unless error

            if times
              times -= 1
              times.zero? ? @failures.delete(on) : @failures[on] = [error, times]
            end
            raise error
          end
        end
      end
    end
  end
end
