# frozen_string_literal: true

require "securerandom"

module GraphQL
  module Armory
    module RateLimits
      # Lets each client run at most `limit` operations at the same time:
      #
      #   use GraphQL::Armory::RateLimits::Concurrency, store: GraphQL::Armory::RateLimits::MemoryStore.new,
      #     limit: 5, soft: false
      #
      # A query analyzer takes a slot before the operation runs, or refuses it before any field resolves; a trace
      # releases every slot its multiplex took when the multiplex ends, even when it raises. A slot a crashed
      # process never released expires after `stale_after` seconds. Soft mode (the default) records but refuses
      # nothing. What happened is in `context[:rate_limit_concurrency]`.
      class Concurrency
        CONTEXT_KEY = :rate_limit_concurrency
        NAMESPACE = :graphql_armory

        def self.use(schema, store:, limit:, stale_after: 60, soft: true, key: nil, on_store_error: nil, sinks: [])
          concurrency = build(store: store, limit: limit, stale_after: stale_after, soft: soft, key: key, on_store_error: on_store_error, sinks: sinks)
          schema.query_analyzer(Class.new(Analyzer) { define_method(:concurrency) { concurrency } })
          schema.trace_with(Release)
        end

        # Wires the app's store with `use`'s defaults (soft mode); `use` goes through here.
        def self.build(store:, limit:, stale_after: 60, soft: true, key: nil, on_store_error: nil, sinks: [])
          new(store: store, limit: limit, stale_after: stale_after, soft: soft, key: key, on_store_error: on_store_error, sinks: sinks)
        end

        # `new` is inert: with no store wired it refuses every query. It checks every setting, so no partial
        # configuration lets a query through either.
        def initialize(store: Store::Null.new, limit: 1, stale_after: 60, soft: false, key: nil, on_store_error: nil, sinks: [])
          unless Settings.store_answers?(store, acquire: %i[token limit ttl force], release: %i[token])
            raise ConfigurationError, "store: must answer acquire(key, token:, limit:, ttl:, force:) and release(key, token:), like a MemoryStore"
          end

          @store = store
          @limit = Settings.wired_limit(limit, store)
          @stale_after = Settings.seconds(:stale_after, stale_after)
          @soft = Settings.wired_soft(soft, store)
          @key = Settings.key_reader(key)
          @on_store_error = Settings.store_error_handler(on_store_error, limiter: :concurrency, sinks: sinks)
        end

        # Takes a slot for the query: the refusal when none is free, or nil to let it run.
        def call(query)
          unless query.current_trace.is_a?(Release)
            raise ConfigurationError, "this query runs with its own trace (context[:trace]), so Concurrency could never release its slot: remove context[:trace] or add trace_with to that trace"
          end

          key = Settings.key_for(@key, query)
          return call_several(query, key) if key.is_a?(Array)

          limit = Settings.limit_for(@limit, key, query)
          if limit.nil?
            record(query, key: key, limit: nil, active: nil, limited: false)
            return nil
          end

          token = SecureRandom.hex(16)
          answer = begin
            @store.acquire(key, token: token, limit: limit, ttl: @stale_after, force: @soft)
          rescue StandardError => error
            @on_store_error.call(error, query)
            return nil
          end
          acquired, active = Settings.checked(answer, :acquire, "the Integer slots held")

          # Per query, not in the context hash: queries of a multiplex may share one hash.
          slots_of(query) << [self, key, token] if acquired || @soft
          record(query, key: key, limit: limit, active: active, limited: !acquired)
          refusal(limit, active) unless acquired || @soft
        end

        def release(query, key, token)
          @store.release(key, token: token)
        rescue StandardError => error
          @on_store_error.call(error, query)
        end

        # Gives every slot back, even if one release raises (an on_store_error that raises); the first such error is
        # raised afterwards.
        def self.release_all(query, slots)
          failure = nil
          slots.each do |concurrency, key, token|
            concurrency.release(query, key, token)
          rescue StandardError => error
            failure ||= error
          end
          raise failure if failure
        end

        private

        def slots_of(query)
          query.context.namespace(NAMESPACE)[:concurrency_slots] ||= []
        end

        # Takes a slot per key, in order. A refusal gives back what this query took here, at once: a multiplex can run on
        # for long. Each slot is listed as it is taken, so a raise later on still lets `Release` give it back.
        def call_several(query, keys)
          limits = Settings.limits_for(@limit, keys, query)
          if limits.empty?
            record(query, key: keys.first, limit: nil, active: nil, limited: false, keys: [])
            return nil
          end

          taken = []
          held = limits.map do |key, limit|
            token = SecureRandom.hex(16)
            answer = begin
              @store.acquire(key, token: token, limit: limit, ttl: @stale_after, force: @soft)
            rescue StandardError => error
              @on_store_error.call(error, query)
              return nil
            end
            acquired, active = Settings.checked(answer, :acquire, "the Integer slots held")
            if acquired || @soft
              slot = [self, key, token]
              taken << slot
              slots_of(query) << slot
            end
            { key: key, limit: limit, active: active, acquired: acquired }
          end
          settle_several(query, held, taken)
        end

        def settle_several(query, held, taken)
          full = held.find { |slot| !slot[:acquired] }
          binding = full || held.max_by { |slot| slot[:active] / slot[:limit].to_f }
          record(query, key: binding[:key], limit: binding[:limit], active: binding[:active], limited: !full.nil?,
                        keys: held.map { |slot| slot.slice(:key, :limit, :active) })
          return unless full && !@soft

          slots_of(query).reject! { |slot| taken.include?(slot) }
          self.class.release_all(query, taken)
          refusal(full[:limit], full[:active])
        end

        def record(query, **info)
          query.context[CONTEXT_KEY] = { **info.slice(:key, :limit, :active), soft: @soft, limited: info[:limited], **info.slice(:keys) }
        end

        def refusal(limit, active)
          GraphQL::AnalysisError.new(
            "Too many operations at the same time: #{active} are already running for this client (limit #{limit}). Retry when one finishes.",
            extensions: { "code" => "RATE_LIMITED", "limit" => limit, "active" => active }
          )
        end

        # Takes the slot during analysis, before anything runs.
        class Analyzer < GraphQL::Analysis::Analyzer
          def result
            concurrency.(query)
          end
        end

        # Releases the slots of every query in the multiplex once it is done, whatever happened. Analysis runs
        # inside `execute_multiplex` on both engines, so every slot taken is released here.
        module Release
          def execute_multiplex(multiplex:)
            super
          ensure
            # Every slot is released even if one release raises (an on_store_error that raises); the first such
            # error is raised afterwards.
            failure = nil
            multiplex.queries.each do |query|
              slots = query.context.namespace(NAMESPACE).delete(:concurrency_slots)
              next unless slots

              begin
                Concurrency.release_all(query, slots)
              rescue StandardError => error
                failure ||= error
              end
            end
            raise failure if failure
          end
        end
      end
    end
  end
end
