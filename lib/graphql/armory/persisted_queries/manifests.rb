# frozen_string_literal: true

module GraphQL
  module Armory
    module PersistedQueries
      # Several manifests behind one `store:`: each frontend's build, and every mobile version still in use.
      #
      #   use GraphQL::Armory::PersistedQueries, store: Manifests.build("config/persisted_queries/*.json"), strict: true
      #
      # A client's id is looked up across all of them, so any client may run any manifest's operation: they are one
      # allowlist, not one per client. Any problem raises at boot.
      class Manifests
        GLOB = /[*?\[{]/

        # `paths` is a glob pattern, a path, or a list of them. One that finds nothing raises: in strict mode its clients
        # would all be refused. A glob skips dotfiles, and drops a missing `{a,b}` alternative: list exact paths to be sure.
        def self.build(paths, digest: :sha256)
          names = paths.is_a?(Array) ? paths : [paths]
          raise ConfigurationError, "no manifest found in an empty list" if names.empty?

          files = names.flat_map { |name| files_of(name) }.uniq
          new(files.map { |file| Manifest.load(file, digest: digest) })
        end

        def self.files_of(name)
          raise ConfigurationError, "manifest paths must be Strings or Pathnames, found a #{name.class}" unless name.is_a?(String) || name.respond_to?(:to_path)

          path = name.is_a?(String) ? name : name.to_path
          return [path] unless path.match?(GLOB)

          found = Dir.glob(path).sort
          found = [path] if found.empty? && File.file?(path) # a name with a `[`, which matched nothing as a pattern
          raise ConfigurationError, "no manifest found in #{path}" if found.empty?

          found
        end
        private_class_method :files_of

        # `new` is inert: with no manifests it holds no operation, so every id is unknown.
        def initialize(manifests = [])
          unless manifests.is_a?(Array) && manifests.all? { |manifest| manifest.instance_of?(Manifest) }
            raise ConfigurationError, "manifests must be an Array of Manifest; use Manifests.build for paths"
          end

          @operations = manifests.each_with_object({}) do |manifest, operations|
            manifest.operations.each do |id, operation|
              kept = operations[id] ||= operation
              next if kept.body == operation.body

              raise ConfigurationError, "two manifests hold different queries for #{id.match?(Manifest::ID_LIKE) ? "the id #{id}" : "one id"}"
            end
          end.freeze
        end

        def fetch(id)
          @operations[id]
        end

        def size
          @operations.size
        end

        def empty?
          @operations.empty?
        end
      end
    end
  end
end
