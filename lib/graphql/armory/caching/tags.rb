# frozen_string_literal: true

require "json"

module GraphQL
  module Armory
    module Caching
      # The purge tags an entry carries, in clear, before the Digester turns them into keyed digests. The walk builds
      # `custom` and `type` tags into the Policy, the keyer the `viewer` tag, and `purge` the same strings from what the
      # app passes, so both sides always agree. Each kind has its own prefix, so a custom tag can never be a type or a
      # viewer tag; the viewer's class and id are JSON-encoded, so no id can forge a separator.
      module Tags
        ANONYMOUS = "viewer:anonymous"

        module_function

        def custom(name)
          raise ArgumentError, "a custom tag is a non-empty String" unless name.is_a?(String) && !name.strip.empty?

          "tag:#{name}"
        end

        def type(graphql_name)
          raise ArgumentError, "a type tag takes a GraphQL type name" unless graphql_name.is_a?(String) && !graphql_name.empty?

          "type:#{graphql_name}"
        end

        # `class_name` is the principal's Ruby class name, `id` a non-empty String or an Integer.
        def viewer(class_name, id)
          raise ArgumentError, "a viewer tag needs the principal's class name" unless class_name.is_a?(String) && !class_name.empty?
          raise ArgumentError, "a viewer id is a non-empty String or an Integer" unless id.is_a?(Integer) || (id.is_a?(String) && !id.empty?)

          "viewer:#{JSON.generate([class_name, id])}"
        end
      end
    end
  end
end
