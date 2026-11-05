# frozen_string_literal: true

require "securerandom"

module GraphQL
  module Armory
    module Caching
      # Answers kept in this process's memory: for tests, development and single-process servers. Each process keeps
      # its own entries and its own purge marks, so a purge reaches only the process it runs in; share a `RedisStore`
      # between processes in production.
      #
      #   store = GraphQL::Armory::Caching::MemoryStore.new(max_bytes: 64 * 1024 * 1024)
      #
      # Keeps the store contract (`Store`). Entries are evicted least recently used first once their bytes (blob, key
      # and tag digests) pass `max_bytes`; the meta record (epoch, seq, purge marks) is never evicted. Purge marks are
      # pruned, up to 100 per purge, once older than `max_ttl` (seconds, the longest TTL it stores). `clock` answers
      # Integer milliseconds; the default is the process's monotonic clock.
      class MemoryStore
        DEFAULT_MAX_BYTES = 32 * 1024 * 1024
        DEFAULT_MAX_TTL = 3600
        PRUNE_PER_PURGE = 100

        def self.monotonic_clock
          -> { Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) }
        end

        Stored = Struct.new(:blob, :tags, :expires_at, :bytes)
        private_constant :Stored

        attr_reader :max_bytes, :max_ttl

        def initialize(max_bytes: DEFAULT_MAX_BYTES, clock: self.class.monotonic_clock, max_ttl: DEFAULT_MAX_TTL)
          raise ConfigurationError, "max_bytes: must be a positive Integer, got #{max_bytes.inspect}" unless max_bytes.is_a?(Integer) && max_bytes.positive?
          raise ConfigurationError, "max_ttl: must be a positive Integer of seconds, got #{max_ttl.inspect}" unless max_ttl.is_a?(Integer) && max_ttl.positive?
          raise ConfigurationError, "clock: must answer call with Integer milliseconds" unless clock.respond_to?(:call)

          @max_bytes = max_bytes
          @max_ttl = max_ttl
          @clock = clock
          # Insertion order is recency: the first entry is the least recently used, the first mark the oldest.
          @entries = {}
          @bytes = 0
          @epoch = SecureRandom.hex(16)
          @seq = 0
          @marks = {}
          @mutex = Mutex.new
        end

        def lookup(key_digest)
          check_digest!(key_digest, "key_digest")

          @mutex.synchronize do
            now = clock
            entry = live(key_digest, now)
            tags = entry ? entry.tags : []
            marks = tags.each_with_object({}) { |tag, found| found[tag] = @marks[tag].first if @marks.key?(tag) }
            Lookup.new(blob: entry&.blob, tags: tags, marks: marks, seq: @seq, epoch: @epoch, now: now)
          end
        end

        def write(key_digest, blob, tags:, ttl:, seq:, epoch:, stored_at:)
          check_write!(key_digest, blob, tags, ttl, seq, epoch, stored_at)

          @mutex.synchronize do
            expires_at = stored_at + (ttl * 1000)
            next false if epoch != @epoch || seq > @seq || tags.any? { |tag| @marks.key?(tag) && @marks[tag].first > seq }
            next false if clock >= expires_at

            bytes = blob.bytesize + key_digest.bytesize + tags.sum(&:bytesize)
            next false if bytes > @max_bytes

            remove(key_digest)
            @entries[key_digest.dup.freeze] = Stored.new(blob.dup.freeze, tags.map { |tag| tag.dup.freeze }.freeze, expires_at, bytes)
            @bytes += bytes
            @bytes -= remove(@entries.each_key.first) while @bytes > @max_bytes
            true
          end
        end

        def purge(tag_digests)
          raise ArgumentError, "tag_digests must be an Array" unless tag_digests.is_a?(Array)

          tag_digests.each { |tag| check_digest!(tag, "tag digest") }
          @mutex.synchronize do
            now = clock
            @seq += 1
            tag_digests.each do |tag|
              @marks.delete(tag)
              @marks[tag.dup.freeze] = [@seq, now]
            end
            prune(now)
            @seq
          end
        end

        def purge_all
          @mutex.synchronize do
            @epoch = SecureRandom.hex(16)
            @marks.clear
            @epoch
          end
        end

        def inspect = "#<#{self.class.name} entries=#{@entries.size} bytes=#{@bytes}/#{@max_bytes}>"
        alias_method :to_s, :inspect

        private

        def clock
          now = @clock.call
          raise ConfigurationError, "clock: must answer Integer milliseconds, got #{now.inspect}" unless now.is_a?(Integer) && now >= 0

          now
        end

        # The entry under `key`, made the most recently used; an expired one is dropped.
        def live(key, now)
          entry = @entries[key] or return
          if now >= entry.expires_at
            remove(key)
            return
          end

          @entries[key] = @entries.delete(key)
        end

        def remove(key)
          entry = @entries.delete(key) or return 0
          @bytes -= entry.bytes
          entry.bytes
        end

        # Marks are kept oldest first, so pruning stops at the first one still young. An entry a mark rejects was
        # stamped no later than that purge and expires within max_ttl of it, so a mark older than max_ttl rejects
        # nothing that could still be answered or written.
        def prune(now)
          PRUNE_PER_PURGE.times do
            tag, (_seq, at) = @marks.first
            break unless tag && now - at > @max_ttl * 1000

            @marks.delete(tag)
          end
        end

        def check_digest!(value, name)
          raise ArgumentError, "#{name} must be 64 hex characters" unless value.is_a?(String) && Key::HEX.match?(value)
        end

        def check_write!(key_digest, blob, tags, ttl, seq, epoch, stored_at)
          check_digest!(key_digest, "key_digest")
          raise ArgumentError, "blob must be a String" unless blob.is_a?(String)
          raise ArgumentError, "tags: must be an Array" unless tags.is_a?(Array)

          tags.each { |tag| check_digest!(tag, "tag digest") }
          raise ArgumentError, "ttl: must be a positive Integer of seconds" unless ttl.is_a?(Integer) && ttl.positive?
          raise ArgumentError, "ttl: #{ttl} is above this store's max_ttl (#{@max_ttl}): purge marks are kept only that long" if ttl > @max_ttl
          raise ArgumentError, "seq: must be a non-negative Integer" unless seq.is_a?(Integer) && seq >= 0
          raise ArgumentError, "epoch: must be a non-empty String" unless epoch.is_a?(String) && !epoch.empty?
          raise ArgumentError, "stored_at: must be Integer milliseconds" unless stored_at.is_a?(Integer) && stored_at >= 0
        end
      end
    end
  end
end
