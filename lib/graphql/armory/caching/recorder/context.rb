# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      module Recorder
        # The context class `use` wraps around the schema's own: it records every read and write from construction on
        # (docs/response-caching.md 4.4). Owned by unit U4; this stub only reserves the constant.
        module Context
        end
      end
    end
  end
end
