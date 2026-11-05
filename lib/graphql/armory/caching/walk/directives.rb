# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      class Walk
        # Any directive anywhere in the document (the operations, their variable definitions, fields, fragment
        # definitions, inline fragments and fragment spreads, selected or not) makes the operation uncacheable, unless
        # it is graphql-ruby's own `@skip` or `@include` (the walk counts both branches) or its class declares
        # `cache_safe`. A directive the schema does not define (or hides from this query) is refused too.
        module Directives
          IGNORED = [GraphQL::Schema::Directive::Skip, GraphQL::Schema::Directive::Include].freeze

          module_function

          # :directive, or nil when every directive in the document is allowed.
          def refusal(document, types)
            classes = nil
            pending = document.definitions.dup
            until pending.empty?
              node = pending.pop
              directives = node.respond_to?(:directives) ? node.directives : []
              if node.is_a?(GraphQL::Language::Nodes::OperationDefinition)
                node.variables.each { |variable| directives += variable.directives if variable.respond_to?(:directives) }
              end
              unless directives.empty?
                classes ||= types.directives.to_h { |directive| [directive.graphql_name, directive] }
                return :directive unless directives.all? { |directive| allowed?(classes[directive.name]) }
              end
              pending.concat(node.selections) if node.respond_to?(:selections)
            end
            nil
          end

          def allowed?(directive_class)
            return false if directive_class.nil?

            IGNORED.any? { |ignored| directive_class.equal?(ignored) } ||
              (directive_class.respond_to?(:armory_cache_safe?) && directive_class.armory_cache_safe? == true)
          end
        end
      end
    end
  end
end
