# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      module Store
        # An in-memory store that keeps the store contract (`Store`), records its calls, fails when told, answers what
        # it is told and lets a test write a raw record as someone with store access could: for tests, instead of
        # hand-written fakes. `now` is a test clock (Integer milliseconds) for the test's own use and for `poison`'s
        # default expiry; the store itself only uses the `now:` each call is given.
        #
        #   store = Store::Substitute.new
        #   store.fail_with(Redis::TimeoutError.new, on: :ids)
        #   store.answer(:write, :viewer_cap)
        #   store.poison(id, "forged", topics: [digest])
        #   store.calls                     # => [[:write, id, { topics:, viewer:, ... }], [:read, id, {}], ...]
        class Substitute
          OPERATIONS = %i[write read ids delete count cleanup].freeze

          attr_accessor :now
          attr_reader :calls

          def initialize(now: 1_000_000)
            raise ArgumentError, "now: must be Integer milliseconds" unless now.is_a?(Integer)

            @now = now
            @records = {}
            @calls = []
            @failures = {}
            @answers = {}
          end

          # Raises `error` from `on` (an operation, or :all) for the next `times` calls, or every call until `recover`.
          def fail_with(error, on: :all, times: nil)
            raise ArgumentError, "on: must be one of #{(OPERATIONS + [:all]).inspect}, got #{on.inspect}" unless (OPERATIONS + [:all]).include?(on)
            raise ArgumentError, "times: must be nil (every call) or a positive Integer, got #{times.inspect}" unless times.nil? || (times.is_a?(Integer) && times.positive?)

            @failures[on] = [error, times]
          end

          def recover
            @failures.clear
          end

          # Answers `value` from `operation` instead of the real answer (and does nothing else), for answers no real
          # store gives at that moment.
          def answer(operation, value)
            raise ArgumentError, "operation must be one of #{OPERATIONS.inspect}" unless OPERATIONS.include?(operation)

            @answers[operation] = value
          end

          # Writes `sealed` under `id` as someone with write access to the store could: no cap, no check, replacing
          # what was there. Not recorded.
          def poison(id, sealed, topics: [], viewer: Record::ANONYMOUS, expires_at: @now + 60_000)
            @records[id] = { sealed: sealed, topics: topics.dup, viewer: viewer, expires_at: expires_at }
          end

          # Every stored sealed record by id, expired ones included, for assertions. Not recorded.
          def records
            @records.transform_values { |record| record[:sealed] }
          end

          def write(id, sealed, topics:, viewer:, expires_at:, viewer_cap:, topic_cap:, now:)
            check_write(id, sealed, topics, viewer, expires_at, viewer_cap, topic_cap, now)
            perform(:write, id, topics: topics, viewer: viewer, expires_at: expires_at, viewer_cap: viewer_cap, topic_cap: topic_cap, now: now) do
              live = @records.values.select { |record| record[:expires_at] > now }
              if @records.key?(id)
                :exists
              elsif viewer_cap && live.count { |record| record[:viewer] == viewer } >= viewer_cap
                :viewer_cap
              elsif topic_cap && topics.any? { |topic| live.count { |record| record[:topics].include?(topic) } >= topic_cap }
                :topic_cap
              else
                @records[id] = { sealed: sealed, topics: topics.uniq, viewer: viewer, expires_at: expires_at }
                :ok
              end
            end
          end

          def read(id)
            perform(:read, id) { @records[id]&.fetch(:sealed) }
          end

          def ids(topic, now:)
            check_now(now)
            perform(:ids, topic, now: now) do
              @records.select { |_id, record| record[:topics].include?(topic) && record[:expires_at] > now }.keys
            end
          end

          def delete(id)
            perform(:delete, id) { !@records.delete(id).nil? }
          end

          def count(viewer, now:)
            check_now(now)
            perform(:count, viewer, now: now) do
              @records.count { |_id, record| record[:viewer] == viewer && record[:expires_at] > now }
            end
          end

          def cleanup(now:)
            check_now(now)
            perform(:cleanup, nil, now: now) do
              expired = @records.select { |_id, record| record[:expires_at] <= now }.keys
              expired.each { |id| @records.delete(id) }
              expired.size
            end
          end

          private

          # A caller's bug, never a store answer: the core must hand every store the same shapes.
          def check_write(id, sealed, topics, viewer, expires_at, viewer_cap, topic_cap, now)
            check_now(now)
            raise ArgumentError, "id must be a non-empty String" unless id.is_a?(String) && !id.empty?
            raise ArgumentError, "sealed must be a String" unless sealed.is_a?(String)
            raise ArgumentError, "topics: must be a non-empty Array of Strings" unless topics.is_a?(Array) && !topics.empty? && topics.all?(String)
            raise ArgumentError, "viewer: must be a non-empty String" unless viewer.is_a?(String) && !viewer.empty?
            raise ArgumentError, "expires_at: must be Integer milliseconds after now:" unless expires_at.is_a?(Integer) && expires_at > now

            [viewer_cap, topic_cap].each do |cap|
              raise ArgumentError, "a cap must be nil or a positive Integer, got #{cap.inspect}" unless cap.nil? || (cap.is_a?(Integer) && cap.positive?)
            end
          end

          def check_now(now)
            raise ArgumentError, "now: must be Integer milliseconds" unless now.is_a?(Integer)
          end

          def perform(operation, subject, **arguments)
            @calls << [operation, subject, arguments]
            fail!(operation)
            return @answers[operation] if @answers.key?(operation)

            yield
          end

          def fail!(operation)
            on = @failures.key?(operation) ? operation : :all
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
