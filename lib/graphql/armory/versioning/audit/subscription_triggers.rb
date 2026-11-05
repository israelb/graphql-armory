# frozen_string_literal: true

module GraphQL
  module Armory
    module Versioning
      class Audit
        # graphql-ruby's `Subscriptions#trigger` finds the field with the trigger's context, but reads its arguments with no
        # query, where every definition counts: it fills in the default of every argument and input field whatever its
        # version, then builds the topic with the trigger's context. So an argument (or a nested input field) that a served
        # version has and the latest does not, or the reverse, breaks triggers: with a default, a trigger naming the version
        # without it raises and a trigger naming another version never reaches that version's subscribers; without one, a
        # trigger that passes it raises unless its context names a version that has it.
        #
        # Listed as information: a subscription field the default version does not have, and `default: :refuse`, since a
        # trigger that names no version then raises.
        class SubscriptionTriggers
          def self.call(schema, findings)
            new(findings).(schema)
          end

          def initialize(findings = Findings.new)
            @findings = findings
          end

          def call(schema)
            root = schema.subscription
            return @findings unless root

            gate = schema.armory_versioning
            default = gate.resolve(nil)
            fields = Armory::Definitions.fields_at_every_level(root)
            refuse(root) if default.refused? && fields.any? { |field| field.is_a?(Integration::Field) }
            fields.each { |field| check(field, gate.versions, default) }
            @findings
          end

          private

          def refuse(root)
            @findings.information(:subscription_trigger, root.graphql_name, "default: :refuse, so a trigger that names no version raises " \
                                                                            "MissingVersionError. Pass context: { armory_version: ... } to every trigger", at: root)
          end

          def check(field, versions, default)
            served = versions.each_served.select { |version| live?(field, version) }
            return if served.empty?

            unless default.refused? || served.include?(default.version)
              @findings.information(:subscription_trigger, field.path, "the default version (#{label(default.version)}) does not have it, so a " \
                                                                       "trigger that names no version raises InvalidTriggerError. Pass " \
                                                                       "context: { armory_version: ... } to its triggers", at: field)
            end
            latest = covered(field.all_argument_definitions, Version::LATEST)
            served.each do |version|
              listed = covered(field.all_argument_definitions, version)
              (listed.keys - latest.keys).each { |argument| differs(argument, Version::LATEST) }
              (latest.keys - listed.keys).each { |argument| differs(argument, version) }
            end
          end

          # The arguments and nested input fields a version has, by identity.
          def covered(arguments, version, found = {}.compare_by_identity, seen = {}.compare_by_identity)
            arguments.each do |argument|
              next unless Integration.covers?(argument, version)

              found[argument] = true
              input = argument.type.unwrap
              next unless input.kind.input_object? && !seen.key?(input)

              seen[input] = true
              covered(input.all_argument_definitions, version, found, seen)
            end
            found
          end

          def differs(argument, without)
            where = label(without)
            message = if argument.default_value?
                        "has a default and is not in #{where}: trigger fills in the default of every argument whatever the version, " \
                          "so a trigger that names #{where} raises, and a trigger that names another version never reaches the " \
                          "subscribers of #{where}. Remove the default, or keep the argument in every version"
                      else
                        "is not in #{where}: trigger reads arguments with no version, so a trigger that passes it raises unless its " \
                          "context names a version that has it (armory_version:)"
                      end
            @findings.problem(:subscription_trigger, argument.path, message, at: argument)
          end

          def live?(field, version)
            [field, field.owner, field.resolver].compact.all? { |member| Integration.lifecycle_of(member).covers?(version) }
          end

          def label(version) = Integration.label(version)
        end
      end
    end
  end
end
