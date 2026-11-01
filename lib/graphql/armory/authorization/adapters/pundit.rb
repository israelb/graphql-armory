# frozen_string_literal: true

require "pundit"

module GraphQL
  module Armory
    module Authorization
      module Adapters
        # Answers the core's four questions with Pundit's public API.
        #
        # The policy is found from the model's class through Pundit::PolicyFinder, so `self.policy_class`
        # overrides and namespaced models work. A policy must answer `true`, `false` or `nil`:
        # anything else (a lazy, a record) is handed back as is and the core refuses it.
        class Pundit
          # `user_key:` is the context key that holds the user.
          def initialize(user_key: :current_user)
            raise ArgumentError, "user_key must be a Symbol or a String, got #{user_key.class}" unless user_key.is_a?(Symbol) || user_key.is_a?(String)

            @user_key = user_key
          end

          def actor(context)
            context[@user_key]
          end

          def authorized?(user, subject, rule)
            query = query_for(rule)
            policies_for(rule, subject).each do |policy_class|
              policy = policy_class.new(user, subject)
              raise AdapterError, "#{policy.class} does not define #{query}" unless policy.respond_to?(query)

              answer = policy.public_send(query)
              return answer unless true.equal?(answer)
            end
            true
          end

          def scope(user, items, rule)
            return items.select { |item| true.equal?(authorized?(user, item, rule)) } if items.is_a?(Array)

            policy = policy_class(rule, normalize(rule.model) || record_target(items))
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

          # The policy a rule that names none asks about this model.
          def found_policy(model)
            finder(normalize(model)).policy
          end

          private

          # A rule's `policy:` answers alone. Otherwise the declared model's policy, which is the one the audit reads, and
          # the record's class's must both allow it: one alone lets a record of another class, or a subclass with a laxer
          # policy, past the first, or a subclass past its own stricter policy.
          def policies_for(rule, subject)
            return [rule.policy] if rule.policy

            model = normalize(rule.model) if rule.model
            declared = finder(model).policy if model
            target = model_named?(subject, model) ? subject : record_target(subject)
            own = finder(target).policy
            return [declared, own].compact.uniq if own
            return [declared] if declared && kind_of_model?(subject, model)

            raise ::Pundit::NotDefinedError, "no policy found for #{subject_name(target)}"
          end

          # A Symbol names a policy only when it is the `model:` the schema author wrote: any other is a record, maybe the
          # client's text, as a String is.
          def model_named?(subject, model)
            Symbol === subject && subject.equal?(model)
          end

          def record_target(subject)
            Symbol === subject ? ::Symbol : policy_subject(subject)
          end

          # Only a record of the model inherits its policy: anything else with no policy of its own raises, as it always did.
          def kind_of_model?(subject, model)
            return false unless model.is_a?(Module)

            target = policy_subject(subject)
            target.is_a?(Module) ? target <= model : model === target
          end

          def policy_class(rule, subject)
            rule.policy || finder(policy_subject(subject)).policy || raise(::Pundit::NotDefinedError, "no policy found for #{subject_name(subject)}")
          end

          # Pundit asks the object for `policy_class` and `model_name`, and reads an Array as a namespace. A record's
          # answers can be the client's data (an OpenStruct from JSON), so only its class is asked. A relation's class
          # names no model, so its `klass` is read, but only on a real relation: `klass` on anything else is an answer too.
          def policy_subject(subject)
            return subject if Module === subject || Symbol === subject
            return subject.klass if defined?(::ActiveRecord::Relation) && ::ActiveRecord::Relation === subject

            ::Kernel.instance_method(:class).bind_call(subject)
          end

          # Never `inspect`: Pundit's own message quotes the record, and on a relation it runs the query.
          # Nor the record's own `class` or `is_a?`: on a Struct or OpenStruct, `class` can be a data member.
          def subject_name(subject)
            Module === subject || Symbol === subject ? subject : ::Kernel.instance_method(:class).bind_call(subject)
          end

          def query_for(rule)
            :"#{rule.action}?"
          end

          def finder(subject)
            ::Pundit::PolicyFinder.new(subject)
          end

          # Pundit reads a Symbol as a model name but a String as a plain object. Only for a model the schema author
          # wrote: a String a type wraps is a record, maybe the client's text, and must not name its own policy.
          def normalize(model)
            model.is_a?(String) ? model.to_sym : model
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
