# frozen_string_literal: true

require "digest"
require "json"

module GraphQL
  module Armory
    module PersistedQueries
      # The operations a client build produced, loaded from Apollo's persisted query manifest or Relay's
      # persisted output. Every id must be the digest of its query, so an edited manifest cannot put another
      # query behind an id; every query is parsed once, here. Any problem raises at boot.
      class Manifest
        DIGESTS = { sha256: Digest::SHA256, sha1: Digest::SHA1, md5: Digest::MD5 }.freeze
        APOLLO_FORMAT = "apollo-persisted-query-manifest"

        Operation = Struct.new(:id, :name, :body, :document, keyword_init: true)

        def self.load(path, digest: :sha256)
          data = begin
            JSON.parse(File.read(path))
          rescue JSON::ParserError
            # Not the parser's message: it quotes the file's content.
            raise ConfigurationError, "#{path} is not valid JSON"
          end
          new(data, digest: digest)
        end

        # `digest:` is how ids were made: :sha256 (Apollo), :md5 or :sha1 (Relay's options), or false for ids
        # that are not digests (then nothing proves an id belongs to its query).
        def initialize(data, digest: :sha256)
          unless digest == false || DIGESTS.key?(digest)
            raise ConfigurationError, "unknown digest #{digest.inspect}: use #{DIGESTS.keys.map(&:inspect).join(", ")} or false"
          end

          @digest = digest && DIGESTS.fetch(digest)
          @operations = entries(data).each_with_object({}) do |(id, name, body), operations|
            raise ConfigurationError, "operation #{id} appears twice in the manifest" if operations.key?(id)

            operations[id] = operation(id, name, body)
          end.freeze
        end

        def fetch(id)
          @operations[id]
        end

        def size
          @operations.size
        end

        private

        # [id, name, body] triples from either format.
        def entries(data)
          return apollo_entries(data) if data.is_a?(Hash) && data.key?("format")
          return data.map { |id, body| [id, nil, body] } if data.is_a?(Hash)

          raise ConfigurationError, "unknown manifest format: expected Apollo's persisted query manifest or Relay's persisted output"
        end

        def apollo_entries(data)
          raise ConfigurationError, "unknown manifest format #{data["format"].inspect}" unless data["format"] == APOLLO_FORMAT
          raise ConfigurationError, "unsupported manifest version #{data["version"].inspect}: expected 1" unless data["version"] == 1

          Array(data["operations"]).map { |entry| entry.values_at("id", "name", "body") }
        end

        def operation(id, name, body)
          unless id.is_a?(String) && body.is_a?(String)
            raise ConfigurationError, "manifest entry #{id.inspect} needs a String id and a String body"
          end
          if @digest && @digest.hexdigest(body) != id
            raise ConfigurationError, "operation #{id} is not the digest of its query: the manifest was edited, or `digest:` is wrong"
          end

          Operation.new(id: id, name: name, body: body, document: parse(id, body)).freeze
        end

        def parse(id, body)
          GraphQL.parse(body)
        rescue GraphQL::ParseError
          raise ConfigurationError, "operation #{id} does not parse"
        end
      end
    end
  end
end
