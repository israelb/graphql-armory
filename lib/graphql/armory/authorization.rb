# frozen_string_literal: true

require "graphql/armory/authorization/errors"
require "graphql/armory/authorization/configuration"
require "graphql/armory/authorization/rule"
require "graphql/armory/authorization/memo"
require "graphql/armory/authorization/adapters/null"
require "graphql/armory/authorization/adapters/substitute"
require "graphql/armory/authorization/authorize"
require "graphql/armory/authorization/scope"
require "graphql/armory/authorization/audit"
require "graphql/armory/authorization/controls/rule"
require "graphql/armory/authorization/controls/context"
require "graphql/armory/authorization/controls/actor"
require "graphql/armory/authorization/controls/subject"
require "graphql/armory/authorization/integration"

module GraphQL
  module Armory
    module Authorization
      module Adapters
        # Loaded on first use, so only the library behind the adapter you pick is required.
        autoload :Pundit, "graphql/armory/authorization/adapters/pundit"
        autoload :CanCan, "graphql/armory/authorization/adapters/cancan"
      end
    end

    module Authorization
      # Authorization's telemetry is the gem's: one Telemetry for every module.
      Telemetry = Armory::Telemetry
    end

    # Deny-by-default authorization. The core (Authorize, Scope) knows nothing about
    # Pundit or CanCanCan: it asks an adapter four questions and trusts only a clear answer.
    module Authorization
      # The schema plugin: `use GraphQL::Armory::Authorization, adapter: :pundit`.
      # Options: `adapter:` (:pundit or an adapter object), `on_unauthorized:` (:null, :error or :raise),
      # `sinks:` (callables that receive each telemetry signal), `own_checks:` (an app's own `authorized?`, `authorizes?`, `authorized_new`, `wrap`,
      # `unauthorized_object` or `visible?` on a class, with the reason, for the audit), `own_denial_hooks:` (the schema's own
      # `unauthorized_field` or `unauthorized_object`, each with the reason, for the audit).
      def self.use(schema_defn, **options)
        schema_defn.extend(Integration::Schema)
        schema_defn.armory_configuration = Configuration.new(**options)
      end
    end
  end
end
