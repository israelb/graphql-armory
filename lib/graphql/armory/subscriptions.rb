# frozen_string_literal: true

module GraphQL
  module Armory
    # graphql-ruby subscriptions delivered through hosted pub/sub services (Pusher, Ably, or any transport that keeps
    # the `Transport` contract), with a store that survives processes, viewer-bound channels and every delivery run
    # as the subscriber, through Authorization, Versioning and PersistedQueries.
    #
    # This file holds the namespace and the parts every other piece builds on: errors, values, the topic digest and
    # the Store, Transport and Http contracts with their Null and Substitute.
    module Subscriptions
    end
  end
end

require "graphql/armory/subscriptions/errors"
require "graphql/armory/subscriptions/values/record"
require "graphql/armory/subscriptions/values/capabilities"
require "graphql/armory/subscriptions/values/message"
require "graphql/armory/subscriptions/values/outcome"
require "graphql/armory/subscriptions/topic"
require "graphql/armory/subscriptions/store"
require "graphql/armory/subscriptions/transport"
require "graphql/armory/subscriptions/http"
require "graphql/armory/subscriptions/controls"

require "graphql/armory/subscriptions/core"
require "graphql/armory/subscriptions/audit"
require "graphql/armory/subscriptions/webhook_app"
require "graphql/armory/subscriptions/memory_store"
require "graphql/armory/subscriptions/redis_store"
require "graphql/armory/subscriptions/pusher"
require "graphql/armory/subscriptions/ably"
