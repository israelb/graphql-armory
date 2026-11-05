# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      class Core < GraphQL::Subscriptions
        # What the core reads the time from: a callable answering Integer milliseconds since the epoch. Every store call
        # gets its `now:` from here, so every store agrees on what is live.
        module Clock
          SYSTEM = -> { Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) }

          def self.system
            SYSTEM
          end

          # A clock the test sets and moves, in milliseconds: for tests, instead of hand-written fakes.
          class Substitute
            attr_accessor :now

            def initialize(now: 1_000_000)
              raise ArgumentError, "now: must be Integer milliseconds" unless now.is_a?(Integer)

              @now = now
            end

            def call
              @now
            end

            def advance(milliseconds)
              raise ArgumentError, "advance takes Integer milliseconds" unless milliseconds.is_a?(Integer)

              @now += milliseconds
            end
          end
        end
      end
    end
  end
end
