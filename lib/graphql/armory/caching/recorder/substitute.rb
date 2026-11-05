# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      module Recorder
        # A recorder that keeps what it saw, in order, for specs: `reads`, `writes`, `all_read?`, and `neutral_depth`
        # while inside `neutral`. It answers `uncovered` and `forbidden_writes` with the same rules as the real one.
        class Substitute
          attr_reader :reads, :writes, :neutral_depth

          def initialize
            @reads = []
            @writes = []
            @all_read = false
            @neutral_depth = 0
          end

          def read(key)
            @reads << key unless neutral?
            nil
          end

          def read_all
            @all_read = true unless neutral?
            nil
          end

          def write(key)
            @writes << [key, @reads.size] unless neutral?
            nil
          end

          def neutral
            @neutral_depth += 1
            yield
          ensure
            @neutral_depth -= 1
          end

          def neutral?
            @neutral_depth.positive?
          end

          def all_read?
            @all_read
          end

          def read?(key)
            @reads.include?(key)
          end

          def uncovered(covered)
            keys = @reads.each_with_index.reject { |key, index| covered.include?(key) || written_before?(key, index) }.map(&:first).uniq
            @all_read ? [ALL, *keys] : keys
          end

          def forbidden_writes(covered)
            @writes.select { |key, reads_before| covered.include?(key) || @reads.first(reads_before).include?(key) }.map(&:first).uniq
          end

          private

          def written_before?(key, read_index)
            @writes.any? { |written, reads_before| written == key && reads_before <= read_index }
          end

          public

          # A context class that records through a `Substitute`, for specs of the modules that read the context
          # neutrally (Versioning, Telemetry, the limiters):
          #
          #   schema.context_class(GraphQL::Armory::Caching::Recorder::Substitute::Context)
          #   recorder = GraphQL::Armory::Caching::RecordKeys.recorder(query.context)
          #
          # It records `[]`, `fetch`, `dig` and `key?` reads and `[]=` and `delete` writes; the real `Recorder::Context`
          # covers every read and write path.
          class Context < GraphQL::Query::Context
            def initialize(...)
              @armory_recorder = Substitute.new
              super(...)
              RecordKeys.recorder!(self, @armory_recorder)
            end

            def [](key)
              @armory_recorder.read(key)
              super
            end

            def fetch(key, *rest, &block)
              @armory_recorder.read(key)
              super
            end

            def dig(key, *rest)
              @armory_recorder.read(key)
              super
            end

            def key?(key)
              @armory_recorder.read(key)
              super
            end

            def []=(key, value)
              @armory_recorder.write(key)
              super
            end

            def delete(key)
              @armory_recorder.write(key)
              super
            end
          end
        end
      end
    end
  end
end
