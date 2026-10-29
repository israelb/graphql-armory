# frozen_string_literal: true

require "graphql/armory/authorization/errors"
require "graphql/armory/authorization/rule"
require "graphql/armory/authorization/memo"
require "graphql/armory/authorization/telemetry"
require "graphql/armory/authorization/adapters/null"
require "graphql/armory/authorization/adapters/substitute"
require "graphql/armory/authorization/authorize"
require "graphql/armory/authorization/scope"
require "graphql/armory/authorization/controls/rule"
require "graphql/armory/authorization/controls/context"
require "graphql/armory/authorization/controls/actor"
require "graphql/armory/authorization/controls/subject"

module GraphQL
  module Armory
    module Authorization
      module Adapters
        # Loaded on first use, so Pundit is only needed by whoever picks this adapter.
        autoload :Pundit, "graphql/armory/authorization/adapters/pundit"
      end
    end

    # Deny-by-default authorization. The core (Authorize, Scope) knows nothing about
    # Pundit or CanCanCan: it asks an adapter four questions and trusts only a clear answer.
    module Authorization
    end
  end
end
