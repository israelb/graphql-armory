# frozen_string_literal: true

module GraphQL
  module Armory
    module Versioning
      # One version of the schema: its label, its position in the list, and whether it is retired. Comparable with another
      # Version of the same list or with one of its labels (`version < "2025-01-01"`); a label the list does not hold raises.
      class Version
        include Comparable

        attr_reader :label, :index, :versions

        def initialize(label, index, retired, versions)
          @label = label
          @index = index
          @retired = retired
          @versions = versions
          freeze
        end

        def retired?
          @retired
        end

        def <=>(other)
          case other
          when Version then index <=> other.index
          when String then index <=> @versions.fetch(other).index
          end
        end

        def to_s
          label
        end

        def inspect
          "#<#{self.class.name} #{label}>"
        end

        # What `visible?` sees when graphql-ruby asks it with no query (`NullContext`): the latest version, with no list at
        # hand. A removed member never comes back, so "latest" is "nothing removed it".
        LATEST = Object.new.tap { |latest| def latest.inspect = "#<GraphQL::Armory::Versioning::Version LATEST>" }.freeze
      end

      # The schema's versions, oldest first. Labels are opaque: their order is their position. Validated by `Gate.build`.
      class Versions
        include Enumerable

        def initialize(labels, retired: [])
          @all = labels.each_with_index.map { |label, index| Version.new(label.dup.freeze, index, retired.include?(label), self) }.freeze
          @by_label = @all.to_h { |version| [version.label, version] }.freeze
          @served = @all.reject(&:retired?).freeze
          freeze
        end

        def index(label)
          @by_label[label]&.index
        end

        def fetch(label)
          @by_label.fetch(label) { raise UnknownVersionError, "#{label.inspect} is not in versions: #{@all.map(&:label).inspect}" }
        end

        def latest
          @all.last
        end

        def served?(label)
          version = @by_label[label]
          version ? !version.retired? : false
        end

        def retired?(label)
          @by_label[label]&.retired? || false
        end

        def each_served(&block)
          @served.each(&block)
        end

        def each(&block)
          @all.each(&block)
        end

        def size
          @all.size
        end

        # The list of a gate nobody wired: it knows no version, so every label is unknown.
        class Null
          include Enumerable

          def index(_label) = nil
          def served?(_label) = false
          def retired?(_label) = false
          def size = 0
          def each_served(&block) = [].each(&block)
          def each(&block) = [].each(&block)

          def fetch(label)
            raise UnknownVersionError, "#{label.inspect} is not a version: no versions are declared (use GraphQL::Armory::Versioning, versions: [...])"
          end

          def latest
            raise UnknownVersionError, "there is no latest version: no versions are declared (use GraphQL::Armory::Versioning, versions: [...])"
          end
        end
      end
    end
  end
end
