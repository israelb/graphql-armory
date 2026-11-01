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
        # `paths` is a glob pattern, a path, or a list of them. A pattern that matches nothing raises: in strict mode it
        # would refuse every client.
        def self.build(paths, digest: :sha256)
          names = Array(paths)
          files = names.flat_map { |path| File.exist?(path) ? [path] : Dir.glob(path).sort }.uniq
          raise ConfigurationError, "no manifest found in #{names.empty? ? "an empty list" : names.join(", ")}" if files.empty?

          new(files.map { |file| Manifest.load(file, digest: digest) })
        end

        # `new` is inert: with no manifests it holds no operation, so every id is unknown.
        def initialize(manifests = [])
          unless manifests.is_a?(Array) && manifests.all?(Manifest)
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
      end
    end
  end
end
