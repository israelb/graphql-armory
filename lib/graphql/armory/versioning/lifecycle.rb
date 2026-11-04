# frozen_string_literal: true

module GraphQL
  module Armory
    module Versioning
      # When a member lives: from `added` (the first version when absent) up to, not including, `removed` (still here when
      # absent). Building it checks only the shape of the labels, because members load before `use` declares the list. Their
      # order is checked against the query's list every time it is asked, with nothing remembered on the member: a type may
      # be shared by two schemas with different lists. The audit is the place to catch an undeclared label before a request.
      class Lifecycle
        # The lifecycle of a member that declares none: every version, at no cost.
        class Everywhere
          def covers?(_version) = true
          def to_h = {}
        end

        EVERYWHERE = Everywhere.new.freeze

        def self.build(added: nil, removed: nil)
          added.nil? && removed.nil? ? EVERYWHERE : new(added: added, removed: removed)
        end

        attr_reader :added, :removed

        def initialize(added: nil, removed: nil)
          { added: added, removed: removed }.each do |name, label|
            next if label.nil? || (label.is_a?(String) && !label.empty?)

            raise ConfigurationError, "#{name}: must be a non-empty String naming a version, got #{label.inspect}"
          end
          raise ConfigurationError, "removed: must be a later version than added:, both are #{added.inspect}" if !added.nil? && added == removed

          @added = added&.dup&.freeze
          @removed = removed&.dup&.freeze
          freeze
        end

        def covers?(version)
          return @removed.nil? if Version::LATEST.equal?(version)

          versions = version.versions
          from = @added ? position(versions, :added, @added) : 0
          to = @removed ? position(versions, :removed, @removed) : versions.size
          raise ConfigurationError, "removed: #{@removed.inspect} comes before added: #{@added.inspect} in versions:" if to <= from

          from <= version.index && version.index < to
        end

        def to_h
          { added: @added, removed: @removed }.compact
        end

        private

        def position(versions, name, label)
          versions.index(label) || raise(ConfigurationError, "#{name}: #{label.inspect} is not in versions: #{versions.map(&:label).inspect}")
        end
      end
    end
  end
end
