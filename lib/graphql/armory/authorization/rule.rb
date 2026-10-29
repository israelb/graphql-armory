# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      # Immutable value holding what was declared, e.g. `authorize :read`.
      # Each adapter reads the parts it needs (policy, subject, attribute, model, scope).
      class Rule
        attr_reader :action, :policy, :subject, :attribute, :model, :scope, :visible_when, :covers_fields, :reason

        def self.none(reason:)
          new(:none, reason: reason)
        end

        def initialize(action, policy: nil, subject: nil, attribute: nil, model: nil, scope: nil, visible_when: nil, covers_fields: false, reason: nil)
          raise ArgumentError, "a rule needs an action" if action.nil?

          @action = action.to_sym
          @policy = policy
          @subject = subject
          @attribute = attribute
          @model = model
          @scope = scope
          @visible_when = visible_when&.to_sym
          @covers_fields = covers_fields
          @reason = reason

          raise ArgumentError, "a bypass needs a reason" if none? && reason.to_s.strip.empty?

          raise ArgumentError, "covers_fields only applies to a bypass (`authorize :none`)" if covers_fields && !none?

          freeze
        end

        # A bypassed type whose fields are covered by something else, such as the payload of a mutation.
        def covers_fields?
          covers_fields
        end

        def none?
          action == :none
        end

        def ==(other)
          other.is_a?(Rule) && members == other.members
        end
        alias eql? ==

        def hash
          members.hash
        end

        protected

        def members
          [action, policy, subject, attribute, model, scope, visible_when, covers_fields, reason]
        end
      end
    end
  end
end
