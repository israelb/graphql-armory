# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      class Http
        # The HTTP client of a transport nobody wired: every request raises `TransportError`, so a transport built
        # with `new` never reaches a provider.
        class Null
          def post(_url, _body, _headers = {})
            raise TransportError, "no HTTP client wired: build the transport with `build`"
          end
        end
      end
    end
  end
end
