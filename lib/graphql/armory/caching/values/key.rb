# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # A request's cache key: `digest`, the keyed hex digest of every key component (built only by the Keyer, so no
      # component is ever in clear), its `scope`, and `viewer_tag`, the keyed digest of the viewer's purge tag for a
      # `:viewer` key (nil for `:public`).
      class Key
        HEX = /\A\h{64}\z/

        attr_reader :digest, :scope, :viewer_tag

        def initialize(digest:, scope:, viewer_tag: nil)
          raise ArgumentError, "Key digest: must be 64 hex characters" unless digest.is_a?(String) && HEX.match?(digest)
          raise ArgumentError, "Key scope: must be :viewer or :public, got #{scope.inspect}" unless Declaration::SCOPES.include?(scope)
          raise ArgumentError, "Key viewer_tag: must be 64 hex characters or nil" unless viewer_tag.nil? || (viewer_tag.is_a?(String) && HEX.match?(viewer_tag))
          raise ArgumentError, "a :public Key has no viewer_tag" if scope == :public && viewer_tag

          @digest = digest.dup.freeze
          @scope = scope
          @viewer_tag = viewer_tag&.dup&.freeze
          freeze
        end

        def ==(other)
          other.is_a?(Key) && other.digest == digest && other.scope == scope && other.viewer_tag == viewer_tag
        end
        alias eql? ==

        def hash = [self.class, digest, scope, viewer_tag].hash

        # Never the digest: a log line must not let anyone look an entry up.
        def inspect = "#<#{self.class.name} scope=#{scope.inspect}>"
        alias to_s inspect
      end
    end
  end
end
