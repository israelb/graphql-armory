# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      # A Rack app for the provider's webhook endpoint: hands the request to the schema's backend (`Core#webhook`),
      # which verifies it through the transport and ends the subscriptions it reports gone.
      #
      #   mount GraphQL::Armory::Subscriptions::WebhookApp.new(AppSchema), at: "/graphql/webhooks"
      #
      # `new` with no schema, or a schema without this backend, answers 404 to everything.
      class WebhookApp
        NOT_FOUND = [404, { "content-type" => "application/json" }.freeze, ["{}"].freeze].freeze

        def initialize(schema = nil)
          @schema = schema
          freeze
        end

        def call(env)
          backend = @schema.respond_to?(:subscriptions) ? @schema.subscriptions : nil
          return [NOT_FOUND[0], NOT_FOUND[1].dup, NOT_FOUND[2].dup] unless backend.is_a?(Core)

          backend.webhook(env)
        end

        def inspect = "#<#{self.class.name}>"
      end
    end
  end
end
