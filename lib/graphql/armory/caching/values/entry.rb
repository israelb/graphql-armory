# frozen_string_literal: true

require "json"

module GraphQL
  module Armory
    module Caching
      # A stored answer. Serialized as JSON, never Marshal:
      #
      #   { "v": 2, "k": key_hex, "data": {...}, "at": stored_at_ms, "ttl": seconds, "scope": "public|viewer",
      #     "seq": S0, "epoch": "...", "tags": [tag digests], "cost": n | null }
      #
      # `stored_at` is the store clock at the lookup that preceded the run, in Integer milliseconds; the entry
      # expires at `stored_at + ttl * 1000`.
      class Entry
        FORMAT = 2
        SCOPES = { "public" => :public, "viewer" => :viewer }.freeze

        # An entry that must not be served: `reason` is one of REASONS. The query runs instead.
        class Rejected < Error
          REASONS = %i[format key expired purged epoch tags decrypt].freeze

          attr_reader :reason

          def initialize(reason)
            raise ArgumentError, "Entry::Rejected reason must be one of #{REASONS.inspect}, got #{reason.inspect}" unless REASONS.include?(reason)

            @reason = reason
            super("cache entry rejected: #{reason}")
          end
        end

        attr_reader :key, :data, :stored_at, :ttl, :scope, :seq, :epoch, :tags, :cost

        # `data` is copied and deep-frozen, unless `copy: false`: then it is used as given, for a tree nobody else
        # holds or changes while the entry is in use (one `parse` just built, or a run's answer sealed at once). A
        # hit answers the parsed tree itself, unfrozen like a run's, without copying it.
        def initialize(key:, data:, stored_at:, ttl:, scope:, seq:, epoch:, tags:, cost: nil, copy: true)
          raise ArgumentError, "Entry key: must be 64 hex characters" unless key.is_a?(String) && Key::HEX.match?(key)
          raise ArgumentError, "Entry data: must be a Hash with String keys" unless data.is_a?(Hash) && data.keys.all?(String)
          raise ArgumentError, "Entry stored_at: must be Integer milliseconds" unless stored_at.is_a?(Integer) && stored_at >= 0
          raise ArgumentError, "Entry ttl: must be a positive Integer" unless ttl.is_a?(Integer) && ttl.positive?
          raise ArgumentError, "Entry scope: must be :viewer or :public" unless Declaration::SCOPES.include?(scope)
          raise ArgumentError, "Entry seq: must be a non-negative Integer" unless seq.is_a?(Integer) && seq >= 0
          raise ArgumentError, "Entry epoch: must be a non-empty String" unless epoch.is_a?(String) && !epoch.empty?
          raise ArgumentError, "Entry tags: must be an Array of hex digests" unless tags.is_a?(Array) && tags.all? { |tag| tag.is_a?(String) && Key::HEX.match?(tag) }
          raise ArgumentError, "Entry cost: must be a non-negative Integer or nil" unless cost.nil? || (cost.is_a?(Integer) && cost >= 0)

          @key = key.dup.freeze
          @data = copy ? deep_freeze(data) : data
          @stored_at = stored_at
          @ttl = ttl
          @scope = scope
          @seq = seq
          @epoch = epoch.dup.freeze
          @tags = tags.map { |tag| tag.dup.freeze }.uniq.sort.freeze
          @cost = cost
          freeze
        end

        # Parses what `to_json_string` wrote. Raises `Rejected` (:format) on anything else. The data is the tree this
        # parse built, owned by the entry, so it is not copied.
        def self.parse(string)
          raise Rejected, :format unless string.is_a?(String)

          hash = JSON.parse(string)
          raise Rejected, :format unless hash.is_a?(Hash) && hash["v"] == FORMAT && SCOPES.key?(hash["scope"])

          new(key: hash["k"], data: hash["data"], stored_at: hash["at"], ttl: hash["ttl"], scope: SCOPES.fetch(hash["scope"]),
              seq: hash["seq"], epoch: hash["epoch"], tags: hash["tags"], cost: hash["cost"], copy: false)
        rescue JSON::ParserError, ArgumentError
          raise Rejected, :format
        end

        def to_json_string
          JSON.generate({ "v" => FORMAT, "k" => key, "data" => data, "at" => stored_at, "ttl" => ttl, "scope" => scope.to_s,
                          "seq" => seq, "epoch" => epoch, "tags" => tags, "cost" => cost })
        end

        def expires_at
          stored_at + (ttl * 1000)
        end

        def expired?(now)
          now >= expires_at
        end

        # Whole seconds since it was stored, for `context[:response_cache]`.
        def age(now)
          [(now - stored_at) / 1000, 0].max
        end

        def inspect = "#<#{self.class.name} scope=#{scope.inspect} ttl=#{ttl}>"

        private

        def deep_freeze(value)
          case value
          when Hash then value.to_h { |key, inner| [key.frozen? ? key : key.dup.freeze, deep_freeze(inner)] }.freeze
          when Array then value.map { |inner| deep_freeze(inner) }.freeze
          when String then value.frozen? ? value : value.dup.freeze
          else value
          end
        end
      end
    end
  end
end
