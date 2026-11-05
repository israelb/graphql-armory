# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      module Controls
        # A record of `user-1` subscribed to `messagePosted(roomId: 5)` through the persisted operation
        # "message-posted", on the interpreter, created at 1_000_000 ms for one hour. Any field can be overridden.
        module Record
          def self.example(**overrides)
            fields = {
              id: Id.example,
              document: "subscription MessagePosted($roomId: ID!) { messagePosted(roomId: $roomId) { id body } }",
              operation_name: "MessagePosted",
              variables: '{"roomId":"5"}',
              operation_id: "message-posted",
              raw_query: false,
              version: "2025-01-01",
              visibility_profile: nil,
              engine: :interpreter,
              viewer_id: "user-1",
              viewer_digest: Digest.example("viewer"),
              context: { "tenant_id" => '"acme"' },
              events: [{ graphql_topic: ":messagePosted:roomId:5", digest: Digest.example("topic") }],
              created_at: 1_000_000,
              expires_at: 1_000_000 + (3_600 * 1000)
            }
            Subscriptions::Record.new(**fields, **overrides)
          end
        end
      end
    end
  end
end
