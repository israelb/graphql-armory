# frozen_string_literal: true

require "digest"
require "base64"

module GraphQL
  module Armory
    module Subscriptions
      module Controls
        # A subscription id in the shape `build_id` makes (32 bytes, urlsafe base64 without padding), fixed per index.
        module Id
          def self.example(index = 0)
            Base64.urlsafe_encode64(::Digest::SHA256.digest("subscription-id-#{index}"), padding: false)
          end
        end

        # A digest in the shape the core stores (64 lowercase hex characters), fixed per text.
        module Digest
          def self.example(text = "topic")
            ::Digest::SHA256.hexdigest("subscription-digest-#{text}")
          end
        end
      end
    end
  end
end
