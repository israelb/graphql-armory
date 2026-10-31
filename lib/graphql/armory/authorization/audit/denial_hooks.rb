# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # A method the schema defines on itself wins over the plugin's, so `on_unauthorized:` no longer decides
        # what that denial looks like. The check runs here because `use` usually comes before those methods.
        module DenialHooks
          def self.call(schema, findings)
            declared = schema.armory_configuration.own_denial_hooks
            Configuration::DENIAL_HOOKS.each do |hook|
              path = "Schema.#{hook}"
              own = schema.method(hook).owner != Integration::Schema
              if own && declared.key?(hook)
                findings.bypass(path, declared[hook])
              elsif own
                findings.problem(:hook, path, "the schema's own method runs instead of the plugin's, so on_unauthorized: does not apply and a denial " \
                                              "may reveal what it hides: remove it, or declare it in own_denial_hooks: with a reason")
              elsif declared.key?(hook)
                findings.problem(:hook, path, "named in own_denial_hooks: but the plugin's hook is the one that runs: remove it from the option")
              end
            end
          end
        end
      end
    end
  end
end
