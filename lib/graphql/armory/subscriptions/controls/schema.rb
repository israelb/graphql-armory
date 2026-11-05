# frozen_string_literal: true

require "date"

module GraphQL
  module Armory
    module Subscriptions
      module Controls
        # A schema with the armory plugins a subscription goes through on every delivery, built fresh on every call:
        # Versioning (`Versioning::Controls::Versions`, default :latest), Authorization (`Policy` over a `Directory`,
        # `on_unauthorized:` :null by default), PersistedQueries (strict over `DOCUMENTS`) and RateLimits::Points
        # (charging `context[:rate_limit_key]`, never soft). The subscriptions plugin is installed only when
        # `subscriptions:` options are given, through `plugin` (`GraphQL::Armory::Subscriptions` by default):
        #
        #   schema = Controls::Schema.example(subscriptions: { store:, transport:, encoder:, viewer: Controls::Viewer.example(directory), ... })
        #   schema.armory_controls  # => { directory:, adapter:, rate_store:, manifest:, types: }
        #
        # `subscriptions: {}, plugin: Controls::EventLog` installs a bare graphql-ruby backend that only keeps the
        # events written, for running subscription operations without our own backend.
        #
        # The Subscription root:
        #
        #   messagePosted(roomId: ID!, priority: Priority, on: Date, filter: MessageFilter = { priority: LOW }): Message
        #     nullable, subscription_scope :tenant_id (a context key the app stores)
        #   roomUpdated(roomId: ID!, thread: ID): Room!
        #     non-null, no scope
        #   inboxChanged: Inbox
        #     nullable, subscription_scope :current_user_id (set by Viewer's load)
        #
        # Message, Room and Inbox are read through the policy (a revoked user gets a null `messagePosted`, and no data
        # at all for the non-null `roomUpdated`); `Message.edited` exists from 2025-01-01 on. The fields have no
        # resolvers: on a delivery graphql-ruby's subscription extension answers the triggered object, and without the
        # plugin the root value's method of the same name answers. `Query.ping` answers "pong". The block, when given,
        # runs in the Query type with the types (`Types.example`) and the field options Execution::Next needs.
        module Schema
          Message = Struct.new(:id, :body, :room_id, :edited, keyword_init: true) do
            def initialize(id:, body:, room_id:, edited: false)
              super
            end
          end
          Room = Struct.new(:id, :name, keyword_init: true)
          Inbox = Struct.new(:unread, keyword_init: true)

          DOCUMENTS = {
            "ping" => "query Ping { ping }",
            "message-posted" => "subscription MessagePosted($roomId: ID!) { messagePosted(roomId: $roomId) { id body } }",
            "room-updated" => "subscription RoomUpdated($roomId: ID!) { roomUpdated(roomId: $roomId) { id name } }",
            "inbox-changed" => "subscription InboxChanged { inboxChanged { unread } }"
          }.freeze

          NEXT_FIELD_OPTIONS =
            if GraphQL::Schema::Field.instance_method(:initialize).parameters.any? { |_, name| name == :resolve_legacy_instance_method }
              { resolve_legacy_instance_method: true }.freeze
            else
              {}.freeze
            end

          def self.example(subscriptions: nil, plugin: nil, directory: Directory.example, adapter: nil, on_unauthorized: :null, strict: true,
                           documents: DOCUMENTS, rate_store: nil, rate_limit: 1_000, types: Types.example, &fields)
            adapter ||= Policy.new(directory)
            rate_store ||= RateLimits::Store::Substitute.new
            manifest = PersistedQueries::Manifest.new(documents, digest: false)
            plugin ||= Armory::Subscriptions unless subscriptions.nil?
            query = Class.new(types.fetch(:object)) do
              graphql_name "Query"
              authorize :none, reason: "the control app's public root", covers_fields: true
              field :ping, String, null: false, **NEXT_FIELD_OPTIONS
              define_method(:ping) { "pong" }
              instance_exec(types, NEXT_FIELD_OPTIONS, &fields) if fields
            end
            subscription = Class.new(types.fetch(:object)) do
              graphql_name "Subscription"
              authorize :none, reason: "each payload type is read through the policy", covers_fields: true
              field :message_posted, types.fetch(:message), null: true, subscription_scope: :tenant_id do
                argument :room_id, GraphQL::Types::ID
                argument :priority, types.fetch(:priority), required: false
                argument :on, types.fetch(:date), required: false
                argument :filter, types.fetch(:filter), required: false, default_value: { "priority" => "LOW" }
              end
              field :room_updated, types.fetch(:room), null: false do
                argument :room_id, GraphQL::Types::ID
                argument :thread, GraphQL::Types::ID, required: false
              end
              field :inbox_changed, types.fetch(:inbox), null: true, subscription_scope: :current_user_id
            end
            controls = { directory: directory, adapter: adapter, rate_store: rate_store, manifest: manifest, types: types }.freeze
            armory = Armory

            Class.new(GraphQL::Schema) do
              use GraphQL::Execution::Next if defined?(GraphQL::Execution::Next)
              query(query)
              subscription(subscription)
              use armory::Versioning, versions: armory::Versioning::Controls::Versions::LABELS,
                                      retired: armory::Versioning::Controls::Versions::RETIRED, default: :latest
              use armory::Authorization, adapter: adapter, on_unauthorized: on_unauthorized
              use armory::PersistedQueries, store: manifest, strict: strict
              use armory::RateLimits::Points, store: rate_store, limit: rate_limit, soft: false
              use plugin, **subscriptions unless subscriptions.nil?
              define_singleton_method(:armory_controls) { controls }
            end
          end

          # The types of the control schema, built fresh: base classes with Versioning's and Authorization's `Base`,
          # a `Date` scalar (ISO 8601 in and out), the `Priority` enum (LOW and HIGH, Ruby values :low and :high), the
          # `Window` and `MessageFilter` input objects and the Message, Room and Inbox payload types.
          module Types
            def self.example
              versioning = Versioning::Base
              auth = Authorization::Base
              base_argument = Class.new(GraphQL::Schema::Argument) do
                include versioning
                include auth
              end
              base_field = Class.new(GraphQL::Schema::Field) do
                include versioning
                include auth
                argument_class(base_argument)
              end
              base_object = Class.new(GraphQL::Schema::Object) do
                include versioning
                include auth
                field_class(base_field)
                default_action :read
              end

              date = Class.new(GraphQL::Schema::Scalar) do
                graphql_name "Date"
                description "An ISO 8601 calendar date"

                def self.coerce_input(value, _context)
                  raise GraphQL::CoercionError, "Date must be an ISO 8601 String" unless value.is_a?(String)

                  ::Date.iso8601(value)
                rescue ::Date::Error
                  raise GraphQL::CoercionError, "Date must be an ISO 8601 date"
                end

                def self.coerce_result(value, _context)
                  raise GraphQL::Error, "Date answers a Date" unless value.is_a?(::Date)

                  value.iso8601
                end
              end
              priority = Class.new(GraphQL::Schema::Enum) do
                graphql_name "Priority"
                value "LOW", value: :low
                value "HIGH", value: :high
              end
              window = Class.new(GraphQL::Schema::InputObject) do
                graphql_name "Window"
                argument :from, date
                argument :to, date, required: false
              end
              filter = Class.new(GraphQL::Schema::InputObject) do
                graphql_name "MessageFilter"
                argument :priority, priority, required: false, default_value: "LOW"
                argument :priorities, [priority], required: false
                argument :window, window, required: false
                argument :min_score, Float, required: false
              end

              message = Class.new(base_object) do
                graphql_name "Message"
                field :id, GraphQL::Types::ID, null: false
                field :body, String, null: false
                field :room_id, GraphQL::Types::ID, null: false
                field :edited, GraphQL::Types::Boolean, null: false, added: "2025-01-01"
              end
              room = Class.new(base_object) do
                graphql_name "Room"
                field :id, GraphQL::Types::ID, null: false
                field :name, String, null: false
              end
              inbox = Class.new(base_object) do
                graphql_name "Inbox"
                field :unread, Integer, null: false
              end

              { argument: base_argument, field: base_field, object: base_object, date: date, priority: priority, window: window, filter: filter,
                message: message, room: room, inbox: inbox }
            end
          end
        end
      end
    end
  end
end
