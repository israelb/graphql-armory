# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      # Where something of the app's schema was written, as "path:line", for the audit's report. graphql-ruby keeps no
      # location for a field or an argument, so the plugin's field and argument classes record the line that declared them,
      # and a type records the line of its `authorize`. Anything else falls back to the line of its class.
      #
      # Limits: a schema built from SDL has no Ruby lines; a field declared by a helper method points to the helper; a class
      # reopened in several files gives the first one.
      module Location
        GRAPHQL_RUBY_PATH = "#{File.dirname(GraphQL::Schema.method(:from_definition).source_location.first)}/"
        ARMORY_PATH = "#{File.expand_path('..', __dir__)}/"
        # The directory the app started in, read once: a later `Dir.chdir` must not change the report's text.
        ROOT = "#{Dir.pwd}/"

        # The first line of the caller's stack outside graphql-ruby and this gem: where the app declared it.
        def self.declared
          found = caller_locations(2, 40)&.find do |location|
            path = location.absolute_path || location.path
            !path.start_with?("<", GRAPHQL_RUBY_PATH, ARMORY_PATH)
          end
          found && "#{found.absolute_path || found.path}:#{found.lineno}"
        end

        # "path:line" for a method, a field, an argument, a type or a class, relative to the directory the app started in
        # when it is inside it, or nil when there is no line to give.
        def self.of(thing)
          relative(absolute(thing))
        end

        def self.absolute(thing)
          case thing
          when nil then nil
          when String then thing
          when Method, UnboundMethod then join(thing.source_location)
          when GraphQL::Schema::Field, GraphQL::Schema::Argument
            (thing.armory_location if thing.respond_to?(:armory_location)) || absolute(thing.owner)
          when Module
            (thing.armory_rule_location if thing.respond_to?(:armory_rule_location)) || constant(thing)
          end
        end
        private_class_method :absolute

        def self.constant(mod)
          name = mod.name
          return if name.nil? || name.empty?

          join(Object.const_source_location(name))
        rescue NameError
          nil
        end
        private_class_method :constant

        def self.join(pair)
          pair && !pair.empty? && pair.first ? "#{pair.first}:#{pair.last}" : nil
        end
        private_class_method :join

        def self.relative(location)
          return location if location.nil?

          location.start_with?(ROOT) ? location.delete_prefix(ROOT) : location
        end
        private_class_method :relative
      end
    end
  end
end
