# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      # Test data for subscriptions, reusable by apps and other gems: ids, digests, records, capabilities, the stand-in
      # dependencies, a viewer directory with its Pundit-style policy, and a control schema.
      module Controls
      end
    end
  end
end

require "graphql/armory/subscriptions/controls/id"
require "graphql/armory/subscriptions/controls/record"
require "graphql/armory/subscriptions/controls/dependencies"
require "graphql/armory/subscriptions/controls/viewer"
require "graphql/armory/subscriptions/controls/event_log"
require "graphql/armory/subscriptions/controls/schema"
