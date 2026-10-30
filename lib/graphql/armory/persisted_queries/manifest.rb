# frozen_string_literal: true

require "digest"
require "json"

module GraphQL
  module Armory
    module PersistedQueries
      # The operations a client build produced, loaded from Apollo's persisted query manifest or Relay's
      # persisted output. Every id must be the digest of its query, so an edited manifest cannot put another
      # query behind an id; every query is parsed once, here. Any problem raises at boot, and no message
      # quotes the manifest's values: they may hold query text.
      class Manifest
        DIGESTS = { sha256: Digest::SHA256, sha1: Digest::SHA1, md5: Digest::MD5 }.freeze
        APOLLO_FORMAT = "apollo-persisted-query-manifest"
        ID_LIKE = /\A[A-Za-z0-9_.:-]{1,128}\z/

        Operation = Struct.new(:id, :name, :body, :document, keyword_init: true)

        def self.load(path, digest: :sha256)
          data = begin
            JSON.parse(File.read(path, mode: "r:bom|utf-8"))
          rescue JSON::ParserError
            # Not the parser's message: it quotes the file's content.
            raise ConfigurationError, "#{path} is not valid JSON"
          rescue SystemCallError => error
            raise ConfigurationError, "#{path} cannot be read (#{error.class})"
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
          @operations = entries(data).each_with_index.with_object({}) do |((id, name, body), index), operations|
            operation = operation(index, id, name, body)
            raise ConfigurationError, "operation #{label(index, id)} appears twice in the manifest" if operations.key?(id)

            operations[id] = operation
          end.freeze
          raise ConfigurationError, "the manifest holds no operations: is it the right file?" if @operations.empty?
        end

        def fetch(id)
          @operations[id]
        end

        def size
          @operations.size
        end

        private

        # [id, name, body] triples from either format. A Relay map may have an operation keyed "format", so a
        # Hash is Apollo's when its format says so, or when it has both "format" and "operations".
        def entries(data)
          raise ConfigurationError, unknown_format unless data.is_a?(Hash)
          return apollo_entries(data) if data["format"] == APOLLO_FORMAT || (data.key?("format") && data.key?("operations"))

          data.map { |id, body| [id, nil, body] }
        end

        def apollo_entries(data)
          raise ConfigurationError, "unknown manifest format: expected #{APOLLO_FORMAT}" unless data["format"] == APOLLO_FORMAT
          raise ConfigurationError, "unsupported manifest version: expected 1" unless data["version"].eql?(1)
          raise ConfigurationError, "the manifest's operations must be an array" unless data["operations"].is_a?(Array)

          data["operations"].each_with_index.map do |entry, index|
            raise ConfigurationError, "manifest entry #{index} is not an object" unless entry.is_a?(Hash)

            entry.values_at("id", "name", "body")
          end
        end

        def operation(index, id, name, body)
          unless id.is_a?(String) && body.is_a?(String) && (name.nil? || name.is_a?(String))
            raise ConfigurationError, "manifest entry #{index} needs a String id, a String body and a String name or none"
          end
          if @digest && @digest.hexdigest(body) != id
            raise ConfigurationError, "operation #{label(index, id)} is not the digest of its query: the manifest was edited, or `digest:` is wrong"
          end

          # Copies, so neither the caller's data nor a fetched operation can change what a later fetch returns.
          Operation.new(id: id.dup.freeze, name: name&.dup&.freeze, body: body.dup.freeze, document: parse(label(index, id), body)).freeze
        end

        def parse(label, body)
          GraphQL.parse(body)
        rescue GraphQL::ParseError
          raise ConfigurationError, "operation #{label} does not parse"
        end

        # The id names the operation in errors only when it looks like an id; otherwise it may be query text.
        def label(index, id)
          id.match?(ID_LIKE) ? id : "at entry #{index}"
        end

        def unknown_format
          "unknown manifest format: expected Apollo's persisted query manifest or Relay's persisted output"
        end
      end
    end
  end
end
