# frozen_string_literal: true

require "graphql/armory/caching/recorder/shared_writes"

module GraphQL
  module Armory
    module Caching
      module Recorder
        # The real recorder of one query (the interface is in `recorder.rb`). `Recorder::Context` feeds it; the gate asks
        # it `uncovered(covered)` and `forbidden_writes(covered)` after the run.
        #
        # - A read is an **input** unless this query wrote that key into the provided values earlier (`write`). A read
        #   answered by this query's own `scoped_set!` never reaches the Log as a read: the context checks that the
        #   value came from the scoped context (see `Context`), since a scoped value covers only its own subtree.
        # - A write (`write` for the provided values, `write_scoped` for the scoped context) is **forbidden** when its
        #   key is covered, or when this query read that key as an input before writing it.
        # - Once shared (`share(hash)`), writes to the provided values and exposures of the Hash are published to the
        #   Hash's `SharedWrites` board. A sibling's write is forbidden for this query when its key is covered here,
        #   when this query read that key through the provided values, or when the sibling had read it before writing.
        #   A sibling that exposed the Hash (`read_all`) makes this query report `:all`.
        # - `neutral { }` answers the block's value and stops recording reads (and `read_all`) for the block, in the
        #   current Fiber only: a read made by another Fiber meanwhile (dataloader sources) is still recorded. A write
        #   inside it (a limiter's record, `context[:rate_limit_points]`) does not make the key "written by this query":
        #   a later read of it outside the block is an input, since the value depends on what the neutral reader read.
        #   It is still checked as a forbidden write (covered, or read before) and still published to siblings: a
        #   neutral reader that overwrites a covered key changes what every later read sees.
        #
        # `new` is useful at once: it records, with nothing shared. Thread-safe.
        class Log
          def initialize
            @inputs = {}       # key => true, in the order first read
            @read = {}         # every key read through the provided values, input or not
            @written = {}      # keys this query wrote into the provided values
            @scoped = {}       # keys this query wrote into its scoped context
            @writes = {}       # key => true when written after an input read of it
            @all = false
            @neutral = {}.compare_by_identity # Fiber => depth
            @board = nil
            @lock = Mutex.new
          end

          # Joins the board of the provided Hash `provided`, publishing what was written or exposed before.
          def share(provided)
            board = SharedWrites.for(provided)
            writes, all = @lock.synchronize do
              return self if @board.equal?(board)

              @board = board
              [@writes.select { |key, _| @written.key?(key) }, @all]
            end
            writes.each { |key, after_read| board.write(self, key, after_read) }
            board.expose(self) if all
            self
          end

          def read(key)
            @lock.synchronize do
              next if @neutral.key?(Fiber.current)

              @read[key] = true
              @inputs[key] = true unless @written.key?(key)
            end
            nil
          end

          def read_all
            board = @lock.synchronize do
              next if @neutral.key?(Fiber.current)

              @all = true
              @board
            end
            board&.expose(self)
            nil
          end

          # A write into the provided values (`[]=`, `delete` of a provided key).
          def write(key)
            after_read, board = @lock.synchronize do
              @written[key] = true unless @neutral.key?(Fiber.current)
              [note_write(key), @board]
            end
            board&.write(self, key, after_read)
            nil
          end

          # A write into this query's scoped context (`scoped_merge!`, `scoped_set!`, `context.scoped`): siblings never
          # see it, and a later read sees it only inside the subtree it was set for.
          def write_scoped(key)
            @lock.synchronize do
              @scoped[key] = true unless @neutral.key?(Fiber.current)
              note_write(key)
            end
            nil
          end

          def scoped_written?(key)
            @lock.synchronize { @scoped.key?(key) }
          end

          def neutral
            fiber = Fiber.current
            @lock.synchronize { @neutral[fiber] = @neutral.fetch(fiber, 0) + 1 }
            begin
              yield
            ensure
              @lock.synchronize do
                depth = @neutral.fetch(fiber) - 1
                depth.zero? ? @neutral.delete(fiber) : @neutral[fiber] = depth
              end
            end
          end

          def uncovered(covered)
            keys, all, board = @lock.synchronize { [@inputs.keys, @all, @board] }
            keys = keys.reject { |key| covered.include?(key) }
            all || board&.exposed_by_others?(self) ? [ALL, *keys] : keys
          end

          def forbidden_writes(covered)
            own, read, board = @lock.synchronize { [@writes.dup, @read.dup, @board] }
            forbidden = own.select { |key, after_read| after_read || covered.include?(key) }.keys
            (board&.writes_by_others(self) || []).each do |key, after_read|
              forbidden << key if after_read || covered.include?(key) || read.key?(key)
            end
            forbidden.uniq
          end

          def inspect = "#<#{self.class.name}>"

          private

          # Called under the lock. Answers whether this write follows an input read of its key.
          def note_write(key)
            after_read = @inputs.key?(key)
            @writes[key] = @writes.fetch(key, false) || after_read
          end
        end
      end
    end
  end
end
