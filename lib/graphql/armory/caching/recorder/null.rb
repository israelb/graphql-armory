# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      module Recorder
        # The recorder of a query whose context records nothing: it reports the whole context uncovered, so the gate
        # never stores an answer it could not check.
        class Null
          def read(_key) = nil
          def read_all = nil
          def write(_key) = nil

          def neutral
            yield
          end

          def uncovered(_covered) = [ALL]
          def forbidden_writes(_covered) = []
        end
      end
    end
  end
end
