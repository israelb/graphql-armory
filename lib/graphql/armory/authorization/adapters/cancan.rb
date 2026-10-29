# frozen_string_literal: true

require "cancancan"

module GraphQL
  module Armory
    module Authorization
      module Adapters
        # Answers the core's four questions with CanCanCan's public API.
        #
        # The actor is an Ability: `context[:current_ability]`, else `Ability.new(context[:current_user])`
        # (or the class given as `ability_class:`). It is built once per query.
        #
        # A field's attribute is passed to `can?`: with `can :read, User, [:username]`, `can?(:read, user)`
        # is true even though only one attribute is readable, so the field must be asked about.
        class CanCan
          def initialize(ability_class: nil)
            @ability_class = ability_class
          end

          def actor(context)
            context[:current_ability] || ability_for(context)
          end

          def authorized?(ability, subject, rule)
            return ability.can?(rule.action, subject, rule.attribute) if rule.attribute

            ability.can?(rule.action, subject)
          end

          # A relation is narrowed in SQL with `accessible_by`, so it stays paginable. A rule defined only
          # with a block cannot be turned into SQL: it fails, unless the type declared `scope: :in_memory`,
          # which filters with `can?` and gives up efficient pagination.
          def scope(ability, items, rule)
            return in_memory(ability, items, rule) if items.is_a?(Array) || rule.scope == :in_memory

            items.accessible_by(ability, rule.action)
          rescue ::CanCan::Error => error
            raise MissingScopeError,
                  "#{error.message} Add an SQL or scope argument to the rule, or declare `scope: :in_memory` on the type"
          end

          # Abilities depend on the user, so nothing can be said without one.
          def check(_type, _rule)
            []
          end

          private

          def in_memory(ability, items, rule)
            items.select { |item| authorized?(ability, item, rule) == true }
          end

          def ability_for(context)
            store = context.namespace(:armory)
            store[:cancan_ability] ||= ability_class.new(context[:current_user])
          end

          def ability_class
            @ability_class || (Object.const_get(:Ability) if Object.const_defined?(:Ability)) ||
              raise(ConfigurationError, "no Ability class found: define ::Ability, pass `ability_class:` " \
                                        "to the adapter or put an ability in context[:current_ability]")
          end
        end
      end
    end
  end
end
