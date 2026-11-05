# frozen_string_literal: true

require "set"

module GraphQL
  module Armory
    module Caching
      class Audit
        # The app's own `visible?`, `authorized?`, `scope_items`, `authorized_new` or `wrap` on a class a `:public`
        # declaration reaches can answer per user, and the audit cannot read what it does: each is reported once, where it
        # is defined, until `own_checks:` declares it with a reason. The classes reached are the type that serves the
        # field and the one that defines it, every type it returns, its field and argument classes, the input objects of
        # its arguments, and its resolver. Methods of graphql-ruby and of this gem are told apart with Authorization's
        # audit's `LibraryMethods`, and the whole `super` chain is read: an override that calls super must not hide one
        # below it.
        class OwnChecks
          TYPE_CHECKS = %i[visible? authorized? scope_items authorized_new wrap].freeze
          MEMBER_CHECKS = %i[visible? authorized?].freeze
          RESOLVER_CLASS_CHECKS = %i[visible?].freeze
          LIBRARY_PATHS = [Authorization::Audit::GRAPHQL_RUBY_PATH, Authorization::Audit::ARMORY_PATH].freeze

          def initialize(definitions, findings)
            @definitions = definitions
            @findings = findings
            @found = {}
            @reached = Set.new.compare_by_identity
          end

          def call(pairs, declared)
            pairs.each do |type, field, _declaration|
              reach_type(type)
              reach_type(field.owner)
              PublicRules.data_types(field, @definitions).each { |returned| reach_type(returned) }
              reach_member(field.class)
              reach_arguments(PublicRules.arguments_of(field))
              reach_resolver(field.resolver) if field.resolver
            end
            report(declared)
          end

          private

          def reach_type(type)
            return unless type.is_a?(Module) && @reached.add?(type)

            TYPE_CHECKS.each { |name| note(type, type.method(name), name, ".") if type.respond_to?(name, true) }
          end

          def reach_member(klass)
            return unless @reached.add?(klass)

            MEMBER_CHECKS.each { |name| note(klass, klass.instance_method(name), name, "#") if instance_check?(klass, name) }
          end

          def reach_resolver(resolver)
            reach_member(resolver)
            RESOLVER_CLASS_CHECKS.each { |name| note(resolver, resolver.method(name), name, ".") if resolver.respond_to?(name, true) }
          end

          def reach_arguments(arguments, seen = Set.new.compare_by_identity)
            arguments.each do |argument|
              reach_member(argument.class)
              input = input_of(argument)
              next unless input && seen.add?(input)

              reach_type(input)
              reach_arguments(input.all_argument_definitions, seen)
            end
          end

          def input_of(argument)
            type = argument.type.unwrap
            type if type.respond_to?(:kind) && type.kind.input_object?
          rescue GraphQL::Error, NameError
            nil
          end

          def instance_check?(klass, name)
            klass.method_defined?(name) || klass.private_method_defined?(name)
          end

          def note(klass, method, name, separator)
            while method
              holder = Authorization::Audit::LibraryMethods.holder_of(klass, method)
              @found[[holder, name]] ||= ["#{label(holder)}#{separator}#{name}", method] if app?(method, holder)
              method = method.super_method
            end
          end

          # A method with no Ruby source is Ruby's own, not the app's.
          def app?(method, holder)
            !method.source_location.nil? && !Authorization::Audit::LibraryMethods.library_method?(method, holder, *LIBRARY_PATHS)
          end

          def report(declared)
            @found.each do |(holder, name), (path, method)|
              reason = declared.fetch(holder, {})[name]
              next @findings.declared(:own_check, path, reason, at: method) if reason

              @findings.problem(:own_check, path, "#{risk(name)}. Remove it, or declare it in own_checks: with a reason", at: method)
            end
            declared.each do |holder, methods|
              methods.each_key do |name|
                next if @found.key?([holder, name]) || defined_by_app?(holder, name)

                @findings.problem(:own_check, "#{label(holder)} #{name}", "named in own_checks: but #{label(holder)} defines no #{name} of its own: remove it from the option", at: holder)
              end
            end
          end

          # A declared check a :public declaration does not reach is not a problem, as long as the class defines it.
          def defined_by_app?(holder, name)
            chain = []
            chain << holder.method(name) if holder.respond_to?(name, true)
            chain << holder.instance_method(name) if holder.is_a?(Module) && instance_check?(holder, name)
            chain.any? do |method|
              found = false
              while method && !found
                found = Authorization::Audit::LibraryMethods.holder_of(holder, method).equal?(holder) && app?(method, holder)
                method = method.super_method
              end
              found
            end
          end

          def label(holder)
            return holder.name if holder.respond_to?(:name) && holder.name.is_a?(String)
            return holder.graphql_name if holder.respond_to?(:graphql_name)

            holder.inspect
          rescue StandardError
            holder.inspect # a class with no name graphql-ruby can give
          end

          def risk(name)
            case name
            when :visible? then "defined by the app, and the audit cannot read it: if it hides something from some users, a cached answer skips the " \
                                "validation that would refuse them, so they get what a viewer who could see it got"
            when :scope_items then "defined by the app, and the audit cannot read it: if it narrows the list per user, a shared answer holds the list " \
                                   "of whoever ran first"
            when :authorized_new, :wrap then "defined by the app, and the audit cannot read it: it decides whether authorized? runs, or which object the " \
                                             "fields see, so it can answer per user"
            else "defined by the app, and the audit cannot read it: if it refuses some users, one it refuses gets the answer cached for one it allowed"
            end
          end
        end
      end
    end
  end
end
