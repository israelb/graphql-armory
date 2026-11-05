# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      module Recorder
        # The context class `use` wraps around the schema's own: it records every read and write from construction on
        # (docs/response-caching.md 4.4). Owned by unit U4.
        #
        # Contract: `Recorder::Context.wrap(klass) -> Class` answers a subclass of `klass` that records, the same class
        # for the same `klass` every time, and `klass` itself when it is already a wrapper.
        # This stub wraps without recording (its queries get no recorder, so `Recorder::Null` applies: nothing stored).
        module Context
          WRAPPERS = {}.compare_by_identity
          LOCK = Mutex.new

          def self.wrap(klass)
            return klass if klass.include?(Wrapped)

            LOCK.synchronize do
              WRAPPERS[klass] ||= Class.new(klass) { include Wrapped }
            end
          end

          # Marks a wrapper class.
          module Wrapped
          end
        end
      end
    end
  end
end
