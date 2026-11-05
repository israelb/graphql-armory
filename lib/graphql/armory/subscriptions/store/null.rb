# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      module Store
        # The store of subscriptions nobody wired: it refuses every write and holds nothing, so `Subscriptions.new`
        # never keeps a subscription. `build` refuses it: a backend that loses every subscription.
        class Null
          def write(_id, _sealed, topics:, viewer:, expires_at:, viewer_cap:, topic_cap:, now:)
            :refused
          end

          def read(_id) = nil
          def ids(_topic, now:) = []
          def delete(_id) = false
          def count(_viewer, now:) = 0
          def cleanup(now:) = 0
        end
      end
    end
  end
end
