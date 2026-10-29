# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      module Adapters
        # An adapter with canned answers that keeps the questions it was asked, for tests.
        class Substitute
          attr_reader :asked, :scoped_for

          def initialize(allow: true, actor: nil, scoped: :itself.to_proc, raises: nil, raises_on_scope: nil)
            @allow = allow
            @actor = actor
            @scoped = scoped
            @raises = raises
            @raises_on_scope = raises_on_scope
            @asked = []
            @scoped_for = []
          end

          def actor(_context)
            @actor
          end

          def authorized?(actor, subject, rule)
            raise @raises if @raises

            @asked << [actor, subject, rule]
            @allow
          end

          def scope(actor, items, rule)
            raise @raises_on_scope if @raises_on_scope

            @scoped_for << [actor, items, rule]
            @scoped.call(items)
          end

          def check(_type, _rule)
            []
          end
        end
      end
    end
  end
end
