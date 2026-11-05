# frozen_string_literal: true

require "fileutils"

module GraphQL
  module Armory
    module Versioning
      # Writes each served version's SDL to `<dir>/<label>.graphql`, plus `<dir>/latest.graphql`: committed, they make every
      # schema change reviewable per version in a pull request.
      #
      #   GraphQL::Armory::Versioning::Dump.(AppSchema, "schema")   # => ["schema/2024-06-01.graphql", ..., "schema/latest.graphql"]
      #
      # Each file is `to_definition(context: { armory_version: label, armory_full_schema: true })`: what a client of that
      # version sees, with nothing hidden by Authorization's `visible_when:`. Retired versions are not written, and a file
      # already there for one is left alone. Every SDL is printed before the first file is written.
      class Dump
        LATEST = "latest"

        # Where the files go. `Directory.new` with nothing writes nothing.
        class Directory
          def self.build(path)
            raise ConfigurationError, "Dump needs a directory to write to, got #{path.inspect}" if path.to_s.empty?

            new(path.to_s)
          end

          def initialize(path = nil)
            @path = path
          end

          # Writes one file and answers its path, or nil when it wrote nothing.
          def write(name, text)
            return unless @path

            FileUtils.mkdir_p(@path)
            File.join(@path, name).tap { |file| File.write(file, text) }
          end

          # Records what it is asked to write (`written`, name => text) and answers the name; told to fail, it raises
          # that error instead and records nothing.
          class Substitute
            attr_reader :written

            def initialize
              @written = {}
              @error = nil
            end

            def fail_with(error)
              @error = error
            end

            def write(name, text)
              raise @error if @error

              @written[name] = text
              name
            end
          end
        end

        def self.build(dir) = new(Directory.build(dir))

        def self.call(schema, dir, context: {}) = build(dir).(schema, context: context)

        # `new` is inert: it prints nothing anywhere.
        def initialize(directory = Directory.new)
          @directory = directory
        end

        # Answers what the directory wrote, in order: each served version oldest first, then latest.
        def call(schema, context: {})
          versions = Integration.gate(schema).versions
          labels = versions.each_served.map(&:label)
          check_labels(labels)

          sdl = labels.to_h { |label| [label, schema.to_definition(context: context.merge(armory_version: label, armory_full_schema: true))] }
          sdl[LATEST] = sdl.fetch(versions.latest.label)
          sdl.filter_map { |label, text| @directory.write("#{label}.graphql", text) }
        end

        private

        # A label becomes a file name, so it must stay one inside the directory and not collide with another.
        def check_labels(labels)
          labels.each do |label|
            if label.match?(%r{[/\\\0]}) || label.start_with?(".") || label.casecmp?(LATEST)
              raise ConfigurationError, "Dump cannot write version #{label.inspect} to a file: a label it writes must not contain " \
                                        "a slash, a backslash or a NUL, start with a dot, or be #{LATEST.inspect}"
            end
          end
          labels.combination(2).each do |one, other|
            if one.casecmp?(other)
              raise ConfigurationError, "Dump cannot write versions #{one.inspect} and #{other.inspect}: their files would be one " \
                                        "on a case-insensitive file system"
            end
          end
        end
      end
    end
  end
end
