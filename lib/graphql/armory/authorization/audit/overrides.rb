# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      class Audit
        # With no Schema::Visibility, a field hidden from a user falls back to another definition of its name, losing its
        # rule, arguments, return type and extensions. Many things can hide it (the field, its resolver, its return type,
        # the schema) and only a request knows, so every redefinition is reported until it declares `override_reason:`.
        class Overrides
          def self.call(schema, definitions, findings)
            new(definitions, findings).(schema)
          end

          def initialize(definitions = [], findings = Findings.new)
            @definitions = definitions
            @findings = findings
            @override_paths = {}.compare_by_identity
            @falling_back = {}.compare_by_identity
            @duplicates = Set.new.compare_by_identity
          end

          def call(schema)
            @definitions.each do |type|
              next if type.introspection?

              note_redefinitions(type.graphql_name, type.ancestors, :own_fields, :original_name)
              note_redefinitions(type.graphql_name, type.ancestors, :own_arguments, :graphql_name) if type.kind.input_object?
              Definitions.fields_at_every_level(type).each do |field|
                levels = [field] + (field.resolver ? field.resolver.ancestors : [])
                note_redefinitions("#{type.graphql_name}.#{field.original_name}", levels, :own_arguments, :graphql_name)
              end
            end
            no_fallback = visibility_without_fallback?(schema)
            @override_paths.each do |member, path|
              falls_back = @falling_back.key?(member) && (!no_fallback || @duplicates.include?(member))
              note_override(falls_back ? @falling_back[member] : path, member, falls_back)
            end
          end

          private

          # Nearest level first; only a lone definition on the farthest level has nothing to fall back to. Duplicates on
          # one level are noted apart: a visibility profile skips the levels below, but still picks one of those.
          def note_redefinitions(prefix, ancestors, reader, name_reader)
            levels = ancestors.select { |ancestor| ancestor.respond_to?(reader) }
            levels.flat_map { |level| level.public_send(reader).keys }.uniq.each do |name|
              definitions = levels.filter_map { |level| [level.public_send(reader)[name]].flatten if level.public_send(reader).key?(name) }
              definitions.flatten.each { |member| @override_paths[member] ||= "#{prefix}.#{member.public_send(name_reader)}" }
              falling = definitions.last.size == 1 ? definitions.flatten[0...-1] : definitions.flatten
              falling.each { |member| @falling_back[member] ||= "#{prefix}.#{member.public_send(name_reader)}" }
              definitions.select { |level| level.size > 1 }.flatten.each { |member| @duplicates << member }
            end
          end

          # graphql-ruby skips the fallback to a lower level only when the request carries a visibility profile. A static
          # profile runs with a plain Hash, so only `Schema::Visibility` with no profiles, not turned off below, rules it out.
          def visibility_without_fallback?(schema)
            visibility = schema.visibility
            return false unless visibility
            return false if schema.respond_to?(:use_visibility_profile?) && !schema.use_visibility_profile?

            visibility.instance_variable_get(:@profiles).to_h.empty?
          end

          def note_override(path, member, falls_back)
            reason = member.armory_override_reason if member.respond_to?(:armory_override_reason)
            if falls_back && reason
              @findings.bypass(path, reason)
            elsif falls_back
              @findings.problem(:ignored_rule, path, "is defined more than once: hidden from a user, it falls back to the other definition, and its own rule, arguments, type and extensions do not apply. " \
                                                     "Remove one or declare override_reason:; for a definition on an ancestor, Schema::Visibility with dynamic: true and no profiles also stops the fallback")
            elsif reason
              @findings.problem(:ignored_rule, path, "declares override_reason: but nothing falls back from it: remove it")
            end
          end
        end
      end
    end
  end
end
