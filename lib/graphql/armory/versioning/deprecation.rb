# frozen_string_literal: true

module GraphQL
  module Armory
    module Versioning
      # `deprecated: D` with `deprecation_reason:` deprecates a member from version D on. graphql-ruby's
      # `deprecation_reason` has no context (introspection and the SDL read it as it is), so one definition is deprecated
      # in every version or in none: the class that defines the member makes two definitions of it through its own DSL
      # method, one living up to D with no reason and one from D with it. They are ordinary twins: each version sees one.
      #
      #   field :amount, Integer, null: false, deprecated: "2024-06-01", deprecation_reason: "Use `total`"
      #   # is
      #   field :amount, Integer, null: false, removed: "2024-06-01"
      #   field :amount, Integer, null: false, added: "2024-06-01", deprecation_reason: "Use `total`"
      module Deprecation
        # The keywords of the two definitions `deprecated:` stands for, after checking what can be checked before
        # `versions:` is known: the order of D against `added:` and `removed:` is checked by each definition's lifecycle
        # the first time a query asks about it.
        def self.pair(name, deprecated, kwargs)
          reason = kwargs[:deprecation_reason]
          unless deprecated.is_a?(String) && !deprecated.empty?
            raise ConfigurationError, "#{name}: deprecated: must be a non-empty String naming a version, got #{deprecated.inspect}"
          end
          if !reason.is_a?(String) || reason.strip.empty?
            raise ConfigurationError, "#{name}: deprecated: needs deprecation_reason:, the reason clients read from that version on"
          end
          if [kwargs[:added], kwargs[:removed]].include?(deprecated)
            raise ConfigurationError, "#{name}: deprecated: must come after added: and before removed:, and #{deprecated.inspect} is one of them"
          end

          before = kwargs.except(:deprecation_reason).merge(removed: deprecated)
          [before, kwargs.merge(added: deprecated)]
        end

        def self.name_of(args, kwargs) = kwargs[:name] || args.first

        # The definition from D on remembers the one before D, so tooling can read the pair as one member written once.
        def self.mark(before, after)
          after.instance_variable_set(:@armory_deprecated_of, before)
          after
        end

        # `field` on an object, interface, resolver or mutation class.
        module Fields
          def field(*args, deprecated: nil, **kwargs, &block)
            return super(*args, **kwargs, &block) if deprecated.nil?

            name = Deprecation.name_of(args, kwargs)
            resolver = kwargs[:resolver] || kwargs[:mutation] || kwargs[:subscription]
            if resolver.respond_to?(:deprecation_reason) && resolver.deprecation_reason
              raise ConfigurationError, "#{name}: deprecated: cannot apply, its resolver #{resolver.name || resolver.inspect} has its own " \
                                        "deprecation_reason, which graphql-ruby gives the field in every version. Remove the resolver's"
            end

            before, after = Deprecation.pair(name, deprecated, kwargs)
            Deprecation.mark(super(*args, **before, &block), super(*args, **after, &block))
          end
        end

        # `argument` on a field, an input object, a resolver or a mutation: input fields are arguments.
        module Arguments
          def argument(*args, deprecated: nil, **kwargs, &block)
            return super(*args, **kwargs, &block) if deprecated.nil?

            name = Deprecation.name_of(args, kwargs)
            if Deprecation.subscription?(self)
              raise ConfigurationError, "#{name}: deprecated: cannot be used on a subscription's arguments: graphql-ruby's trigger reads " \
                                        "them with no version, where two definitions raise"
            end

            before, after = Deprecation.pair(name, deprecated, kwargs)
            Deprecation.mark(super(*args, **before, &block), super(*args, **after, &block))
          end
        end

        # `value` on an enum. graphql-ruby defines one method per value name, so only the first definition gets it.
        module Values
          def value(*args, deprecated: nil, **kwargs, &block)
            return super(*args, **kwargs, &block) if deprecated.nil?

            before, after = Deprecation.pair(Deprecation.name_of(args, kwargs), deprecated, kwargs)
            Deprecation.mark(super(*args, **before, &block), super(*args, **after.merge(value_method: false), &block))
          end
        end

        # A subscription class, or a field that a subscription class resolves. A field declared directly on the
        # subscription root is not known as one yet: the schema check refuses its twins when the schema is used.
        def self.subscription?(owner)
          owner = owner.resolver if owner.is_a?(GraphQL::Schema::Field)
          owner.is_a?(Class) && owner < GraphQL::Schema::Subscription
        end
      end
    end
  end
end
