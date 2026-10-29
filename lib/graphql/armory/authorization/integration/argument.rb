# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      module Integration
        # Included in an argument class by `include GraphQL::Armory::Authorization::Base`.
        #
        #   argument :include_internal, Boolean, authorize: :manage            # checked when the client sends it
        #   argument :tag, String, visible_when: :export                       # hidden from users who cannot export
        #   argument :status, String, authorize: :none, reason: "public"      # declared, listed in the audit
        #
        # An argument with no rule is covered by its field: the field already decides whether the user may call it.
        # A declared rule is checked on top, only when the client sends the argument (graphql-ruby skips
        # arguments left at their default), and a denial denies the whole field.
        #
        # The question is asked of the parent object when it is an instance of the model, else of the model's
        # class (a root field has no record). The model is the one the field's type wraps, or `model:`.
        module Argument
          def initialize(*args, authorize: nil, reason: nil, model: nil, visible_when: nil, **kwargs, &block)
            unless [nil, :none].include?(authorize) || authorize.is_a?(Symbol)
              raise ArgumentError, "an argument's `authorize:` is an action or :none, not #{authorize.inspect}"
            end

            if authorize && authorize != :none && kwargs.key?(:default_value)
              raise ArgumentError,
                    "a restricted argument cannot have a default_value: the interpreter skips the check for a default " \
                    "and Execution::Next applies it, so the engines would disagree"
            end

            @armory_declared = authorize
            @armory_reason = reason
            @armory_model = model
            @armory_visible_when = visible_when&.to_sym
            Rule.none(reason: reason) if authorize == :none
            super(*args, **kwargs, &block)
          end

          attr_reader :armory_declared, :armory_reason, :armory_visible_when

          def armory_model
            @armory_model || armory_field_model
          end

          def authorized?(object, value, context)
            return super if @armory_declared.nil? || @armory_declared == :none

            model = armory_model
            subject = object.is_a?(model) ? object : model
            Integration.allowed?(subject, Rule.new(@armory_declared, attribute: keyword), context) && super
          end

          def visible?(context)
            return super unless @armory_visible_when

            super && Integration.visible?(armory_model, Rule.new(@armory_visible_when, attribute: keyword), context)
          end

          private

          def armory_field_model
            type = owner.respond_to?(:owner) ? owner.owner : owner
            model = type.armory_model if type.respond_to?(:armory_model)
            return model if model

            raise ConfigurationError, "#{keyword}: cannot tell which model to ask about, pass `model: YourModel`"
          rescue ConfigurationError
            raise ConfigurationError, "#{keyword}: cannot tell which model to ask about, pass `model: YourModel`"
          end
        end
      end
    end
  end
end
