# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # What one store round trip answered: the sealed entry (`blob`, nil on a miss), the keyed tag digests stored
      # beside it, the purge `marks` of those tags (digest => seq), the store's purge sequence `seq` and `epoch`, and
      # the store clock `now` in Integer milliseconds, which becomes the run's `lookup_at`.
      Lookup = Data.define(:blob, :tags, :marks, :seq, :epoch, :now) do
        def self.miss(seq:, epoch:, now:)
          new(blob: nil, tags: [], marks: {}, seq: seq, epoch: epoch, now: now)
        end

        def initialize(blob:, tags:, marks:, seq:, epoch:, now:)
          raise ArgumentError, "Lookup blob: must be a String or nil" unless blob.nil? || blob.is_a?(String)
          raise ArgumentError, "Lookup tags: must be an Array of Strings" unless tags.is_a?(Array) && tags.all?(String)
          raise ArgumentError, "Lookup marks: must be a Hash of String => Integer" unless marks.is_a?(Hash) && marks.all? { |tag, mark| tag.is_a?(String) && mark.is_a?(Integer) }
          raise ArgumentError, "Lookup seq: must be a non-negative Integer" unless seq.is_a?(Integer) && seq >= 0
          raise ArgumentError, "Lookup epoch: must be a non-empty String" unless epoch.is_a?(String) && !epoch.empty?
          raise ArgumentError, "Lookup now: must be Integer milliseconds" unless now.is_a?(Integer) && now >= 0

          super(blob: blob&.dup&.freeze, tags: tags.map { |tag| tag.dup.freeze }.freeze, marks: marks.dup.freeze, seq: seq, epoch: epoch.dup.freeze, now: now)
        end

        def found?
          !blob.nil?
        end

        def inspect = "#<#{self.class.name} found=#{found?} seq=#{seq}>"
        alias_method :to_s, :inspect
      end
    end
  end
end
