# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      # Where something of the app's schema was written, as "path:line", for the audit's report. graphql-ruby keeps no
      # location for a field or an argument, so the plugin's field and argument classes record the line that declared them,
      # and a type records the line of its `authorize`. Anything else falls back to the line of its class, and a type
      # graphql-ruby generated (a mutation's payload, a connection, an edge) to the class it was generated from.
      #
      # Limits: a schema built from SDL has no Ruby lines; a field declared by a helper method points to the helper; a class
      # reopened in several files gives the first one.
      module Location
        GRAPHQL_RUBY_PATH = "#{File.dirname(GraphQL::Schema.method(:from_definition).source_location.first)}/"
        ARMORY_PATH = "#{File.expand_path('..', __dir__)}/"
        # The directory the app started in, read once: a later `Dir.chdir` must not change the report's text. None when the
        # directory is gone, and then paths stay absolute.
        ROOT = begin
          "#{Dir.pwd}/"
        rescue SystemCallError
          nil
        end

        # The first line of the caller's stack outside graphql-ruby and this gem: where the app declared it. An `initialize`
        # is skipped too: an app's field or argument class, or another gem's module, may define one that calls super into
        # the plugin's, and its line is the same for every field.
        def self.declared
          found = caller_locations(2, 40)&.find do |location|
            path = location.absolute_path || location.path
            !path.start_with?("<", GRAPHQL_RUBY_PATH, ARMORY_PATH) && location.base_label != "initialize"
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
            (thing.armory_rule_location if thing.respond_to?(:armory_rule_location)) || constant(thing) || generated_from(thing)
          end
        end
        private_class_method :absolute

        # graphql-ruby generates some types as classes with no constant: a mutation's payload, and a type's connection and
        # edge. They point to the class they were generated from, which was written somewhere.
        # A connection of connections can lead back to itself, so each class is visited once.
        def self.generated_from(type)
          seen = {}.compare_by_identity
          while type.is_a?(Module) && !seen.key?(type)
            seen[type] = true
            source = type.mutation if type.respond_to?(:mutation)
            source ||= type.node_type if type.respond_to?(:node_type)
            return unless source.is_a?(Module)

            found = (source.armory_rule_location if source.respond_to?(:armory_rule_location)) || constant(source)
            return found if found

            type = source
          end
        rescue StandardError, NotImplementedError
          nil
        end
        private_class_method :generated_from

        # Only when the name leads back to this class: a class may answer another constant's name. A location is never worth
        # failing the audit, so a `name` that raises gives none.
        def self.constant(mod)
          name = mod.name
          return if !name.is_a?(String) || name.empty? || !Object.const_get(name).equal?(mod)

          join(Object.const_source_location(name))
        rescue StandardError, NotImplementedError
          nil
        end
        private_class_method :constant

        def self.join(pair)
          pair && !pair.empty? && pair.first ? "#{pair.first}:#{pair.last}" : nil
        end
        private_class_method :join

        def self.relative(location)
          return location if location.nil? || ROOT.nil?

          location.start_with?(ROOT) ? location.delete_prefix(ROOT) : location
        end
        private_class_method :relative
      end
    end
  end
end
