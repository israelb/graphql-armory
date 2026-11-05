# frozen_string_literal: true

require "securerandom"

module GraphQL
  module Armory
    module Caching
      module Store
        # An in-memory store on a clock the test moves (`now`, Integer milliseconds) that keeps the store contract
        # (`Store`), records its calls, fails when told, answers what it is told and can lose its meta record: for
        # tests, instead of hand-written fakes.
        #
        #   store = Store::Substitute.new
        #   store.fail_with(Redis::TimeoutError.new, on: :write)
        #   store.answer(:lookup, some_lookup)
        #   store.reset!                       # the meta record is gone: every older entry fails the epoch check
        #   store.calls                        # => [[:lookup, key_digest, {}], [:write, key_digest, {tags:, ...}], ...]
        class Substitute
          OPERATIONS = %i[lookup write purge purge_all].freeze

          attr_accessor :now
          attr_reader :calls

          def initialize(now: 1_000_000)
            raise ArgumentError, "now: must be Integer milliseconds" unless now.is_a?(Integer)

            @now = now
            @entries = {}
            @meta = nil
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

          # Answers `value` from `operation` instead of the real answer, for answers no real store gives.
          def answer(operation, value)
            raise ArgumentError, "operation must be one of #{OPERATIONS.inspect}" unless OPERATIONS.include?(operation)

            @answers[operation] = value
          end

          # Loses the meta record (eviction, a flush, a failover to a replica without it). Entries stay. Not recorded.
          def reset!
            @meta = nil
          end

          # Moves the store's seq back, as a failover to a replica that lost recent increments would. Not recorded.
          def rewind_seq(to)
            meta[:seq] = to
          end

          # The current meta record, for assertions. Not recorded.
          def epoch = meta[:epoch]
          def seq = meta[:seq]

          # Every stored blob by key digest, for assertions such as "nothing in the store names the viewer". Not recorded.
          def blobs
            @entries.transform_values { |entry| entry[:blob] }
          end

          # Overwrites what is stored under `key_digest` as someone with write access to the store could. Not recorded.
          def poison(key_digest, blob, tags: [], expires_at: @now + 60_000)
            @entries[key_digest] = { blob: blob, tags: tags, expires_at: expires_at }
          end

          def lookup(key_digest)
            perform(:lookup, key_digest) do
              entry = @entries[key_digest]
              entry = nil if entry && @now >= entry[:expires_at]
              tags = entry ? entry[:tags] : []
              Lookup.new(blob: entry&.fetch(:blob), tags: tags, marks: meta[:marks].slice(*tags), seq: meta[:seq], epoch: meta[:epoch], now: @now)
            end
          end

          def write(key_digest, blob, tags:, ttl:, seq:, epoch:, stored_at:)
            perform(:write, key_digest, tags: tags, ttl: ttl, seq: seq, epoch: epoch, stored_at: stored_at) do
              expires_at = stored_at + (ttl * 1000)
              if epoch != meta[:epoch] || seq > meta[:seq] || tags.any? { |tag| meta[:marks].fetch(tag, -1) > seq } || @now >= expires_at
                false
              else
                @entries[key_digest] = { blob: blob, tags: tags.dup, expires_at: expires_at }
                true
              end
            end
          end

          def purge(tag_digests)
            perform(:purge, nil, tags: tag_digests) do
              meta[:seq] += 1
              tag_digests.each { |tag| meta[:marks][tag] = meta[:seq] }
              meta[:seq]
            end
          end

          def purge_all
            perform(:purge_all, nil) do
              meta[:epoch] = SecureRandom.hex(16)
              meta[:marks].clear
              meta[:epoch]
            end
          end

          private

          def meta
            @meta ||= { epoch: SecureRandom.hex(16), seq: 0, marks: {} }
          end

          def perform(operation, key_digest, **arguments)
            @calls << [operation, key_digest, arguments]
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
