# frozen_string_literal: true

require "pundit"

module GraphQL
  module Armory
    module Authorization
      module Adapters
        # Answers the core's four questions with Pundit's public API.
        #
        # The policy is found from the model through Pundit::PolicyFinder, so `policy_class`
        # overrides and namespaced models work. A policy must answer `true`, `false` or `nil`:
        # anything else (a lazy, a record) is handed back as is and the core refuses it.
        class Pundit
          def actor(context)
            context[:current_user]
          end

          def authorized?(user, subject, rule)
            policy = policy_class(rule, subject).new(user, subject)
            query = query_for(rule)
            unless policy.respond_to?(query)
              raise AdapterError, "#{policy.class} does not define #{query}"
            end

            policy.public_send(query)
          end

          def scope(user, items, rule)
            return items if items.is_a?(Array) && items.empty? && rule.model.nil? && rule.policy.nil?

            policy = policy_class(rule, rule.model || sample(items))
            scope_class = scope_constant(policy)
            raise MissingScopeError, "#{policy} has no Scope class" if scope_class.nil?

            scope_class.new(user, items).resolve
          end

          def check(type, rule)
            return [] if rule.none?

            model = normalize(rule.model || type)
            policy = rule.policy || finder(model).policy
            return ["#{model.is_a?(Symbol) ? model.to_s.camelize : model}Policy not found"] if policy.nil?

            problems = []
            query = query_for(rule)
            problems << "#{policy}##{query} is not defined" unless policy.public_method_defined?(query)
            problems << "#{policy}::Scope is not defined" if scope_constant(policy).nil?
            problems
          end

          private

          def policy_class(rule, subject)
            rule.policy || finder(subject).policy!
          end

          def query_for(rule)
            :"#{rule.action}?"
          end

          def finder(subject)
            ::Pundit::PolicyFinder.new(normalize(subject))
          end

          # Pundit reads a Symbol as a model name but a String as a plain object.
          def normalize(subject)
            subject.is_a?(String) ? subject.to_sym : subject
          end

          def sample(items)
            items.is_a?(Array) ? items.first : items
          end

          # Looks the Scope up through the policy's ancestors but never in Object, so a
          # top-level constant called Scope cannot be mistaken for a policy scope.
          def scope_constant(policy)
            owner = policy.ancestors.take_while { |ancestor| ancestor != Object }
                          .find { |ancestor| ancestor.const_defined?(:Scope, false) }
            owner&.const_get(:Scope, false)
          end
        end
      end
    end
  end
end
