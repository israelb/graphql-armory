# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      module Controls
        # A user of the control app.
        User = Struct.new(:id, :name, keyword_init: true)

        # The control app's users: `user-1` (Ada) and `user-2` (Grace). A test revokes a user (still loadable, refused
        # by the policy) or removes one (gone: the viewer no longer loads).
        class Directory
          def self.example
            new([User.new(id: "user-1", name: "Ada"), User.new(id: "user-2", name: "Grace")])
          end

          def initialize(users = [])
            @users = users.to_h { |user| [user.id, user] }
            @revoked = []
          end

          def find(id) = @users[id]

          def add(user)
            @users[user.id] = user
          end

          def remove(id)
            @users.delete(id)
          end

          def revoke(id)
            @revoked << id
          end

          def restore(id)
            @revoked.delete(id)
          end

          def allowed?(user)
            !user.nil? && @users.key?(user.id) && !@revoked.include?(user.id)
          end
        end

        # The `viewer:` option of `use GraphQL::Armory::Subscriptions` for the control app: `dump` answers the current
        # user's id, `load` puts the user (nil when gone) and its id back into the context keys `sets` declares.
        module Viewer
          SETS = %i[current_user current_user_id].freeze

          def self.example(directory = Directory.example)
            {
              dump: ->(context) { context[:current_user]&.id },
              load: lambda do |id, context|
                user = directory.find(id)
                context[:current_user] = user
                context[:current_user_id] = user&.id
              end,
              sets: SETS
            }
          end
        end

        # A Pundit-style Authorization adapter over a Directory: the actor is `context[:current_user]`, and a record
        # is readable while that user exists and is not revoked. Records the questions it was asked.
        class Policy
          attr_reader :asked

          def self.example(directory = Directory.example)
            new(directory)
          end

          def initialize(directory)
            @directory = directory
            @asked = []
          end

          def actor(context)
            context[:current_user]
          end

          def authorized?(actor, subject, rule)
            @asked << [actor&.id, subject.class, rule]
            @directory.allowed?(actor)
          end

          def scope(actor, items, _rule)
            return items if @directory.allowed?(actor)

            items.respond_to?(:none) ? items.none : []
          end

          def check(_type, _rule)
            []
          end
        end
      end
    end
  end
end
