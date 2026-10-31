# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # Tells a library's method from an app's.
        module LibraryMethods
          module_function

          def holder_of(klass, method)
            owner = method.owner
            klass.ancestors.find { |ancestor| ancestor.singleton_class == owner } || owner
          end

          def library_method?(method, holder, *paths)
            file = method.source_location&.first
            !file.nil? && file.start_with?(*paths) && holder.name&.start_with?("GraphQL::") == true
          end
        end
      end
    end
  end
end
