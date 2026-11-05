# frozen_string_literal: true

module GraphQL
  module Armory
    module Versioning
      class Audit
        # An app's `visible?` that answers before the plugin's decides the version for it: if it does not call `super`, it
        # serves a member outside its lifecycle. The audit cannot read whether it does, so each one is reported once, where it
        # is defined, until `own_checks:` declares it with a reason. Methods of graphql-ruby and of this gem are not the app's,
        # and a method behind the plugin's runs only after the version allowed the member.
        #
        # Read along the whole chain, as Ruby calls it (`method(:visible?)` and its `super_method`): on type classes,
        # resolvers and mutations with `Base`, on field, argument, enum value and membership classes with `Base`, on one
        # member (a `def self.visible?` in a field's block, which no class holds, so it cannot be declared), and on the
        # schema, whose `self.visible?` graphql-ruby asks for every member.
        class OwnChecks
          INTEGRATIONS = [Integration::Type, Integration::Field, Integration::Argument, Integration::EnumValue, Integration::Membership].freeze
          LIBRARIES = [Armory::Location::GRAPHQL_RUBY_PATH, Armory::Location::ARMORY_PATH].freeze

          def self.call(schema, definitions, members, findings)
            new(definitions, members, findings).(schema, schema.armory_versioning.own_checks)
          end

          def initialize(definitions = [], members = [], findings = Findings.new)
            @definitions = definitions
            @members = members
            @findings = findings
            @found = {}.compare_by_identity
            @singletons = []
          end

          def call(schema, declared)
            types = @definitions + @members.grep(GraphQL::Schema::Field).filter_map(&:resolver)
            types.uniq.each { |type| note_type(type) }
            @members.each { |member| note_member(member) unless member.is_a?(Module) }
            note_schema(schema)
            report(declared)
            @findings
          end

          private

          def note_type(type)
            return unless type.is_a?(Module) && type.singleton_class.include?(Integration::Type)

            ahead(type.method(:visible?)) { |method| note(holder_of(type, method), method, ".") }
          end

          def note_member(member)
            return unless INTEGRATIONS.any? { |integration| member.is_a?(integration) }

            ahead(member.method(:visible?)) do |method|
              if member.class.ancestors.include?(method.owner)
                note(method.owner, method, "#")
              else
                @singletons << [member, method]
              end
            end
          end

          # Every method of the chain: the schema has no plugin method to stop at.
          def note_schema(schema)
            method = schema.method(:visible?)
            while method
              note(holder_of(schema, method), method, ".") unless library?(method)
              method = method.super_method
            end
          end

          # The app's methods Ruby calls before the plugin's.
          def ahead(method)
            while method && !INTEGRATIONS.include?(method.owner)
              yield method unless library?(method)
              method = method.super_method
            end
          end

          def library?(method)
            file = method.source_location&.first
            !file.nil? && file.start_with?(*LIBRARIES)
          end

          def note(holder, method, separator)
            @found[holder] ||= ["#{name_of(holder)}#{separator}visible?", method]
          end

          # A class method's holder is the class, and an interface's `definition_methods` belong to the interface.
          def holder_of(owner, method)
            held = method.owner
            owner.ancestors.find do |ancestor|
              ancestor.singleton_class.equal?(held) ||
                (!ancestor.is_a?(Class) && ancestor.const_defined?(:DefinitionMethods, false) && ancestor.const_get(:DefinitionMethods, false).equal?(held))
            end || held
          end

          def name_of(holder)
            return holder.name || "Schema" if holder.is_a?(Class) && holder <= GraphQL::Schema
            return Integration.display_name(holder) if holder.respond_to?(:graphql_name)

            holder.name || holder.inspect
          end

          def report(declared)
            @found.each do |holder, (path, method)|
              reason = declared.fetch(holder, {})[:visible?]
              next @findings.information(:own_check, path, "declared in own_checks: #{reason}", at: method) if reason

              @findings.problem(:own_check, path, "#{risk(holder)}. Remove it, or declare it in own_checks: with a reason", at: method)
            end
            @singletons.uniq { |member, _| member.object_id }.each do |member, method|
              @findings.problem(:own_check, member.path, "has a visible? of its own (a def self.visible? on this one member): it answers " \
                                                         "before the plugin's, and own_checks: cannot declare it. Move it to a class, or remove it", at: method)
            end
            declared.each_key do |holder|
              next if @found.key?(holder)

              @findings.problem(:own_check, "#{name_of(holder)} visible?", "named in own_checks: but defines no visible? ahead of the plugin's: " \
                                                                         "remove it from the option", at: holder)
            end
          end

          def risk(holder)
            if holder.is_a?(Class) && holder <= GraphQL::Schema
              "defined by the app on the schema: graphql-ruby asks it about every member, so if it does not call super nothing is versioned"
            else
              "defined by the app, it answers before the plugin's: if it does not call super, it serves members outside their lifecycle"
            end
          end
        end
      end
    end
  end
end
