# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      module Recorder
        # What the queries built from one provided Hash did to it. graphql-ruby keeps the Hash given as `context:`
        # (`Query::Context#initialize`), so queries of one multiplex given the same Hash object see each other's
        # `[]=` and `delete`. Each query's `Log` joins the board of its Hash and reports its siblings' writes and
        # exposures through its own `forbidden_writes` and `uncovered`, so the gate asks each query only about itself.
        #
        # Boards are found by the Hash's identity, never by equality: two equal Hashes are two requests. The registry
        # holds the Hash weakly, and a board lives as long as a Log that joined it.
        class SharedWrites
          REGISTRY = ObjectSpace::WeakMap.new
          LOCK = Mutex.new
          private_constant :REGISTRY, :LOCK

          # The board of `provided`, created on first use.
          def self.for(provided)
            LOCK.synchronize { REGISTRY[provided] ||= new }
          end

          def initialize
            @writes = {}.compare_by_identity # log => { key => written after that log read it }
            @exposers = {}.compare_by_identity
            @lock = Mutex.new
          end

          def write(log, key, after_read)
            @lock.synchronize do
              keys = (@writes[log] ||= {})
              keys[key] = keys.fetch(key, false) || after_read
            end
            nil
          end

          # `log` handed out the Hash itself (`namespace(nil)`, `to_h`): anything may have changed it.
          def expose(log)
            @lock.synchronize { @exposers[log] = true }
            nil
          end

          # `[[key, after_read], ...]` written by every log but `log`.
          def writes_by_others(log)
            @lock.synchronize do
              @writes.reject { |writer, _| writer.equal?(log) }.flat_map { |_, keys| keys.to_a }
            end
          end

          def exposed_by_others?(log)
            @lock.synchronize { @exposers.each_key.any? { |exposer| !exposer.equal?(log) } }
          end
        end
      end
    end
  end
end
