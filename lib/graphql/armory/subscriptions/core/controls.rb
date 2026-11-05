# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      module Controls
        # An Encoder subclass with a fixed key, for tests only: everyone who reads this file knows its key.
        module AppEncoder
          KEY = "subscriptions-control-key-not-a-secret"

          def self.example(key = KEY)
            Class.new(Armory::Encoder) { key(key) }
          end
        end

        # The options of `use GraphQL::Armory::Subscriptions` for the control schema (`Schema.example(subscriptions:)`):
        # a `Store::Substitute`, a viewer-bound `Transport::Substitute`, the control encoder, the control app's viewer
        # over `directory`, `tenant_id` stored (the scope of `messagePosted`), one hour of lifetime. Any option can be
        # overridden or added.
        module Options
          def self.example(directory: Directory.example, store: Store.example, transport: Transport.example, encoder: AppEncoder.example, **overrides)
            { store: store, transport: transport, encoder: encoder, viewer: Viewer.example(directory),
              context_keys: { tenant_id: "scopes every message to the subscriber's tenant" }, max_lifetime: 3_600, **overrides }
          end
        end
      end
    end
  end
end
