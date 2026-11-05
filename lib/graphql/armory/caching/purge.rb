# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # Purges answers by the keyed digests of their tags (docs/response-caching.md "Purging"):
      #
      #   Purge.(AppSchema, all: true)                 # everything: the store replaces its epoch
      #   Purge.(AppSchema, viewer: user)              # a principal's answers, by the [class, id] the key uses
      #   Purge.(AppSchema, viewer: :anonymous)        # the shared anonymous answers
      #   Purge.(AppSchema, tag: "pricing")            # a declared custom tag
      #   Purge.(AppSchema, type: Types::Invoice)      # best effort: answers whose selection can return that type
      #
      # A store error raises `PurgeError`: a purge that silently failed serves stale data until the TTL. The signal
      # `:cache_purged` says which kind, never the tag or the viewer.
      class Purge
        def self.call(schema, all: false, viewer: nil, tag: nil, type: nil)
          build(schema).(all: all, viewer: viewer, tag: tag, type: type)
        end

        # From the schema's installed settings, so the tags are digested with the digester the gate stored them with.
        def self.build(schema)
          settings = schema.respond_to?(:armory_caching) ? schema.armory_caching : nil
          raise ConfigurationError, "#{schema} does not use GraphQL::Armory::Caching: there is nothing to purge" unless settings

          new(store: settings.store, digester: settings.digester, viewer_id: settings.viewer_id, telemetry: settings.telemetry)
        end

        # `new` is inert: it purges the null store, which holds nothing.
        def initialize(store: Store::Null.new, digester: Digester.new, viewer_id: Integration::Settings::DEFAULT_VIEWER_ID, telemetry: Telemetry.new)
          @store = store
          @digester = digester
          @viewer_id = viewer_id
          @telemetry = telemetry
        end

        def call(all: false, viewer: nil, tag: nil, type: nil)
          raise ArgumentError, "all: must be true or false, got #{all.inspect}" unless [true, false].include?(all)

          given = { all: all || nil, viewer: viewer, tag: tag, type: type }.compact
          raise ArgumentError, "purge takes exactly one of all: true, viewer:, tag: or type:" unless given.size == 1

          kind, value = given.first
          if kind == :all
            perform { @store.purge_all }
          else
            digests = [@digester.(tag_for(kind, value))]
            perform { @store.purge(digests) }
          end
          @telemetry.record(:cache_purged, kind: kind, **(kind == :type ? { type: value.graphql_name } : {}))
          nil
        end

        def inspect = "#<#{self.class.name}>"

        private

        def tag_for(kind, value)
          case kind
          when :tag then Tags.custom(value)
          when :type then type_tag(value)
          else viewer_tag(value)
          end
        end

        def type_tag(type)
          raise ArgumentError, "type: takes a GraphQL type class, like Types::Invoice" unless type.respond_to?(:graphql_name) && !type.is_a?(String)

          Tags.type(type.graphql_name)
        end

        # The same [class name, id] the key's viewer component uses, so a principal's answers are reached.
        def viewer_tag(principal)
          return Tags::ANONYMOUS if principal == :anonymous
          raise ArgumentError, "viewer: takes a principal or :anonymous, got #{principal.inspect}" if principal.is_a?(Symbol)

          class_name = principal.class.name
          raise ConfigurationError, "viewer: a principal of an anonymous class cannot be identified: give its class a name" if class_name.nil? || class_name.empty?

          id = @viewer_id.call(principal)
          unless id.is_a?(Integer) || (id.is_a?(String) && !id.empty?)
            raise ConfigurationError, "viewer_id: must answer a non-empty String or an Integer for a #{class_name}, got a #{id.class}"
          end

          Tags.viewer(class_name, id)
        end

        # The error's class only: a store's message may hold its URL and credentials.
        def perform
          yield
        rescue StandardError => error
          @telemetry.record(:cache_store_failed, operation: :purge, error: error.class.name)
          raise PurgeError, "the cache store failed to purge (#{error.class.name}): the answers may still be served, retry the purge"
        end
      end
    end
  end
end
