# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      # Subscriptions kept in this process's memory: for tests, development and single-process servers. Each process
      # keeps its own, so a trigger reaches only the subscribers written in the process that runs it; share a
      # `RedisStore` between processes in production.
      #
      #   store = GraphQL::Armory::Subscriptions::MemoryStore.new
      #
      # Keeps the store contract (`Store`) under one mutex, so every operation is atomic. It has no clock of its own:
      # every time-dependent call takes the caller's `now:` (Integer ms), as in `RedisStore`. `read` has no `now:`, so
      # an expired record stays readable (and counts as taken for `write`'s `:exists`) until `delete` or `cleanup`
      # removes it; the core checks `expires_at` in the record itself. Call `cleanup` periodically to bound memory.
      class MemoryStore
        Stored = Struct.new(:sealed, :topics, :viewer, :expires_at)
        private_constant :Stored

        def initialize
          @records = {}
          @topics = Hash.new { |hash, key| hash[key] = {} }
          @viewers = Hash.new { |hash, key| hash[key] = {} }
          @mutex = Mutex.new
        end

        def write(id, sealed, topics:, viewer:, expires_at:, viewer_cap:, topic_cap:, now:)
          check_write!(id, sealed, topics, viewer, expires_at, viewer_cap, topic_cap, now)
          topics = topics.uniq.map { |topic| topic.dup.freeze }

          @mutex.synchronize do
            next :exists if @records.key?(id)
            next :viewer_cap if viewer_cap && live_count(@viewers.fetch(viewer, {}), now) >= viewer_cap
            next :topic_cap if topic_cap && topics.any? { |topic| live_count(@topics.fetch(topic, {}), now) >= topic_cap }

            id = id.dup.freeze
            viewer = viewer.dup.freeze
            @records[id] = Stored.new(sealed.dup.freeze, topics.freeze, viewer, expires_at)
            @viewers[viewer][id] = true
            topics.each { |topic| @topics[topic][id] = true }
            :ok
          end
        end

        def read(id)
          @mutex.synchronize { @records[id]&.sealed }
        end

        def ids(topic, now:)
          check_now!(now)
          @mutex.synchronize { live_ids(@topics.fetch(topic, {}), now) }
        end

        def delete(id)
          @mutex.synchronize { remove(id) }
        end

        def count(viewer, now:)
          check_now!(now)
          @mutex.synchronize { live_count(@viewers.fetch(viewer, {}), now) }
        end

        def cleanup(now:)
          check_now!(now)
          @mutex.synchronize do
            expired = @records.select { |_id, stored| stored.expires_at <= now }.keys
            expired.each { |id| remove(id) }
            expired.size
          end
        end

        def inspect = "#<#{self.class.name} records=#{@records.size}>"
        alias_method :to_s, :inspect

        private

        def live_ids(index, now) = index.keys.select { |id| @records[id].expires_at > now }

        def live_count(index, now) = index.count { |id, _| @records[id].expires_at > now }

        # Removes the record and its entries in the indexes, dropping an index nobody is left in.
        def remove(id)
          stored = @records.delete(id) or return false

          drop(@viewers, stored.viewer, id)
          stored.topics.each { |topic| drop(@topics, topic, id) }
          true
        end

        def drop(indexes, key, id)
          indexes[key].delete(id)
          indexes.delete(key) if indexes[key].empty?
        end

        # A caller's bug, never a store answer: the core must hand every store the same shapes.
        def check_write!(id, sealed, topics, viewer, expires_at, viewer_cap, topic_cap, now)
          check_now!(now)
          raise ArgumentError, "id must be a non-empty String" unless id.is_a?(String) && !id.empty?
          raise ArgumentError, "sealed must be a String" unless sealed.is_a?(String)
          raise ArgumentError, "topics: must be a non-empty Array of non-empty Strings" unless topics.is_a?(Array) && !topics.empty? && topics.all? { |topic| topic.is_a?(String) && !topic.empty? }
          raise ArgumentError, "viewer: must be a non-empty String" unless viewer.is_a?(String) && !viewer.empty?
          raise ArgumentError, "expires_at: must be Integer milliseconds after now:" unless expires_at.is_a?(Integer) && expires_at > now

          [viewer_cap, topic_cap].each do |cap|
            raise ArgumentError, "a cap must be nil or a positive Integer, got #{cap.inspect}" unless cap.nil? || (cap.is_a?(Integer) && cap.positive?)
          end
        end

        def check_now!(now)
          raise ArgumentError, "now: must be Integer milliseconds" unless now.is_a?(Integer)
        end
      end
    end
  end
end
