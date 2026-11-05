# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      module Controls
        # Principals of two classes with the same id: `User 7` and `AdminUser 7` must never share an entry.
        module Viewer
          User = Struct.new(:id)
          AdminUser = Struct.new(:id)

          def self.example(id: 7, admin: false)
            (admin ? AdminUser : User).new(id)
          end
        end

        # A request's context: the persisted operation to run, the viewer (`current_user`) and a locale.
        module Context
          def self.example(operation: "catalog", viewer: Viewer.example, locale: "en", **extra)
            { operation_id: operation, current_user: viewer, locale: locale }.merge(extra).compact
          end

          def self.anonymous(operation: "catalog", locale: "en", **extra)
            example(operation: operation, viewer: nil, locale: locale, **extra)
          end
        end
      end
    end
  end
end
