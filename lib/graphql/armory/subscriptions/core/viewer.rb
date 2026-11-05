# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      class Core < GraphQL::Subscriptions
        # The viewer could not be loaded back for a delivery (its `load` raised, or the context it built does not dump
        # to the stored id): the subscription ends.
        class ViewerGone < StandardError; end

        # Who the subscriber is, across processes: the `viewer:` option (`Bound`), or `anonymous:` with `cap_key:`
        # (`Anonymous`). `Null` is what an inert backend holds: it refuses every subscription.
        module Viewer
          KEYS = %i[dump load sets].freeze

          def self.build(viewer:, anonymous:, cap_key:)
            return anonymous(anonymous, cap_key) if viewer.nil?

            unless anonymous.nil? && cap_key.nil?
              raise ConfigurationError, "anonymous: and cap_key: are for viewer-independent subscriptions only: give viewer: or anonymous:, not both"
            end
            raise ConfigurationError, "viewer: must be a Hash with dump:, load: and optionally sets:, got #{viewer.class}" unless viewer.is_a?(Hash)

            unknown = viewer.keys - KEYS
            raise ConfigurationError, "viewer: unknown keys #{unknown.inspect}: it takes #{KEYS.inspect}" unless unknown.empty?

            dump = viewer[:dump]
            load = viewer[:load]
            raise ConfigurationError, "viewer: dump: must be a callable taking the context and answering the viewer's id String" unless dump.respond_to?(:call)
            raise ConfigurationError, "viewer: load: must be a callable taking the id and the delivery's context Hash" unless load.respond_to?(:call)

            sets = viewer.fetch(:sets, [])
            raise ConfigurationError, "viewer: sets: must be an Array of the context keys load: sets (Symbols)" unless sets.is_a?(Array) && sets.all?(Symbol)

            Bound.new(dump: dump, load: load, sets: sets)
          end

          def self.anonymous(reason, cap_key)
            if reason.nil?
              raise ConfigurationError, "viewer: is required (who the subscriber is, so a delivery runs as them and a channel is theirs only), " \
                                        "or anonymous: \"why every subscription is viewer-independent\" with cap_key:"
            end
            raise ConfigurationError, "anonymous: must be a non-empty String saying why no subscription depends on the viewer" unless reason.is_a?(String) && !reason.strip.empty?
            raise ConfigurationError, "anonymous: needs cap_key: (a callable taking the context, answering what max_per_viewer counts by, such as the client IP)" unless cap_key.respond_to?(:call)

            Anonymous.new(reason: reason, cap_key: cap_key)
          end
          private_class_method :anonymous

          # A configured viewer: `dump` answers the subscriber's id String from a context, `load` puts the viewer back
          # into a delivery's context Hash, `sets` names the context keys `load` sets.
          class Bound
            attr_reader :sets

            def initialize(dump:, load:, sets: [])
              @dump = dump
              @load = load
              @sets = sets.dup.freeze
              freeze
            end

            def anonymous? = false
            def reason = nil

            # The viewer's id: a non-empty String, or RefusedError (a dump that raises or answers anything else).
            def id(context)
              dumped = begin
                @dump.call(context)
              rescue StandardError
                raise RefusedError.new("the viewer could not be identified", reason: :viewer)
              end
              raise RefusedError.new("the viewer could not be identified", reason: :viewer) unless dumped.is_a?(String) && !dumped.empty?

              dumped
            end

            # What max_per_viewer counts by.
            def cap_subject(context)
              id(context)
            end

            # Loads `id` into `values`, then checks it dumps back to the same id: a viewer that is gone, or a load that
            # left someone else, raises ViewerGone.
            def load(id, values)
              begin
                @load.call(id, values)
              rescue StandardError
                raise ViewerGone
              end
              loaded = begin
                id(values)
              rescue RefusedError
                raise ViewerGone
              end
              raise ViewerGone unless loaded == id

              values
            end

            def inspect = "#<#{self.class.name} sets=#{sets.inspect}>"
          end

          # No viewer: every subscription is viewer-independent; `cap_key` answers what max_per_viewer counts by.
          class Anonymous
            attr_reader :reason

            def initialize(reason:, cap_key:)
              @reason = reason.dup.freeze
              @cap_key = cap_key
              freeze
            end

            def anonymous? = true
            def sets = [].freeze
            def id(_context) = nil

            def cap_subject(context)
              key = begin
                @cap_key.call(context)
              rescue StandardError
                raise RefusedError.new("the client could not be identified", reason: :cap_key)
              end
              raise RefusedError.new("the client could not be identified", reason: :cap_key) unless key.is_a?(String) && !key.empty?

              key
            end

            def load(_id, values) = values

            def inspect = "#<#{self.class.name}>"
          end

          # The viewer of an inert backend: identifies no one, so every subscription is refused.
          class Null
            def anonymous? = false
            def reason = nil
            def sets = [].freeze

            def id(_context)
              raise RefusedError.new("no viewer configured", reason: :viewer)
            end

            def cap_subject(context) = id(context)

            def load(_id, _values)
              raise ViewerGone
            end
          end
        end
      end
    end
  end
end
